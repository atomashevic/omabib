use crate::db::{Library, required, text};
use crate::recognize::{self, Clues, Title};
use anyhow::{Context, Result, ensure};
use rusqlite::OptionalExtension;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs::{File, OpenOptions},
    io::Read,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};
const MAX_PDF: u64 = 512 * 1024 * 1024;
pub(crate) fn inspect(path: &Path) -> Result<String> {
    let mut f = File::open(path).context("Cannot open PDF")?;
    ensure!(
        f.metadata()?.is_file() && f.metadata()?.len() <= MAX_PDF,
        "PDF must be a regular file no larger than 512 MiB"
    );
    let mut hash = Sha256::new();
    let mut buffer = [0u8; 65536];
    let mut first = true;
    loop {
        let n = f.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        if first {
            ensure!(
                buffer[..n].windows(5).take(1024).any(|s| s == b"%PDF-"),
                "File is not a PDF"
            );
            first = false;
        }
        hash.update(&buffer[..n]);
    }
    ensure!(!first, "PDF is empty");
    Ok(format!("{:x}", hash.finalize()))
}
pub fn add(lib: &Library, a: &Value) -> Result<Value> {
    let r = lib.call(
        "get_reference",
        &json!({"id":required(a,"ref_id")?,"include_metadata":false}),
    )?;
    let input = PathBuf::from(required(a, "path")?);
    ensure!(input.is_absolute(), "PDF path must be absolute");
    let path = input.canonicalize()?;
    let hash = inspect(&path)?;
    let mut args = json!({"ref_id":r["id"],"path":path,"file_type":"pdf","fingerprint":hash});
    if let Some(k) = a.get("idempotency_key") {
        args["idempotency_key"] = k.clone();
    }
    lib.call("attach", &args)
}
pub(crate) fn temp(lib: &Library) -> Result<PathBuf> {
    let dir = lib.path.parent().unwrap().join("pdfs");
    std::fs::create_dir_all(&dir)?;
    Ok(dir.join(format!(".{}.part", uuid::Uuid::new_v4())))
}
/// Turn a citation key into a filesystem-safe basename for a managed PDF.
fn sanitize_filename(name: &str) -> String {
    let s: String = name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-') {
                c
            } else {
                '_'
            }
        })
        .collect();
    let s = s.trim_matches(|c| c == '_' || c == '.').to_string();
    if s.is_empty() { "reference".into() } else { s }
}
/// Move a validated, downloaded/restored PDF into managed storage, named
/// after the reference's citation key (e.g. `pdfs/watts1998collective.pdf`)
/// rather than its content hash, so a person can find it by browsing.
/// A same-named file with different bytes gets a short hash suffix instead
/// of being overwritten.
pub(crate) fn finish(lib: &Library, path: &Path, citekey: &str) -> Result<(PathBuf, String)> {
    let hash = inspect(path)?;
    let dir = lib.path.parent().unwrap().join("pdfs");
    std::fs::create_dir_all(&dir)?;
    let base = sanitize_filename(citekey);
    let mut target = dir.join(format!("{base}.pdf"));
    if target.exists() && inspect(&target)? != hash {
        target = dir.join(format!("{base}-{}.pdf", &hash[..8]));
    }
    if target.exists() {
        ensure!(inspect(&target)? == hash, "Cached PDF checksum mismatch");
        std::fs::remove_file(path)?;
    } else {
        std::fs::rename(path, &target)?;
    }
    Ok((target, hash))
}
/// Download a PDF from an HTTPS URL into managed storage under a
/// citekey-derived name, without attaching it to any reference. Shared by
/// `pull` (which already has a saved reference to name it after) and
/// `add_reference` (which names it from a not-yet-saved preview's citekey
/// hint, since the download happens before the reference is imported).
pub(crate) fn download_and_store(
    lib: &Library,
    url: &str,
    citekey_hint: &str,
) -> Result<(PathBuf, String)> {
    let temporary = temp(lib)?;
    let result = (|| {
        let url = reqwest::Url::parse(url)?;
        ensure!(
            url.scheme() == "https" && url.username().is_empty() && url.password().is_none(),
            "PDF downloads require an HTTPS URL without embedded credentials"
        );
        let response = reqwest::blocking::Client::builder()
            .https_only(true)
            .timeout(Duration::from_secs(90))
            .build()?
            .get(url)
            .send()?
            .error_for_status()?;
        ensure!(
            response.content_length().is_none_or(|n| n <= MAX_PDF),
            "PDF exceeds 512 MiB"
        );
        let mut output = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)?;
        let bytes = std::io::copy(&mut response.take(MAX_PDF + 1), &mut output)?;
        ensure!(bytes <= MAX_PDF, "PDF exceeds 512 MiB");
        drop(output);
        finish(lib, &temporary, citekey_hint)
    })();
    if temporary.exists() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}
