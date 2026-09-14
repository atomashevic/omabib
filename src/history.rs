use crate::db::{Library, read_connection, required, text};
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
/// A quick, non-mutating git call that never blocks on another Git process
/// holding the repo's lock files (used by read-only status checks so they
/// never queue up behind a sync).
fn git_readonly(repo: &Path, args: &[&str]) -> Result<String> {
    let mut full = vec!["--no-optional-locks"];
    full.extend_from_slice(args);
    git(repo, &full)
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
    save_config_locked(lib, a)
}
/// The actual work of `save_config`, assuming the caller already holds
/// `history_lock` — used by `repo_setup`, which validates/creates the
/// checkout and saves its configuration as one locked operation, so it
/// cannot re-lock the (non-reentrant) mutex by calling `save_config` itself.
fn save_config_locked(lib: &Library, a: &Value) -> Result<Value> {
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

// --- Sync state -------------------------------------------------------
// A small local record of the last sync attempt/success, so `repo_status`
// can answer "when did this last work, and what went wrong" without
// re-running Git. Never committed to the history repo itself.

fn state_path(lib: &Library) -> PathBuf {
    lib.path.parent().unwrap().join("sync-state.json")
}
fn read_state(lib: &Library) -> Value {
    std::fs::read(state_path(lib))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_else(|| json!({}))
}
fn write_state(lib: &Library, v: &Value) -> Result<()> {
    let path = state_path(lib);
    let temporary = path.with_extension("json.tmp");
    std::fs::write(&temporary, serde_json::to_vec_pretty(v)?)?;
    std::fs::rename(temporary, path)?;
    Ok(())
}
/// A timestamp in the exact same format and clock as `refs.created_at` /
/// `refs.updated_at` (`strftime('%Y-%m-%dT%H:%M:%fZ','now')`), so "pending
/// since the last sync" can compare as ordinary sortable strings without a
/// cross-clock mismatch or the 1-second truncation an integer epoch would
/// have against sub-second row timestamps.
fn now_iso(lib: &Library) -> String {
    read_connection(&lib.path)
        .and_then(|c| {
            c.query_row("SELECT strftime('%Y-%m-%dT%H:%M:%fZ','now')", [], |r| {
                r.get::<_, String>(0)
            })
            .map_err(Into::into)
        })
        .unwrap_or_default()
}

/// Classify a Git/LFS/gh error into a stable machine-readable kind plus a
/// human hint, so a caller doesn't have to pattern-match raw Git output.
pub fn explain(stderr: &str, repo: &Path, branch: &str) -> Value {
    let s = stderr.to_lowercase();
    let (kind, hint): (&str, String) = if s.contains("non-fast-forward")
        || s.contains("rejected")
        || s.contains("fetch first")
        || s.contains("behind its remote")
    {
        (
            "diverged",
            format!(
                "Omabib never merges or force-pushes. Run: git -C {} pull --rebase origin {branch}, then sync again.",
                repo.display()
            ),
        )
    } else if s.contains("authentication")
        || s.contains("permission denied")
        || s.contains("could not read username")
        || s.contains("403")
        || s.contains("401")
    {
        (
            "auth",
            "Run: gh auth setup-git (or gh auth login), then sync again.".into(),
        )
    } else if s.contains("could not resolve host")
        || s.contains("network is unreachable")
        || s.contains("timed out")
        || s.contains("connection refused")
        || s.contains("could not connect")
    {
        (
            "network",
            "The commit was kept locally. Sync again once you're online.".into(),
        )
    } else if s.contains("lfs") {
        (
            "lfs",
            format!(
                "Git LFS is missing, or this checkout doesn't track PDFs. Run: git -C {} lfs install --local",
                repo.display()
            ),
        )
    } else if s.contains("local edits")
        || s.contains("staged changes")
        || s.contains("merge conflict")
    {
        (
            "dirty",
            format!(
                "The checkout has changes outside Omabib's control. Run: git -C {} status",
                repo.display()
            ),
        )
    } else if s.contains("checkout the configured branch")
        || s.contains("checkout a branch")
    {
        (
            "branch",
            format!("The checkout is on a different branch than configured ({branch})."),
        )
    } else if s.contains("origin changed") {
        (
            "origin-changed",
            "The remote no longer matches the saved configuration. Open repository setup to review it.".into(),
        )
    } else if s.contains("already running") {
        (
            "busy",
            "Another history operation is already running. Wait for it to finish.".into(),
        )
    } else {
        (
            "unknown",
            stderr.lines().rev().take(20).collect::<Vec<_>>().into_iter().rev().collect::<Vec<_>>().join("\n"),
        )
    };
    json!({"kind":kind,"message":stderr.trim(),"hint":hint})
}

pub fn sync(lib: &Library, a: &Value) -> Result<Value> {
    let _guard = lib
        .history_lock
        .try_lock()
        .map_err(|_| anyhow::anyhow!("History operation already running"))?;
    let (repo, c) = configured_repo(lib)?;
    let branch = text(&c, "branch").to_string();
    let started = now_iso(lib);
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
    .arg(&branch);
    if a.get("push") != Some(&json!(false)) {
        cmd.arg("--push");
    }
    let output = cmd.output()?;
    let mut state = read_state(lib);
    state["last_attempt"] = json!(started);
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        let err = explain(&stderr, &repo, &branch);
        state["last_error"] = err.clone();
        let _ = write_state(lib, &state);
        anyhow::bail!("{}", err["message"]);
    }
    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let result: Value = serde_json::from_str(&stdout).context("Invalid snapshot response")?;
    state["last_result"] = result.clone();
    if result["ok"] == false {
        state["last_error"] = explain(text(&result, "push_error"), &repo, &branch);
    } else {
        state["last_success"] = json!(started);
        state["last_error"] = Value::Null;
    }
    let _ = write_state(lib, &state);
    Ok(result)
}

