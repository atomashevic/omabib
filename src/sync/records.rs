//! Synced records as JSON field maps, read from and written to the library's
//! tables. Local-only columns (revision counters, file paths, image bytes) are
//! left out; `write` fills them in for this computer.
use crate::db::{index_note, insert_doc};
use anyhow::{Context, Result, bail};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Map, Value, json};
use std::collections::HashMap;

/// Parents before children: the order changes are applied in.
pub const KINDS: [&str; 7] = [
    "project",
    "ref",
    "note",
    "assoc",
    "attachment",
    "image",
    "summary",
];

/// Each synced table, its record kind and the columns forming the key.
pub const TABLES: [(&str, &str, &[&str]); 7] = [
    ("projects", "project", &["id"]),
    ("refs", "ref", &["id"]),
    ("notes", "note", &["id"]),
    ("associations", "assoc", &["ref_id", "project_id"]),
    ("attachments", "attachment", &["id"]),
    ("note_images", "image", &["note_id"]),
    ("external_summaries", "summary", &["ref_id"]),
];

/// The prefix a not-yet-downloaded attachment's path carries.
pub const CLOUD_PATH: &str = "omabib-sync:";

fn parsed(s: String) -> Value {
    serde_json::from_str(&s).unwrap_or(Value::Null)
}

fn map(v: Value) -> Map<String, Value> {
    match v {
        Value::Object(m) => m,
        _ => Map::new(),
    }
}

fn s<'a>(r: &'a Map<String, Value>, k: &str) -> &'a str {
    r.get(k).and_then(Value::as_str).unwrap_or("")
}

fn opt(r: &Map<String, Value>, k: &str) -> Option<String> {
    r.get(k).and_then(Value::as_str).map(str::to_owned)
}

fn json_text(r: &Map<String, Value>, k: &str, default: Value) -> String {
    r.get(k)
        .filter(|v| !v.is_null())
        .cloned()
        .unwrap_or(default)
        .to_string()
}

/// The current time in SQLite's `strftime('%Y-%m-%dT%H:%M:%fZ')` form.
pub fn now() -> String {
    let ms = super::clock::now_ms();
    let secs = (ms / 1000) as i64;
    let days = secs.div_euclid(86400);
    let rem = secs.rem_euclid(86400);
    // Civil date from days (inverse of clock::iso_ms).
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}.{:03}Z",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60,
        ms % 1000
    )
}

pub fn split_assoc(key: &str) -> Result<(&str, &str)> {
    key.split_once('|').context("Malformed association key")
}

