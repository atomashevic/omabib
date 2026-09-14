use crate::{
    db::{Library, required, text},
    history,
};
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs::{File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::Duration,
};
const MAX_PDF: u64 = 512 * 1024 * 1024;
fn inspect(path: &Path) -> Result<String> {
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
fn temp(lib: &Library) -> Result<PathBuf> {
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
fn finish(lib: &Library, path: &Path, citekey: &str) -> Result<(PathBuf, String)> {
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
pub fn pull(lib: &Library, a: &Value) -> Result<Value> {
    let temporary = temp(lib)?;
    let result = (|| {
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
            let (path, _) = finish(lib, &temporary, text(&reference, "citekey"))?;
            let mut args = json!({"ref_id":ref_id,"path":path});
            if let Some(k) = a.get("idempotency_key") {
                args["idempotency_key"] = k.clone();
            }
            return add(lib, &args);
        }
        let _guard = lib
            .history_lock
            .try_lock()
            .map_err(|_| anyhow::anyhow!("History operation already running"))?;
        let id = required(a, "attachment_id")?;
        ensure!(
            uuid::Uuid::parse_str(id).is_ok(),
            "Attachment ID must be a UUID"
        );
        let attachment = lib.call("get_attachment", &json!({"id":id}))?;
        let reference = lib.call(
            "get_reference",
            &json!({"id":attachment["ref_id"],"include_metadata":false}),
        )?;
        let (repo, cfg) = history::configured_repo(lib)?;
        history::git(&repo, &["fetch", "origin", text(&cfg, "branch")])?;
        let remote_ref = format!("refs/remotes/origin/{}", text(&cfg, "branch"));
        let metadata = history::git(
            &repo,
            &[
                "show",
                &format!("{remote_ref}:metadata/attachments/{id}.json"),
            ],
        )?;
        let archived: Value = serde_json::from_str(&metadata)?;
        ensure!(
            archived["ref_id"] == attachment["ref_id"],
            "Archived PDF belongs to a different reference"
        );
        let hash = required(&archived, "sha256")?;
        ensure!(
            hash.len() == 64 && hash.bytes().all(|b| b.is_ascii_hexdigit()),
            "Invalid archived PDF hash"
        );
        let pdf = format!("pdfs/{hash}.pdf");
        ensure!(
            text(&archived, "repository_path") == pdf,
            "Invalid archive path"
        );
        let pointer = history::git(&repo, &["show", &format!("{remote_ref}:{pdf}")])?;
        ensure!(
            pointer.starts_with("version https://git-lfs.github.com/spec/v1\n")
                && pointer.lines().any(|l| l == format!("oid sha256:{hash}")),
            "Archive is not the expected LFS pointer"
        );
        let size = pointer
            .lines()
            .find_map(|l| l.strip_prefix("size "))
            .context("LFS pointer has no size")?
            .parse::<u64>()?;
        ensure!(size <= MAX_PDF, "Archived PDF exceeds 512 MiB");
        let out = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)?;
        let mut cmd = history::command("timeout");
        cmd.args(["120s", "git", "-C"])
            .arg(&repo)
            .args([
                "-c",
                "lfs.fetchinclude=",
                "-c",
                "lfs.fetchexclude=",
                "lfs",
                "smudge",
                &pdf,
            ])
            .env_remove("GIT_LFS_SKIP_SMUDGE")
            .stdin(Stdio::piped())
            .stdout(Stdio::from(out))
            .stderr(Stdio::piped());
        let mut child = cmd.spawn()?;
        child.stdin.take().unwrap().write_all(pointer.as_bytes())?;
        history::checked(child.wait_with_output()?)?;
        ensure!(
            std::fs::metadata(&temporary)?.len() == size && inspect(&temporary)? == hash,
            "Downloaded PDF checksum mismatch"
        );
        let (path, hash) = finish(lib, &temporary, text(&reference, "citekey"))?;
        lib.call(
            "relink_attachment",
            &json!({"id":id,"path":path,"fingerprint":hash}),
        )
    })();
    if temporary.exists() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}
/// Return a locally readable path to a reference's PDF, in order: an
/// existing attachment; a missing attachment restored from the history
/// repository's Git LFS archive; or (unless `download:false`) a freshly
/// downloaded open-access copy, attached in the process.
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
            if let Ok(restored) = pull(lib, &json!({"attachment_id":p["id"]})) {
                return Ok(
                    json!({"path":restored["path"],"source":"history","attachment_id":restored["id"]}),
                );
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
/// Read the first two pages of a PDF to recognize an embedded DOI or arXiv
/// ID, falling back to a Crossref title search using the PDF's Title
/// metadata (or its first substantial line of text) when no identifier is
/// found. Page text is used only for this lookup; it is never stored.
pub fn identify_pdf(a: &Value) -> Result<Value> {
    let input = PathBuf::from(required(a, "path")?);
    ensure!(input.is_absolute(), "PDF path must be absolute");
    let path = input.canonicalize()?;
    inspect(&path)?;
    let out = Command::new("pdftotext")
        .args(["-f", "1", "-l", "2", "-q"])
        .arg(&path)
        .arg("-")
        .output()
        .context("pdftotext is required to read PDF text (install poppler-utils)")?;
    ensure!(out.status.success(), "Could not extract text from this PDF");
    let page_text = String::from_utf8_lossy(&out.stdout).to_string();
    let info = Command::new("pdfinfo").arg(&path).output().ok();
    let info_text = info
        .as_ref()
        .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
        .unwrap_or_default();
    let pages: Option<i64> = info_text
        .lines()
        .find_map(|l| l.strip_prefix("Pages:"))
        .and_then(|s| s.trim().parse().ok());
    let title = info_text
        .lines()
        .find_map(|l| l.strip_prefix("Title:"))
        .map(|s| s.trim().to_string())
        .filter(|t| !t.is_empty());

    for token in page_text.split(|c: char| c.is_whitespace() || "()[]<>".contains(c)) {
        let token = token.trim_matches(|c: char| !c.is_alphanumeric() && !"./:-".contains(c));
        if token.len() < 6 {
            continue;
        }
        if crate::ingest::doi_from_text(token).is_none()
            && crate::ingest::arxiv_id_from_text(token).is_none()
        {
            continue;
        }
        if let Ok(mut item) = crate::ingest::identify_one(token) {
            item["match_kind"] = json!("identifier found in the PDF text");
            return Ok(json!({"candidates":[item],"pages":pages}));
        }
    }
    let query_title = title.unwrap_or_else(|| {
        page_text
            .lines()
            .map(str::trim)
            .find(|l| l.chars().count() > 8)
            .unwrap_or("")
            .to_string()
    });
    ensure!(
        !query_title.is_empty(),
        "No DOI, arXiv ID or usable title was found in this PDF. Paste its DOI, arXiv ID or BibTeX instead."
    );
    let c = crate::metadata::client()?;
    let mut candidates = crate::metadata::title_search(&c, &query_title, "")?;
    let target = json!({"title":query_title});
    candidates.sort_by(|a, b| {
        crate::metadata::match_score(&target, b).total_cmp(&crate::metadata::match_score(&target, a))
    });
    candidates.truncate(5);
    for c in &mut candidates {
        c["match_kind"] = json!("pdf title search: verify the paper");
    }
    ensure!(
        !candidates.is_empty(),
        "No matching reference was found for this PDF's title. Paste its DOI or BibTeX instead."
    );
    Ok(json!({"candidates":candidates,"pages":pages,"query_title":query_title}))
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
}
