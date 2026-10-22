//! Native PDF reading with MuPDF: page images for reader tabs, word boxes for
//! selection, search, and clip rendering for visual notes. MuPDF documents are
//! not thread-safe, so one worker thread owns every open document.
//!
//! Coordinates are PDF points in page space with the origin at the top left,
//! as MuPDF reports them. Page numbers in the API are 1-based, like notes.
use crate::db::{Library, required};
use anyhow::{Context, Result, anyhow, bail, ensure};
use mupdf::{
    Colorspace, Device, Document, IRect, ImageFormat, Matrix, Pixmap, Rect, TextCharFlags,
    TextPage, TextPageFlags, pdf::PdfDocument,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::{Mutex, mpsc},
};

const OPEN_DOCUMENTS: usize = 8;
const CACHE_LIMIT: u64 = 500 * 1024 * 1024;
const MAX_HITS: usize = 500;
const MAX_CLIP_PIXELS: f32 = 32_000_000.0;

type Job = Box<dyn FnOnce(&mut Worker) + Send>;

pub struct Pdf {
    cache: PathBuf,
    jobs: Mutex<Option<mpsc::Sender<Job>>>,
}

pub fn cache_dir() -> PathBuf {
    std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(std::env::var_os("HOME").unwrap()).join(".cache"))
        .join("omabib/pages")
}

impl Pdf {
    pub fn new(cache: impl Into<PathBuf>) -> Self {
        Self {
            cache: cache.into(),
            jobs: Mutex::new(None),
        }
    }

    /// Run `f` on the MuPDF thread, starting it on first use and again if it died.
    fn run<T: Send + 'static>(
        &self,
        f: impl FnOnce(&mut Worker) -> Result<T> + Send + 'static,
    ) -> Result<T> {
        let (reply, answer) = mpsc::channel();
        let job: Job = Box::new(move |w| {
            let _ = reply.send(f(w));
        });
        let mut jobs = self.jobs.lock().unwrap();
        let sender = jobs.get_or_insert_with(|| {
            let (tx, rx) = mpsc::channel::<Job>();
            let cache = self.cache.clone();
            std::thread::Builder::new()
                .name("omabib-pdf".into())
                .spawn(move || {
                    let mut worker = Worker::new(cache);
                    for job in rx {
                        job(&mut worker);
                    }
                })
                .expect("spawn PDF worker");
            tx
        });
        if sender.send(job).is_err() {
            *jobs = None;
            bail!("The PDF renderer stopped; try again");
        }
        drop(jobs);
        answer.recv().unwrap_or_else(|_| {
            *self.jobs.lock().unwrap() = None;
            Err(anyhow!("The PDF renderer stopped; try again"))
        })
    }

    pub fn open_path(&self, path: &Path) -> Result<Value> {
        let path = path.to_path_buf();
        self.run(move |w| {
            let id = w.register(&path)?;
            w.info(&id)
        })
    }

    pub fn render(&self, doc_id: &str, page: u32, scale: f32) -> Result<Value> {
        let id = doc_id.to_string();
        self.run(move |w| w.render(&id, page, scale))
    }

    pub fn text(&self, doc_id: &str, page: u32) -> Result<Value> {
        let id = doc_id.to_string();
        self.run(move |w| w.text(&id, page))
    }

    pub fn search(&self, doc_id: &str, query: &str) -> Result<Value> {
        let (id, query) = (doc_id.to_string(), query.to_string());
        self.run(move |w| w.search(&id, &query))
    }

    /// The first pages' lines with their fonts and sizes, and the document
    /// information dictionary, for identifying the paper (see `recognize`).
    pub fn read_paper(&self, path: &Path) -> Result<crate::recognize::Reading> {
        let path = path.to_path_buf();
        self.run(move |_| read_paper(&path))
    }

    /// Render `rect` (pt) of a page at `scale` as PNG bytes.
    pub fn clip(&self, path: &Path, page: u32, rect: [f32; 4], scale: f32) -> Result<Vec<u8>> {
        let path = path.to_path_buf();
        self.run(move |w| {
            let id = w.register(&path)?;
            w.clip(&id, page, rect, scale)
        })
    }
}

struct Worker {
    cache: PathBuf,
    known: HashMap<String, PathBuf>,
    // Most recently used last.
    open: Vec<(String, Document)>,
    writes: usize,
}

fn to_err(e: mupdf::Error) -> anyhow::Error {
    anyhow!("PDF error: {e}")
}

