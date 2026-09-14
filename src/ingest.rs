//! Zotero-style "magic add": recognize a DOI, arXiv ID, plain HTTP(S) URL or
//! raw BibTeX, or several of these pasted together, and turn each into a
//! previewable BibTeX entry with a `family_word_year`-style citation key,
//! an abstract when one can be found, and an open-access PDF link when one
//! exists. Nothing here writes to the library; see `db::import` for that.
use crate::db::{required, text};
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
use std::{
    io::{Read, Write},
    process::{Command, Stdio},
    time::Duration,
};

/// Common English/French/German connective words skipped when picking the
/// first "meaningful" title word for a citation key.
const KEY_STOPWORDS: &[&str] = &[
    "a", "an", "the", "of", "on", "in", "for", "and", "to", "with", "from", "using", "toward",
    "towards", "by", "as", "at", "into", "is", "are", "was", "were", "de", "der", "die", "das",
    "des", "le", "la", "les",
];

/// Build a `family_word_year` citation key from candidate fields, matching
/// this library's existing convention (e.g. `watts_collective_1998`).
/// Collisions are resolved later by `db::import`, which appends `_2`, `_3`...
pub(crate) fn citation_key(fields: &Value) -> String {
    let author = text(fields, "author");
    let family = author
        .split(" and ")
        .next()
        .unwrap_or("")
        .split(',')
        .next()
        .unwrap_or("")
        .trim();
    let family: String = crate::db::normalize(family)
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .collect();
    let title = text(fields, "title");
    let word = crate::db::normalize(title)
        .split(|c: char| !c.is_alphanumeric())
        .find(|w| !w.is_empty() && !KEY_STOPWORDS.contains(w))
        .unwrap_or("")
        .to_string();
    let year: String = text(fields, "year")
        .chars()
        .filter(char::is_ascii_digit)
        .take(4)
        .collect();
    let mut parts = Vec::new();
    if !family.is_empty() {
        parts.push(family);
    }
    if !word.is_empty() {
        parts.push(word);
    }
    if !year.is_empty() {
        parts.push(year);
    }
    if parts.is_empty() {
        "reference".to_string()
    } else {
        parts.join("_")
    }
}

fn bibliography(fields: &Value, kind: &str) -> Result<String> {
    let title = text(fields, "title");
    ensure!(
        !title.is_empty(),
        "No bibliographic title found. Paste BibTeX or a DOI instead."
    );
    let key = citation_key(fields);
    let mut b = crate::db::parse_bibtex(&format!("@{kind}{{{key}, title={{Temporary}}}}"))?;
    let e = b.iter_mut().next().unwrap();
    for (key, value) in fields.as_object().context("Invalid online metadata")? {
        if let Some(s) = value.as_str()
            && !s.is_empty()
        {
            e.set(
                key,
                vec![biblatex::Spanned::detached(biblatex::Chunk::Normal(
                    s.into(),
                ))],
            );
        }
    }
    Ok(crate::db::serialize_entry(e))
}

/// Strip a trailing `vN` arXiv version suffix, if present.
fn strip_arxiv_version(id: &str) -> &str {
    match id.rsplit_once('v') {
        Some((base, ver)) if !ver.is_empty() && ver.chars().all(|c| c.is_ascii_digit()) => base,
        _ => id,
    }
}
fn new_style_arxiv(s: &str) -> Option<String> {
    let (a, b) = s.split_once('.')?;
    (a.len() == 4
        && a.chars().all(|c| c.is_ascii_digit())
        && (4..=5).contains(&b.len())
        && b.chars().all(|c| c.is_ascii_digit()))
    .then(|| s.to_string())
}
fn old_style_arxiv(s: &str) -> Option<String> {
    let (archive, num) = s.split_once('/')?;
    let archive_ok = !archive.is_empty()
        && archive
            .chars()
            .all(|c| c.is_ascii_lowercase() || c == '-' || c == '.');
    let num_ok = num.len() == 7 && num.chars().all(|c| c.is_ascii_digit());
    (archive_ok && num_ok).then(|| s.to_string())
}