/// Read-only prerequisites for the storage-repo setup wizard: what tools are
/// installed, whether `gh` is logged in, and (when a path is given) what
/// state that path is in.
pub fn check(a: &Value) -> Result<Value> {
    let installed = |program: &str, args: &[&str]| -> bool {
        command(program).args(args).output().map(|o| o.status.success()).unwrap_or(false)
    };
    let git_ok = installed("git", &["--version"]);
    let lfs_ok = installed("git-lfs", &["version"]);
    let gh_ok = installed("gh", &["--version"]);
    let gh_logged_in = gh_ok && installed("gh", &["auth", "status"]);
    let gh_user = gh_logged_in
        .then(|| command("gh").args(["api", "user", "--jq", ".login"]).output().ok())
        .flatten()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|s| !s.is_empty());
    let name_set = command("git")
        .args(["config", "--global", "user.name"])
        .output()
        .map(|o| o.status.success() && !o.stdout.is_empty())
        .unwrap_or(false);
    let email_set = command("git")
        .args(["config", "--global", "user.email"])
        .output()
        .map(|o| o.status.success() && !o.stdout.is_empty())
        .unwrap_or(false);
    let path = a
        .get("repo_path")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(describe_path)
        .transpose()?
        .unwrap_or(json!({"state":"unspecified"}));
    Ok(json!({
        "git": git_ok, "git_lfs": lfs_ok, "gh": gh_ok, "gh_logged_in": gh_logged_in, "gh_user": gh_user,
        "git_identity": name_set && email_set,
        "path": path,
    }))
}
fn describe_path(raw: &str) -> Result<Value> {
    let path = PathBuf::from(raw);
    if !path.is_absolute() {
        return Ok(json!({"state":"not_absolute","path":path}));
    }
    if !path.exists() {
        return Ok(json!({"state":"missing","path":path}));
    }
    if !path.is_dir() {
        return Ok(json!({"state":"not_a_directory","path":path}));
    }
    if std::fs::read_dir(&path)?.next().is_none() {
        return Ok(json!({"state":"empty","path":path}));
    }
    if !path.join(".git").exists() {
        return Ok(json!({"state":"not_a_repo","path":path}));
    }
    let path = path.canonicalize()?;
    let lfs_tracked = git(&path, &["check-attr", "filter", "--", "pdfs/omabib-probe.pdf"])
        .map(|s| s.trim().ends_with(": lfs"))
        .unwrap_or(false);
    let branch = git(&path, &["branch", "--show-current"]).unwrap_or_default().trim().to_string();
    let origin = git(&path, &["remote", "get-url", "origin"]).unwrap_or_default().trim().to_string();
    let dirty = !git(&path, &["status", "--porcelain"]).unwrap_or_default().trim().is_empty();
    let commits: i64 = git(&path, &["rev-list", "--count", "HEAD"])
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(0);
    let is_omabib_history = path.join("metadata/format.json").exists();
    Ok(json!({
        "state":"repo", "path":path, "lfs_tracked":lfs_tracked, "branch":branch,
        "origin":origin, "dirty":dirty, "commits":commits, "is_omabib_history":is_omabib_history,
    }))
}

