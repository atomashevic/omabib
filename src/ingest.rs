use crate::db::{required, text};
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
use std::{
    io::{Read, Write},
    process::{Command, Stdio},
    time::Duration,
};

fn bibliography(fields: &Value, kind: &str) -> Result<String> {
    let title = text(fields, "title");
    ensure!(
        !title.is_empty(),
        "No bibliographic title found at this URL. Paste BibTeX or a DOI instead."
    );
    let seed = format!("{}{}", text(fields, "year"), title);
    let key: String = seed
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .take(48)
        .collect();
    let mut b = crate::db::parse_bibtex(&format!(
        "@{kind}{{{}, title={{Temporary}}}}",
        if key.is_empty() { "NewReference" } else { &key }
    ))?;
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
fn from_doi(doi: &str) -> Result<Value> {
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
    Ok(
        json!({"bibtex":bibliography(&fields,if text(&candidate,"entry_type").is_empty(){"misc"}else{text(&candidate,"entry_type")})?,"source":candidate["source"],"recognized":"doi","warnings":warnings,"saved":false}),
    )
}
pub fn preview(a: &Value) -> Result<Value> {
    let input = required(a, "input")?
        .trim()
        .trim_start_matches('\u{feff}')
        .trim();
    ensure!(input.len() <= 2 * 1024 * 1024, "Input exceeds 2 MiB");
    if input.starts_with('@') || input.starts_with('%') {
        return Ok(
            json!({"bibtex":input,"source":"Pasted BibTeX","recognized":"bibtex","saved":false}),
        );
    }
    let normalized = crate::db::normalize_doi(input);
    if normalized.starts_with("10.")
        && normalized.contains('/')
        && !normalized.chars().any(char::is_whitespace)
    {
        return from_doi(&normalized);
    }
    let url = reqwest::Url::parse(input).context("Paste a DOI, HTTP(S) URL or BibTeX entry")?;
    ensure!(
        ["https", "http"].contains(&url.scheme())
            && url.username().is_empty()
            && url.password().is_none(),
        "Provide an HTTP(S) URL without credentials"
    );
    let doi = crate::metadata::inferred_doi(&json!({"fields":{"url":input}}));
    if !doi.is_empty() {
        return from_doi(&doi);
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
        return from_doi(&doi);
    }
    fields.as_object_mut().unwrap().remove("doi");
    fields["url"] = json!(final_url.as_str());
    if let Ok(pdf) = final_url.join(text(&fields, "pdf"))
        && !text(&fields, "pdf").is_empty()
    {
        fields["pdf"] = json!(pdf.as_str())
    }
    Ok(
        json!({"bibtex":bibliography(&fields,"online")?,"source":final_url.as_str(),"recognized":"url","saved":false}),
    )
}