/// Recognize an arXiv identifier from a bare ID, an `arXiv:` prefix, or an
/// arxiv.org abs/pdf URL, in either the new (`2401.01234`) or old
/// (`hep-th/9901001`) style, with an optional version suffix.
pub(crate) fn arxiv_id_from_text(token: &str) -> Option<String> {
    let trimmed = token.trim().trim_end_matches(['.', ',', ';', ')', ']']);
    let raw: String = if let Some(rest) = trimmed
        .strip_prefix("arXiv:")
        .or_else(|| trimmed.strip_prefix("arxiv:"))
    {
        rest.to_string()
    } else if let Ok(url) = reqwest::Url::parse(trimmed)
        && url
            .host_str()
            .is_some_and(|h| h == "arxiv.org" || h.ends_with(".arxiv.org"))
    {
        let path = url.path().trim_start_matches('/');
        let rest = path.strip_prefix("abs/").or_else(|| path.strip_prefix("pdf/"))?;
        rest.trim_end_matches(".pdf").to_string()
    } else {
        trimmed.to_string()
    };
    let id = strip_arxiv_version(&raw);
    new_style_arxiv(id).or_else(|| old_style_arxiv(id))
}

/// Recognize a DOI from a bare identifier, `doi:` prefix or doi.org URL.
pub(crate) fn doi_from_text(token: &str) -> Option<String> {
    let trimmed = token.trim().trim_end_matches(['.', ',', ';', ')', ']']);
    let doi = crate::db::normalize_doi(trimmed);
    (doi.starts_with("10.") && doi.contains('/') && !doi.chars().any(char::is_whitespace))
        .then_some(doi)
}