/// A document identity that changes when the file does.
fn doc_id(path: &Path) -> Result<String> {
    let meta =
        std::fs::metadata(path).with_context(|| format!("PDF not found: {}", path.display()))?;
    let modified = meta
        .modified()?
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let digest = Sha256::digest(format!("{}|{}|{modified}", path.display(), meta.len()));
    Ok(format!("{digest:x}")[..24].to_string())
}

fn png_size(path: &Path) -> Option<(u32, u32)> {
    use std::io::Read;
    let mut head = [0u8; 24];
    std::fs::File::open(path).ok()?.read_exact(&mut head).ok()?;
    (head[..8] == *b"\x89PNG\r\n\x1a\n").then(|| {
        (
            u32::from_be_bytes(head[16..20].try_into().unwrap()),
            u32::from_be_bytes(head[20..24].try_into().unwrap()),
        )
    })
}

fn rect_json(r: Rect) -> Value {
    json!([r.x0, r.y0, r.x1, r.y1])
}

/// Opened apart from the reader's documents: a document read once to identify
/// it, and its trailer, which only the PDF-specific type exposes.
fn read_paper(path: &Path) -> Result<crate::recognize::Reading> {
    let doc = PdfDocument::open(path.to_string_lossy().as_ref()).map_err(to_err)?;
    ensure!(
        !doc.needs_password().map_err(to_err)?,
        "Password-protected PDFs are not supported"
    );
    let page_count = doc.page_count().map_err(to_err)?.max(0) as usize;
    let mut pages = Vec::new();
    for i in 0..page_count.min(crate::recognize::PAGES) {
        let page = doc.load_page(i as i32).map_err(to_err)?;
        let b = page.bounds().map_err(to_err)?;
        let text = page
            .to_text_page(TextPageFlags::empty())
            .map_err(to_err)?;
        pages.push(read_page(&text, b.x1 - b.x0, b.y1 - b.y0));
    }
    let mut info = Vec::new();
    if let Ok(Some(dict)) = doc.trailer().and_then(|t| t.get_dict("Info"))
        && let Ok(entries) = dict.dict_iter()
    {
        for (key, value) in entries.flatten() {
            if let (Ok(key), Ok(value)) = (key.as_name(), value.as_string())
                && !value.trim().is_empty()
            {
                info.push((String::from_utf8_lossy(&key).into_owned(), value.trim().to_string()));
            }
        }
    }
    Ok(crate::recognize::Reading {
        page_count,
        info,
        pages,
    })
}

/// The value counted most often, ties to the larger.
fn most<K: Ord + Clone>(counts: &HashMap<K, usize>) -> Option<K> {
    counts
        .iter()
        .max_by(|a, b| a.1.cmp(b.1).then_with(|| a.0.cmp(b.0)))
        .map(|(k, _)| k.clone())
}

fn read_page(text: &TextPage, width: f32, height: f32) -> crate::recognize::Page {
    // Sizes in hundredths of a point, so they can be counted and compared.
    let mut page_sizes: HashMap<i32, usize> = HashMap::new();
    let mut page = crate::recognize::Page {
        width,
        height,
        ..Default::default()
    };
    for block in text.blocks() {
        for line in block.lines() {
            let mut s = String::new();
            let (mut sizes, mut fonts) = (HashMap::<i32, usize>::new(), HashMap::<String, usize>::new());
            let (mut bold, mut chars) = (0, 0);
            let (mut first, mut last) = (None, None);
            for ch in line.chars() {
                let Some(c) = ch.char() else { continue };
                s.push(c);
                if c.is_whitespace() {
                    continue;
                }
                let font = ch.font();
                if ch.flags().contains(TextCharFlags::BOLD) || font.as_ref().is_some_and(|f| f.is_bold()) {
                    bold += 1;
                }
                *fonts.entry(font.map(|f| f.name().to_string()).unwrap_or_default()).or_default() += 1;
                *sizes.entry((ch.size() * 100.0).round() as i32).or_default() += 1;
                chars += 1;
                first.get_or_insert(ch.origin());
                last = Some(ch.origin());
            }
            page.text.push_str(s.trim_end());
            page.text.push('\n');
            // A line running up the margin, like arXiv's stamp, or across the
            // page, like an "Article in Press" watermark, is text but not layout.
            let upright = match (first, last) {
                (Some(a), Some(b)) => (b.y - a.y).abs() <= (b.x - a.x).abs() * 0.1,
                _ => false,
            };
            if chars == 0 || !upright {
                continue;
            }
            for (size, n) in &sizes {
                *page_sizes.entry(*size).or_default() += n;
            }
            let r = line.bounds();
            let mut font_names: Vec<String> = fonts.keys().cloned().collect();
            font_names.sort();
            page.lines.push(crate::recognize::Line {
                text: s.trim().to_string(),
                x0: r.x0,
                y0: r.y0,
                x1: r.x1,
                y1: r.y1,
                size: most(&sizes).unwrap_or(0) as f32 / 100.0,
                font: most(&fonts).unwrap_or_default(),
                bold: bold * 2 > chars,
                fonts: font_names,
                sizes: sizes.keys().map(|s| *s as f32 / 100.0).collect(),
            });
        }
    }
    let mut sizes: Vec<(f32, usize)> = page_sizes
        .into_iter()
        .map(|(s, n)| (s as f32 / 100.0, n))
        .collect();
    sizes.sort_by(|a, b| a.0.total_cmp(&b.0));
    page.sizes = sizes;
    page
}

