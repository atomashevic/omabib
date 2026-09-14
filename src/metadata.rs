//! Explicit, bounded online metadata lookup. Search candidates require selection.
use crate::db::{self, Library, required, text};
use anyhow::{Result, ensure};
use reqwest::{Url, blocking::Client};
use rusqlite::OptionalExtension;
use serde_json::{Map, Value, json};
use std::{io::Read, time::Duration};

pub(crate) fn client() -> Result<Client> {
    Ok(Client::builder()
        .https_only(true)
        .timeout(Duration::from_secs(18))
        .user_agent("Omabib/0.1 (personal bibliography metadata lookup)")
        .build()?)
}
pub(crate) fn fetch(c: &Client, url: Url) -> Result<Value> {
    let response = c.get(url).send()?.error_for_status()?;
    let mut bytes = Vec::new();
    response.take(4 * 1024 * 1024 + 1).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() <= 4 * 1024 * 1024,
        "Metadata response too large"
    );
    Ok(serde_json::from_slice(&bytes)?)
}
pub(crate) fn endpoint(base: &str, id: &str) -> Result<Url> {
    let mut u = Url::parse(base)?;
    u.path_segments_mut().unwrap().push(id);
    Ok(u)
}
fn clean(s: &str) -> String {
    let mut out = String::new();
    let mut tag = false;
    for ch in s.chars() {
        match ch {
            '<' => {
                tag = true;
                out.push(' ');
            }
            '>' => tag = false,
            _ if !tag => out.push(ch),
            _ => (),
        }
    }
    for (a, b) in [
        ("&amp;", "&"),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&apos;", "'"),
        ("&#39;", "'"),
        ("&nbsp;", " "),
    ] {
        out = out.replace(a, b)
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}
fn insert(f: &mut Map<String, Value>, key: &str, s: &str) {
    let s = clean(s);
    if !s.is_empty() {
        f.insert(key.into(), json!(s));
    }
}
fn first(v: &Value) -> &str {
    v.get(0).and_then(Value::as_str).unwrap_or("")
}
pub(crate) fn crossref(v: &Value) -> Value {
    let mut f = Map::new();
    for (k, s) in [
        ("title", first(&v["title"])),
        ("doi", text(v, "DOI")),
        ("isbn", first(&v["ISBN"])),
        ("issn", first(&v["ISSN"])),
        ("url", text(v, "URL")),
        ("abstract", text(v, "abstract")),
        ("publisher", text(v, "publisher")),
        ("volume", text(v, "volume")),
        ("number", text(v, "issue")),
        ("pages", text(v, "page")),
        ("journal", first(&v["container-title"])),
    ] {
        insert(&mut f, k, s)
    }
    if let Some(y) = v["published"]["date-parts"][0][0].as_i64() {
        insert(&mut f, "year", &y.to_string())
    }
    if let Some(a) = v["author"].as_array() {
        insert(
            &mut f,
            "author",
            &a.iter()
                .map(|x| {
                    if !text(x, "name").is_empty() {
                        format!("{{{}}}", text(x, "name"))
                    } else {
                        [text(x, "family"), text(x, "given")]
                            .into_iter()
                            .filter(|x| !x.is_empty())
                            .collect::<Vec<_>>()
                            .join(", ")
                    }
                })
                .collect::<Vec<_>>()
                .join(" and "),
        )
    }
    if let Some(a) = v["link"].as_array()
        && let Some(p) = a
            .iter()
            .find(|x| text(x, "content-type") == "application/pdf")
    {
        insert(&mut f, "pdf", text(p, "URL"))
    }
    json!({"entry_type":match text(v,"type"){"journal-article"=>"article","book"|"monograph"|"edited-book"=>"book","book-chapter"=>"incollection","proceedings-article"=>"inproceedings",_=>"misc"},"gateway":"Crossref","source":format!("https://api.crossref.org/works/{}",text(v,"DOI")),"fields":f})
}
pub(crate) fn datacite(v: &Value) -> Value {
    let mut f = Map::new();
    for (k, s) in [
        ("title", text(&v["titles"][0], "title")),
        ("doi", text(v, "doi")),
        ("url", text(v, "url")),
        ("publisher", text(v, "publisher")),
    ] {
        insert(&mut f, k, s)
    }
    if let Some(y) = v["publicationYear"].as_i64() {
        insert(&mut f, "year", &y.to_string())
    }
    if let Some(a) = v["creators"].as_array() {
        insert(
            &mut f,
            "author",
            &a.iter()
                .map(|x| text(x, "name"))
                .collect::<Vec<_>>()
                .join(" and "),
        )
    }
    if let Some(a) = v["descriptions"].as_array()
        && let Some(ab) = a.iter().find(|x| text(x, "descriptionType") == "Abstract")
    {
        insert(&mut f, "abstract", text(ab, "description"))
    }
    json!({"gateway":"DataCite","source":format!("https://api.datacite.org/dois/{}",text(v,"doi")),"fields":f})
}
pub(crate) fn inferred_doi(r: &Value) -> String {
    let fields = &r["fields"];
    let doi = db::normalize_doi(text(fields, "doi"));
    if !doi.is_empty() {
        return doi;
    }
    for key in ["url", "eprint"] {
        let s = text(fields, key);
        if s.contains("doi.org/") {
            return db::normalize_doi(s);
        }
        let arxiv = s
            .split("arxiv.org/abs/")
            .nth(1)
            .or_else(|| s.split("arxiv.org/pdf/").nth(1))
            .or_else(|| {
                if key == "eprint" && text(fields, "archiveprefix").eq_ignore_ascii_case("arxiv") {
                    Some(s)
                } else {
                    None
                }
            });
        if let Some(id) = arxiv {
            let id = id
                .split(['?', '#'])
                .next()
                .unwrap_or("")
                .trim_end_matches(".pdf");
            let id = id
                .rsplit_once('v')
                .filter(|(_, v)| v.chars().all(|c| c.is_ascii_digit()))
                .map_or(id, |(a, _)| a);
            if !id.is_empty() {
                return format!("10.48550/arxiv.{id}");
            }
        }
    }
    String::new()
}
fn match_score(reference: &Value, candidate: &Value) -> f64 {
    fn words(s: &str) -> std::collections::BTreeSet<String> {
        db::normalize(s)
            .split(|c: char| !c.is_alphanumeric())
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
            .collect()
    }
    let left = words(text(reference, "title"));
    let right = words(text(&candidate["fields"], "title"));
    let title =
        2.0 * left.intersection(&right).count() as f64 / (left.len() + right.len()).max(1) as f64;
    let year = if !text(reference, "year").is_empty()
        && text(reference, "year") == text(&candidate["fields"], "year")
    {
        0.15
    } else {
        0.0
    };
    let authors = words(text(reference, "authors"));
    let found = words(text(&candidate["fields"], "author"));
    title + year + 0.1 * authors.intersection(&found).count() as f64 / authors.len().max(1) as f64
}
pub fn lookup(lib: &Library, a: &Value) -> Result<Value> {
    let r = lib.call("get_reference", &json!({"id":required(a,"id")?}))?;
    let c = client()?;
    let mut candidates = Vec::new();
    let mut warnings = Vec::new();
    let doi = inferred_doi(&r);
    if !doi.is_empty() {
        match fetch(&c, endpoint("https://api.crossref.org/works/", &doi)?) {
            Ok(v) => candidates.push(crossref(&v["message"])),
            Err(e) => warnings.push(format!("Crossref: {e}")),
        }
        if candidates.is_empty() {
            match fetch(&c, endpoint("https://api.datacite.org/dois/", &doi)?) {
                Ok(v) => candidates.push(datacite(&v["data"]["attributes"])),
                Err(e) => warnings.push(format!("DataCite: {e}")),
            }
        }
    } else {
        ensure!(
            !text(&r, "title").is_empty(),
            "Add a title or DOI before looking up metadata"
        );
        let mut url = Url::parse("https://api.crossref.org/works")?;
        url.query_pairs_mut()
            .append_pair("query.title", text(&r, "title"))
            .append_pair("rows", "15");
        if !text(&r, "authors").is_empty() {
            url.query_pairs_mut()
                .append_pair("query.author", text(&r, "authors"));
        }
        match fetch(&c, url) {
            Ok(v) => {
                if let Some(items) = v["message"]["items"].as_array() {
                    candidates.extend(items.iter().map(crossref))
                }
            }
            Err(e) => warnings.push(format!("Crossref: {e}")),
        }
    }
    if doi.is_empty() {
        candidates.sort_by(|a, b| match_score(&r, b).total_cmp(&match_score(&r, a)));
        candidates.truncate(5);
    }
    for candidate in &mut candidates {
        candidate["match_kind"] = json!(if doi.is_empty() {
            "title search: verify the paper"
        } else {
            "identifier"
        });
        let mut additions = Map::new();
        let mut conflicts = Map::new();
        for (k, v) in candidate["fields"].as_object().unwrap() {
            let old = text(&r["fields"], k);
            if old.trim().is_empty() {
                additions.insert(k.clone(), v.clone());
            } else if old != v.as_str().unwrap_or("") {
                conflicts.insert(k.clone(), json!({"existing":old,"online":v}));
            }
        }
        candidate["needs_abstract"] = json!(
            text(&r["fields"], "abstract").is_empty()
                && text(&candidate["fields"], "abstract").is_empty()
        );
        candidate["additions"] = json!(additions);
        candidate["conflicts"] = json!(conflicts);
    }
    Ok(
        json!({"id":r["id"],"expected_revision":r["revision"],"candidates":candidates,"warnings":warnings,"saved":false}),
    )
}
/// Supplement a selected candidate by exact DOI only; never mix title-search results.
pub fn supplement(lib: &Library, a: &Value) -> Result<Value> {
    lib.call("get_reference", &json!({"id":required(a,"id")?}))?;
    let doi = db::normalize_doi(required(a, "doi")?);
    ensure!(
        doi.starts_with("10.") && !doi.chars().any(char::is_whitespace),
        "Invalid DOI"
    );
    let mut url = Url::parse("https://www.ebi.ac.uk/europepmc/webservices/rest/search")?;
    url.query_pairs_mut()
        .append_pair("query", &format!("DOI:\"{}\"", doi.replace('"', "")))
        .append_pair("format", "json")
        .append_pair("resultType", "core")
        .append_pair("pageSize", "3");
    let v = match fetch(&client()?, url.clone()) {
        Ok(v) => v,
        Err(e) => {
            return Ok(
                json!({"fields":{},"warning":format!("Europe PMC unavailable: {e}"),"saved":false}),
            );
        }
    };
    let mut fields = Map::new();
    if let Some(items) = v["resultList"]["result"].as_array()
        && let Some(v) = items
            .iter()
            .find(|v| db::normalize_doi(text(v, "doi")) == doi)
    {
        insert(&mut fields, "abstract", text(v, "abstractText"));
    }
    Ok(json!({"fields":fields,"source":url.as_str(),"gateway":"Europe PMC","saved":false}))
}
pub fn apply(c: &rusqlite::Connection, a: &Value) -> Result<Value> {
    let r = db::get_reference(c, &json!({"id":required(a,"id")?}))?;
    ensure!(
        a["expected_revision"].as_i64() == r["revision"].as_i64(),
        "Revision conflict: reload metadata before applying"
    );
    let fields = a["fields"]
        .as_object()
        .ok_or_else(|| anyhow::anyhow!("fields must be an object"))?;
    let mut b = db::parse_bibtex(text(&r, "bibtex"))?;
    let entry = b.iter_mut().next().unwrap();
    let mut filled = Vec::new();
    for (key, value) in fields {
        ensure!(
            [
                "title",
                "author",
                "year",
                "abstract",
                "doi",
                "url",
                "pdf",
                "journal",
                "publisher",
                "volume",
                "number",
                "pages",
                "isbn",
                "issn"
            ]
            .contains(&key.as_str()),
            "Unsupported metadata field: {key}"
        );
        let s = value
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Metadata fields must be strings"))?;
        ensure!(s.len() <= 65536, "Metadata field too large");
        if s.trim().is_empty() || !text(&r["fields"], key).trim().is_empty() {
            continue;
        }
        if key == "doi" {
            let other: Option<String> = c
                .query_row(
                    "SELECT citekey FROM refs WHERE doi=? AND id<>?",
                    rusqlite::params![db::normalize_doi(s), text(&r, "id")],
                    |row| row.get(0),
                )
                .optional()?;
            ensure!(
                other.is_none(),
                "This DOI already belongs to {}. No changes were saved; review the duplicate references first.",
                other.unwrap_or_default()
            );
        }
        entry.set(
            key,
            vec![biblatex::Spanned::detached(biblatex::Chunk::Normal(
                s.into(),
            ))],
        );
        filled.push(key.clone());
    }
    if !filled.is_empty() {
        let source = format!(
            "{}\nMetadata enrichment: {}",
            text(&r, "source"),
            required(a, "source")?
        );
        db::save_entry(c, text(&r, "id"), entry, false, &source)?;
    }
    Ok(
        json!({"id":r["id"],"filled":filled,"revision":r["revision"].as_i64().unwrap()+i64::from(!filled.is_empty())}),
    )
}
/// Prefer an existing PDF, then a safe bibliographic URL, then DOI resolution.
pub fn open_target(lib: &Library, a: &Value) -> Result<Value> {
    let r = lib.call(
        "get_reference",
        &json!({"id":required(a,"id")?,"include_attachments":true}),
    )?;
    if let Some(items) = r["attachments"].as_array() {
        for p in items {
            if p["exists"] == true && text(p, "file_type").eq_ignore_ascii_case("pdf") {
                return Ok(
                    json!({"url":Url::from_file_path(text(p,"path")).map_err(|_|anyhow::anyhow!("Invalid PDF path"))?.as_str(),"kind":"pdf"}),
                );
            }
        }
    }
    for key in ["url", "pdf"] {
        if let Ok(u) = Url::parse(text(&r["fields"], key))
            && ["https", "http"].contains(&u.scheme())
        {
            return Ok(json!({"url":u.as_str(),"kind":"url"}));
        }
    }
    let doi = inferred_doi(&r);
    if !doi.is_empty() {
        return Ok(json!({"url":endpoint("https://doi.org/",&doi)?.as_str(),"kind":"doi"}));
    }
    anyhow::bail!("No PDF, URL or DOI available. Use Fill metadata to look up this reference.")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn original_paper_ranks_above_commentary() {
        let r = json!({"title":"Collective dynamics of small-world networks","authors":"Watts, Duncan J. and Strogatz, Steven H.","year":"1998"});
        let original = json!({"fields":{"title":"Collective dynamics of small-world networks","author":"Watts, Duncan J. and Strogatz, Steven H.","year":"1998"}});
        let commentary = json!({"fields":{"title":"Watts and Strogatz (1998). Collective dynamics of small-world networks. Nature 393, 440-442.","author":"Lietz, Haiko","year":"2018"}});
        assert!(match_score(&r, &original) > match_score(&r, &commentary));
    }
    #[test]
    fn provider_mapping_and_arxiv_identity() {
        let v = crossref(
            &json!({"DOI":"10.1234/test","title":["A title"],"abstract":"<jats:p>Test &amp; science.</jats:p>","published":{"date-parts":[[2024]]},"author":[{"family":"Smith","given":"Alex"}],"link":[{"content-type":"application/pdf","URL":"https://example.org/paper.pdf"}]}),
        );
        assert_eq!(v["fields"]["abstract"], "Test & science.");
        assert_eq!(v["fields"]["year"], "2024");
        assert_eq!(v["fields"]["author"], "Smith, Alex");
        assert_eq!(v["fields"]["pdf"], "https://example.org/paper.pdf");
        let v = datacite(
            &json!({"doi":"10.48550/arxiv.2609.08049","titles":[{"title":"Example"}],"descriptions":[{"descriptionType":"Abstract","description":"A repository abstract."}]}),
        );
        assert_eq!(v["fields"]["abstract"], "A repository abstract.");
        assert_eq!(
            inferred_doi(&json!({"fields":{"url":"https://arxiv.org/pdf/2609.08049v2.pdf"}})),
            "10.48550/arxiv.2609.08049"
        );
    }
}