/// Split pasted text into individual identifier tokens on whitespace and
/// commas (a whole BibTeX entry is handled separately, before this is
/// called). Capped so a pathological paste cannot trigger unbounded lookups.
pub(crate) fn split_identifiers(input: &str) -> Vec<String> {
    input
        .split(|c: char| c.is_whitespace() || c == ',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .take(50)
        .map(str::to_string)
        .collect()
}

fn from_doi(doi: &str, recognized: &str) -> Result<Value> {
    let c = crate::metadata::client()?;
    let mut warnings = Vec::new();
    let candidate = match crate::metadata::fetch(
        &c,
        crate::metadata::endpoint("https://api.crossref.org/works/", doi)?,
    ) {
        Ok(v) => crate::metadata::crossref(&v["message"]),
        Err(e) => {
            warnings.push(format!("Crossref: {e}"));
            let v = crate::metadata::fetch(
                &c,
                crate::metadata::endpoint("https://api.datacite.org/dois/", doi)?,
            )?;
            crate::metadata::datacite(&v["data"]["attributes"])
        }
    };
    let mut fields = candidate["fields"].clone();
    if text(&fields, "url").is_empty() {
        fields["url"] = json!(format!("https://doi.org/{doi}"));
    }
    let arxiv_id = crate::metadata::arxiv_from_doi(doi);
    let mut abstract_source = Value::Null;
    let mut pdf_url = Value::Null;
    if text(&fields, "abstract").is_empty() || text(&fields, "pdf").is_empty() {
        match crate::abstracts::enrich(doi, &arxiv_id) {
            Ok(e) => {
                if let Some(found) = e.abstract_result
                    && text(&fields, "abstract").is_empty()
                {
                    abstract_source = json!(found.source);
                    fields["abstract"] = json!(found.text);
                }
                if let Some(url) = e.pdf_url {
                    pdf_url = json!(url);
                    if text(&fields, "pdf").is_empty() {
                        fields["pdf"] = pdf_url.clone();
                    }
                }
                warnings.extend(e.warnings);
            }
            Err(e) => warnings.push(format!("Abstract/PDF lookup: {e}")),
        }
    }
    let entry_type = if text(&candidate, "entry_type").is_empty() {
        "misc"
    } else {
        text(&candidate, "entry_type")
    };
    Ok(json!({
        "bibtex": bibliography(&fields, entry_type)?,
        "citekey": citation_key(&fields),
        "title": text(&fields,"title"),
        "authors": text(&fields,"author"),
        "year": text(&fields,"year"),
        "source": candidate["source"],
        "recognized": recognized,
        "abstract_source": abstract_source,
        "pdf_url": pdf_url,
        "warnings": warnings,
        "saved": false,
    }))
}

fn from_url(token: &str, url: reqwest::Url) -> Result<Value> {
    let doi = crate::metadata::inferred_doi(&json!({"fields":{"url":token}}));
    if !doi.is_empty() {
        return from_doi(&doi, "doi");
    }
    let c = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(20))
        .user_agent("Omabib/0.1 (bibliography metadata lookup)")
        .build()?;
    let response = c.get(url.clone()).send()?.error_for_status()?;
    let final_url = response.url().clone();
    let mut html = Vec::new();
    response.take(2 * 1024 * 1024 + 1).read_to_end(&mut html)?;
    ensure!(
        html.len() <= 2 * 1024 * 1024,
        "Page exceeds 2 MiB; paste its DOI or BibTeX instead"
    );
    let mut child = Command::new("python3")
        .args(["-c", include_str!("../scripts/page_metadata.py")])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    child.stdin.take().unwrap().write_all(&html)?;
    let output = child.wait_with_output()?;
    ensure!(output.status.success(), "Could not parse page metadata");
    let mut fields: Value = serde_json::from_slice(&output.stdout)?;
    let doi = crate::db::normalize_doi(text(&fields, "doi"));
    if doi.starts_with("10.") && doi.contains('/') && !doi.chars().any(char::is_whitespace) {
        return from_doi(&doi, "doi");
    }
    fields.as_object_mut().unwrap().remove("doi");
    fields["url"] = json!(final_url.as_str());
    if let Ok(pdf) = final_url.join(text(&fields, "pdf"))
        && !text(&fields, "pdf").is_empty()
    {
        fields["pdf"] = json!(pdf.as_str())
    }
    let pdf_url = fields.get("pdf").cloned().unwrap_or(Value::Null);
    Ok(json!({
        "bibtex": bibliography(&fields, "online")?,
        "citekey": citation_key(&fields),
        "title": text(&fields,"title"),
        "authors": text(&fields,"author"),
        "year": text(&fields,"year"),
        "source": final_url.as_str(),
        "recognized": "url",
        "abstract_source": Value::Null,
        "pdf_url": pdf_url,
        "warnings": Vec::<String>::new(),
        "saved": false,
    }))
}

/// Identify a single token (not a whole BibTeX entry) as a DOI, arXiv ID or
/// plain URL, and fetch a previewable entry for it.
fn identify_one(token: &str) -> Result<Value> {
    let token = token.trim();
    let mut result = if let Some(doi) = doi_from_text(token) {
        from_doi(&doi, "doi")
    } else if let Some(id) = arxiv_id_from_text(token) {
        from_doi(&format!("10.48550/arxiv.{id}"), "arxiv")
    } else {
        let url = reqwest::Url::parse(token).context("Not a DOI, arXiv ID or HTTP(S) URL")?;
        ensure!(
            ["https", "http"].contains(&url.scheme())
                && url.username().is_empty()
                && url.password().is_none(),
            "Provide an HTTP(S) URL without credentials"
        );
        from_url(token, url)
    }?;
    result["input"] = json!(token);
    Ok(result)
}

