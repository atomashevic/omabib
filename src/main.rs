use anyhow::Result;
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
    /// Save a history snapshot and push it (use --local for a local commit only).
    Sync {
        #[arg(long)]
        local: bool,
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
    /// Open the universal URL, DOI or BibTeX entry box.
    Add,
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
    Show,
    Set {
        path: PathBuf,
        remote: String,
        #[arg(long, default_value = "main")]
        branch: String,
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
}
fn main() {
    if let Err(e) = run() {
        eprintln!("{e:#}");
        std::process::exit(1);
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
        Command::Lookup { reference } => {
            omabib::transport::request("lookup_metadata", &json!({"id":reference}))?
        }
        Command::Sync { local } => {
            omabib::transport::request("sync_repo", &json!({"push":!local}))?
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
        },
        Command::Status => omabib::transport::request("status", &json!({}))?,
        Command::Add => {
            let status = std::process::Command::new("omarchy-shell")
                .args(["shell", "summon", "omabib", r#"{"action":"add"}"#])
                .status()?;
            anyhow::ensure!(status.success(), "Unable to open Omabib");
            return Ok(());
        }
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
            json!({"tools":omabib::mcp::tools(),"cli_only":["preview_entry","lookup_metadata","supplement_metadata","apply_metadata","open_target","get_repo_config","set_repo_config","sync_repo","get_attachment","import_bibtex","upsert_reference","create_project","update_project","associate","attach","preview_doi","export_notes","backup","status"]})
        }
    };
    println!("{}", serde_json::to_string_pretty(&result)?);
    Ok(())
}
