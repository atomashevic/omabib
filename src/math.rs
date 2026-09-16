//! LaTeX math for note previews: mitex converts TeX to Typst math, Typst lays
//! it out with its embedded fonts, and the SVG is cached on disk for Qt rich text.
use anyhow::{Result, bail, ensure};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    path::{Path, PathBuf},
    sync::LazyLock,
};
use typst::diag::{FileError, FileResult};
use typst::foundations::{Bytes, Datetime, Duration};
use typst::layout::{Frame, FrameItem};
use typst::syntax::{FileId, RootedPath, Source, VirtualPath, VirtualRoot};
use typst::text::{Font, FontBook};
use typst::utils::LazyHash;
use typst::{Library, LibraryExt, World};
use typst_layout::PagedDocument;

const MAX_TEX: usize = 4096;
const MAX_ITEMS: usize = 200;
// Bump when the SVG layout changes so stale cache entries are ignored.
const VERSION: &str = "1";

static FONTS: LazyLock<(LazyHash<FontBook>, Vec<Font>)> = LazyLock::new(|| {
    let fonts: Vec<Font> = typst_assets::fonts()
        .flat_map(|data| Font::iter(Bytes::new(data)))
        .collect();
    (LazyHash::new(FontBook::from_fonts(&fonts)), fonts)
});
static LIBRARY: LazyLock<LazyHash<Library>> = LazyLock::new(|| LazyHash::new(Library::default()));

fn file_id(path: &str) -> FileId {
    RootedPath::new(VirtualRoot::Project, VirtualPath::new(path).unwrap()).intern()
}

struct MathWorld {
    main: Source,
    formula: String,
}

impl World for MathWorld {
    fn library(&self) -> &LazyHash<Library> {
        &LIBRARY
    }
    fn book(&self) -> &LazyHash<FontBook> {
        &FONTS.0
    }
    fn main(&self) -> FileId {
        self.main.id()
    }
    fn source(&self, id: FileId) -> FileResult<Source> {
        if id == self.main.id() {
            return Ok(self.main.clone());
        }
        let text = match id.vpath().get_without_slash() {
            "mitex/mod.typ" => include_str!("mitex/mod.typ"),
            "mitex/prelude.typ" => include_str!("mitex/prelude.typ"),
            "mitex/latex/standard.typ" => include_str!("mitex/latex/standard.typ"),
            _ => return Err(FileError::AccessDenied),
        };
        Ok(Source::new(id, text.into()))
    }
    fn file(&self, id: FileId) -> FileResult<Bytes> {
        if id == file_id("formula.txt") {
            return Ok(Bytes::from_string(self.formula.clone()));
        }
        self.source(id)
            .map(|s| Bytes::from_string(s.text().to_string()))
    }
    fn font(&self, index: usize) -> Option<Font> {
        FONTS.1.get(index).cloned()
    }
    fn today(&self, _: Option<Duration>) -> Option<Datetime> {
        None
    }
}

pub fn cache_dir() -> PathBuf {
    std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(std::env::var_os("HOME").unwrap()).join(".cache"))
        .join("omabib/math")
}

/// `render_math`: `{items:[{tex, display}], color:"#rrggbb", size_px, scale?}`.
pub fn render(a: &Value) -> Result<Value> {
    render_in(a, &cache_dir())
}

pub fn render_in(a: &Value, dir: &Path) -> Result<Value> {
    let items = a["items"].as_array().map(Vec::as_slice).unwrap_or(&[]);
    ensure!(
        items.len() <= MAX_ITEMS,
        "At most {MAX_ITEMS} formulas per request"
    );
    let color = a["color"].as_str().unwrap_or("#000000");
    ensure!(
        color.len() == 7
            && color.starts_with('#')
            && color[1..].bytes().all(|b| b.is_ascii_hexdigit()),
        "Color must be #rrggbb"
    );
    let size = a["size_px"].as_f64().unwrap_or(14.0);
    ensure!(
        (6.0..=72.0).contains(&size),
        "size_px must be between 6 and 72"
    );
    let scale = a["scale"].as_f64().unwrap_or(2.0);
    ensure!(
        (1.0..=4.0).contains(&scale),
        "scale must be between 1 and 4"
    );
    std::fs::create_dir_all(dir)?;
    let out = items
        .iter()
        .map(|item| {
            let tex = item["tex"].as_str().unwrap_or("");
            let display = item["display"].as_bool().unwrap_or(false);
            one(dir, tex, display, color, size, scale)
        })
        .collect::<Vec<_>>();
    Ok(json!({ "items": out }))
}

fn one(dir: &Path, tex: &str, display: bool, color: &str, size: f64, scale: f64) -> Value {
    let key = format!(
        "{:x}",
        Sha256::digest(format!("{VERSION}|{display}|{color}|{size}|{scale}|{tex}"))
    )[..32]
        .to_string();
    let svg_path = dir.join(format!("{key}.svg"));
    let meta_path = dir.join(format!("{key}.json"));
    if let Ok(meta) = std::fs::read(&meta_path).map(|b| serde_json::from_slice::<Value>(&b))
        && let Ok(mut meta) = meta
        && (meta.get("error").is_some() || svg_path.is_file())
    {
        meta["key"] = json!(key);
        meta["cached"] = json!(true);
        return meta;
    }
    let meta = match typeset(tex, display, color, size, scale) {
        Ok((svg, width, height)) => {
            if let Err(e) = write_atomic(&svg_path, svg.as_bytes()) {
                return json!({ "key": key, "error": e.to_string() });
            }
            json!({ "path": svg_path, "width": width, "height": height })
        }
        Err(e) => json!({ "error": e.to_string() }),
    };
    let _ = write_atomic(&meta_path, meta.to_string().as_bytes());
    let mut meta = meta;
    meta["key"] = json!(key);
    meta
}

