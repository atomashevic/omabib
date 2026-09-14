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
    process::Stdio,
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
fn finish(lib: &Library, path: &Path, attachment: Option<&str>) -> Result<(PathBuf, String)> {
    let hash = inspect(path)?;
    let dir = lib
        .path
        .parent()
        .unwrap()
        .join("pdfs")
        .join(attachment.unwrap_or("downloads"));
    std::fs::create_dir_all(&dir)?;
    let target = dir.join(format!("{hash}.pdf"));
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
            lib.call(
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
            let (path, _) = finish(lib, &temporary, None)?;
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
        let (path, hash) = finish(lib, &temporary, Some(id))?;
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
