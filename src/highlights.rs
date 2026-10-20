//! Text highlights on a PDF page. The boxes live in the library. The PDF file
//! is never written. Highlights are not notes, they are not searched, and they
//! follow the PDF rather than a project.
use crate::db::{Library, id};
use anyhow::{Context, Result, ensure};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

pub const COLORS: [&str; 5] = ["yellow", "red", "green", "purple", "blue"];
const CAP: usize = 8 * 1024;

pub const SCHEMA: &str = "\
CREATE TABLE IF NOT EXISTS highlights (\
 id TEXT PRIMARY KEY,\
 ref_id TEXT NOT NULL,\
 attachment_id TEXT NOT NULL,\
 source_sha256 TEXT NOT NULL,\
 page INTEGER NOT NULL,\
 rects TEXT NOT NULL,\
 quote TEXT NOT NULL,\
 color TEXT NOT NULL,\
 comment TEXT NOT NULL DEFAULT '',\
 created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),\
 updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))\
);\
CREATE INDEX IF NOT EXISTS highlights_ref_page ON highlights(ref_id, page);\
CREATE INDEX IF NOT EXISTS highlights_feed ON highlights(updated_at DESC, id DESC);";

fn table_exists(c: &Connection) -> Result<bool> {
    Ok(c
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='highlights'",
            [],
            |_| Ok(true),
        )
        .optional()?
        .unwrap_or(false))
}

/// Creates the table on open. The first time an existing library is missing
/// it, the library is backed up before the table is added. A brand-new library
/// has nothing to keep, so it is not backed up.
pub fn ensure_table(c: &Connection, db_path: &Path, fresh: bool) -> Result<()> {
    if !table_exists(c)? && !fresh {
        backup_before_table(c, db_path)?;
    }
    c.execute_batch(SCHEMA)?;
    Ok(())
}

/// Same SQLite backup the `backup` operation uses. Sync only prunes
/// `before-sync-*`, so this file stays.
fn backup_before_table(c: &Connection, db_path: &Path) -> Result<PathBuf> {
    let dir = db_path
        .parent()
        .context("Library path has no folder")?
        .join("backups");
    std::fs::create_dir_all(&dir)?;
    let stamp = crate::sync::records::now().replace([':', '.'], "-");
    let dest = dir.join(format!("before-highlights-{stamp}.db"));
    ensure!(!dest.exists(), "Backup destination already exists");
    use std::os::unix::fs::OpenOptionsExt;
    std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&dest)?;
    c.backup(rusqlite::MAIN_DB, &dest, None)
        .context("Could not back up the library before adding highlights")?;
    Ok(dest)
}

fn cap(s: &str) -> String {
    if s.len() <= CAP {
        return s.to_string();
    }
    let mut end = CAP;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    s[..end].to_string()
}

fn rects_json(rects: &[[f64; 4]]) -> Result<String> {
    ensure!(!rects.is_empty(), "A highlight needs at least one box");
    for r in rects {
        ensure!(
            r.iter().all(|n| n.is_finite()),
            "Highlight boxes must be finite numbers"
        );
    }
    Ok(json!(rects).to_string())
}

fn row(c: &Connection, id: &str) -> Result<Option<Value>> {
    Ok(c.query_row(
        "SELECT id,ref_id,attachment_id,source_sha256,page,rects,quote,color,comment,created_at,updated_at FROM highlights WHERE id=?",
        [id],
        |r| {
            Ok(json!({
                "id": r.get::<_, String>(0)?,
                "ref_id": r.get::<_, String>(1)?,
                "attachment_id": r.get::<_, String>(2)?,
                "source_sha256": r.get::<_, String>(3)?,
                "page": r.get::<_, i64>(4)?,
                "rects": serde_json::from_str::<Value>(&r.get::<_, String>(5)?).unwrap_or(Value::Null),
                "quote": r.get::<_, String>(6)?,
                "color": r.get::<_, String>(7)?,
                "comment": r.get::<_, String>(8)?,
                "created_at": r.get::<_, String>(9)?,
                "updated_at": r.get::<_, String>(10)?,
            }))
        },
    ).optional()?)
}

/// Stores a yellow highlight. `color` is always yellow here; a later edit can
/// change it. The PDF is read only when the attachment has no fingerprint yet.
pub fn create(
    lib: &Library,
    ref_id: &str,
    attachment_id: &str,
    page: i64,
    rects: &[[f64; 4]],
    quote: &str,
) -> Result<Value> {
    ensure!(page >= 1, "Page must be 1 or greater");
    let rects = rects_json(rects)?;
    let quote = cap(quote);
    let c = lib.writer.lock().unwrap();
    let found: Option<(String, Option<String>)> = c
        .query_row(
            "SELECT path,fingerprint FROM attachments WHERE id=? AND ref_id=? AND file_type='pdf'",
            params![attachment_id, ref_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    let (path, fingerprint) = found.context("PDF attachment not found on this reference")?;
    let sha = match fingerprint.filter(|s| !s.is_empty()) {
        Some(sha) => sha,
        None => {
            ensure!(
                !path.starts_with(crate::sync::records::CLOUD_PATH),
                "PDF is not on this computer"
            );
            crate::attachments::inspect(Path::new(&path))?
        }
    };
    let hid = id();
    c.execute(
        "INSERT INTO highlights(id,ref_id,attachment_id,source_sha256,page,rects,quote,color,comment) VALUES(?,?,?,?,?,?,?,'yellow','')",
        params![hid, ref_id, attachment_id, sha, page, rects, quote],
    )?;
    row(&c, &hid)?.context("Highlight was not stored")
}

/// Changes the color, the comment, or both. Geometry stays as it was.
/// `updated_at` moves; `created_at` does not.
pub fn update(
    lib: &Library,
    id: &str,
    color: Option<&str>,
    comment: Option<&str>,
) -> Result<Value> {
    ensure!(color.is_some() || comment.is_some(), "Nothing to change");
    if let Some(color) = color {
        ensure!(COLORS.contains(&color), "Unknown highlight color");
    }
    let comment = comment.map(cap);
    let c = lib.writer.lock().unwrap();
    let n = match (color, comment.as_deref()) {
        (Some(color), Some(comment)) => c.execute(
            "UPDATE highlights SET color=?, comment=?, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?",
            params![color, comment, id],
        )?,
        (Some(color), None) => c.execute(
            "UPDATE highlights SET color=?, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?",
            params![color, id],
        )?,
        (None, Some(comment)) => c.execute(
            "UPDATE highlights SET comment=?, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?",
            params![comment, id],
        )?,
        (None, None) => 0,
    };
    ensure!(n == 1, "Highlight not found");
    row(&c, id)?.context("Highlight not found")
}

pub fn delete(lib: &Library, id: &str) -> Result<()> {
    let c = lib.writer.lock().unwrap();
    ensure!(
        c.execute("DELETE FROM highlights WHERE id=?", [id])? == 1,
        "Highlight not found"
    );
    Ok(())
}

pub fn get(lib: &Library, id: &str) -> Result<Option<Value>> {
    let c = crate::db::read_connection(&lib.path)?;
    row(&c, id)
}