/// Preview one or more pasted identifiers, or a raw BibTeX entry, without
/// writing anything. `Library::call("preview_entry", ...)` wraps this with a
/// rollback-import pass to also report conflicts, repairs and assigned keys.
pub fn preview(a: &Value) -> Result<Value> {
    let input = required(a, "input")?
        .trim()
        .trim_start_matches('\u{feff}')
        .trim();
    ensure!(input.len() <= 2 * 1024 * 1024, "Input exceeds 2 MiB");
    if input.starts_with('@') || input.starts_with('%') {
        return Ok(json!({
            "bibtex": input,
            "source": "Pasted BibTeX",
            "recognized": "bibtex",
            "saved": false,
            "items": [{"input":input,"recognized":"bibtex","bibtex":input}],
            "warnings": Vec::<String>::new(),
        }));
    }
    let tokens = split_identifiers(input);
    ensure!(
        !tokens.is_empty(),
        "Paste a DOI, arXiv ID, HTTP(S) URL or BibTeX entry"
    );
    let mut items = Vec::new();
    let mut combined = String::new();
    let mut warnings = Vec::new();
    for t in &tokens {
        match identify_one(t) {
            Ok(v) => {
                if let Some(s) = v["bibtex"].as_str() {
                    if !combined.is_empty() {
                        combined.push_str("\n\n");
                    }
                    combined.push_str(s);
                }
                items.push(v);
            }
            Err(e) => warnings.push(format!("{t}: {e:#}")),
        }
    }
    ensure!(
        !items.is_empty(),
        "{}",
        if warnings.is_empty() {
            "Paste a DOI, arXiv ID, HTTP(S) URL or BibTeX entry".to_string()
        } else {
            warnings.join("; ")
        }
    );
    let first = items[0].clone();
    Ok(json!({
        "bibtex": combined,
        "source": if items.len()==1 { first["source"].clone() } else { json!(format!("{} identifiers", items.len())) },
        "recognized": if items.len()==1 { first["recognized"].clone() } else { json!("multiple") },
        "saved": false,
        "items": items,
        "warnings": warnings,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognizes_arxiv_new_and_old_styles() {
        assert_eq!(arxiv_id_from_text("2401.01234"), Some("2401.01234".into()));
        assert_eq!(
            arxiv_id_from_text("2401.01234v2"),
            Some("2401.01234".into())
        );
        assert_eq!(
            arxiv_id_from_text("arXiv:2401.01234"),
            Some("2401.01234".into())
        );
        assert_eq!(
            arxiv_id_from_text("https://arxiv.org/abs/2401.01234v3"),
            Some("2401.01234".into())
        );
        assert_eq!(
            arxiv_id_from_text("https://arxiv.org/pdf/2401.01234.pdf"),
            Some("2401.01234".into())
        );
        assert_eq!(
            arxiv_id_from_text("hep-th/9901001"),
            Some("hep-th/9901001".into())
        );
        assert_eq!(
            arxiv_id_from_text("arXiv:cond-mat/0106096"),
            Some("cond-mat/0106096".into())
        );
        assert_eq!(arxiv_id_from_text("not-an-id"), None);
        assert_eq!(arxiv_id_from_text("10.1234/example"), None);
    }

    #[test]
    fn recognizes_doi_forms() {
        assert_eq!(
            doi_from_text("10.1234/example"),
            Some("10.1234/example".into())
        );
        assert_eq!(
            doi_from_text("https://doi.org/10.1234/Example"),
            Some("10.1234/example".into())
        );
        assert_eq!(
            doi_from_text("doi:10.1234/example,"),
            Some("10.1234/example".into())
        );
        assert_eq!(doi_from_text("not a doi"), None);
        assert_eq!(doi_from_text("2401.01234"), None);
    }

    #[test]
    fn splits_on_whitespace_commas_and_newlines() {
        let tokens = split_identifiers("10.1/a, 10.2/b\n2401.01234\thttps://x.example/y");
        assert_eq!(tokens, vec!["10.1/a", "10.2/b", "2401.01234", "https://x.example/y"]);
        assert_eq!(split_identifiers("   "), Vec::<String>::new());
    }

    #[test]
    fn citation_key_follows_family_word_year() {
        let f = json!({"author":"Watts, Duncan J. and Strogatz, Steven H.","title":"Collective dynamics of small-world networks","year":"1998"});
        assert_eq!(citation_key(&f), "watts_collective_1998");
        let f2 = json!({"author":"","title":"The Emergence of Scaling","year":"1999"});
        assert_eq!(citation_key(&f2), "emergence_1999");
        assert_eq!(citation_key(&json!({})), "reference");
    }
}