impl Worker {
    fn new(cache: PathBuf) -> Self {
        Self {
            cache,
            known: HashMap::new(),
            open: Vec::new(),
            writes: 0,
        }
    }

    fn register(&mut self, path: &Path) -> Result<String> {
        let path = path
            .canonicalize()
            .with_context(|| format!("PDF not found: {}", path.display()))?;
        let id = doc_id(&path)?;
        self.known.insert(id.clone(), path);
        Ok(id)
    }

    fn document(&mut self, id: &str) -> Result<&Document> {
        let path = self
            .known
            .get(id)
            .context("Unknown PDF document; open it again")?
            .clone();
        // A replaced or edited file must not be read through a stale handle.
        if doc_id(&path).ok().as_deref() != Some(id) {
            self.open.retain(|(k, _)| k != id);
            self.known.remove(id);
            bail!("The PDF changed on disk; open it again");
        }
        if let Some(at) = self.open.iter().position(|(k, _)| k == id) {
            let entry = self.open.remove(at);
            self.open.push(entry);
        } else {
            let doc = Document::open(path.to_string_lossy().as_ref()).map_err(to_err)?;
            ensure!(
                !doc.needs_password().map_err(to_err)?,
                "Password-protected PDFs are not supported"
            );
            self.open.push((id.to_string(), doc));
            if self.open.len() > OPEN_DOCUMENTS {
                self.open.remove(0);
            }
        }
        Ok(&self.open.last().unwrap().1)
    }

    fn page(&mut self, id: &str, page: u32) -> Result<mupdf::Page> {
        let doc = self.document(id)?;
        let count = doc.page_count().map_err(to_err)?;
        ensure!(
            page >= 1 && page as i32 <= count,
            "Page {page} is outside 1–{count}"
        );
        doc.load_page(page as i32 - 1).map_err(to_err)
    }

    fn info(&mut self, id: &str) -> Result<Value> {
        let doc = self.document(id)?;
        let count = doc.page_count().map_err(to_err)?;
        let mut pages = Vec::with_capacity(count.max(0) as usize);
        for i in 0..count {
            let b = doc.load_page(i).and_then(|p| p.bounds()).map_err(to_err)?;
            pages.push(json!({"x0":b.x0,"y0":b.y0,"w":b.x1 - b.x0,"h":b.y1 - b.y0}));
        }
        let mut outline = Vec::new();
        fn walk(items: &[mupdf::Outline], level: usize, out: &mut Vec<Value>) {
            for item in items {
                out.push(json!({
                    "title": item.title,
                    "level": level,
                    "page": item.dest.map(|d| d.loc.page_number + 1),
                    "uri": item.uri,
                }));
                walk(&item.down, level + 1, out);
            }
        }
        walk(&doc.outlines().map_err(to_err)?, 0, &mut outline);
        let title = doc.metadata(mupdf::MetadataName::Title).unwrap_or_default();
        Ok(json!({"doc_id":id,"page_count":count,"pages":pages,"title":title,"outline":outline}))
    }

    fn links(page: &mupdf::Page) -> Result<Vec<Value>> {
        Ok(page
            .links()
            .map_err(to_err)?
            .map(|l| {
                let target = l.dest.map(|d| d.loc.page_number + 1);
                let external = target.is_none()
                    && (l.uri.starts_with("http://") || l.uri.starts_with("https://") || l.uri.starts_with("mailto:"));
                json!({"rect":rect_json(l.bounds),"page":target,"uri":if external { Some(l.uri) } else { None }})
            })
            .collect())
    }