/// Download a PDF from an explicit HTTPS `url` for `ref_id` and attach it, or
/// fetch attachment `attachment_id` from the sync storage.
pub fn pull(lib: &Library, a: &Value) -> Result<Value> {
    if let Some(url) = a.get("url").and_then(Value::as_str) {
        ensure!(
            a.get("attachment_id").is_none(),
            "Choose a URL or an attachment ID"
        );
        let ref_id = required(a, "ref_id")?;
        let reference = lib.call(
            "get_reference",
            &json!({"id":ref_id,"include_metadata":false}),
        )?;
        let (path, _) = download_and_store(lib, url, text(&reference, "citekey"))?;
        let mut args = json!({"ref_id":ref_id,"path":path});
        if let Some(k) = a.get("idempotency_key") {
            args["idempotency_key"] = k.clone();
        }
        return add(lib, &args);
    }
    let id = required(a, "attachment_id")?;
    ensure!(
        uuid::Uuid::parse_str(id).is_ok(),
        "Attachment ID must be a UUID"
    );
    crate::sync::fetch_attachment(lib, id)?
        .context("This PDF isn't in the sync storage; sync the computer that has it first")?;
    let mut attachment = lib.call("get_attachment", &json!({"id":id}))?;
    attachment["exists"] = json!(true);
    Ok(attachment)
}
/// Return a locally readable path to a reference's PDF, in order: an
/// existing attachment; one only in the sync storage, downloaded; or (unless
/// `download:false`) a freshly downloaded open-access copy, attached in the
/// process.
pub fn get_pdf(lib: &Library, a: &Value) -> Result<Value> {
    let ref_id = required(a, "ref_id")?;
    let r = lib.call(
        "get_reference",
        &json!({"id":ref_id,"include_attachments":true}),
    )?;
    if let Some(items) = r["attachments"].as_array() {
        for p in items {
            if !text(p, "file_type").eq_ignore_ascii_case("pdf") {
                continue;
            }
            if p["exists"] == true {
                return Ok(json!({"path":p["path"],"source":"local","attachment_id":p["id"]}));
            }
            if let Some(path) = crate::sync::fetch_attachment(lib, text(p, "id"))? {
                return Ok(json!({"path":path,"source":"cloud","attachment_id":p["id"]}));
            }
        }
    }
    ensure!(
        a.get("download") != Some(&json!(false)),
        "No local PDF for this reference, and download is disabled"
    );
    let doi = crate::metadata::inferred_doi(&r);
    let arxiv_id = crate::metadata::arxiv_from_doi(&doi);
    let mut url = text(&r["fields"], "pdf").to_string();
    if url.is_empty() && !arxiv_id.is_empty() {
        url = format!("https://arxiv.org/pdf/{arxiv_id}");
    }
    if url.is_empty() {
        let e = crate::abstracts::enrich(&doi, &arxiv_id)?;
        url = e.pdf_url.unwrap_or_default();
    }
    ensure!(
        !url.is_empty(),
        "No PDF is attached, and no open-access copy was found (checked the reference's own link, arXiv, OpenAlex and Semantic Scholar). Use add_pdf to attach one manually."
    );
    let result = pull(lib, &json!({"ref_id":ref_id,"url":url}))?;
    Ok(json!({"path":result["path"],"source":"downloaded","attachment_id":result["id"]}))
}
/// Copy a PDF into managed storage under a citekey-derived name, as Zotero
/// stores an imported file; the original stays where it is. A file already
/// in managed storage is used as it is. Returns the stored path and its hash.
pub(crate) fn store_copy(lib: &Library, path: &Path, citekey_hint: &str) -> Result<(PathBuf, String)> {
    let path = path.canonicalize().context("Cannot read pdf_path")?;
    let dir = lib.path.parent().unwrap().join("pdfs");
    if dir.canonicalize().is_ok_and(|d| path.starts_with(d)) {
        let hash = inspect(&path)?;
        return Ok((path, hash));
    }
    let temporary = temp(lib)?;
    let result = std::fs::copy(&path, &temporary)
        .map_err(anyhow::Error::from)
        .and_then(|_| finish(lib, &temporary, citekey_hint));
    if temporary.exists() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}
