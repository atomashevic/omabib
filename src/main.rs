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
        /// Blank-query browse order: added_desc or citekey.
        #[arg(long, value_parser = ["added_desc", "citekey"])]
        sort: Option<String>,
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
    /// Sync the library with your other computers now, or set sync up.
    Sync {
        #[command(subcommand)]
        command: Option<SyncCommand>,
        /// Print the raw JSON result instead of a summary.
        #[arg(long)]
        json: bool,
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
    /// Show, focus or hide the Omabib window.
    Open,
    /// Create a consistent SQLite backup at a new path.
    Backup { path: PathBuf },
    /// Restore a backup to a NEW database path; never overwrite a running library.
    Restore {
        backup: PathBuf,
        #[arg(long)]
        to: PathBuf,
    },
    /// Print the operations and MCP tool schemas, or only the named tools'.
    Schema { tools: Vec<String> },
}
#[derive(Subcommand)]
enum SyncCommand {
    /// Show where the library syncs and how it went.
    Status,
    /// Connect a place to sync: drive, dropbox or onedrive (browser sign-in),
    /// `folder PATH`, or `rclone REMOTE` from Omabib's own rclone config.
    Connect { provider: String, target: Option<String> },
    /// Start syncing: `new` uploads this library; `join`, `merge` or `replace`
    /// use the library already there.
    Start { mode: String },
    /// Stop syncing this computer; its library stays as it is.
    Disconnect,
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
    /// Open a reference's PDF in an Omabib reader tab (downloading it first
    /// if needed).
    Open { reference: String },
}
fn command_output(program: &str, args: &[&str]) -> Option<Vec<u8>> {
    std::process::Command::new(program)
        .args(args)
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| o.stdout)
}
/// The Omabib window's Hyprland address, and whether it has focus.
fn omabib_window() -> Option<(String, bool)> {
    let clients: Value = serde_json::from_slice(&command_output("hyprctl", &["clients", "-j"])?).ok()?;
    let address = clients
        .as_array()?
        .iter()
        .find(|c| c["title"] == "Omabib" && c["mapped"] != false)?["address"]
        .as_str()?
        .to_owned();
    let active: Value = command_output("hyprctl", &["activewindow", "-j"])
        .and_then(|o| serde_json::from_slice(&o).ok())
        .unwrap_or(Value::Null);
    let focused = active["address"] == address.as_str();
    Some((address, focused))
}
/// Focus the Omabib window, waiting briefly for a just-shown window to map.
fn focus_omabib() {
    for _ in 0..40 {
        if let Some((address, focused)) = omabib_window() {
            if !focused {
                let _ = std::process::Command::new("hyprctl")
                    .args(["dispatch", &format!("hl.dsp.focus({{ window = \"address:{address}\" }})")])
                    .status();
            }
            return;
        }
        std::thread::sleep(std::time::Duration::from_millis(25));
    }
}
fn shell(args: &[&str]) -> Result<()> {
    let status = std::process::Command::new("omarchy-shell").args(args).status()?;
    anyhow::ensure!(status.success(), "Unable to reach the Omarchy shell");
    Ok(())
}
fn main() {
    if let Err(e) = run() {
        eprintln!("{e:#}");
        std::process::exit(1);
    }
}
fn print_sync_status(r: &Value) {
    if r["configured"] != json!(true) {
        eprintln!(
            "{}",
            if r["connected"] == json!(true) {
                "Connected, but not syncing yet. Run: omabib sync start new (or join)"
            } else {
                "Sync is not set up. Run: omabib sync connect dropbox|onedrive|drive|folder PATH"
            }
        );
        return;
    }
    eprintln!(
        "Syncing with {}: {}{}",
        r["where"].as_str().unwrap_or(""),
        r["state"].as_str().unwrap_or(""),
        r["message"].as_str().filter(|m| !m.is_empty()).map(|m| format!(" ({m})")).unwrap_or_default()
    );
    if let Some(t) = r["last_success"].as_str() {
        eprintln!("Last synced {t}.");
    }
    eprintln!(
        "{} change(s) waiting, {} to review, {} PDF(s) only in the storage.",
        r["pending"], r["conflicts"], r["pdfs"]["cloud_only"]
    );
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
            sort,
        } => omabib::transport::request(
            "search",
            &json!({"query":query,"project_id":project,"include_other_projects":all_notes,"sort":sort}),
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
                    .args(["shell", "summon", "io.github.atomashevic.omabib", r#"{"action":"add"}"#])
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
            // Listed through the running service (not a direct file read),
            // so this always sees the exact same database the subsequent
            // lookup_abstract/apply_metadata calls below will write to.
            let listing = omabib::transport::request(
                "missing_abstracts",
                &json!({"limit":limit.unwrap_or(5000)}),
            )?;
            let total = listing["total"].as_i64().unwrap_or(0);
            let rows: Vec<(String, String)> = listing["items"]
                .as_array()
                .context("missing_abstracts returned no items array")?
                .iter()
                .map(|v| {
                    (
                        v["id"].as_str().unwrap_or_default().to_string(),
                        v["citekey"].as_str().unwrap_or_default().to_string(),
                    )
                })
                .collect();
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
        Command::Sync { command, json: as_json } => {
            let r = match command {
                None => omabib::transport::request_with_timeout("sync_now", &json!({}), std::time::Duration::from_secs(3600))?,
                Some(SyncCommand::Status) => omabib::transport::request("sync_status", &json!({}))?,
                Some(SyncCommand::Connect { provider, target }) => {
                    let mut a = json!({"provider":provider});
                    if provider == "folder" {
                        a["path"] = json!(std::path::absolute(target.context("Give the folder: omabib sync connect folder PATH")?)?);
                    } else if provider == "rclone" {
                        a["remote"] = json!(target.context("Give the remote: omabib sync connect rclone REMOTE")?);
                    }
                    let mut r = omabib::transport::request("sync_connect", &a)?;
                    // A cloud sign-in happens in the browser; wait for it here.
                    while r["connecting"]["state"].as_str().is_some_and(|s| ["starting", "browser", "finishing"].contains(&s)) {
                        if let Some(url) = r["connecting"]["url"].as_str() {
                            eprintln!("Sign in here: {url}");
                            let _ = std::process::Command::new("xdg-open").arg(url).status();
                            while r["connecting"]["state"] == "browser" {
                                std::thread::sleep(std::time::Duration::from_millis(500));
                                r = omabib::transport::request("sync_status", &json!({}))?;
                            }
                        }
                        std::thread::sleep(std::time::Duration::from_millis(300));
                        r = omabib::transport::request("sync_status", &json!({}))?;
                    }
                    if r["connecting"]["state"] == "error" {
                        anyhow::bail!("{}", r["connecting"]["message"].as_str().unwrap_or("Connecting failed"));
                    }
                    r
                }
                Some(SyncCommand::Start { mode }) => omabib::transport::request_with_timeout(
                    "sync_start",
                    &json!({"mode":mode}),
                    std::time::Duration::from_secs(3600),
                )?,
                Some(SyncCommand::Disconnect) => omabib::transport::request("sync_disconnect", &json!({}))?,
            };
            if as_json {
                r
            } else {
                if r["already_running"] == true {
                    println!("Sync is already in progress.");
                } else if r.get("received").is_some() {
                    eprintln!(
                        "Synced: sent {} change(s), received {}{}.",
                        r["sent"],
                        r["received"],
                        r["from"].as_array().filter(|f| !f.is_empty()).map(|f| format!(" from {}", f.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(", "))).unwrap_or_default()
                    );
                } else {
                    print_sync_status(&r);
                }
                return Ok(());
            }
        }
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
                let r = omabib::transport::request(
                    "get_reference",
                    &json!({"id":reference,"include_metadata":false}),
                )?;
                omabib::transport::request("get_pdf", &json!({"ref_id":r["id"]}))?;
                shell(&[
                    "shell", "summon", "io.github.atomashevic.omabib",
                    &json!({"action": "pdf", "ref_id": r["id"].as_str().context("Reference without id")?}).to_string(),
                ])?;
                focus_omabib();
                return Ok(());
            }
        },
        Command::Status => omabib::transport::request("status", &json!({}))?,
        // Super+B: show and focus the window, focus it if it is in the
        // background, or hide it when it already has focus.
        Command::Open => {
            match omabib_window() {
                Some((_, true)) => shell(&["shell", "hide", "io.github.atomashevic.omabib"])?,
                Some(_) => focus_omabib(),
                None => {
                    shell(&["shell", "summon", "io.github.atomashevic.omabib", "{}"])?;
                    focus_omabib();
                }
            }
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
        Command::Schema { tools } if !tools.is_empty() => {
            let found: Vec<Value> = omabib::mcp::tools()
                .into_iter()
                .filter(|t| tools.iter().any(|name| t["name"] == name.as_str()))
                .collect();
            anyhow::ensure!(found.len() == tools.len(), "Unknown tool; run omabib schema for the list");
            json!({"tools":found})
        }
        Command::Schema { .. } => {
            json!({"tools":omabib::mcp::tools(),"cli_only":["preview_entry","lookup_metadata","supplement_metadata","apply_metadata","open_target","sync_status","sync_providers","sync_connect","sync_connect_cancel","sync_inspect","sync_start","sync_now","sync_conflicts","sync_resolve","sync_download_all","sync_disconnect","sync_nudge","identify_pdf","lookup_abstract","missing_abstracts","get_attachment","import_bibtex","upsert_reference","create_project","update_project","associate","attach","preview_doi","export_notes","backup","status"]})
        }
    };
    println!("{}", serde_json::to_string_pretty(&result)?);
    Ok(())
}