    fn render(&mut self, id: &str, page_no: u32, scale: f32) -> Result<Value> {
        ensure!(scale.is_finite(), "Invalid scale");
        let scale = ((scale * 4.0).round() / 4.0).clamp(0.25, 8.0);
        let page = self.page(id, page_no)?;
        let links = Self::links(&page)?;
        let dir = self.cache.join(id);
        let file = dir.join(format!("{page_no}@{scale:.2}.png"));
        if let Some((width, height)) = png_size(&file) {
            return Ok(
                json!({"path":file,"width":width,"height":height,"scale":scale,"links":links}),
            );
        }
        let pix = page
            .to_pixmap(
                &Matrix::new_scale(scale, scale),
                &Colorspace::device_rgb(),
                false,
                true,
            )
            .map_err(to_err)?;
        let mut png = Vec::new();
        pix.write_to(&mut png, ImageFormat::PNG).map_err(to_err)?;
        std::fs::create_dir_all(&dir)?;
        crate::math::write_atomic(&file, &png)?;
        self.writes += 1;
        if self.writes % 20 == 1 {
            self.evict(id);
        }
        Ok(
            json!({"path":file,"width":pix.width(),"height":pix.height(),"scale":scale,"links":links}),
        )
    }

    /// Keep the page cache under its limit, dropping the least recently written documents.
    fn evict(&self, keep: &str) {
        let Ok(entries) = std::fs::read_dir(&self.cache) else {
            return;
        };
        let mut docs: Vec<(std::time::SystemTime, u64, PathBuf)> = entries
            .flatten()
            .filter(|e| e.file_name().to_string_lossy() != keep)
            .filter_map(|e| {
                let files = std::fs::read_dir(e.path()).ok()?;
                let (mut size, mut newest) = (0, std::time::UNIX_EPOCH);
                for f in files.flatten() {
                    if let Ok(m) = f.metadata() {
                        size += m.len();
                        newest = newest.max(m.modified().unwrap_or(std::time::UNIX_EPOCH));
                    }
                }
                Some((newest, size, e.path()))
            })
            .collect();
        let mut total: u64 = docs.iter().map(|d| d.1).sum();
        if total <= CACHE_LIMIT {
            return;
        }
        docs.sort();
        for (_, size, path) in docs {
            if total <= CACHE_LIMIT * 4 / 5 {
                break;
            }
            if std::fs::remove_dir_all(&path).is_ok() {
                total = total.saturating_sub(size);
            }
        }
    }

    fn text(&mut self, id: &str, page_no: u32) -> Result<Value> {
        let page = self.page(id, page_no)?;
        let words = page
            .to_text_page(TextPageFlags::empty())
            .map_err(to_err)?
            .words()
            .into_iter()
            .map(|w| {
                json!([
                    w.text,
                    w.bounds.x0,
                    w.bounds.y0,
                    w.bounds.x1,
                    w.bounds.y1,
                    w.block,
                    w.line
                ])
            })
            .collect::<Vec<_>>();
        Ok(json!({"page":page_no,"words":words}))
    }

    fn search(&mut self, id: &str, query: &str) -> Result<Value> {
        let query = query.trim();
        ensure!(!query.is_empty(), "Empty search");
        ensure!(query.len() <= 256, "Search text is too long");
        let count = self.document(id)?.page_count().map_err(to_err)?;
        let (mut hits, mut total, mut truncated) = (Vec::new(), 0, false);
        for i in 0..count {
            let page = self.document(id)?.load_page(i).map_err(to_err)?;
            let quads = page
                .search(query, (MAX_HITS - total) as u32 + 1)
                .map_err(to_err)?;
            if quads.is_empty() {
                continue;
            }
            let mut rects: Vec<Value> = quads
                .iter()
                .map(|q| {
                    let (xs, ys) = (
                        [q.ul.x, q.ur.x, q.ll.x, q.lr.x],
                        [q.ul.y, q.ur.y, q.ll.y, q.lr.y],
                    );
                    json!([
                        xs.iter().cloned().fold(f32::MAX, f32::min),
                        ys.iter().cloned().fold(f32::MAX, f32::min),
                        xs.iter().cloned().fold(f32::MIN, f32::max),
                        ys.iter().cloned().fold(f32::MIN, f32::max)
                    ])
                })
                .collect();
            if total + rects.len() > MAX_HITS {
                rects.truncate(MAX_HITS - total);
                truncated = true;
            }
            total += rects.len();
            hits.push(json!({"page":i + 1,"rects":rects}));
            if truncated {
                break;
            }
        }
        Ok(json!({"query":query,"hits":hits,"total":total,"truncated":truncated}))
    }

