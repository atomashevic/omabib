use crate::db::{Library, required, text};
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
use std::{
    path::{Path, PathBuf},
    process::{Command, Output},
};

pub fn command(program: &str) -> Command {
    let mut c = Command::new(program);
    let home = std::env::var("HOME").unwrap_or_default();
    c.env(
        "PATH",
        format!(
            "{home}/.local/bin:{}",
            std::env::var("PATH").unwrap_or_default()
        ),
    );
    c.env("GIT_TERMINAL_PROMPT", "0");
    c
}
pub fn checked(output: Output) -> Result<String> {
    ensure!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr).trim()
    );
    Ok(String::from_utf8(output.stdout)?)
}
pub fn git(repo: &Path, args: &[&str]) -> Result<String> {
    checked(
        command("timeout")
            .args(["120s", "git", "-C"])
            .arg(repo)
            .args(args)
            .output()?,
    )
}
fn config_path(lib: &Library) -> PathBuf {
    lib.path.parent().unwrap().join("history-config.json")
}
pub fn config(lib: &Library) -> Result<Value> {
    let file = config_path(lib);
    let mut c = if file.exists() {
        serde_json::from_slice(&std::fs::read(file)?)?
    } else {
        let repo = lib.path.parent().unwrap().join("history");
        let remote = git(&repo, &["remote", "get-url", "origin"]).unwrap_or_default();
        json!({"repo_path":repo,"remote_url":remote.trim(),"branch":"main"})
    };
    c["configured"] = json!(Path::new(text(&c, "repo_path")).join(".git").exists());
    Ok(c)
}
fn validate(c: &Value) -> Result<PathBuf> {
    let repo = PathBuf::from(required(c, "repo_path")?);
    ensure!(repo.is_absolute(), "Repository path must be absolute");
    let repo = repo
        .canonicalize()
        .context("Repository directory does not exist")?;
    let top = git(&repo, &["rev-parse", "--show-toplevel"])?;
    ensure!(
        Path::new(top.trim()).canonicalize()? == repo,
        "Choose the repository root directory"
    );
    ensure!(
        git(
            &repo,
            &["check-attr", "filter", "--", "pdfs/omabib-probe.pdf"]
        )?
        .trim()
        .ends_with(": lfs"),
        "This checkout must track PDFs with Git LFS before it can be used for history"
    );
    let branch = required(c, "branch")?;
    git(
        &repo,
        &["check-ref-format", &format!("refs/heads/{branch}")],
    )?;
    let remote = required(c, "remote_url")?;
    ensure!(
        !remote.contains(['\n', '\r'])
            && (remote.starts_with("https://")
                || remote.starts_with("ssh://")
                || remote.starts_with("git@")
                || Path::new(remote).is_absolute()),
        "Use an HTTPS/SSH remote or an absolute local Git path"
    );
    Ok(repo)
}
pub fn save_config(lib: &Library, a: &Value) -> Result<Value> {
    let _guard = lib
        .history_lock
        .try_lock()
        .map_err(|_| anyhow::anyhow!("History operation already running"))?;
    let repo = validate(a)?;
    git(&repo, &["status", "--porcelain"])?;
    let url = required(a, "remote_url")?;
    if git(&repo, &["remote", "get-url", "origin"]).is_ok() {
        git(&repo, &["remote", "set-url", "origin", url])?;
    } else {
        git(&repo, &["remote", "add", "origin", url])?;
    }
    let c = json!({"repo_path":repo,"remote_url":url,"branch":required(a,"branch")?});
    let path = config_path(lib);
    let temporary = path.with_extension("json.tmp");
    std::fs::write(&temporary, serde_json::to_vec_pretty(&c)?)?;
    std::fs::rename(temporary, path)?;
    config(lib)
}
pub fn configured_repo(lib: &Library) -> Result<(PathBuf, Value)> {
    let c = config(lib)?;
    let repo = validate(&c)?;
    ensure!(
        git(&repo, &["remote", "get-url", "origin"])?.trim() == text(&c, "remote_url"),
        "Origin changed; review and save repository settings first"
    );
    Ok((repo, c))
}
pub fn sync(lib: &Library, a: &Value) -> Result<Value> {
    let _guard = lib
        .history_lock
        .try_lock()
        .map_err(|_| anyhow::anyhow!("History operation already running"))?;
    let (repo, c) = configured_repo(lib)?;
    let mut cmd = command("timeout");
    cmd.args([
        "300s",
        "python3",
        "-c",
        include_str!("../scripts/history_snapshot.py"),
        "--repo",
    ])
    .arg(&repo)
    .arg("--db")
    .arg(&lib.path)
    .arg("--branch")
    .arg(text(&c, "branch"));
    if a.get("push") != Some(&json!(false)) {
        cmd.arg("--push");
    }
    let out = checked(cmd.output()?)?;
    serde_json::from_str(&out).context("Invalid snapshot response")
}
