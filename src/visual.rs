//! Lossless visual notes. Image bytes stay in SQLite backups, outside search results.
use crate::db::required;
use anyhow::{Context, Result, ensure};
use base64::{Engine, engine::general_purpose::STANDARD};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{io::Read, path::Path};

/// Clips drawn in the reader are rendered at 216 dpi.
pub const CLIP_SCALE: f32 = 3.0;

pub const SCHEMA: &str = "CREATE TABLE IF NOT EXISTS note_images(note_id TEXT PRIMARY KEY REFERENCES notes(id), mime_type TEXT NOT NULL, width INTEGER NOT NULL, height INTEGER NOT NULL, sha256 TEXT NOT NULL, source_pdf TEXT NOT NULL, page INTEGER NOT NULL, rectangle TEXT NOT NULL, data BLOB NOT NULL);";

pub fn insert(c: &Connection, a: &Value, note_id: &str, pdf: &crate::pdf::Pdf) -> Result<()> {
    let page = a["page"].as_u64().context("PDF page required")?;
    ensure!(page > 0 && page <= 1_000_000, "Invalid PDF page");
    let source = Path::new(required(a, "source_pdf")?).canonicalize()?;
    let mut query = c.prepare("SELECT path FROM attachments WHERE ref_id=? AND file_type='pdf'")?;
    let paths = query
        .query_map([required(a, "ref_id")?], |r| r.get::<_, String>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    ensure!(
        paths
            .iter()
            .any(|p| Path::new(p).canonicalize().ok().as_ref() == Some(&source)),
        "Source PDF is not attached to this reference"
    );
    // A rectangle in PDF points is rendered here from the PDF itself; the older
    // form passes a screenshot PNG with a screen-pixel rectangle.
    let (data, rect) = if let Some(r) = a.get("rect_pt") {
        ensure!(
            a.get("image_path").is_none(),
            "Pass either rect_pt or image_path, not both"
        );
        let v: Vec<f64> = ["x", "y", "width", "height"]
            .iter()
            .map(|k| r[k].as_f64().filter(|v| v.is_finite()))
            .collect::<Option<_>>()
            .context("rect_pt needs numeric x, y, width and height")?;
        ensure!(v[2] >= 1.0 && v[3] >= 1.0, "Invalid capture rectangle");
        let png = pdf.clip(
            &source,
            page as u32,
            [v[0] as f32, v[1] as f32, v[2] as f32, v[3] as f32],
            CLIP_SCALE,
        )?;
        (
            png,
            json!({"x":v[0],"y":v[1],"width":v[2],"height":v[3],"unit":"pt"}),
        )
    } else {
        let path = Path::new(required(a, "image_path")?);
        ensure!(path.is_absolute(), "Image path must be absolute");
        let file = std::fs::File::open(path)?;
        ensure!(file.metadata()?.is_file(), "Image must be a regular file");
        let mut data = Vec::new();
        file.take(8 * 1024 * 1024 + 1).read_to_end(&mut data)?;
        let rect = a.get("rectangle").context("Capture rectangle required")?;
        ensure!(
            ["x", "y", "width", "height"]
                .iter()
                .all(|k| rect[k].as_i64().is_some())
                && rect["width"].as_i64().unwrap() > 0
                && rect["height"].as_i64().unwrap() > 0,
            "Invalid capture rectangle"
        );
        (data, rect.clone())
    };
    ensure!(data.len() <= 8 * 1024 * 1024, "Clip exceeds 8 MiB");
    ensure!(
        data.len() >= 33 && data[..8] == *b"\x89PNG\r\n\x1a\n" && data[12..16] == *b"IHDR",
        "Clip must be a PNG image"
    );
    let width = u32::from_be_bytes(data[16..20].try_into()?);
    let height = u32::from_be_bytes(data[20..24].try_into()?);
    ensure!(
        width > 0 && height > 0 && u64::from(width) * u64::from(height) <= 32_000_000,
        "Invalid or oversized clip dimensions"
    );
    c.execute(
        "INSERT INTO note_images VALUES(?, 'image/png', ?, ?, ?, ?, ?, ?, ?)",
        params![
            note_id,
            width,
            height,
            format!("{:x}", Sha256::digest(&data)),
            source.to_string_lossy(),
            page as i64,
            rect.to_string(),
            data
        ],
    )?;
    Ok(())
}

pub fn metadata(c: &Connection, note_id: &str) -> Result<Option<Value>> {
    Ok(c.query_row("SELECT mime_type,width,height,sha256,source_pdf,page,rectangle,length(data) FROM note_images WHERE note_id=?",[note_id],|r|Ok(json!({"note_id":note_id,"mime_type":r.get::<_,String>(0)?,"width":r.get::<_,u32>(1)?,"height":r.get::<_,u32>(2)?,"sha256":r.get::<_,String>(3)?,"source_pdf":r.get::<_,String>(4)?,"page":r.get::<_,u32>(5)?,"rectangle":serde_json::from_str::<Value>(&r.get::<_,String>(6)?).unwrap_or(Value::Null),"bytes":r.get::<_,i64>(7)?}))).optional()?)
}

pub fn get(c: &Connection, a: &Value) -> Result<Value> {
    let id = required(a, "note_id")?;
    ensure!(
        a.get("project_id").is_some(),
        "Explicit project_id required; null for global"
    );
    let scope: Option<String> =
        c.query_row("SELECT project_id FROM notes WHERE id=?", [id], |r| {
            r.get(0)
        })?;
    ensure!(
        scope.is_none() || scope.as_deref() == a["project_id"].as_str(),
        "Note belongs to another project"
    );
    let mut meta = metadata(c, id)?.context("Note has no image")?;
    let data: Vec<u8> = c.query_row("SELECT data FROM note_images WHERE note_id=?", [id], |r| {
        r.get(0)
    })?;
    meta["data"] = json!(STANDARD.encode(data));
    Ok(meta)
}