/// Set up the storage repository: `mode:"create_github"` makes a new
/// private GitHub repository via `gh`; `mode:"local"` adopts an existing
/// checkout, optionally configuring Git LFS for it first.
pub fn setup(lib: &Library, a: &Value) -> Result<Value> {
    let _guard = lib
        .history_lock
        .try_lock()
        .map_err(|_| anyhow::anyhow!("History operation already running"))?;
    match required(a, "mode")? {
        "create_github" => create_github(lib, a),
        "local" => use_local(lib, a),
        other => anyhow::bail!("Unknown repo_setup mode: {other}"),
    }
}
fn create_github(lib: &Library, a: &Value) -> Result<Value> {
    let name = required(a, "name")?;
    let default_path = lib.path.parent().unwrap().join("history");
    let repo_path = a
        .get("repo_path")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .unwrap_or(default_path);
    ensure!(repo_path.is_absolute(), "Repository path must be absolute");
    ensure!(
        !repo_path.exists() || std::fs::read_dir(&repo_path)?.next().is_none(),
        "The target directory already exists and is not empty"
    );
    let branch = a.get("branch").and_then(Value::as_str).unwrap_or("main").to_string();
    std::fs::create_dir_all(&repo_path)?;
    checked(
        command("git")
            .args(["init", "-q", "-b", &branch])
            .arg(&repo_path)
            .output()?,
    )?;
    checked(
        command("timeout")
            .args(["30s", "git", "-C"])
            .arg(&repo_path)
            .args(["lfs", "install", "--local"])
            .output()?,
    )?;
    std::fs::write(
        repo_path.join(".gitattributes"),
        include_str!("../packaging/history/.gitattributes"),
    )?;
    std::fs::write(
        repo_path.join(".gitignore"),
        include_str!("../packaging/history/.gitignore"),
    )?;
    std::fs::write(
        repo_path.join("README.md"),
        include_str!("../packaging/history/README.md"),
    )?;
    std::fs::create_dir_all(repo_path.join("pdfs"))?;
    std::fs::write(repo_path.join("pdfs/.gitkeep"), "")?;
    std::fs::create_dir_all(repo_path.join("tools"))?;
    std::fs::write(
        repo_path.join("tools/snapshot.py"),
        include_str!("../packaging/history/tools/snapshot.py"),
    )?;
    git(&repo_path, &["add", "."])?;
    git(&repo_path, &["commit", "-q", "-m", "Initialize Omabib history"])?;
    checked(
        command("timeout")
            .args(["60s", "gh", "repo", "create", name, "--private", "--source"])
            .arg(&repo_path)
            .args(["--remote", "origin", "--push"])
            .output()?,
    )?;
    let remote = git(&repo_path, &["remote", "get-url", "origin"])?.trim().to_string();
    save_config_locked(
        lib,
        &json!({"repo_path":repo_path,"remote_url":remote,"branch":branch}),
    )
}
fn use_local(lib: &Library, a: &Value) -> Result<Value> {
    let repo_path = PathBuf::from(required(a, "repo_path")?);
    ensure!(repo_path.is_absolute(), "Repository path must be absolute");
    ensure!(
        repo_path.join(".git").exists(),
        "This directory is not a Git repository. Run `git init` there first, or use Create private GitHub repo."
    );
    let repo_path = repo_path.canonicalize()?;
    let branch = a.get("branch").and_then(Value::as_str).unwrap_or("main").to_string();
    let lfs_tracked = git(&repo_path, &["check-attr", "filter", "--", "pdfs/omabib-probe.pdf"])
        .map(|s| s.trim().ends_with(": lfs"))
        .unwrap_or(false);
    if !lfs_tracked {
        ensure!(
            a.get("fix_lfs") == Some(&json!(true)),
            "This checkout must track PDFs with Git LFS. Retry with fix_lfs to configure it automatically."
        );
        checked(
            command("timeout")
                .args(["30s", "git", "-C"])
                .arg(&repo_path)
                .args(["lfs", "install", "--local"])
                .output()?,
        )?;
        let attrs = repo_path.join(".gitattributes");
        let mut existing = std::fs::read_to_string(&attrs).unwrap_or_default();
        if !existing.contains("filter=lfs") {
            existing.push_str("*.pdf filter=lfs diff=lfs merge=lfs -text\n*.PDF filter=lfs diff=lfs merge=lfs -text\n");
            std::fs::write(&attrs, existing)?;
        }
        let ignore = repo_path.join(".gitignore");
        let mut ig = std::fs::read_to_string(&ignore).unwrap_or_default();
        for line in [".snapshot.lock", "pdfs/.incoming-*"] {
            if !ig.lines().any(|l| l == line) {
                ig.push_str(line);
                ig.push('\n');
            }
        }
        std::fs::write(&ignore, ig)?;
        std::fs::create_dir_all(repo_path.join("pdfs"))?;
        if !repo_path.join("pdfs/.gitkeep").exists() {
            std::fs::write(repo_path.join("pdfs/.gitkeep"), "")?;
        }
        git(&repo_path, &["add", ".gitattributes", ".gitignore", "pdfs"])?;
        if git(&repo_path, &["diff", "--cached", "--quiet"]).is_err() {
            git(&repo_path, &["commit", "-q", "-m", "Configure Git LFS for Omabib PDFs"])?;
        }
    }
    let remote_url = a
        .get("remote_url")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .or_else(|| {
            git(&repo_path, &["remote", "get-url", "origin"])
                .ok()
                .map(|s| s.trim().to_string())
        })
        .filter(|s| !s.is_empty())
        .context("This checkout has no origin remote; pass remote_url")?;
    save_config_locked(
        lib,
        &json!({"repo_path":repo_path,"remote_url":remote_url,"branch":branch}),
    )
}

