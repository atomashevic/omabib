//! Text highlights on a PDF page. The boxes live in the library. The PDF file
//! is never written. Highlights are not notes, they are not searched, and they
//! follow the PDF rather than a project.
use crate::db::{Library, id};
use anyhow::{Context, Result, bail, ensure};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};
use std::path::Path;

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

/// Creates the table on open. It starts empty, so this cannot lose data, and a
/// backup must not keep the library from opening.
pub fn ensure_table(c: &Connection) -> Result<()> {
    c.execute_batch(SCHEMA)?;
    Ok(())
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

/// Stores a yellow highlight; see `create_in`.
pub fn create(
    lib: &Library,
    ref_id: &str,
    attachment_id: &str,
    page: i64,
    rects: &[[f64; 4]],
    quote: &str,
) -> Result<Value> {
    create_in(lib, ref_id, attachment_id, page, rects, quote, "yellow")
}

/// Stores a highlight in `color`. The PDF is read only when the attachment
/// has no fingerprint yet; the fingerprint is then kept on the attachment,
/// since a highlight is drawn only on the file it was made on.
pub fn create_in(
    lib: &Library,
    ref_id: &str,
    attachment_id: &str,
    page: i64,
    rects: &[[f64; 4]],
    quote: &str,
    color: &str,
) -> Result<Value> {
    ensure!(page >= 1, "Page must be 1 or greater");
    ensure!(COLORS.contains(&color), "Unknown highlight color");
    let rects = rects_json(rects)?;
    let quote = cap(quote);
    // Hash the PDF before taking the writer lock for the insert.
    let (path, fingerprint) = {
        let c = lib.writer.lock().unwrap();
        c.query_row(
            "SELECT path,fingerprint FROM attachments WHERE id=? AND ref_id=? AND file_type='pdf'",
            params![attachment_id, ref_id],
            |r| Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?)),
        )
        .optional()?
        .context("PDF attachment not found on this reference")?
    };
    let (sha, measured) = match fingerprint.filter(|s| !s.is_empty()) {
        Some(sha) => (sha, false),
        None => {
            ensure!(
                !path.starts_with(crate::sync::records::CLOUD_PATH),
                "PDF is not on this computer"
            );
            (crate::attachments::inspect(Path::new(&path))?, true)
        }
    };
    let hid = id();
    let c = lib.writer.lock().unwrap();
    if measured {
        c.execute(
            "UPDATE attachments SET fingerprint=? WHERE id=? AND (fingerprint IS NULL OR fingerprint='')",
            params![sha, attachment_id],
        )?;
    }
    c.execute(
        "INSERT INTO highlights(id,ref_id,attachment_id,source_sha256,page,rects,quote,color,comment) VALUES(?,?,?,?,?,?,?,?,'')",
        params![hid, ref_id, attachment_id, sha, page, rects, quote, color],
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

fn reference_id(c: &Connection, key: &str) -> Result<String> {
    c.query_row(
        "SELECT id FROM refs WHERE id=?1 OR citekey=?1",
        [key],
        |r| r.get(0),
    )
    .context("Reference not found")
}

fn optional_str<'a>(a: &'a Value, key: &str) -> Result<Option<&'a str>> {
    match a.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => Ok(Some(s)),
        Some(_) => bail!("{key} must be a string"),
    }
}

fn boxes(v: &Value) -> Result<Vec<[f64; 4]>> {
    let list = v.as_array().context("rects must be an array of boxes")?;
    let mut out = Vec::with_capacity(list.len());
    for b in list {
        let n = b.as_array().context("each highlight box is four numbers")?;
        ensure!(n.len() == 4, "each highlight box is four numbers");
        let mut r = [0.0; 4];
        for (i, x) in n.iter().enumerate() {
            r[i] = x.as_f64().context("highlight boxes must be numbers")?;
        }
        out.push(r);
    }
    Ok(out)
}