/// What identifying a PDF has found so far.
#[derive(Default)]
struct Search {
    /// A record that is this paper, which ends the search.
    sure: Option<Value>,
    /// Records found but not confirmed by the PDF's text, for the person to check.
    maybe: Vec<Value>,
    warnings: Vec<String>,
}
impl Search {
    fn done(&self, deadline: Instant) -> bool {
        self.sure.is_some() || Instant::now() > deadline
    }
    fn keep(&mut self, mut item: Value, how: &str, sure: bool) {
        item["match_kind"] = json!(how);
        item["confident"] = json!(sure);
        if sure && self.sure.is_none() {
            self.sure = Some(item);
        } else if !self.maybe.iter().any(|m| m["bibtex"] == item["bibtex"]) {
            self.maybe.push(item);
        }
    }
    /// Look an identifier up the way the Add box does; sure when `trusted`
    /// and the PDF prints the title found.
    fn identifier(&mut self, clues: &Clues, token: &str, how: &str, trusted: bool) {
        match crate::ingest::identify_one(token) {
            Ok(item) => {
                let sure = trusted && confirmed(clues, text(&item, "title"), text(&item, "authors"));
                self.keep(item, how, sure)
            }
            Err(e) => self.warnings.push(format!("{token}: {e:#}")),
        }
    }
    /// A record from a title search, by its DOI or arXiv ID when it has one,
    /// so it gets the metadata and abstract an identifier would.
    fn record(&mut self, clues: &Clues, record: &Value, how: &str, trusted: bool) {
        let f = &record["fields"];
        if !text(f, "doi").is_empty() {
            self.identifier(clues, text(f, "doi"), how, trusted)
        } else if text(f, "archiveprefix") == "arXiv" && record["entry_type"] == "misc" {
            self.identifier(clues, &format!("arXiv:{}", text(f, "eprint")), how, trusted)
        } else {
            match made(record) {
                Ok(item) => self.keep(item, how, trusted),
                Err(e) => self.warnings.push(format!("{}: {e:#}", text(record, "gateway"))),
            }
        }
    }
}
fn confirmed(clues: &Clues, title: &str, authors: &str) -> bool {
    clues.printed(title, &recognize::surnames(authors))
}
fn confirmed_record(clues: &Clues, record: &Value) -> bool {
    confirmed(clues, text(&record["fields"], "title"), text(&record["fields"], "author"))
}
/// The same title can be an article and its reprint or preprint: the record
/// whose venue and year the PDF prints is the one in hand.
fn venue_score(clues: &Clues, record: &Value) -> i32 {
    let f = &record["fields"];
    let venue = ["journal", "booktitle"]
        .iter()
        .map(|k| text(f, k))
        .find(|v| !v.is_empty())
        .unwrap_or("");
    2 * i32::from(clues.mentions(venue))
        + i32::from(clues.has_year(text(f, "year")))
        + i32::from(["article", "inproceedings"].contains(&text(record, "entry_type")))
}
fn candidate(fields: &Value, kind: &str, source: &Value, recognized: &str, abstract_source: Value) -> Result<Value> {
    let bibtex = crate::ingest::bibliography(fields, kind)?;
    Ok(json!({
        "input": source,
        "bibtex": bibtex,
        "citekey": crate::ingest::citation_key(fields),
        "title": text(fields, "title"),
        "authors": text(fields, "author"),
        "year": text(fields, "year"),
        "source": source,
        "recognized": recognized,
        "abstract_source": abstract_source,
        "pdf_url": Value::Null,
        "warnings": Vec::<String>::new(),
    }))
}
/// A candidate from a record that has no DOI to look up, with an arXiv
/// abstract when the record lacks one and has an arXiv ID.
fn made(record: &Value) -> Result<Value> {
    let mut fields = record["fields"].clone();
    let mut abstract_source = if text(&fields, "abstract").is_empty() {
        Value::Null
    } else {
        record["gateway"].clone()
    };
    let arxiv = text(&fields, "eprint").to_string();
    if abstract_source.is_null()
        && text(&fields, "archiveprefix") == "arXiv"
        && let Ok((Some(found), _)) =
            crate::abstracts::find_abstract(&format!("10.48550/arxiv.{arxiv}"), &arxiv)
    {
        fields["abstract"] = json!(found.text);
        abstract_source = json!(found.source);
    }
    let kind = Some(text(record, "entry_type")).filter(|k| !k.is_empty()).unwrap_or("misc");
    let recognized = if kind == "book" { "isbn" } else { "title" };
    candidate(&fields, kind, &record["source"], recognized, abstract_source)
}
fn with_field(bibtex: &str, key: &str, value: &str) -> Result<String> {
    let mut b = crate::db::parse_bibtex(bibtex)?;
    let e = b.iter_mut().next().context("Empty BibTeX entry")?;
    e.set(
        key,
        vec![biblatex::Spanned::detached(biblatex::Chunk::Normal(value.into()))],
    );
    Ok(crate::db::serialize_entry(e))
}
fn file_title(name: &str) -> String {
    let stem = Path::new(name)
        .file_stem()
        .map(|s| s.to_string_lossy().replace(['_', '+'], " "))
        .unwrap_or_default();
    let title = stem.split_whitespace().collect::<Vec<_>>().join(" ");
    if title.is_empty() { "Untitled PDF".into() } else { title }
}
/// The entry Zotero makes when nothing is found online: the PDF's own
/// title, authors, abstract and year, or a title from the file name.
fn from_pdf(clues: &Clues, file_name: &str) -> Result<Value> {
    let (title, how) = match clues.titles.first() {
        Some(t) => (t.text.clone(), "read from the PDF itself"),
        None => (file_title(file_name), "title from the file name"),
    };
    let abstract_text = clues.abstract_text.clone().unwrap_or_default();
    let fields = json!({
        "title": title,
        "author": recognize::bibtex_authors(&clues.authors),
        "abstract": abstract_text,
        "year": clues.year.clone().unwrap_or_default(),
    });
    let read = if abstract_text.is_empty() { Value::Null } else { json!("the PDF") };
    let mut item = candidate(&fields, "misc", &json!(format!("PDF file {file_name}")), "pdf", read)?;
    item["match_kind"] = json!(how);
    item["confident"] = json!(false);
    Ok(item)
}
fn search_online(clues: &Clues, s: &mut Search) -> Result<()> {
    use crate::metadata as m;
    let c = m::client()?;
    let deadline = Instant::now() + Duration::from_secs(60);
    if let Some(id) = &clues.arxiv {
        s.identifier(clues, &format!("arXiv:{id}"), "arXiv ID on the first page", true);
    }
    if !s.done(deadline)
        && let Some(doi) = &clues.info_doi
    {
        s.identifier(clues, doi, "DOI in the PDF's properties", true);
    }
    // A DOI printed on the first pages can be a cited paper's: check the
    // record's title against the page before the full lookup.
    let mut unconfirmed = None;
    for doi in clues.dois.iter().take(3) {
        if s.done(deadline) {
            break;
        }
        match m::doi_record(&c, doi) {
            Ok(r) if confirmed_record(clues, &r) => {
                s.identifier(clues, doi, "DOI printed in the PDF", true)
            }
            Ok(_) => {
                unconfirmed.get_or_insert(doi.clone());
            }
            Err(e) => s.warnings.push(format!("{doi}: {e:#}")),
        }
    }
    if !s.done(deadline)
        && let Some(isbn) = &clues.isbn
    {
        match m::open_library(&c, isbn) {
            // A book's title page can be a few pages in, so the title
            // printed anywhere in the pages read confirms it.
            Ok(Some(r)) => match made(&r) {
                Ok(item) => {
                    let sure = clues.mentions(text(&r["fields"], "title"));
                    s.keep(item, "ISBN printed in the PDF", sure)
                }
                Err(e) => s.warnings.push(format!("Open Library: {e:#}")),
            },
            Ok(None) => s.warnings.push(format!("ISBN {isbn} is not in Open Library")),
            Err(e) => s.warnings.push(format!("Open Library: {e:#}")),
        }
    }
    let titles: Vec<&Title> = clues.titles.iter().take(2).collect();
    for t in &titles {
        if s.done(deadline) {
            break;
        }
        // Narrowed by the first author when the PDF names one; Crossref
        // ranks exact titles poorly without.
        let hint = clues.author_hint(t);
        let search = |author: &str| -> Result<Vec<Value>> {
            Ok(m::title_search(&c, &t.text, author)?
                .into_iter()
                .filter(|r| confirmed_record(clues, r))
                .collect())
        };
        let mut found = search(hint.as_deref().unwrap_or(""));
        if hint.is_some() && found.as_ref().is_ok_and(Vec::is_empty) {
            found = search("");
        }
        let mut found = match found {
            Ok(found) => found,
            Err(e) => {
                s.warnings.push(format!("Crossref: {e:#}"));
                continue;
            }
        };
        found.sort_by_key(|r| std::cmp::Reverse(venue_score(clues, r)));
        let tied = found.len() > 1
            && venue_score(clues, &found[1]) == venue_score(clues, &found[0])
            && found[1]["fields"]["doi"] != found[0]["fields"]["doi"];
        if let Some(best) = found.first() {
            s.record(clues, best, "title found on Crossref", !tied);
        }
        if tied {
            s.record(clues, &found[1], "title found on Crossref", false);
        }
    }
    for t in &titles {
        if s.done(deadline) {
            break;
        }
        match m::semantic_scholar_match(&c, &t.text) {
            Ok(Some(p)) => {
                let r = m::semantic_scholar(&p);
                if confirmed_record(clues, &r) {
                    s.record(clues, &r, "title found on Semantic Scholar", true);
                }
            }
            Ok(None) => {}
            Err(e) => s.warnings.push(format!("Semantic Scholar: {e:#}")),
        }
    }
    for t in &titles {
        if s.done(deadline) {
            break;
        }
        match m::arxiv_search(&c, &t.text) {
            Ok(hits) => {
                let hit = hits.iter().find(|h| {
                    let names: Vec<&str> = h["authors"].as_array().into_iter().flatten().filter_map(Value::as_str).collect();
                    confirmed(clues, text(h, "title"), &names.join(" and "))
                });
                if let Some(h) = hit {
                    s.identifier(clues, &format!("arXiv:{}", text(h, "arxiv")), "title found on arXiv", true);
                }
            }
            Err(e) => s.warnings.push(format!("arXiv: {e:#}")),
        }
    }
    for t in &titles {
        if s.done(deadline) {
            break;
        }
        match m::europe_pmc_search(&c, &t.text) {
            Ok(records) => {
                if let Some(r) = records.iter().find(|r| confirmed_record(clues, r)) {
                    s.record(clues, r, "title found on Europe PMC", true);
                }
            }
            Err(e) => s.warnings.push(format!("Europe PMC: {e:#}")),
        }
    }
    if !s.done(deadline)
        && let Some(doi) = unconfirmed
    {
        s.identifier(clues, &doi, "DOI printed in the PDF", false);
    }
    if Instant::now() > deadline && s.sure.is_none() {
        s.warnings.push("Stopped looking after a minute; some services did not answer.".into());
    }
    Ok(())
}
/// Identify a PDF the way Zotero's recognizer does, with public services in
/// place of Zotero's own server and title database. In order: an arXiv ID
/// stamped on page one; a DOI in the document properties; DOIs printed on
/// the first two pages; an ISBN (Open Library); then the title searched on
/// Crossref, Semantic Scholar, arXiv and Europe PMC. A record counts only
/// when the PDF prints its title (`Clues::printed`), and the search stops at
/// the first that does; others are offered to check. An entry read from the
/// PDF itself is always offered last. Only titles, a surname and identifiers
/// leave the computer, and nothing does with `online:false`.
pub fn identify_pdf(lib: &Library, a: &Value) -> Result<Value> {
    let input = PathBuf::from(required(a, "path")?);
    ensure!(input.is_absolute(), "PDF path must be absolute");
    let path = input.canonicalize()?;
    let fingerprint = inspect(&path)?;
    let reading = lib.pdf.read_paper(&path)?;
    let clues = Clues::read(&reading);
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let mut search = Search::default();
    if a.get("online") != Some(&json!(false)) && clues.has_text {
        search_online(&clues, &mut search)?;
    }
    // As Zotero does, the PDF's own abstract fills in for a record without one.
    if let Some(found) = &clues.abstract_text {
        for item in search.sure.iter_mut().chain(search.maybe.iter_mut()) {
            if item["abstract_source"].is_null()
                && let Ok(bibtex) = with_field(text(item, "bibtex"), "abstract", found)
            {
                item["bibtex"] = json!(bibtex);
                item["abstract_source"] = json!("the PDF");
            }
        }
    }
    let mut candidates: Vec<Value> = search.sure.into_iter().chain(search.maybe).collect();
    let mut warnings = if candidates.first().is_some_and(|c| c["confident"] == true) {
        Vec::new()
    } else {
        search.warnings
    };
    candidates.push(from_pdf(&clues, &name)?);
    if !clues.has_text {
        warnings.insert(0, "This PDF has no text to read; it may be a scanned image. Add its DOI instead, or edit the entry made from its file name.".into());
    }
    let existing = crate::db::read_connection(&lib.path)?
        .query_row(
            "SELECT r.id,r.citekey,r.title FROM attachments a JOIN refs r ON r.id=a.ref_id WHERE a.fingerprint=? AND a.file_type='pdf' LIMIT 1",
            [&fingerprint],
            |row| Ok(json!({"id":row.get::<_,String>(0)?,"citekey":row.get::<_,String>(1)?,"title":row.get::<_,String>(2)?})),
        )
        .optional()?;
    Ok(json!({
        "path": path,
        "file_name": name,
        "pages": reading.page_count,
        "fingerprint": fingerprint,
        "existing": existing,
        "has_text": clues.has_text,
        "query_title": clues.titles.first().map(|t| t.text.clone()),
        "candidates": candidates,
        "warnings": warnings,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn sanitize_filename_keeps_safe_characters_only() {
        assert_eq!(sanitize_filename("watts1998collective"), "watts1998collective");
        assert_eq!(sanitize_filename("weird/name: paper?.pdf"), "weird_name__paper_.pdf");
        assert_eq!(sanitize_filename(""), "reference");
        assert_eq!(sanitize_filename("___"), "reference");
    }
    #[test]
    fn file_title_turns_a_file_name_into_words() {
        assert_eq!(file_title("Attention_Is_All_You+Need.pdf"), "Attention Is All You Need");
        assert_eq!(file_title("___.pdf"), "Untitled PDF");
    }
}