/// The record's synced fields, or None when it doesn't exist.
pub fn read(c: &Connection, kind: &str, key: &str) -> Result<Option<Map<String, Value>>> {
    let row = match kind {
        "ref" => c
            .query_row(
                "SELECT citekey,entry_type,title,authors,abstract,year,doi,fields,bibtex,source,created_at,updated_at FROM refs WHERE id=?",
                [key],
                |r| {
                    Ok(json!({
                        "citekey": r.get::<_, String>(0)?, "entry_type": r.get::<_, String>(1)?,
                        "title": r.get::<_, String>(2)?, "authors": r.get::<_, String>(3)?,
                        "abstract": r.get::<_, String>(4)?, "year": r.get::<_, String>(5)?,
                        "doi": r.get::<_, Option<String>>(6)?, "fields": parsed(r.get(7)?),
                        "bibtex": r.get::<_, String>(8)?, "source": r.get::<_, String>(9)?,
                        "created_at": r.get::<_, String>(10)?, "updated_at": r.get::<_, String>(11)?,
                    }))
                },
            )
            .optional()?,
        "project" => c
            .query_row(
                "SELECT name,description,roots FROM projects WHERE id=?",
                [key],
                |r| {
                    Ok(json!({"name": r.get::<_, String>(0)?, "description": r.get::<_, String>(1)?,
                        "roots": parsed(r.get(2)?)}))
                },
            )
            .optional()?,
        "assoc" => {
            let (rid, pid) = split_assoc(key)?;
            c.query_row(
                "SELECT labels FROM associations WHERE ref_id=? AND project_id=?",
                [rid, pid],
                |r| Ok(json!({"ref_id": rid, "project_id": pid, "labels": parsed(r.get(0)?)})),
            )
            .optional()?
        }
        "note" => c
            .query_row(
                "SELECT ref_id,project_id,body,labels,evidence,provenance,created_at,updated_at FROM notes WHERE id=?",
                [key],
                |r| {
                    Ok(json!({
                        "ref_id": r.get::<_, String>(0)?, "project_id": r.get::<_, Option<String>>(1)?,
                        "body": r.get::<_, String>(2)?, "labels": parsed(r.get(3)?),
                        "evidence": r.get::<_, Option<String>>(4)?, "provenance": r.get::<_, String>(5)?,
                        "created_at": r.get::<_, Option<String>>(6)?, "updated_at": r.get::<_, Option<String>>(7)?,
                    }))
                },
            )
            .optional()?,
        "attachment" => {
            let row = c
                .query_row(
                    "SELECT ref_id,path,file_type,fingerprint FROM attachments WHERE id=?",
                    [key],
                    |r| {
                        Ok((
                            r.get::<_, String>(0)?,
                            r.get::<_, String>(1)?,
                            r.get::<_, String>(2)?,
                            r.get::<_, Option<String>>(3)?,
                        ))
                    },
                )
                .optional()?;
            row.map(|(rid, path, file_type, fingerprint)| {
                // Older links have no hash yet; a readable PDF gets one now.
                let sha = fingerprint.or_else(|| {
                    (file_type.eq_ignore_ascii_case("pdf") && !path.starts_with(CLOUD_PATH))
                        .then(|| crate::attachments::inspect(std::path::Path::new(&path)).ok())
                        .flatten()
                });
                json!({"ref_id": rid, "file_type": file_type, "sha256": sha})
            })
        }
        "image" => c
            .query_row(
                "SELECT mime_type,width,height,sha256,page,rectangle,source_sha256,source_pdf FROM note_images WHERE note_id=?",
                [key],
                |r| {
                    Ok((
                        json!({
                            "mime_type": r.get::<_, String>(0)?, "width": r.get::<_, i64>(1)?,
                            "height": r.get::<_, i64>(2)?, "sha256": r.get::<_, String>(3)?,
                            "page": r.get::<_, i64>(4)?, "rectangle": parsed(r.get(5)?),
                            "source_sha256": r.get::<_, Option<String>>(6)?,
                        }),
                        r.get::<_, String>(7)?,
                    ))
                },
            )
            .optional()?
            .map(|(mut v, source_pdf)| {
                if v["source_sha256"].is_null() {
                    let sha: Option<String> = c
                        .query_row(
                            "SELECT fingerprint FROM attachments WHERE path=? AND fingerprint IS NOT NULL LIMIT 1",
                            [&source_pdf],
                            |r| r.get(0),
                        )
                        .optional()
                        .ok()
                        .flatten();
                    v["source_sha256"] = json!(sha);
                }
                v
            }),
        "summary" => c
            .query_row(
                "SELECT source,external_id,source_url,body,fetched_at FROM external_summaries WHERE ref_id=?",
                [key],
                |r| {
                    Ok(json!({"source": r.get::<_, String>(0)?, "external_id": r.get::<_, String>(1)?,
                        "source_url": r.get::<_, String>(2)?, "body": r.get::<_, String>(3)?,
                        "fetched_at": r.get::<_, String>(4)?}))
                },
            )
            .optional()?,
        _ => bail!("Unknown record kind {kind}"),
    };
    Ok(row.map(map))
}

/// Every key of a kind, for snapshots and merges.
pub fn keys(c: &Connection, kind: &str) -> Result<Vec<String>> {
    let sql = match kind {
        "ref" => "SELECT id FROM refs",
        "project" => "SELECT id FROM projects",
        "assoc" => "SELECT ref_id || '|' || project_id FROM associations",
        "note" => "SELECT id FROM notes",
        "attachment" => "SELECT id FROM attachments",
        "image" => "SELECT note_id FROM note_images",
        "summary" => "SELECT ref_id FROM external_summaries",
        _ => bail!("Unknown record kind {kind}"),
    };
    let mut stmt = c.prepare(sql)?;
    let keys = stmt
        .query_map([], |r| r.get(0))?
        .collect::<rusqlite::Result<Vec<String>>>()?;
    Ok(keys)
}