/// `list_highlights`. One reference, or the whole library when `ref_id` is
/// omitted. Newest `updated_at` first, then `id` descending.
pub fn list(lib: &Library, a: &Value) -> Result<Value> {
    let limit = match a.get("limit") {
        None | Some(Value::Null) => 50,
        Some(v) => v.as_u64().context("limit must be a whole number")?,
    };
    ensure!((1..=100).contains(&limit), "limit must be from 1 to 100");
    let offset = match a.get("cursor") {
        None | Some(Value::Null) => 0,
        Some(v) => v.as_u64().context("cursor must be a whole number")?,
    };
    let c = crate::db::read_connection(&lib.path)?;
    let ref_id = match a.get("ref_id") {
        None | Some(Value::Null) => None,
        Some(Value::String(s)) if s.is_empty() => None,
        Some(Value::String(s)) => Some(reference_id(&c, s)?),
        Some(_) => bail!("ref_id must be a string"),
    };
    let mut stmt = c.prepare(
        "SELECT h.id, h.ref_id, coalesce(r.citekey, ''), h.attachment_id, h.page, h.quote, \
         h.color, h.comment, h.created_at, h.updated_at, \
         CASE WHEN a.fingerprint IS NOT NULL AND a.fingerprint != '' AND a.fingerprint = h.source_sha256 \
              THEN 0 ELSE 1 END \
         FROM highlights h \
         LEFT JOIN refs r ON r.id = h.ref_id \
         LEFT JOIN attachments a ON a.id = h.attachment_id \
         WHERE (?1 IS NULL OR h.ref_id = ?1) \
         ORDER BY h.updated_at DESC, h.id DESC \
         LIMIT ?2 OFFSET ?3",
    )?;
    let mut highlights = stmt
        .query_map(params![ref_id, (limit + 1) as i64, offset as i64], |r| {
            Ok(json!({
                "id": r.get::<_, String>(0)?,
                "ref_id": r.get::<_, String>(1)?,
                "citekey": r.get::<_, String>(2)?,
                "attachment_id": r.get::<_, String>(3)?,
                "page": r.get::<_, i64>(4)?,
                "quote": r.get::<_, String>(5)?,
                "color": r.get::<_, String>(6)?,
                "comment": r.get::<_, String>(7)?,
                "created_at": r.get::<_, String>(8)?,
                "updated_at": r.get::<_, String>(9)?,
                "stale": r.get::<_, i64>(10)? != 0,
            }))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let more = highlights.len() > limit as usize;
    highlights.truncate(limit as usize);
    Ok(json!({
        "highlights": highlights,
        "next_cursor": if more { json!(offset + limit) } else { Value::Null },
    }))
}

/// Highlights to draw on the open PDF. A row is included only when that
/// attachment's fingerprint still matches the file the boxes were taken from.
/// The PDF is not read or written.
pub fn for_pdf(lib: &Library, a: &Value) -> Result<Value> {
    let key = crate::db::required(a, "ref_id")?;
    let attachment_id = crate::db::required(a, "attachment_id")?;
    let c = crate::db::read_connection(&lib.path)?;
    let ref_id = reference_id(&c, key)?;
    let mut stmt = c.prepare(
        "SELECT h.id, h.page, h.rects, h.quote, h.color, h.comment \
         FROM highlights h \
         JOIN attachments a ON a.id = h.attachment_id \
         WHERE h.ref_id=?1 AND h.attachment_id=?2 \
           AND a.fingerprint IS NOT NULL AND a.fingerprint != '' \
           AND a.fingerprint = h.source_sha256 \
         ORDER BY h.page, h.id",
    )?;
    let highlights = stmt
        .query_map(params![ref_id, attachment_id], |r| {
            let rects: String = r.get(2)?;
            Ok(json!({
                "id": r.get::<_, String>(0)?,
                "page": r.get::<_, i64>(1)?,
                "rects": serde_json::from_str::<Value>(&rects).unwrap_or(Value::Null),
                "quote": r.get::<_, String>(3)?,
                "color": r.get::<_, String>(4)?,
                "comment": r.get::<_, String>(5)?,
            }))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(json!({ "highlights": highlights }))
}

/// `add_highlight`. Yellow unless `color` says otherwise. The PDF file is not written.
pub fn add(lib: &Library, a: &Value) -> Result<Value> {
    let color = optional_str(a, "color")?.unwrap_or("yellow");
    let key = crate::db::required(a, "ref_id")?;
    let ref_id = reference_id(&crate::db::read_connection(&lib.path)?, key)?;
    let attachment_id = crate::db::required(a, "attachment_id")?;
    let page = match a.get("page") {
        None | Some(Value::Null) => bail!("page is required"),
        Some(v) => v.as_i64().context("page must be a whole number")?,
    };
    let rects = boxes(a.get("rects").context("rects is required")?)?;
    let quote = a
        .get("quote")
        .and_then(Value::as_str)
        .context("quote is required")?;
    create_in(lib, &ref_id, attachment_id, page, &rects, quote, color)
}

/// `update_highlight`. Color, comment, or both. Geometry stays.
pub fn change(lib: &Library, a: &Value) -> Result<Value> {
    let id = crate::db::required(a, "id")?;
    update(lib, id, optional_str(a, "color")?, optional_str(a, "comment")?)
}

/// `delete_highlight`.
pub fn remove(lib: &Library, a: &Value) -> Result<Value> {
    let id = crate::db::required(a, "id")?.to_string();
    delete(lib, &id)?;
    Ok(json!({"id": id, "deleted": true}))
}