    fn clip(
        &mut self,
        id: &str,
        page_no: u32,
        [x, y, w, h]: [f32; 4],
        scale: f32,
    ) -> Result<Vec<u8>> {
        ensure!(
            [x, y, w, h].iter().all(|v| v.is_finite()) && w >= 1.0 && h >= 1.0,
            "Clip rectangle must be at least 1pt wide and high"
        );
        let page = self.page(id, page_no)?;
        let b = page.bounds().map_err(to_err)?;
        let (x0, y0) = (x.max(b.x0), y.max(b.y0));
        let (x1, y1) = ((x + w).min(b.x1), (y + h).min(b.y1));
        ensure!(
            x1 - x0 >= 1.0 && y1 - y0 >= 1.0,
            "Clip rectangle is outside the page"
        );
        let scale = scale.min((MAX_CLIP_PIXELS / ((x1 - x0) * (y1 - y0))).sqrt());
        let rect = IRect {
            x0: (x0 * scale).floor() as i32,
            y0: (y0 * scale).floor() as i32,
            x1: (x1 * scale).ceil() as i32,
            y1: (y1 * scale).ceil() as i32,
        };
        let mut pix =
            Pixmap::new_with_rect(&Colorspace::device_rgb(), rect, false).map_err(to_err)?;
        pix.clear_with(255).map_err(to_err)?;
        {
            let device = Device::from_pixmap(&pix).map_err(to_err)?;
            page.run(&device, &Matrix::new_scale(scale, scale))
                .map_err(to_err)?;
        }
        let mut png = Vec::new();
        pix.write_to(&mut png, ImageFormat::PNG).map_err(to_err)?;
        Ok(png)
    }
}

/// `pdf_open`: the reference's PDF (a given attachment, or the first local one,
/// downloaded from sync storage or found online) with its page sizes and outline.
pub fn open(lib: &Library, a: &Value) -> Result<Value> {
    let ref_id = required(a, "ref_id")?;
    let (path, attachment_id, source) = if let Some(attachment) = a["attachment_id"].as_str() {
        let at = lib.call("get_attachment", &json!({"id":attachment}))?;
        ensure!(
            at["ref_id"] == ref_id,
            "Attachment belongs to another reference"
        );
        ensure!(
            at["file_type"]
                .as_str()
                .is_some_and(|t| t.eq_ignore_ascii_case("pdf")),
            "Attachment is not a PDF"
        );
        (
            at["path"].as_str().unwrap_or("").to_string(),
            attachment.to_string(),
            "local".to_string(),
        )
    } else {
        let got = crate::attachments::get_pdf(
            lib,
            &json!({"ref_id":ref_id,"download":a.get("download") != Some(&json!(false))}),
        )?;
        (
            got["path"].as_str().unwrap_or("").to_string(),
            got["attachment_id"].as_str().unwrap_or("").to_string(),
            got["source"].as_str().unwrap_or("local").to_string(),
        )
    };
    let path = Path::new(&path)
        .canonicalize()
        .with_context(|| format!("PDF not found: {path}"))?;
    let mut info = lib.pdf.open_path(&path)?;
    info["ref_id"] = json!(ref_id);
    info["attachment_id"] = json!(attachment_id);
    info["path"] = json!(path);
    info["source"] = json!(source);
    Ok(info)
}

fn page_arg(a: &Value) -> Result<u32> {
    a["page"]
        .as_u64()
        .filter(|p| (1..=100_000).contains(p))
        .map(|p| p as u32)
        .context("page must be a page number from 1")
}

pub fn render(lib: &Library, a: &Value) -> Result<Value> {
    let scale = a["scale"].as_f64().unwrap_or(1.0) as f32;
    lib.pdf.render(required(a, "doc_id")?, page_arg(a)?, scale)
}

pub fn text(lib: &Library, a: &Value) -> Result<Value> {
    lib.pdf.text(required(a, "doc_id")?, page_arg(a)?)
}

pub fn search(lib: &Library, a: &Value) -> Result<Value> {
    lib.pdf
        .search(required(a, "doc_id")?, required(a, "query")?)
}
