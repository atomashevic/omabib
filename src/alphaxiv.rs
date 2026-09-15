//! On-demand, source-labelled alphaXiv AI overviews.
use crate::db::{Library, read_connection, required};
use anyhow::{Result, ensure};
use reqwest::blocking::Client;
use rusqlite::{OptionalExtension, params};
use serde_json::{Value, json};
use std::{io::Read, time::Duration};

pub const SCHEMA: &str = "CREATE TABLE IF NOT EXISTS external_summaries (\
    ref_id TEXT PRIMARY KEY REFERENCES refs(id), source TEXT NOT NULL, external_id TEXT NOT NULL, \
    source_url TEXT NOT NULL, body TEXT NOT NULL, fetched_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);";

fn arxiv_id(fields: &Value) -> Option<String> {
    let doi = fields["doi"].as_str().unwrap_or("").to_ascii_lowercase();
    let raw = if let Some(id) = doi.strip_prefix("10.48550/arxiv.") {
        id.to_string()
    } else {
        let url = fields["url"].as_str().unwrap_or("");
        let eprint = fields["eprint"].as_str().unwrap_or("");
        [url, eprint]
            .iter()
            .find_map(|s| {
                s.split("arxiv.org/abs/")
                    .nth(1)
                    .or_else(|| s.split("arxiv.org/pdf/").nth(1))
            })
            .or_else(|| (!eprint.is_empty()).then_some(eprint))?
            .split(['?', '#', '/'])
            .next()?
            .trim_end_matches(".pdf")
            .to_string()
    };
    let id = raw.split('v').next().unwrap_or("");
    let (year_month, number) = id.split_once('.')?;
    if year_month.len() != 4
        || !(4..=5).contains(&number.len())
        || !year_month.bytes().all(|b| b.is_ascii_digit())
        || !number.bytes().all(|b| b.is_ascii_digit())
    {
        return None;
    }
    Some(id.to_string())
}

/// alphaXiv serves overviews as Markdown with section headings, but the
/// opening varies: a "# Research Report:" title, or a sentence of prose before
/// "### 1. Authors". Accept any substantial Markdown with a heading; reject
/// HTML (an error or login page served with 200).
fn looks_like_overview(body: &str) -> bool {
    let text = body.trim_start();
    text.len() >= 100
        && !text.starts_with('<')
        && text.lines().any(|line| {
            let line = line.trim_start();
            line.starts_with('#') && line.trim_start_matches('#').starts_with(' ')
        })
}

pub fn get(lib: &Library, args: &Value) -> Result<Value> {
    let ref_id = required(args, "id")?;
    let c = read_connection(&lib.path)?;
    let fields: String =
        c.query_row("SELECT fields FROM refs WHERE id=?", [ref_id], |r| r.get(0))?;
    let id = arxiv_id(&serde_json::from_str::<Value>(&fields)?)
        .ok_or_else(|| anyhow::anyhow!("Reference has no supported arXiv ID"))?;
    if let Some((cached_id, url, body, fetched_at)) = c.query_row(
        "SELECT external_id,source_url,body,fetched_at FROM external_summaries WHERE ref_id=? AND source='alphaXiv'",
        [ref_id], |r| Ok((r.get::<_, String>(0)?,r.get::<_, String>(1)?,r.get::<_, String>(2)?,r.get::<_, String>(3)?))
    ).optional()? && cached_id == id {
        return Ok(json!({"available":true,"cached":true,"arxiv_id":id,"source":"alphaXiv AI Overview","source_url":url,"body":body,"fetched_at":fetched_at}));
    }
    drop(c);
    let url = format!("https://www.alphaxiv.org/overview/{id}.md");
    let client = Client::builder()
        .https_only(true)
        .connect_timeout(Duration::from_secs(3))
        .timeout(Duration::from_secs(12))
        .user_agent("Mozilla/5.0 (compatible; Omabib/0.1)")
        .build()?;
    let response = client.get(&url).send()?;
    if response.status() == reqwest::StatusCode::NOT_FOUND {
        return Ok(json!({"available":false,"arxiv_id":id,"source_url":url}));
    }
    let response = response.error_for_status()?;
    let html = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v.to_ascii_lowercase().contains("html"));
    ensure!(!html, "AlphaXiv did not return an AI overview");
    let mut bytes = Vec::new();
    response.take(256 * 1024 + 1).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() <= 256 * 1024,
        "AlphaXiv overview exceeds 256 KiB"
    );
    let body = String::from_utf8(bytes)?;
    ensure!(
        looks_like_overview(&body),
        "AlphaXiv did not return an AI overview"
    );
    let writer = lib.writer.lock().unwrap();
    writer.execute("INSERT INTO external_summaries(ref_id,source,external_id,source_url,body) VALUES(?1,'alphaXiv',?2,?3,?4) \
        ON CONFLICT(ref_id) DO UPDATE SET external_id=excluded.external_id,source_url=excluded.source_url,body=excluded.body,fetched_at=CURRENT_TIMESTAMP",
        params![ref_id,id,url,body])?;
    let fetched_at: String = writer.query_row(
        "SELECT fetched_at FROM external_summaries WHERE ref_id=?",
        [ref_id],
        |r| r.get(0),
    )?;
    Ok(
        json!({"available":true,"cached":false,"arxiv_id":id,"source":"alphaXiv AI Overview","source_url":url,"body":body,"fetched_at":fetched_at}),
    )
}

#[cfg(test)]
mod tests {
    use super::{arxiv_id, looks_like_overview};
    use serde_json::json;

    #[test]
    fn accepts_only_complete_modern_arxiv_identifiers() {
        assert_eq!(
            arxiv_id(&json!({"doi":"10.48550/arXiv.2609.11108v2"})).as_deref(),
            Some("2609.11108")
        );
        assert_eq!(
            arxiv_id(&json!({"url":"https://arxiv.org/abs/2609.11108"})).as_deref(),
            Some("2609.11108")
        );
        assert_eq!(
            arxiv_id(&json!({"eprint":"2609.11108"})).as_deref(),
            Some("2609.11108")
        );
        assert_eq!(arxiv_id(&json!({"doi":"10.48550/arxiv.not-an-id"})), None);
    }

    #[test]
    fn accepts_both_live_report_headings_and_rejects_html() {
        assert!(looks_like_overview(&format!(
            "# Research Report: Paper\n{}",
            "Text ".repeat(30)
        )));
        assert!(looks_like_overview(&format!(
            "## Research Report: Paper\n{}",
            "Text ".repeat(30)
        )));
        assert!(!looks_like_overview(&format!(
            "<html><body>{}</body></html>",
            "Text ".repeat(30)
        )));
    }

    #[test]
    fn accepts_overviews_that_open_with_prose() {
        assert!(looks_like_overview(&format!(
            "This report provides a detailed analysis of the research paper.\n\n### 1. Authors and Institution(s)\n\n{}",
            "Text ".repeat(30)
        )));
        assert!(!looks_like_overview(&"Plain text without any heading. ".repeat(10)));
        assert!(!looks_like_overview(&format!("#hashtag\n{}", "Text ".repeat(30))));
    }
}