/// Writes a record's synced fields, creating it when missing. `clips` holds
/// image bytes by sha256 for `image` records.
pub fn write(
    c: &Connection,
    kind: &str,
    key: &str,
    r: &Map<String, Value>,
    clips: &HashMap<String, Vec<u8>>,
) -> Result<()> {
    let stamp = now();
    match kind {
        "ref" => {
            c.execute(
                "INSERT INTO refs(id,citekey,entry_type,title,authors,abstract,year,doi,fields,bibtex,source,created_at,updated_at) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13) \
                 ON CONFLICT(id) DO UPDATE SET citekey=excluded.citekey,entry_type=excluded.entry_type,title=excluded.title,authors=excluded.authors,abstract=excluded.abstract,year=excluded.year,doi=excluded.doi,fields=excluded.fields,bibtex=excluded.bibtex,source=excluded.source,created_at=excluded.created_at,updated_at=excluded.updated_at,revision=revision+1",
                params![
                    key,
                    s(r, "citekey"),
                    s(r, "entry_type"),
                    s(r, "title"),
                    s(r, "authors"),
                    s(r, "abstract"),
                    s(r, "year"),
                    opt(r, "doi").filter(|d| !d.is_empty()),
                    json_text(r, "fields", json!({})),
                    s(r, "bibtex"),
                    s(r, "source"),
                    opt(r, "created_at").unwrap_or_else(|| stamp.clone()),
                    opt(r, "updated_at").unwrap_or_else(|| stamp.clone()),
                ],
            )?;
            insert_doc(c, key)?;
        }
        "project" => {
            c.execute(
                "INSERT INTO projects(id,name,description,roots) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,description=excluded.description,roots=excluded.roots",
                params![key, s(r, "name"), s(r, "description"), json_text(r, "roots", json!([]))],
            )?;
        }
        "assoc" => {
            let (rid, pid) = split_assoc(key)?;
            c.execute(
                "INSERT INTO associations(ref_id,project_id,labels) VALUES(?,?,?) ON CONFLICT(ref_id,project_id) DO UPDATE SET labels=excluded.labels",
                params![rid, pid, json_text(r, "labels", json!([]))],
            )?;
        }
        "note" => {
            let old = crate::db::note(c, key).ok();
            if let Some(old) = &old {
                let rev = old["revision"].as_i64().unwrap_or(1);
                c.execute(
                    "INSERT OR REPLACE INTO note_revisions VALUES(?,?,?)",
                    params![key, rev, old.to_string()],
                )?;
            }
            c.execute(
                "INSERT INTO notes(id,ref_id,project_id,body,labels,evidence,provenance,created_at,updated_at) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9) \
                 ON CONFLICT(id) DO UPDATE SET ref_id=excluded.ref_id,project_id=excluded.project_id,body=excluded.body,labels=excluded.labels,evidence=excluded.evidence,provenance=excluded.provenance,created_at=excluded.created_at,updated_at=excluded.updated_at,revision=revision+1",
                params![
                    key,
                    s(r, "ref_id"),
                    opt(r, "project_id"),
                    s(r, "body"),
                    json_text(r, "labels", json!([])),
                    opt(r, "evidence"),
                    s(r, "provenance"),
                    opt(r, "created_at").unwrap_or_else(|| stamp.clone()),
                    opt(r, "updated_at").unwrap_or_else(|| stamp.clone()),
                ],
            )?;
            index_note(c, key)?;
        }
        "attachment" => {
            let sha = opt(r, "sha256");
            let existing: Option<(String, Option<String>)> = c
                .query_row(
                    "SELECT path,fingerprint FROM attachments WHERE id=?",
                    [key],
                    |x| Ok((x.get(0)?, x.get(1)?)),
                )
                .optional()?;
            // Keep a downloaded file while its content is unchanged.
            let path = match existing {
                Some((path, fingerprint)) if fingerprint == sha => path,
                _ => format!("{CLOUD_PATH}{key}"),
            };
            c.execute(
                "INSERT INTO attachments(id,ref_id,path,file_type,fingerprint) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET ref_id=excluded.ref_id,path=excluded.path,file_type=excluded.file_type,fingerprint=excluded.fingerprint",
                params![key, s(r, "ref_id"), path, s(r, "file_type"), sha],
            )?;
        }
        "image" => {
            let sha = s(r, "sha256");
            let data = match clips.get(sha) {
                Some(d) => d.clone(),
                None => c
                    .query_row(
                        "SELECT data FROM note_images WHERE sha256=? LIMIT 1",
                        [sha],
                        |x| x.get::<_, Vec<u8>>(0),
                    )
                    .optional()?
                    .with_context(|| format!("The clip {sha} was not downloaded"))?,
            };
            let source_sha = opt(r, "source_sha256");
            let source_pdf: String = match &source_sha {
                Some(h) => c
                    .query_row(
                        "SELECT path FROM attachments WHERE fingerprint=? AND path NOT LIKE 'omabib-sync:%' LIMIT 1",
                        [h],
                        |x| x.get(0),
                    )
                    .optional()?
                    .unwrap_or_default(),
                None => String::new(),
            };
            c.execute(
                "INSERT INTO note_images(note_id,mime_type,width,height,sha256,source_pdf,page,rectangle,data,source_sha256) VALUES(?,?,?,?,?,?,?,?,?,?) \
                 ON CONFLICT(note_id) DO UPDATE SET mime_type=excluded.mime_type,width=excluded.width,height=excluded.height,sha256=excluded.sha256,source_pdf=excluded.source_pdf,page=excluded.page,rectangle=excluded.rectangle,data=excluded.data,source_sha256=excluded.source_sha256",
                params![
                    key,
                    r.get("mime_type").and_then(Value::as_str).unwrap_or("image/png"),
                    r.get("width").and_then(Value::as_i64).unwrap_or(0),
                    r.get("height").and_then(Value::as_i64).unwrap_or(0),
                    sha,
                    source_pdf,
                    r.get("page").and_then(Value::as_i64).unwrap_or(0),
                    json_text(r, "rectangle", json!({})),
                    data,
                    source_sha,
                ],
            )?;
        }
        "summary" => {
            c.execute(
                "INSERT INTO external_summaries(ref_id,source,external_id,source_url,body,fetched_at) VALUES(?,?,?,?,?,?) \
                 ON CONFLICT(ref_id) DO UPDATE SET source=excluded.source,external_id=excluded.external_id,source_url=excluded.source_url,body=excluded.body,fetched_at=excluded.fetched_at",
                params![
                    key,
                    s(r, "source"),
                    s(r, "external_id"),
                    s(r, "source_url"),
                    s(r, "body"),
                    opt(r, "fetched_at").unwrap_or(stamp),
                ],
            )?;
        }
        _ => bail!("Unknown record kind {kind}"),
    }
    Ok(())
}

