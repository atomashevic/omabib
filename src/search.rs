use crate::db::{Library, clip, normalize, normalize_doi, text};
use anyhow::{Result, ensure};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};
use std::{collections::HashSet, path::Path};
use symspell::Verbosity;

#[derive(Debug)]
struct Term {
    value: String,
    phrase: bool,
}
fn terms(q: &str) -> Vec<Term> {
    let mut out = Vec::new();
    let mut buf = String::new();
    let mut quoted = false;
    for c in normalize(q).chars() {
        if c == '"' {
            if !buf.trim().is_empty() {
                out.push(Term {
                    value: buf.trim().into(),
                    phrase: quoted,
                });
                buf.clear();
            }
            quoted = !quoted;
        } else if c.is_alphanumeric() || c == '_' {
            buf.push(c);
        } else if quoted {
            buf.push(' ');
        } else if !buf.is_empty() {
            out.push(Term {
                value: std::mem::take(&mut buf),
                phrase: false,
            });
        }
    }
    if !buf.trim().is_empty() {
        out.push(Term {
            value: buf.trim().into(),
            phrase: quoted,
        });
    }
    out.truncate(16);
    out
}
fn expression(ts: &[Term], prefix: bool) -> String {
    ts.iter()
        .enumerate()
        .map(|(i, t)| {
            format!(
                "\"{}\"{}",
                t.value.replace('"', "\"\""),
                if prefix && i == ts.len() - 1 && !t.phrase {
                    "*"
                } else {
                    ""
                }
            )
        })
        .collect::<Vec<_>>()
        .join(" AND ")
}
const FILTER: &str = "(?2 IS NULL OR r.year=?2) AND (?3 IS NULL OR r.entry_type=?3) AND (?4 IS NULL OR r.id IN (SELECT ref_id FROM associations WHERE project_id=?4)) AND (?5='' OR d.authors LIKE '%'||?5||'%') AND (?6='' OR EXISTS(SELECT 1 FROM associations aa,json_each(aa.labels) j WHERE aa.ref_id=r.id AND (?7 IS NULL OR aa.project_id=?7) AND j.value=?6) OR EXISTS(SELECT 1 FROM notes nn,json_each(nn.labels) j WHERE nn.ref_id=r.id AND (?8 OR nn.project_id IS NULL OR nn.project_id=?7) AND j.value=?6)) AND (d.note_id IS NULL OR ?8 OR d.project_id IS NULL OR d.project_id=?7)";
fn optional<'a>(a: &'a Value, k: &str) -> Option<&'a str> {
    a.get(k).and_then(Value::as_str).filter(|s| !s.is_empty())
}
fn run(c: &Connection, a: &Value, table: &str, q: &str, limit: usize) -> Result<Vec<Value>> {
    let all = a["include_other_projects"] == true || optional(a, "project_id").is_none();
    let from = if q.is_empty() {
        "docs d JOIN refs r ON r.id=d.ref_id".into()
    } else {
        format!("{table} JOIN docs d ON d.id={table}.rowid JOIN refs r ON r.id=d.ref_id")
    };
    let condition = if q.is_empty() {
        "d.note_id IS NULL AND ?1=''".into()
    } else {
        format!("{table} MATCH ?1")
    };
    // Bound work before scoring. Broad queries do not require sorting the entire corpus.
    let order = if q.is_empty() {
        "ORDER BY r.citekey"
    } else {
        ""
    };
    let sql = format!(
        "SELECT r.id,r.citekey,r.title,r.authors,r.year,r.entry_type,d.note_id,d.project_id,d.citekey,d.title,d.authors,d.abstract,d.keywords,d.body,EXISTS(SELECT 1 FROM associations aa WHERE aa.ref_id=r.id AND aa.project_id=?7) FROM {from} WHERE {condition} AND {FILTER} {order} LIMIT ?9"
    );
    let mut statement = c.prepare_cached(&sql)?;
    let tokens = terms(text(a, "query"));
    let rows=statement.query_map(params![q,optional(a,"year"),optional(a,"entry_type"),optional(a,"project_filter"),normalize(text(a,"author")),text(a,"label"),optional(a,"project_id"),all,limit as i64],|r|{
  let mut best=String::new();let mut best_weight=0.0;let mut score=0.0;
  for (column,weight) in [(8,20.0),(9,12.0),(10,9.0),(11,2.0),(12,4.0),(13,1.0)] {
   let field:String=r.get(column)?;
   let matched=tokens.iter().filter(|t|field.contains(&t.value)).count() as f64;
   let weighted=matched*weight;score+=weighted;
   if weighted>best_weight {best_weight=weighted;best=field;}
  }
  let position=tokens.iter().filter_map(|t|best.find(&t.value)).min().unwrap_or(0);
  let char_position=best[..position].chars().count();let snippet:String=best.chars().skip(char_position.saturating_sub(40)).take(200).collect();
  Ok(json!({"id":r.get::<_,String>(0)?,"citekey":r.get::<_,String>(1)?,"title":r.get::<_,String>(2)?,"authors":clip(&r.get::<_,String>(3)?,180),"year":r.get::<_,String>(4)?,"entry_type":r.get::<_,String>(5)?,"note_id":r.get::<_,Option<String>>(6)?,"project_id":r.get::<_,Option<String>>(7)?,"snippet":snippet,"score":-score,"in_project":r.get::<_,bool>(14)?}))
 })?;
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
}