/// Sync status: current configuration, HEAD, ahead/behind the remote, local
/// edits, pending changes since the last successful sync, and the outcome
/// of the last attempt. Read-only and safe to poll (uses
/// `--no-optional-locks` so it never queues behind a sync in progress).
pub fn status(lib: &Library, a: &Value) -> Result<Value> {
    let c = config(lib)?;
    if c["configured"] != true {
        return Ok(json!({"configured":false}));
    }
    let repo = PathBuf::from(text(&c, "repo_path"));
    let branch = text(&c, "branch").to_string();
    if a.get("fetch") == Some(&json!(true)) {
        let _ = git(&repo, &["fetch", "origin", &branch]);
    }
    let head_hash = git_readonly(&repo, &["rev-parse", "--short", "HEAD"])
        .unwrap_or_default()
        .trim()
        .to_string();
    let head_subject = git_readonly(&repo, &["log", "-1", "--format=%s"])
        .unwrap_or_default()
        .trim()
        .to_string();
    let head_date = git_readonly(&repo, &["log", "-1", "--format=%cI"])
        .unwrap_or_default()
        .trim()
        .to_string();
    let ahead: i64 = git_readonly(&repo, &["rev-list", "--count", &format!("origin/{branch}..HEAD")])
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(0);
    let behind: i64 = git_readonly(&repo, &["rev-list", "--count", &format!("HEAD..origin/{branch}")])
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(0);
    // Scoped to the directories a sync actually manages (matching
    // history_snapshot.py's own check), so an unrelated change elsewhere in
    // the checkout — e.g. a PDF someone deleted by hand — is not reported
    // as something blocking the next sync.
    let dirty = !git_readonly(&repo, &["status", "--porcelain", "--", "metadata", "notes"])
        .unwrap_or_default()
        .trim()
        .is_empty();
    let state = read_state(lib);
    // Compared as plain strings: created_at/updated_at are fixed-width
    // ISO8601 (strftime('%Y-%m-%dT%H:%M:%fZ','now')), which sorts exactly
    // like the timestamps it represents, and last_success is stamped with
    // the same format and clock (see now_iso) so there's no cross-clock or
    // rounding mismatch between the two sides of this comparison.
    let since = state.get("last_success").and_then(Value::as_str).map(str::to_string);
    let cx = read_connection(&lib.path)?;
    let (new_refs, edited_refs, new_notes, edited_notes): (i64, i64, i64, i64) = if let Some(t) = &since {
        (
            cx.query_row("SELECT count(*) FROM refs WHERE created_at>?", [t], |r| r.get(0))
                .unwrap_or(0),
            cx.query_row(
                "SELECT count(*) FROM refs WHERE updated_at>? AND created_at<=?",
                [t, t],
                |r| r.get(0),
            )
            .unwrap_or(0),
            cx.query_row("SELECT count(*) FROM notes WHERE created_at>?", [t], |r| r.get(0))
                .unwrap_or(0),
            cx.query_row(
                "SELECT count(*) FROM notes WHERE updated_at>? AND created_at<=?",
                [t, t],
                |r| r.get(0),
            )
            .unwrap_or(0),
        )
    } else {
        (
            cx.query_row("SELECT count(*) FROM refs", [], |r| r.get(0)).unwrap_or(0),
            0,
            cx.query_row("SELECT count(*) FROM notes", [], |r| r.get(0)).unwrap_or(0),
            0,
        )
    };
    let any_pending = new_refs + edited_refs + new_notes + edited_notes > 0;
    Ok(json!({
        "configured": true,
        "repo_path": repo, "remote_url": text(&c,"remote_url"), "branch": branch,
        "head": {"hash":head_hash, "subject":head_subject, "date":head_date},
        "ahead": ahead, "behind": behind, "dirty": dirty,
        "pending": {"new_references":new_refs,"edited_references":edited_refs,"new_notes":new_notes,"edited_notes":edited_notes,"any":any_pending},
        "last_attempt": state.get("last_attempt").cloned().unwrap_or(Value::Null),
        "last_success": state.get("last_success").cloned().unwrap_or(Value::Null),
        "last_result": state.get("last_result").cloned().unwrap_or(Value::Null),
        "last_error": state.get("last_error").cloned().unwrap_or(Value::Null),
    }))
}