/// The dependent records removed with a record, and the chats of a removed reference.
pub type Removed = (Vec<(String, String)>, Vec<String>);

/// Removes a record and whatever depends on it.
pub fn delete(c: &Connection, kind: &str, key: &str) -> Result<Removed> {
    let mut gone = Vec::new();
    let mut chats = Vec::new();
    let collect = |sql: &str, kind: &str, gone: &mut Vec<(String, String)>| -> Result<()> {
        let mut stmt = c.prepare(sql)?;
        for k in stmt.query_map([key], |r| r.get::<_, String>(0))? {
            gone.push((kind.to_string(), k?));
        }
        Ok(())
    };
    match kind {
        "ref" => {
            collect("SELECT id FROM notes WHERE ref_id=?", "note", &mut gone)?;
            collect(
                "SELECT note_id FROM note_images WHERE note_id IN (SELECT id FROM notes WHERE ref_id=?)",
                "image",
                &mut gone,
            )?;
            collect(
                "SELECT id FROM attachments WHERE ref_id=?",
                "attachment",
                &mut gone,
            )?;
            collect(
                "SELECT ref_id || '|' || project_id FROM associations WHERE ref_id=?",
                "assoc",
                &mut gone,
            )?;
            collect(
                "SELECT ref_id FROM external_summaries WHERE ref_id=?",
                "summary",
                &mut gone,
            )?;
            let mut stmt = c.prepare("SELECT id FROM chats WHERE ref_id=?")?;
            for id in stmt.query_map([key], |r| r.get::<_, String>(0))? {
                chats.push(id?);
            }
            for sql in [
                "DELETE FROM chat_events WHERE chat_id IN (SELECT id FROM chats WHERE ref_id=?)",
                "DELETE FROM chats WHERE ref_id=?",
                "DELETE FROM note_revisions WHERE note_id IN (SELECT id FROM notes WHERE ref_id=?)",
                "DELETE FROM note_images WHERE note_id IN (SELECT id FROM notes WHERE ref_id=?)",
                "DELETE FROM docs WHERE ref_id=?",
                "DELETE FROM notes WHERE ref_id=?",
                "DELETE FROM attachments WHERE ref_id=?",
                "DELETE FROM associations WHERE ref_id=?",
                "DELETE FROM external_summaries WHERE ref_id=?",
                "DELETE FROM refs WHERE id=?",
            ] {
                c.execute(sql, [key])?;
            }
        }
        "note" => {
            collect(
                "SELECT note_id FROM note_images WHERE note_id=?",
                "image",
                &mut gone,
            )?;
            for sql in [
                "DELETE FROM note_revisions WHERE note_id=?",
                "DELETE FROM note_images WHERE note_id=?",
                "DELETE FROM docs WHERE note_id=?",
                "DELETE FROM notes WHERE id=?",
            ] {
                c.execute(sql, [key])?;
            }
        }
        "project" => {
            collect(
                "SELECT ref_id || '|' || project_id FROM associations WHERE project_id=?",
                "assoc",
                &mut gone,
            )?;
            c.execute("DELETE FROM associations WHERE project_id=?", [key])?;
            c.execute("UPDATE notes SET project_id=NULL WHERE project_id=?", [key])?;
            c.execute("UPDATE docs SET project_id=NULL WHERE project_id=?", [key])?;
            c.execute("DELETE FROM projects WHERE id=?", [key])?;
        }
        "assoc" => {
            let (rid, pid) = split_assoc(key)?;
            c.execute(
                "DELETE FROM associations WHERE ref_id=? AND project_id=?",
                [rid, pid],
            )?;
        }
        "attachment" => {
            c.execute("DELETE FROM attachments WHERE id=?", [key])?;
        }
        "image" => {
            c.execute("DELETE FROM note_images WHERE note_id=?", [key])?;
        }
        "summary" => {
            c.execute("DELETE FROM external_summaries WHERE ref_id=?", [key])?;
        }
        _ => bail!("Unknown record kind {kind}"),
    }
    Ok((gone, chats))
}