pub fn search(lib: &Library, a: &Value) -> Result<Value> {
    search_cancellable(lib, a, None)
}
pub fn search_cancellable(
    lib: &Library,
    a: &Value,
    cancel: Option<(std::sync::Arc<std::sync::atomic::AtomicUsize>, usize)>,
) -> Result<Value> {
    let start = std::time::Instant::now();
    let c = lib.read()?;
    if let Some((generation, ticket)) = cancel {
        c.progress_handler(
            1000,
            Some(move || generation.load(std::sync::atomic::Ordering::Relaxed) != ticket),
        )?;
    }
    let q = text(a, "query");
    ensure!(q.len() <= 2048, "Query is too long");
    let limit = a
        .get("limit")
        .and_then(Value::as_u64)
        .unwrap_or(8)
        .clamp(1, 25) as usize;
    let offset = a.get("cursor").and_then(Value::as_u64).unwrap_or(0) as usize;
    ensure!(offset <= 10000, "Cursor exceeds 10000; narrow the query");
    let cap = if q.trim().is_empty() {
        offset + limit + 1
    } else {
        256
    };
    let ts = terms(q);
    let mut hits = Vec::new();
    let mut corrected = Vec::<String>::new();
    if !q.trim().is_empty() {
        let mut exact = a.clone();
        exact["query"] = json!(q);
        // Exact candidates still pass all scope and field filters.
        let mut es = c.prepare("SELECT citekey FROM refs WHERE citekey=? OR doi=?")?;
        let keys = es
            .query_map(params![q.trim(), normalize_doi(q)], |r| {
                r.get::<_, String>(0)
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        for key in keys {
            for mut hit in run(
                &c,
                a,
                "search_fts",
                &format!("citekey : \"{}\"", normalize(&key).replace('"', "\"\"")),
                cap,
            )? {
                if text(&hit, "citekey") == key {
                    hit["match_type"] = json!("exact");
                    hits.push(hit);
                }
            }
        }
    }
    let query = expression(&ts, true);
    if !query.is_empty() {
        let focused = format!("{{citekey title authors}} : ({query})");
        for mut h in run(&c, a, "search_fts", &focused, cap)? {
            h["match_type"] = json!("keyword");
            hits.push(h);
        }
    }
    if !query.is_empty() || q.trim().is_empty() {
        for mut h in run(&c, a, "search_fts", &query, cap)? {
            h["match_type"] = json!("keyword");
            hits.push(h);
        }
    }
    let unique = |xs: &Vec<Value>| {
        xs.iter()
            .map(|x| text(x, "id"))
            .collect::<HashSet<_>>()
            .len()
    };
    if unique(&hits) < offset + limit + 1
        && !ts.is_empty()
        && ts.iter().all(|t| t.value.chars().count() >= 3)
    {
        for mut h in run(&c, a, "substring_fts", &expression(&ts, false), cap)? {
            h["match_type"] = json!("substring");
            hits.push(h);
        }
    }
    if lib.spell_ready.load(std::sync::atomic::Ordering::Acquire)
        && unique(&hits) < offset + limit + 1
        && !ts.is_empty()
    {
        let spell = lib.spell.read().unwrap();
        let mut parts = Vec::new();
        let mut changed = false;
        for t in &ts {
            let mut variants = vec![format!("\"{}\"", t.value)];
            if !t.phrase && t.value.chars().count() >= 4 {
                for suggestion in spell.lookup(&t.value, Verbosity::Closest, 1).iter().take(4) {
                    if suggestion.term != t.value {
                        changed = true;
                        corrected.push(suggestion.term.to_string());
                        variants.push(format!("\"{}\"", suggestion.term.replace('"', "\"\"")));
                    }
                }
            }
            parts.push(format!("({})", variants.join(" OR ")));
        }
        drop(spell);
        if changed {
            for mut h in run(&c, a, "search_fts", &parts.join(" AND "), cap)? {
                h["match_type"] = json!("typo");
                hits.push(h);
            }
        }
    }
    // Match stages stay ordered; project membership modestly boosts within each stage.
    hits.sort_by(|a, b| {
        let stage = |v: &Value| match text(v, "match_type") {
            "exact" => 0,
            "keyword" => 1,
            "substring" => 2,
            _ => 3,
        };
        stage(a)
            .cmp(&stage(b))
            .then_with(|| {
                let score = |v: &Value| {
                    v["score"].as_f64().unwrap_or(0.0)
                        * if v["in_project"] == true { 1.1 } else { 1.0 }
                };
                score(a).total_cmp(&score(b))
            })
            .then_with(|| text(a, "citekey").cmp(text(b, "citekey")))
    });
    let mut grouped: Vec<Value> = Vec::new();
    for mut hit in hits {
        let note_match = if !hit["note_id"].is_null() {
            let pid = hit["project_id"].clone();
            let name = if let Some(p) = pid.as_str() {
                c.query_row("SELECT name FROM projects WHERE id=?", [p], |r| {
                    r.get::<_, String>(0)
                })
                .ok()
            } else {
                None
            };
            Some(
                json!({"note_id":hit["note_id"],"project_id":pid,"project_name":name,"snippet":hit["snippet"]}),
            )
        } else {
            None
        };
        if let Some(existing) = grouped.iter_mut().find(|x| x["id"] == hit["id"]) {
            if let Some(n) = note_match {
                let ns = existing["note_matches"].as_array_mut().unwrap();
                if ns.len() < 2 && !ns.iter().any(|x| x["note_id"] == n["note_id"]) {
                    ns.push(n);
                }
            }
            continue;
        }
        hit["note_matches"] = json!(note_match.into_iter().collect::<Vec<_>>());
        for k in ["note_id", "project_id", "score"] {
            hit.as_object_mut().unwrap().remove(k);
        }
        grouped.push(hit);
    }
    let candidate_limited = !q.trim().is_empty() && grouped.len() >= cap / 4;
    let more = grouped.len() > offset + limit;
    let mut result = grouped
        .into_iter()
        .skip(offset)
        .take(limit)
        .collect::<Vec<_>>();
    for h in &mut result {
        let id = text(h, "id").to_string();
        h["note_count"] = json!(c.query_row(
            "SELECT count(*) FROM notes WHERE ref_id=?",
            [&id],
            |r| r.get::<_, i64>(0)
        )?);
        h["has_abstract"] = json!(
            c.query_row("SELECT abstract<>'' FROM refs WHERE id=?", [&id], |r| r
                .get::<_, bool>(0))
                .unwrap_or(false)
        );
        let pdf_path: Option<String> = c
            .query_row(
                "SELECT path FROM attachments WHERE ref_id=? AND file_type='pdf' ORDER BY rowid",
                [&id],
                |r| r.get(0),
            )
            .optional()?;
        h["has_pdf"] = json!(pdf_path.is_some_and(|p| Path::new(&p).is_file()));
    }
    Ok(
        json!({"results":result,"next_cursor":if more{json!(offset+limit)}else{Value::Null},"corrections":corrected,"ranking":"bounded_field_weighted","candidate_limited":candidate_limited,"elapsed_ms":start.elapsed().as_secs_f64()*1000.0}),
    )
}
