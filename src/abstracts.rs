//! Abstract enrichment: try several open metadata gateways beyond the primary
//! DOI/DataCite record, stopping at the first sufficiently long abstract.
//! Every gateway here is public and requires no API key.
use crate::metadata::{clean, client, fetch};
use anyhow::Result;
use reqwest::Url;
use serde_json::Value;

/// An abstract judged "good enough" to stop searching further gateways.
const MIN_GOOD: usize = 100;

pub struct AbstractResult {
    pub text: String,
    pub source: String,
}

/// Reconstruct plain text from OpenAlex's inverted index representation.
pub(crate) fn openalex_abstract(v: &Value) -> Option<String> {
    let idx = v.get("abstract_inverted_index")?.as_object()?;
    let mut words: Vec<(u64, &str)> = Vec::new();
    for (word, positions) in idx {
        for p in positions.as_array().into_iter().flatten() {
            if let Some(n) = p.as_u64() {
                words.push((n, word.as_str()));
            }
        }
    }
    if words.is_empty() {
        return None;
    }
    words.sort_by_key(|(p, _)| *p);
    let text = words.into_iter().map(|(_, w)| w).collect::<Vec<_>>().join(" ");
    let text = clean(&text);
    if text.trim().is_empty() { None } else { Some(text) }
}

/// Semantic Scholar's Graph API returns a plain-text abstract field.
pub(crate) fn semantic_scholar_abstract(v: &Value) -> Option<String> {
    v.get("abstract")
        .and_then(Value::as_str)
        .map(clean)
        .filter(|s| !s.trim().is_empty())
}

/// Europe PMC's search result carries `abstractText` on the matching record.
pub(crate) fn europe_pmc_abstract(v: &Value, doi: &str) -> Option<String> {
    let items = v["resultList"]["result"].as_array()?;
    let hit = items
        .iter()
        .find(|r| crate::db::normalize_doi(crate::db::text(r, "doi")) == doi)?;
    let text = clean(crate::db::text(hit, "abstractText"));
    if text.trim().is_empty() { None } else { Some(text) }
}

fn consider(best: &mut Option<AbstractResult>, text: Option<String>, source: &str) -> bool {
    if let Some(text) = text
        && !text.trim().is_empty()
    {
        let better = best.as_ref().is_none_or(|b| text.chars().count() > b.text.chars().count());
        let good_enough = text.chars().count() >= MIN_GOOD;
        if better {
            *best = Some(AbstractResult {
                text,
                source: source.to_string(),
            });
        }
        return good_enough;
    }
    false
}

/// Look for an abstract by exact DOI or arXiv ID, trying OpenAlex, Semantic
/// Scholar, then Europe PMC in order. Stops as soon as a sufficiently long
/// abstract is found; otherwise returns the longest one seen, if any.
pub fn find_abstract(doi: &str, arxiv_id: &str) -> Result<(Option<AbstractResult>, Vec<String>)> {
    let mut warnings = Vec::new();
    let mut best: Option<AbstractResult> = None;
    let c = client()?;

    if !doi.is_empty() {
        match Url::parse(&format!("https://api.openalex.org/works/doi:{doi}")) {
            Ok(url) => match fetch(&c, url) {
                Ok(v) => {
                    if consider(&mut best, openalex_abstract(&v), "OpenAlex") {
                        return Ok((best, warnings));
                    }
                }
                Err(e) => warnings.push(format!("OpenAlex: {e}")),
            },
            Err(e) => warnings.push(format!("OpenAlex: {e}")),
        }
    }

    let s2_id = if !doi.is_empty() {
        Some(format!("DOI:{doi}"))
    } else if !arxiv_id.is_empty() {
        Some(format!("ARXIV:{arxiv_id}"))
    } else {
        None
    };
    if let Some(id) = s2_id {
        let mut url = Url::parse(&format!(
            "https://api.semanticscholar.org/graph/v1/paper/{id}"
        ))?;
        url.query_pairs_mut().append_pair("fields", "abstract");
        match fetch(&c, url) {
            Ok(v) => {
                if consider(&mut best, semantic_scholar_abstract(&v), "Semantic Scholar") {
                    return Ok((best, warnings));
                }
            }
            Err(e) => warnings.push(format!("Semantic Scholar: {e}")),
        }
    }

    if !doi.is_empty() {
        let mut url = Url::parse("https://www.ebi.ac.uk/europepmc/webservices/rest/search")?;
        url.query_pairs_mut()
            .append_pair("query", &format!("DOI:\"{}\"", doi.replace('"', "")))
            .append_pair("format", "json")
            .append_pair("resultType", "core")
            .append_pair("pageSize", "3");
        match fetch(&c, url) {
            Ok(v) => {
                consider(&mut best, europe_pmc_abstract(&v, doi), "Europe PMC");
            }
            Err(e) => warnings.push(format!("Europe PMC: {e}")),
        }
    }

    Ok((best, warnings))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn openalex_inverted_index_reconstructs_order() {
        let v = json!({"abstract_inverted_index":{"Group":[0],"consensus":[1],"emerges":[2],"slowly.":[3]}});
        assert_eq!(
            openalex_abstract(&v).unwrap(),
            "Group consensus emerges slowly."
        );
        assert_eq!(openalex_abstract(&json!({})), None);
        assert_eq!(openalex_abstract(&json!({"abstract_inverted_index":{}})), None);
    }

    #[test]
    fn semantic_scholar_abstract_field() {
        assert_eq!(
            semantic_scholar_abstract(&json!({"abstract":"  A short text.  "})),
            Some("A short text.".to_string())
        );
        assert_eq!(semantic_scholar_abstract(&json!({"abstract":""})), None);
        assert_eq!(semantic_scholar_abstract(&json!({})), None);
    }

    #[test]
    fn europe_pmc_matches_exact_doi_only() {
        let v = json!({"resultList":{"result":[
            {"doi":"10.1038/other","abstractText":"Wrong paper."},
            {"doi":"10.1038/30918","abstractText":"Right paper abstract."}
        ]}});
        assert_eq!(
            europe_pmc_abstract(&v, "10.1038/30918"),
            Some("Right paper abstract.".to_string())
        );
        assert_eq!(europe_pmc_abstract(&v, "10.1038/nope"), None);
    }

    #[test]
    fn consider_prefers_longer_and_stops_at_threshold() {
        let mut best = None;
        assert!(!consider(&mut best, Some("short".into()), "A"));
        assert_eq!(best.as_ref().unwrap().source, "A");
        let long = "x".repeat(MIN_GOOD);
        // A shorter candidate than the current best never overwrites it.
        assert!(!consider(&mut best, Some("shrt".into()), "B"));
        assert_eq!(best.as_ref().unwrap().source, "A");
        assert!(consider(&mut best, Some(long.clone()), "C"));
        assert_eq!(best.as_ref().unwrap().text, long);
        assert_eq!(best.as_ref().unwrap().source, "C");
    }
}