/// The parent a record needs: (kind, key), if any.
pub fn parent(kind: &str, key: &str, r: &Map<String, Value>) -> Vec<(String, String)> {
    let get = |k: &str| r.get(k).and_then(Value::as_str).map(str::to_owned);
    match kind {
        "note" => get("ref_id")
            .map(|x| vec![("ref".into(), x)])
            .unwrap_or_default(),
        "attachment" => get("ref_id")
            .map(|x| vec![("ref".into(), x)])
            .unwrap_or_default(),
        "summary" => vec![("ref".into(), key.into())],
        "image" => vec![("note".into(), key.into())],
        "assoc" => split_assoc(key)
            .map(|(r, p)| vec![("ref".into(), r.into()), ("project".into(), p.into())])
            .unwrap_or_default(),
        _ => vec![],
    }
}

/// Whether a record's row exists locally.
pub fn exists(c: &Connection, kind: &str, key: &str) -> Result<bool> {
    let sql = match kind {
        "ref" => "SELECT 1 FROM refs WHERE id=?",
        "project" => "SELECT 1 FROM projects WHERE id=?",
        "note" => "SELECT 1 FROM notes WHERE id=?",
        "attachment" => "SELECT 1 FROM attachments WHERE id=?",
        "image" => "SELECT 1 FROM note_images WHERE note_id=?",
        "summary" => "SELECT 1 FROM external_summaries WHERE ref_id=?",
        "assoc" => {
            let (rid, pid) = split_assoc(key)?;
            return Ok(c
                .query_row(
                    "SELECT 1 FROM associations WHERE ref_id=? AND project_id=?",
                    [rid, pid],
                    |_| Ok(()),
                )
                .optional()?
                .is_some());
        }
        _ => bail!("Unknown record kind {kind}"),
    };
    Ok(c.query_row(sql, [key], |_| Ok(())).optional()?.is_some())
}

#[cfg(test)]
mod tests {
    #[test]
    fn timestamps_round_trip() {
        let t = super::now();
        let ms = super::super::clock::iso_ms(&t).unwrap();
        assert!(ms.abs_diff(super::super::clock::now_ms()) < 5000, "{t}");
    }
}
