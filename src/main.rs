use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use serde_json::{Value, json};
use std::path::PathBuf;
#[derive(Parser)]
#[command(version, about)]
struct Args {
    #[command(subcommand)]
    command: Command,
}
#[derive(Subcommand)]
enum Command {
    /// Run the local library service.
    Serve {
        #[arg(long)]
        db: Option<PathBuf>,
    },
    /// Run a local stdio MCP adapter (connects to the service).
    Mcp,
    /// Call any JSON operation. Read JSON from stdin when omitted.
    Call {
        method: String,
        json: Option<String>,
    },
    /// Search titles, authors, abstracts and notes.
    Search {
        query: String,
        #[arg(long)]
        project: Option<String>,
        #[arg(long)]
        all_notes: bool,
    },
    /// Import a BibTeX file without overwriting existing values.
    Import { file: PathBuf },
    /// Add one or more DOIs, arXiv IDs, URLs or BibTeX entries; with no
    /// arguments, open the universal add box in the desktop popup.
    Add {
        /// DOIs, arXiv IDs, URLs, or a single BibTeX entry.
        identifiers: Vec<String>,
        /// Identify and attach a local PDF file instead of an identifier.
        #[arg(long, conflicts_with = "identifiers")]
        pdf: Option<PathBuf>,
        /// Link the added reference(s) to this project ID.
        #[arg(long)]
        project: Option<String>,
        /// Don't download an open-access PDF automatically.
        #[arg(long)]
        no_pdf: bool,
        /// Preview what would be added without writing anything.
        #[arg(long)]
        dry_run: bool,
    },
    /// Backfill missing data across the library. Currently: --abstracts,
    /// for references that already have an exact DOI or arXiv ID.
    Enrich {
        #[arg(long)]
        abstracts: bool,
        /// Stop after checking this many references.
        #[arg(long)]
        limit: Option<usize>,
        /// Report what would be filled without writing anything.
        #[arg(long)]
        dry_run: bool,
    },
    /// Save a history snapshot and push it (use --local for a local commit only).
    Sync {
        #[arg(long)]
        local: bool,
        /// Print the raw JSON result instead of a summary.
        #[arg(long)]
        json: bool,
    },
    /// Inspect or configure the history repository.
    Repo {
        #[command(subcommand)]
        command: RepoCommand,
    },
    /// Add, retrieve, or unlink PDF attachments.
    Pdf {
        #[command(subcommand)]
        command: PdfCommand,
    },
    /// Look up online metadata candidates without changing the reference.
    Lookup { reference: String },
    /// Show library counts and version.
    Status,
    /// Open the native Omarchy search palette.
    Open,
    /// Create a consistent SQLite backup at a new path.
    Backup { path: PathBuf },
    /// Restore a backup to a NEW database path; never overwrite a running library.
    Restore {
        backup: PathBuf,
        #[arg(long)]
        to: PathBuf,
    },
    /// Print the operations and MCP tool schemas.
    Schema,
}
#[derive(Subcommand)]
enum RepoCommand {
    /// Show the currently configured storage repository.
    Show,
    /// Point at an existing, already-LFS-enabled checkout directly. Prefer
    /// `repo use`, which also checks and can fix prerequisites.
    Set {
        path: PathBuf,
        remote: String,
        #[arg(long, default_value = "main")]
        branch: String,
    },
    /// Report prerequisites for a candidate storage repository path: tools
    /// installed, gh login, and (with a path) its Git/LFS state.
    Check { path: Option<PathBuf> },
    /// Create a new private GitHub repository and configure it for history.
    Init {
        name: String,
        #[arg(long)]
        path: Option<PathBuf>,
        #[arg(long, default_value = "main")]
        branch: String,
    },
    /// Adopt an existing local checkout, configuring Git LFS if it isn't
    /// already tracking PDFs (pass --fix-lfs to do so automatically).
    Use {
        path: PathBuf,
        #[arg(long)]
        remote: Option<String>,
        #[arg(long, default_value = "main")]
        branch: String,
        #[arg(long)]
        fix_lfs: bool,
    },
    /// Show sync status: HEAD, ahead/behind, pending changes, last result.
    Status {
        /// Fetch from the remote first, to also check what's behind.
        #[arg(long)]
        fetch: bool,
        #[arg(long)]
        json: bool,
    },
}
#[derive(Subcommand)]
enum PdfCommand {
    Add {
        reference: String,
        path: PathBuf,
    },
    Pull {
        #[arg(long)]
        attachment: Option<String>,
        #[arg(long)]
        reference: Option<String>,
        #[arg(long)]
        url: Option<String>,
    },
    Remove {
        attachment: String,
    },
    /// Print a locally readable path to a reference's PDF, downloading an
    /// open-access copy if none is attached yet.
    Get {
        reference: String,
        #[arg(long)]
        no_download: bool,
    },
    /// Open a reference's PDF in the default viewer (downloading it first
    /// if needed).
    Open { reference: String },
}
fn main() {
    if let Err(e) = run() {
        eprintln!("{e:#}");
        std::process::exit(1);
    }
}
fn print_sync_result(r: &Value) {
    let refs = r["references"].as_i64().unwrap_or(0);
    let notes = r["notes"].as_i64().unwrap_or(0);
    let pdfs = r["archived_pdfs"].as_i64().unwrap_or(0);
    if r.get("ok") == Some(&json!(false)) {
        eprintln!("Sync: exported and committed locally, but the push failed.");
        if let Some(commit) = r["commit"].as_str() {
            eprintln!("  Local commit: {commit}");
        }
        if let Some(err) = r["push_error"].as_str() {
            eprintln!("  {err}");
        }
        return;
    }
    let committed = r["committed"].as_bool().unwrap_or(r["commit"] != json!("unchanged"));
    let pushed = r["pushed"].as_bool().unwrap_or(false);
    eprintln!(
        "Sync: {refs} references, {notes} notes, {pdfs} archived PDFs.{}{}",
        if committed {
            " Committed."
        } else {
            " No changes to commit."
        },
        if pushed {
            format!(
                " Pushed {} commit(s).",
                r["commits_pushed"].as_i64().unwrap_or(0)
            )
        } else {
            String::new()
        },
    );
    if let Some(missing) = r["missing_pdf_ids"].as_array()
        && !missing.is_empty()
    {
        eprintln!("  {} attachment(s) have no local file to archive.", missing.len());
    }
}
fn print_repo_status(r: &Value) {
    if r.get("configured") != Some(&json!(true)) {
        eprintln!("No storage repository configured. Run: omabib repo init NAME, or omabib repo use PATH");
        return;
    }
    eprintln!(
        "Repository: {} ({}, branch {})",
        r["repo_path"].as_str().unwrap_or(""),
        r["remote_url"].as_str().unwrap_or(""),
        r["branch"].as_str().unwrap_or(""),
    );
    eprintln!(
        "HEAD: {} {} ({})",
        r["head"]["hash"].as_str().unwrap_or(""),
        r["head"]["subject"].as_str().unwrap_or(""),
        r["head"]["date"].as_str().unwrap_or(""),
    );
    let ahead = r["ahead"].as_i64().unwrap_or(0);
    let behind = r["behind"].as_i64().unwrap_or(0);
    eprintln!(
        "Ahead {ahead}, behind {behind}. {}",
        if r["dirty"] == json!(true) {
            "Local edits present in metadata/notes."
        } else {
            "Clean."
        }
    );
    let p = &r["pending"];
    eprintln!(
        "Pending since last sync: {} new reference(s), {} edited, {} new note(s), {} edited.",
        p["new_references"], p["edited_references"], p["new_notes"], p["edited_notes"]
    );
    match (r["last_success"].as_str(), r["last_attempt"].as_str()) {
        (Some(s), _) => eprintln!("Last successful sync: {s}"),
        (None, Some(a)) => eprintln!("Last sync attempt ({a}) did not succeed."),
        _ => eprintln!("Never synced."),
    }
    if let Some(err) = r["last_error"].as_object() {
        eprintln!(
            "Last error ({}): {}",
            err.get("kind").and_then(Value::as_str).unwrap_or("unknown"),
            err.get("message").and_then(Value::as_str).unwrap_or("")
        );
        if let Some(hint) = err.get("hint").and_then(Value::as_str) {
            eprintln!("  {hint}");
        }
    }
}
fn run() -> Result<()> {
    unsafe {
        libc::umask(0o077);
    }
    let command = Args::parse().command;
    let result = match command {
        Command::Serve { db } => {
            return omabib::transport::serve(db.unwrap_or_else(omabib::transport::data_path));
        }
        Command::Mcp => return omabib::mcp::serve(),
        Command::Call { method, json } => {
            let raw = match json {
                Some(s) => s,
                None => {
                    let mut s = String::new();
                    use std::io::Read;
                    std::io::stdin().read_to_string(&mut s)?;
                    s
                }
            };
            let params: Value =
                serde_json::from_str(if raw.trim().is_empty() { "{}" } else { &raw })?;
            omabib::transport::request(&method, &params)?
        }
        Command::Search {
            query,
            project,
            all_notes,
        } => omabib::transport::request(
            "search",
            &json!({"query":query,"project_id":project,"include_other_projects":all_notes}),
        )?,
        Command::Import { file } => omabib::transport::request(
            "import_bibtex",
            &json!({"bibtex":std::fs::read_to_string(&file)?,"source":file.to_string_lossy()}),
        )?,
        Command::Add {
            identifiers,
            pdf,
            project,
            no_pdf,
            dry_run,
        } => {
            if identifiers.is_empty() && pdf.is_none() {
                let status = std::process::Command::new("omarchy-shell")
                    .args(["shell", "summon", "omabib", r#"{"action":"add"}"#])
                    .status()?;
                anyhow::ensure!(status.success(), "Unable to open Omabib");
                return Ok(());
            }
            if dry_run {
                anyhow::ensure!(
                    pdf.is_none(),
                    "--dry-run does not support --pdf; run `omabib call identify_pdf` directly"
                );
                omabib::transport::request(
                    "preview_entry",
                    &json!({"input":identifiers.join(" ")}),
                )?
            } else if let Some(pdf) = pdf {
                let path = std::fs::canonicalize(&pdf)?;
                let mut args = json!({
                    "pdf_path": path,
                    "download_pdf": !no_pdf,
                    "idempotency_key": format!("cli-add-pdf-{}", uuid::Uuid::new_v4()),
                });
                if let Some(p) = project {
                    args["project_id"] = json!(p);
                }
                omabib::transport::request("add_reference", &args)?
            } else {
                let mut results = Vec::new();
                for identifier in &identifiers {
                    let mut args = json!({
                        "input": identifier,
                        "download_pdf": !no_pdf,
                        "idempotency_key": format!("cli-add-{}", uuid::Uuid::new_v4()),
                    });
                    if let Some(p) = &project {
                        args["project_id"] = json!(p);
                    }
                    match omabib::transport::request("add_reference", &args) {
                        Ok(v) => {
                            eprintln!(
                                "Added {} ({})",
                                v["citekey"].as_str().unwrap_or(identifier),
                                if v["merged"] == json!(true) {
                                    "filled an existing reference"
                                } else {
                                    "new"
                                }
                            );
                            results.push(v);
                        }
                        Err(e) => {
                            eprintln!("Failed: {identifier}: {e:#}");
                            results.push(json!({"input":identifier,"error":e.to_string()}));
                        }
                    }
                }
                json!(results)
            }
        }
        Command::Enrich {
            abstracts,
            limit,
            dry_run,
        } => {
            anyhow::ensure!(
                abstracts,
                "Specify --abstracts (the only supported enrichment kind in this release)"
            );
            let conn = omabib::db::read_connection(&omabib::transport::data_path())?;
            let mut stmt = conn.prepare("SELECT id,citekey FROM refs WHERE abstract='' ORDER BY citekey")?;
            let rows: Vec<(String, String)> = stmt
                .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
                .collect::<rusqlite::Result<_>>()?;
            drop(stmt);
            drop(conn);
            let total = rows.len();
            let rows: Vec<_> = match limit {
                Some(n) => rows.into_iter().take(n).collect(),
                None => rows,
            };
            eprintln!(
                "{total} reference(s) have no abstract; checking {}{}",
                rows.len(),
                if dry_run { " (dry run)" } else { "" }
            );
            let mut filled_by_source: std::collections::BTreeMap<String, i64> = Default::default();
            let (mut not_found, mut skipped, mut failed) = (0i64, 0i64, 0i64);
            for (i, (id, citekey)) in rows.iter().enumerate() {
                eprint!("[{}/{}] {citekey} ... ", i + 1, rows.len());
                match omabib::transport::request("lookup_abstract", &json!({"id":id})) {
                    Ok(r) => match r["abstract"].as_str() {
                        Some(text) => {
                            let source = r["source"].as_str().unwrap_or("unknown").to_string();
                            if dry_run {
                                eprintln!("would fill via {source} ({} chars)", text.chars().count());
                                *filled_by_source.entry(source).or_insert(0) += 1;
                            } else {
                                let applied = omabib::transport::request(
                                    "apply_metadata",
                                    &json!({
                                        "id": r["id"], "expected_revision": r["expected_revision"],
                                        "fields": {"abstract": text},
                                        "source": format!("Abstract enrichment: {source}"),
                                    }),
                                );
                                match applied {
                                    Ok(_) => {
                                        eprintln!("filled via {source} ({} chars)", text.chars().count());
                                        *filled_by_source.entry(source).or_insert(0) += 1;
                                    }
                                    Err(e) => {
                                        eprintln!("apply failed: {e:#}");
                                        failed += 1;
                                    }
                                }
                            }
                        }
                        None => {
                            eprintln!("no abstract found");
                            not_found += 1;
                        }
                    },
                    Err(e) if e.to_string().contains("no DOI or arXiv identifier") => {
                        eprintln!("skipped (no DOI or arXiv identifier)");
                        skipped += 1;
                    }
                    Err(e) => {
                        eprintln!("failed: {e:#}");
                        failed += 1;
                    }
                }
                std::thread::sleep(std::time::Duration::from_millis(1000));
            }
            let filled: i64 = filled_by_source.values().sum();
            json!({
                "checked": rows.len(), "filled": filled, "filled_by_source": filled_by_source,
                "not_found": not_found, "skipped_no_identifier": skipped, "failed": failed,
                "dry_run": dry_run,
            })
        }
        Command::Lookup { reference } => {
            omabib::transport::request("lookup_metadata", &json!({"id":reference}))?
        }
        Command::Sync { local, json: as_json } => {
            let r = omabib::transport::request("sync_repo", &json!({"push":!local}))?;
            if !as_json {
                print_sync_result(&r);
                if r.get("ok") == Some(&json!(false)) {
                    std::process::exit(1);
                }
                return Ok(());
            }
            r
        }
        Command::Repo { command } => match command {
            RepoCommand::Show => omabib::transport::request("get_repo_config", &json!({}))?,
            RepoCommand::Set {
                path,
                remote,
                branch,
            } => omabib::transport::request(
                "set_repo_config",
                &json!({"repo_path":path,"remote_url":remote,"branch":branch}),
            )?,
            RepoCommand::Check { path } => {
                let mut a = json!({});
                if let Some(p) = path {
                    a["repo_path"] = json!(p);
                }
                omabib::transport::request("repo_check", &a)?
            }
            RepoCommand::Init { name, path, branch } => {
                let mut a = json!({"mode":"create_github","name":name,"branch":branch});
                if let Some(p) = path {
                    a["repo_path"] = json!(p);
                }
                omabib::transport::request("repo_setup", &a)?
            }
            RepoCommand::Use {
                path,
                remote,
                branch,
                fix_lfs,
            } => {
                let mut a = json!({"mode":"local","repo_path":path,"branch":branch,"fix_lfs":fix_lfs});
                if let Some(r) = remote {
                    a["remote_url"] = json!(r);
                }
                omabib::transport::request("repo_setup", &a)?
            }
            RepoCommand::Status { fetch, json: as_json } => {
                let r = omabib::transport::request("repo_status", &json!({"fetch":fetch}))?;
                if !as_json {
                    print_repo_status(&r);
                    return Ok(());
                }
                r
            }
        },
        Command::Pdf { command } => match command {
            PdfCommand::Add { reference, path } => {
                omabib::transport::request("add_pdf", &json!({"ref_id":reference,"path":path}))?
            }
            PdfCommand::Remove { attachment } => {
                omabib::transport::request("remove_pdf", &json!({"attachment_id":attachment}))?
            }
            PdfCommand::Pull {
                attachment,
                reference,
                url,
            } => {
                let mut p = json!({});
                if let Some(v) = attachment {
                    p["attachment_id"] = json!(v);
                }
                if let Some(v) = reference {
                    p["ref_id"] = json!(v);
                }
                if let Some(v) = url {
                    p["url"] = json!(v);
                }
                omabib::transport::request("pull_pdf", &p)?
            }
            PdfCommand::Get {
                reference,
                no_download,
            } => omabib::transport::request(
                "get_pdf",
                &json!({"ref_id":reference,"download":!no_download}),
            )?,
            PdfCommand::Open { reference } => {
                let r = omabib::transport::request("get_pdf", &json!({"ref_id":reference}))?;
                let path = r["path"].as_str().context("get_pdf returned no path")?;
                let status = std::process::Command::new("xdg-open").arg(path).status()?;
                anyhow::ensure!(status.success(), "Unable to open {path}");
                return Ok(());
            }
        },
        Command::Status => omabib::transport::request("status", &json!({}))?,
        Command::Open => {
            let status = std::process::Command::new("omarchy-shell")
                .args(["shell", "toggle", "omabib", "{}"])
                .status()?;
            anyhow::ensure!(status.success(), "Unable to open Omabib");
            return Ok(());
        }
        Command::Backup { path } => omabib::transport::request("backup", &json!({"path":path}))?,
        Command::Restore { backup, to } => {
            anyhow::ensure!(!to.exists(), "Restore destination already exists");
            let c = rusqlite::Connection::open_with_flags(
                &backup,
                rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
            )?;
            let integrity: String = c.query_row("PRAGMA integrity_check", [], |r| r.get(0))?;
            anyhow::ensure!(integrity == "ok", "Backup integrity check failed");
            let schema: i64 = c.query_row("PRAGMA user_version", [], |r| r.get(0))?;
            anyhow::ensure!(schema == 1, "Unsupported backup schema");
            if let Some(p) = to.parent() {
                std::fs::create_dir_all(p)?;
            }
            std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&to)?;
            c.backup(rusqlite::MAIN_DB, &to, None)?;
            json!({"restored_to":to})
        }
        Command::Schema => {
            json!({"tools":omabib::mcp::tools(),"cli_only":["preview_entry","lookup_metadata","supplement_metadata","apply_metadata","open_target","get_repo_config","set_repo_config","sync_repo","repo_check","repo_setup","repo_status","identify_pdf","lookup_abstract","get_attachment","import_bibtex","upsert_reference","create_project","update_project","associate","attach","preview_doi","export_notes","backup","status"]})
        }
    };
    println!("{}", serde_json::to_string_pretty(&result)?);
    Ok(())
}