pub(crate) fn write_atomic(path: &Path, data: &[u8]) -> Result<()> {
    let tmp = path.with_extension(format!("tmp{}", std::process::id()));
    std::fs::write(&tmp, data)?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

/// Lay out one formula. Returns the SVG and its size in logical pixels.
///
/// Inline formulas are padded vertically so that, centered on a line with Qt's
/// `vertical-align: middle`, their baseline sits on the text baseline.
pub fn typeset(
    tex: &str,
    display: bool,
    color: &str,
    size: f64,
    scale: f64,
) -> Result<(String, u32, u32)> {
    let tex = tex.trim();
    ensure!(!tex.is_empty(), "Empty formula");
    ensure!(tex.len() <= MAX_TEX, "Formula exceeds {MAX_TEX} bytes");
    let converted = match mitex::convert_math(tex, None) {
        Ok(c) => c,
        Err(e) => bail!("{}", e.trim_start_matches("error: ")),
    };
    // Sizes are given in pt so one Typst point is one logical pixel.
    let main = format!(
        "#import \"mitex/mod.typ\": mitex-scope\n\
         #set page(width: auto, height: auto, margin: 0pt, fill: none)\n\
         #set text(fill: rgb(\"{color}\"), size: {size}pt, top-edge: \"bounds\", bottom-edge: \"bounds\")\n\
         #math.equation(block: {display}, eval(\"$\" + read(\"formula.txt\") + \"$\", scope: mitex-scope))\n"
    );
    let world = MathWorld {
        main: Source::new(file_id("main.typ"), main),
        formula: converted,
    };
    let doc: PagedDocument = match typst::compile(&world).output {
        Ok(doc) => doc,
        Err(errors) => bail!(
            "{}",
            errors
                .first()
                .map(|e| e.message.as_str())
                .unwrap_or("Math layout failed")
        ),
    };
    let page = doc
        .pages()
        .first()
        .ok_or_else(|| anyhow::anyhow!("Empty formula"))?;
    let svg = typst_svg::svg(page, &typst_svg::SvgOptions::default());
    let size_pt = page.frame.size();
    let (w, h) = (size_pt.x.to_pt(), size_pt.y.to_pt());
    let (top, bottom) = if display {
        (0.0, 0.0)
    } else {
        let ascent = baseline(&page.frame).unwrap_or(h);
        // The middle of a line of body text sits about 0.3em above its baseline;
        // pad so the image center lands there: top + h + bottom = 2 * (top + ascent - lift).
        let diff = 2.0 * (ascent - 0.3 * size) - h;
        if diff >= 0.0 {
            (0.0, diff)
        } else {
            (-diff, 0.0)
        }
    };
    let total_h = h + top + bottom;
    let svg = resize(&svg, w, total_h, -top, scale)?;
    Ok((svg, w.ceil() as u32, total_h.ceil() as u32))
}

/// The baseline of the first line in a frame, measured from its top.
fn baseline(frame: &Frame) -> Option<f64> {
    frame.items().find_map(|(pos, item)| match item {
        FrameItem::Group(g) if g.frame.has_baseline() => {
            Some(pos.y.to_pt() + g.frame.baseline().to_pt())
        }
        FrameItem::Group(g) => baseline(&g.frame).map(|b| pos.y.to_pt() + b),
        _ => None,
    })
}

/// Rewrite the root element's viewBox and pixel size: `y` shifts the view up
/// (negative) to add top padding, and the intrinsic size is `scale` times the
/// logical size so Qt downsamples instead of upscaling.
fn resize(svg: &str, w: f64, h: f64, y: f64, scale: f64) -> Result<String> {
    let end = svg
        .find('>')
        .ok_or_else(|| anyhow::anyhow!("Malformed SVG"))?;
    let head = &svg[..end];
    let mut out = String::with_capacity(svg.len() + 64);
    let mut rest = head;
    for (name, value) in [
        ("viewBox", format!("0 {y:.3} {w:.3} {h:.3}")),
        ("width", format!("{:.0}", (w * scale).ceil())),
        ("height", format!("{:.0}", (h * scale).ceil())),
    ] {
        let at = rest
            .find(&format!(" {name}=\""))
            .ok_or_else(|| anyhow::anyhow!("SVG without {name}"))?;
        let start = at + name.len() + 3;
        let close = rest[start..]
            .find('"')
            .ok_or_else(|| anyhow::anyhow!("Malformed SVG"))?
            + start;
        out.push_str(&rest[..start]);
        out.push_str(&value);
        rest = &rest[close..];
    }
    out.push_str(rest);
    out.push_str(&svg[end..]);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resize_rewrites_root_attributes_only() {
        let svg = r#"<svg viewBox="0 0 10 5" width="10pt" height="5pt" xmlns="x"><rect width="3pt"/></svg>"#;
        let out = resize(svg, 10.0, 8.0, -3.0, 2.0).unwrap();
        assert!(
            out.starts_with(
                r#"<svg viewBox="0 -3.000 10.000 8.000" width="20" height="16" xmlns="x">"#
            ),
            "{out}"
        );
        assert!(out.contains(r#"<rect width="3pt"/>"#));
    }
}
