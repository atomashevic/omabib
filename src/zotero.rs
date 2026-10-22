//! Moving a Zotero library into Omabib. Zotero's database is read from a
//! copy, so a running Zotero is never locked or changed. Each item becomes a
//! BibTeX entry under the citation key it already has (Zotero 7's own field,
//! Better BibTeX's, or one in Extra), with its PDFs, its notes, its PDF
//! annotations as a note, and its collections as projects. Running it again
//! fills in what is new and adds nothing twice.
use crate::db::{Library, parse_bibtex, serialize_entry, text};
use anyhow::{Context, Result, ensure};
use rusqlite::{Connection, OpenFlags, OptionalExtension, params};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// Omabib's notes hold up to 64 KiB; longer Zotero notes are split.
const NOTE_LIMIT: usize = 60_000;

fn home() -> PathBuf {
    PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
}

/// Zotero profiles' prefs.js, which say where the library is: Linux, macOS, Flatpak.
fn prefs() -> Vec<String> {
    let h = home();
    [
        ".zotero/zotero",
        "Library/Application Support/Zotero/Profiles",
        ".var/app/org.zotero.Zotero/.zotero/zotero",
    ]
    .iter()
    .filter_map(|d| std::fs::read_dir(h.join(d)).ok())
    .flatten()
    .flatten()
    .filter_map(|e| std::fs::read_to_string(e.path().join("prefs.js")).ok())
    .collect()
}

/// A string preference from prefs.js: `user_pref("name", "value");`.
fn pref(prefs: &str, name: &str) -> Option<String> {
    prefs.lines().find_map(|l| {
        let rest = l
            .trim()
            .strip_prefix("user_pref(\"")?
            .strip_prefix(name)?
            .strip_prefix("\",")?;
        let value = rest.trim().strip_prefix('"')?.rsplit_once("\");")?.0;
        Some(value.replace("\\\\", "\u{0}").replace("\\\"", "\"").replace('\u{0}', "\\"))
    })
}

/// Where Zotero keeps its library: the folder its preferences name, else ~/Zotero.
fn find() -> Option<PathBuf> {
    let mut dirs: Vec<PathBuf> = prefs()
        .iter()
        .filter_map(|p| pref(p, "extensions.zotero.dataDir"))
        .map(PathBuf::from)
        .collect();
    dirs.push(home().join("Zotero"));
    dirs.into_iter().find(|d| d.join("zotero.sqlite").is_file())
}

/// The library folder asked for (it, or its zotero.sqlite), or the one found.
fn data_dir(a: &Value) -> Result<PathBuf> {
    match a.get("path").and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()) {
        Some(p) => {
            let p = PathBuf::from(p);
            let dir = if p.file_name().is_some_and(|n| n == "zotero.sqlite") {
                p.parent().map(Path::to_path_buf).unwrap_or_default()
            } else {
                p
            };
            ensure!(
                dir.join("zotero.sqlite").is_file(),
                "There is no Zotero library (zotero.sqlite) in {}",
                dir.display()
            );
            Ok(dir)
        }
        None => find().context(
            "No Zotero library was found. Choose Zotero's data folder, the one with zotero.sqlite in it.",
        ),
    }
}

/// Whether Zotero is open: it keeps its database locked while it runs.
fn running(dir: &Path) -> bool {
    Connection::open_with_flags(dir.join("zotero.sqlite"), OpenFlags::SQLITE_OPEN_READ_ONLY)
        .and_then(|c| c.query_row("SELECT count(*) FROM items", [], |r| r.get::<_, i64>(0)))
        .is_err()
}

/// A private copy of Zotero's database, with any journal beside it so an
/// unfinished write rolls back in the copy.
fn snapshot(dir: &Path) -> Result<(tempfile::TempDir, Connection)> {
    let tmp = tempfile::tempdir()?;
    for name in ["zotero.sqlite", "zotero.sqlite-journal", "zotero.sqlite-wal"] {
        let source = dir.join(name);
        if source.is_file() {
            std::fs::copy(&source, tmp.path().join(name))
                .with_context(|| format!("Cannot read {}", source.display()))?;
        }
    }
    let c = Connection::open(tmp.path().join("zotero.sqlite"))?;
    let check: String = c.query_row("PRAGMA quick_check", [], |r| r.get(0))?;
    ensure!(
        check == "ok",
        "Zotero's library changed while it was being read. Close Zotero and try again."
    );
    Ok((tmp, c))
}

fn value(v: rusqlite::types::Value) -> String {
    match v {
        rusqlite::types::Value::Text(s) => s,
        rusqlite::types::Value::Integer(n) => n.to_string(),
        rusqlite::types::Value::Real(n) => n.to_string(),
        _ => String::new(),
    }
}

#[derive(Default)]
struct Item {
    library: i64,
    key: String,
    kind: String,
    /// When it was added to Zotero, as Omabib stores it.
    added: String,
    fields: BTreeMap<String, String>,
    /// (role, last name, first name, a single-field name such as an institution)
    creators: Vec<(String, String, String, bool)>,
    tags: Vec<String>,
}

struct File {
    id: i64,
    key: String,
    added: String,
    library: i64,
    parent: Option<i64>,
    link: i64,
    content_type: String,
    path: String,
}

struct Mark {
    kind: i64,
    text: String,
    comment: String,
    page: String,
}

/// What a Zotero library holds, read once.
#[derive(Default)]
struct Zotero {
    dir: PathBuf,
    /// Where relative linked files live (`attachments:` paths).
    base: Option<PathBuf>,
    /// Group libraries by ID; the user's own library is not one.
    groups: BTreeMap<i64, String>,
    items: BTreeMap<i64, Item>,
    files: Vec<File>,
    /// (note item key, library, parent item, HTML)
    notes: Vec<(String, i64, i64, String)>,
    loose_notes: usize,
    /// Annotations by the attachment they are on, in reading order.
    marks: HashMap<i64, Vec<Mark>>,
    /// (name, parent, library)
    collections: BTreeMap<i64, (String, Option<i64>, i64)>,
    memberships: HashMap<i64, Vec<i64>>,
    /// Better BibTeX's citation keys by (library, item key).
    keys: HashMap<(i64, String), String>,
}

fn read(dir: &Path) -> Result<Zotero> {
    let (_tmp, c) = snapshot(dir)?;
    let has = |table: &str| -> Result<bool> {
        Ok(c.query_row(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
            [table],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
    };
    ensure!(
        has("fieldsCombined")? && has("itemTypesCombined")?,
        "This Zotero library is from an older Zotero. Open it once in Zotero 7, then try again."
    );
    let mut z = Zotero {
        dir: dir.to_path_buf(),
        base: prefs().iter().find_map(|p| pref(p, "extensions.zotero.baseAttachmentPath")).map(PathBuf::from),
        ..Default::default()
    };
    let mut feeds = HashSet::new();
    let mut stmt = c.prepare("SELECT l.libraryID, l.type, g.name FROM libraries l LEFT JOIN groups g USING(libraryID)")?;
    for row in stmt.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?, r.get::<_, Option<String>>(2)?)))? {
        let (id, kind, name) = row?;
        if kind == "feed" {
            feeds.insert(id);
        } else if let Some(name) = name {
            z.groups.insert(id, name);
        }
    }

    // Every item not in the trash: (library, key, type), and when it was added.
    let mut meta: HashMap<i64, (i64, String, String)> = HashMap::new();
    let mut added: HashMap<i64, String> = HashMap::new();
    let mut stmt = c.prepare(
        "SELECT i.itemID, i.libraryID, i.key, t.typeName, i.dateAdded FROM items i JOIN itemTypesCombined t USING(itemTypeID) \
         WHERE i.itemID NOT IN (SELECT itemID FROM deletedItems)",
    )?;
    for row in stmt.query_map([], |r| {
        Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, r.get::<_, String>(2)?, r.get::<_, String>(3)?, value(r.get(4)?)))
    })? {
        let (id, library, key, kind, when) = row?;
        if feeds.contains(&library) {
            continue;
        }
        let when = timestamp(&when);
        if !["attachment", "note", "annotation"].contains(&kind.as_str()) {
            z.items.insert(id, Item { library, key: key.clone(), kind: kind.clone(), added: when.clone(), ..Default::default() });
        }
        added.insert(id, when);
        meta.insert(id, (library, key, kind));
    }
    let mut stmt = c.prepare(
        "SELECT d.itemID, f.fieldName, v.value FROM itemData d JOIN fieldsCombined f USING(fieldID) JOIN itemDataValues v USING(valueID)",
    )?;
    for row in stmt.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?, value(r.get(2)?))))? {
        let (id, field, v) = row?;
        if let Some(item) = z.items.get_mut(&id) {
            item.fields.insert(field, v);
        }
    }
    let mut stmt = c.prepare(
        "SELECT ic.itemID, ct.creatorType, c.lastName, c.firstName, c.fieldMode FROM itemCreators ic \
         JOIN creators c USING(creatorID) JOIN creatorTypes ct USING(creatorTypeID) ORDER BY ic.itemID, ic.orderIndex",
    )?;
    for row in stmt.query_map([], |r| {
        Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?, r.get::<_, Option<String>>(2)?, r.get::<_, Option<String>>(3)?, r.get::<_, Option<i64>>(4)?))
    })? {
        let (id, role, last, first, mode) = row?;
        if let Some(item) = z.items.get_mut(&id) {
            item.creators.push((role, last.unwrap_or_default(), first.unwrap_or_default(), mode == Some(1)));
        }
    }
    // Tags people gave; automatic ones from databases are left behind.
    let mut stmt = c.prepare("SELECT it.itemID, t.name FROM itemTags it JOIN tags t USING(tagID) WHERE it.type=0 ORDER BY t.name")?;
    for row in stmt.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))? {
        let (id, tag) = row?;
        if let Some(item) = z.items.get_mut(&id) {
            item.tags.push(tag);
        }
    }
    let mut stmt = c.prepare("SELECT itemID, parentItemID, linkMode, contentType, path FROM itemAttachments")?;
    for row in stmt.query_map([], |r| {
        Ok((r.get::<_, i64>(0)?, r.get::<_, Option<i64>>(1)?, r.get::<_, Option<i64>>(2)?, r.get::<_, Option<String>>(3)?, r.get::<_, Option<String>>(4)?))
    })? {
        let (id, parent, link, content_type, path) = row?;
        let Some((library, key, kind)) = meta.get(&id) else { continue };
        if kind != "attachment" || parent.is_some_and(|p| !z.items.contains_key(&p)) {
            continue;
        }
        z.files.push(File {
            id,
            key: key.clone(),
            added: added.get(&id).cloned().unwrap_or_default(),
            library: *library,
            parent,
            link: link.unwrap_or(-1),
            content_type: content_type.unwrap_or_default(),
            path: path.unwrap_or_default(),
        });
    }
    let mut stmt = c.prepare("SELECT itemID, parentItemID, note FROM itemNotes")?;
    for row in stmt.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, Option<i64>>(1)?, r.get::<_, Option<String>>(2)?)))? {
        let (id, parent, html) = row?;
        let Some((library, key, kind)) = meta.get(&id) else { continue };
        if kind != "note" {
            continue;
        }
        match parent.filter(|p| z.items.contains_key(p)) {
            Some(parent) => z.notes.push((key.clone(), *library, parent, html.unwrap_or_default())),
            None => z.loose_notes += 1,
        }
    }
    if has("itemAnnotations")? {
        let mut stmt = c.prepare(
            "SELECT itemID, parentItemID, type, text, comment, pageLabel FROM itemAnnotations ORDER BY parentItemID, sortIndex",
        )?;
        for row in stmt.query_map([], |r| {
            Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, r.get::<_, i64>(2)?, r.get::<_, Option<String>>(3)?, r.get::<_, Option<String>>(4)?, r.get::<_, Option<String>>(5)?))
        })? {
            let (id, parent, kind, text, comment, page) = row?;
            if meta.contains_key(&id) {
                z.marks.entry(parent).or_default().push(Mark {
                    kind,
                    text: text.unwrap_or_default(),
                    comment: comment.unwrap_or_default(),
                    page: page.unwrap_or_default(),
                });
            }
        }
    }
    let deleted = if has("deletedCollections")? { "WHERE collectionID NOT IN (SELECT collectionID FROM deletedCollections)" } else { "" };
    let mut stmt = c.prepare(&format!("SELECT collectionID, collectionName, parentCollectionID, libraryID FROM collections {deleted}"))?;
    for row in stmt.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?, r.get::<_, Option<i64>>(2)?, r.get::<_, i64>(3)?)))? {
        let (id, name, parent, library) = row?;
        z.collections.insert(id, (name, parent, library));
    }
    let mut stmt = c.prepare("SELECT collectionID, itemID FROM collectionItems")?;
    for row in stmt.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?)))? {
        let (collection, item) = row?;
        if z.collections.contains_key(&collection) {
            z.memberships.entry(item).or_default().push(collection);
        }
    }
    // Better BibTeX keeps its keys in a database of its own.
    let bbt = dir.join("better-bibtex.sqlite");
    if bbt.is_file()
        && let Ok(b) = Connection::open_with_flags(
            format!("file:{}?immutable=1", bbt.display()),
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
        )
        && let Ok(mut stmt) = b.prepare("SELECT libraryID, itemKey, citationKey FROM citationkey")
        && let Ok(rows) = stmt.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?)))
    {
        for (library, key, citekey) in rows.flatten() {
            z.keys.insert((library, key), citekey);
        }
    }
    Ok(z)
}

/// Zotero's "2026-07-16 08:49:57" (UTC) as Omabib writes times, or "" if it
/// isn't one.
fn timestamp(v: &str) -> String {
    let v = v.trim();
    let ok = v.len() == 19
        && v.bytes().enumerate().all(|(i, b)| match i {
            4 | 7 => b == b'-',
            10 => b == b' ' || b == b'T',
            13 | 16 => b == b':',
            _ => b.is_ascii_digit(),
        });
    if ok { format!("{}T{}.000Z", &v[..10], &v[11..]) } else { String::new() }
}

/// A citation key as BibTeX accepts it.
fn clean_key(key: &str) -> String {
    key.trim()
        .chars()
        .map(|c| if c.is_alphanumeric() || "_-:./+".contains(c) { c } else { '_' })
        .collect()
}

/// Year and month from a Zotero date, stored as "2021-03-00 March 2021".
fn date(v: &str) -> (String, String) {
    let sql = v.split_whitespace().next().unwrap_or("");
    let mut parts = sql.split('-');
    let year = parts.next().filter(|y| y.len() == 4 && y.bytes().all(|b| b.is_ascii_digit()) && *y != "0000");
    let month = parts.next().and_then(|m| m.parse::<u32>().ok()).filter(|m| (1..=12).contains(m));
    match year {
        Some(y) => (y.to_string(), month.map(|m| m.to_string()).unwrap_or_default()),
        None => (
            v.split(|c: char| !c.is_ascii_digit())
                .find(|w| w.len() == 4)
                .unwrap_or("")
                .to_string(),
            String::new(),
        ),
    }
}

/// An item as a BibTeX entry type and fields, and the citation key it had in
/// Zotero, if any.
fn entry(z: &Zotero, item: &Item) -> (String, BTreeMap<String, String>, Option<String>) {
    let get = |k: &str| item.fields.get(k).map(|v| v.trim()).filter(|v| !v.is_empty());
    let mut f: BTreeMap<String, String> = BTreeMap::new();
    let put = |f: &mut BTreeMap<String, String>, k: &str, v: Option<&str>| {
        if let Some(v) = v.map(str::trim).filter(|v| !v.is_empty()) {
            f.entry(k.to_string()).or_insert_with(|| v.to_string());
        }
    };
    let kind = match item.kind.as_str() {
        "journalArticle" | "magazineArticle" | "newspaperArticle" => "article",
        "book" => "book",
        "bookSection" | "encyclopediaArticle" | "dictionaryEntry" => "incollection",
        "conferencePaper" => "inproceedings",
        "thesis" if get("thesisType").is_some_and(|t| t.to_lowercase().contains("master")) => "mastersthesis",
        "thesis" => "phdthesis",
        "report" => "techreport",
        "manuscript" => "unpublished",
        _ => "misc",
    };
    for (zotero, bibtex) in [
        ("title", "title"),
        ("abstractNote", "abstract"),
        ("DOI", "doi"),
        ("url", "url"),
        ("volume", "volume"),
        ("issue", "number"),
        ("number", "number"),
        ("reportNumber", "number"),
        ("pages", "pages"),
        ("publisher", "publisher"),
        ("place", "address"),
        ("ISBN", "isbn"),
        ("ISSN", "issn"),
        ("language", "language"),
        ("series", "series"),
        ("edition", "edition"),
        ("numPages", "pagetotal"),
        ("shortTitle", "shorttitle"),
        ("PMID", "pmid"),
        ("PMCID", "pmcid"),
        ("university", "school"),
        ("institution", "institution"),
        ("thesisType", "type"),
        ("reportType", "type"),
        ("conferenceName", "eventtitle"),
    ] {
        put(&mut f, bibtex, get(zotero));
    }
    match kind {
        "article" => put(&mut f, "journal", get("publicationTitle")),
        "incollection" | "inproceedings" => {
            for k in ["bookTitle", "proceedingsTitle", "encyclopediaTitle", "dictionaryTitle", "publicationTitle"] {
                put(&mut f, "booktitle", get(k));
            }
        }
        _ => {
            for k in ["websiteTitle", "blogTitle", "forumTitle", "publicationTitle"] {
                put(&mut f, "howpublished", get(k));
            }
        }
    }
    if let Some(id) = get("archiveID").and_then(|a| a.strip_prefix("arXiv:")) {
        put(&mut f, "eprint", Some(id));
        put(&mut f, "archiveprefix", Some("arXiv"));
    } else if item.kind == "preprint" {
        put(&mut f, "howpublished", get("repository"));
    }
    if let Some(d) = get("date") {
        let (year, month) = date(d);
        put(&mut f, "year", Some(&year));
        put(&mut f, "month", Some(&month));
    }
    put(&mut f, "urldate", get("accessDate").map(|d| d.get(..10).unwrap_or(d)));
    let mut key = get("citationKey").map(str::to_string);
    let mut rest = Vec::new();
    for line in get("extra").unwrap_or("").lines() {
        let Some((k, v)) = line.split_once(':') else {
            rest.push(line);
            continue;
        };
        let (k, v) = (k.trim().to_lowercase(), v.trim());
        match k.as_str() {
            "citation key" => {
                key.get_or_insert_with(|| v.to_string());
            }
            "arxiv" => {
                put(&mut f, "eprint", Some(v));
                put(&mut f, "archiveprefix", Some("arXiv"));
            }
            "pmid" | "pmcid" | "doi" => put(&mut f, &k, Some(v)),
            _ if k.starts_with("tex.") => put(&mut f, &k[4..], Some(v)),
            _ => rest.push(line),
        }
    }
    put(&mut f, "annotation", Some(&rest.join("\n")));
    let names = |roles: &[&str]| {
        item.creators
            .iter()
            .filter(|(role, ..)| roles.contains(&role.as_str()))
            .map(|(_, last, first, single)| {
                if *single || first.trim().is_empty() {
                    format!("{{{}}}", last.trim())
                } else {
                    format!("{}, {}", last.trim(), first.trim())
                }
            })
            .collect::<Vec<_>>()
            .join(" and ")
    };
    put(&mut f, "author", Some(&names(&["author", "inventor", "programmer", "artist", "presenter", "director"])));
    put(&mut f, "editor", Some(&names(&["editor"])));
    put(&mut f, "bookauthor", Some(&names(&["bookAuthor"])));
    put(&mut f, "keywords", Some(&item.tags.join(", ")));
    let key = key
        .or_else(|| z.keys.get(&(item.library, item.key.clone())).cloned())
        .map(|k| clean_key(&k))
        .filter(|k| !k.is_empty());
    (kind.to_string(), f, key)
}

fn bibtex(kind: &str, key: &str, fields: &BTreeMap<String, String>) -> Result<String> {
    let mut b = parse_bibtex(&format!("@{kind}{{{key}, title={{Temporary}}}}"))?;
    let e = b.iter_mut().next().context("Empty BibTeX entry")?;
    for (k, v) in fields {
        // Names are braced to stay whole: `{Google Brain}`.
        if ["author", "editor", "bookauthor"].contains(&k.as_str()) {
            e.set(k, crate::db::source_chunks(v));
        } else {
            e.set(k, vec![biblatex::Spanned::detached(biblatex::Chunk::Normal(v.clone()))]);
        }
    }
    Ok(serialize_entry(e))
}

fn decode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(at) = rest.find('&') {
        out.push_str(&rest[..at]);
        rest = &rest[at..];
        let end = rest.find(';').filter(|e| *e <= 10);
        let entity = end.map(|e| &rest[1..e]);
        let ch = entity.and_then(|e| match e {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            "nbsp" => Some(' '),
            _ => e
                .strip_prefix("#x")
                .or_else(|| e.strip_prefix("#X"))
                .and_then(|h| u32::from_str_radix(h, 16).ok())
                .or_else(|| e.strip_prefix('#').and_then(|d| d.parse().ok()))
                .and_then(char::from_u32),
        });
        match (ch, end) {
            (Some(c), Some(e)) => {
                out.push(c);
                rest = &rest[e + 1..];
            }
            _ => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

fn attribute(tag: &str, name: &str) -> String {
    tag.split_once(&format!("{name}=\""))
        .and_then(|(_, rest)| rest.split_once('"'))
        .map(|(v, _)| decode(v))
        .unwrap_or_default()
}

/// A Zotero note's HTML as the Markdown Omabib's notes are written in.
pub(crate) fn markdown(html: &str) -> String {
    let mut out = String::new();
    let mut links: Vec<Option<String>> = Vec::new();
    let mut lists: Vec<(bool, usize)> = Vec::new();
    let mut pre = false;
    let block = |out: &mut String| {
        while out.ends_with(' ') {
            out.pop();
        }
        if !out.is_empty() && !out.ends_with("\n\n") {
            out.push_str(if out.ends_with('\n') { "\n" } else { "\n\n" });
        }
    };
    let mut rest = html;
    while !rest.is_empty() {
        if let Some(inner) = rest.strip_prefix('<') {
            let end = inner.find('>').unwrap_or(inner.len());
            let tag = &inner[..end];
            rest = inner.get(end + 1..).unwrap_or("");
            let closing = tag.starts_with('/');
            let name = tag
                .trim_start_matches('/')
                .chars()
                .take_while(char::is_ascii_alphanumeric)
                .collect::<String>()
                .to_ascii_lowercase();
            match (name.as_str(), closing) {
                // A quote's first paragraph stays on its "> " line.
                ("p" | "div", _) if out.ends_with("> ") => {}
                ("p" | "div", _) => block(&mut out),
                ("br", _) => out.push('\n'),
                ("h1" | "h2" | "h3" | "h4" | "h5" | "h6", false) => {
                    block(&mut out);
                    out.push_str(&"#".repeat(name[1..].parse().unwrap_or(1)));
                    out.push(' ');
                }
                ("h1" | "h2" | "h3" | "h4" | "h5" | "h6", true) => block(&mut out),
                ("strong" | "b", _) => out.push_str("**"),
                ("em" | "i", _) => out.push('*'),
                ("code", _) if !pre => out.push('`'),
                ("pre", false) => {
                    block(&mut out);
                    out.push_str("```\n");
                    pre = true;
                }
                ("pre", true) => {
                    out.push_str("\n```");
                    block(&mut out);
                    pre = false;
                }
                ("blockquote", false) => {
                    block(&mut out);
                    out.push_str("> ");
                }
                ("blockquote", true) => block(&mut out),
                ("ul", false) => lists.push((false, 0)),
                ("ol", false) => lists.push((true, 0)),
                ("ul" | "ol", true) => {
                    lists.pop();
                    block(&mut out);
                }
                ("li", false) => {
                    if !out.is_empty() && !out.ends_with('\n') {
                        out.push('\n');
                    }
                    out.push_str(&"  ".repeat(lists.len().saturating_sub(1)));
                    match lists.last_mut() {
                        Some((true, n)) => {
                            *n += 1;
                            out.push_str(&format!("{n}. "));
                        }
                        _ => out.push_str("- "),
                    }
                }
                ("a", false) => {
                    let href = attribute(tag, "href");
                    if href.is_empty() {
                        links.push(None);
                    } else {
                        out.push('[');
                        links.push(Some(href));
                    }
                }
                ("a", true) => {
                    if let Some(Some(href)) = links.pop() {
                        out.push_str(&format!("]({href})"));
                    }
                }
                ("hr", _) => {
                    block(&mut out);
                    out.push_str("---");
                    block(&mut out);
                }
                ("tr", true) => out.push('\n'),
                ("td" | "th", true) => out.push_str(" | "),
                _ => {}
            }
        } else {
            let end = rest.find('<').unwrap_or(rest.len());
            let raw = decode(&rest[..end]);
            rest = &rest[end..];
            if pre {
                out.push_str(&raw);
            } else {
                let mut words = raw.split_whitespace().peekable();
                if raw.starts_with(char::is_whitespace) && !out.is_empty() && !out.ends_with([' ', '\n']) && words.peek().is_some() {
                    out.push(' ');
                }
                out.push_str(&words.collect::<Vec<_>>().join(" "));
                if raw.ends_with(char::is_whitespace) && !raw.trim().is_empty() {
                    out.push(' ');
                }
            }
        }
    }
    let mut tidy = String::new();
    for line in out.lines() {
        let line = line.trim_end();
        if line.is_empty() && (tidy.is_empty() || tidy.ends_with("\n\n")) {
            continue;
        }
        tidy.push_str(line);
        tidy.push('\n');
    }
    tidy.trim().to_string()
}

/// A note too long for one Omabib note, cut at paragraphs into parts.
fn parts(text: &str) -> Vec<String> {
    if text.len() <= NOTE_LIMIT {
        return vec![text.to_string()];
    }
    let mut out = vec![String::new()];
    for para in text.split("\n\n") {
        let mut para = para;
        while !para.is_empty() {
            let last = out.last_mut().unwrap();
            let room = NOTE_LIMIT.saturating_sub(last.len() + 2);
            if para.len() <= room {
                if !last.is_empty() {
                    last.push_str("\n\n");
                }
                last.push_str(para);
                para = "";
            } else if last.is_empty() {
                let mut cut = room.min(para.len());
                while !para.is_char_boundary(cut) {
                    cut -= 1;
                }
                last.push_str(&para[..cut]);
                para = &para[cut..];
                out.push(String::new());
            } else {
                out.push(String::new());
            }
        }
    }
    out.retain(|p| !p.is_empty());
    out
}

/// A PDF's annotations as one note: highlighted passages quoted with their
/// pages, and the comments on them.
fn annotations(file_name: &str, marks: &[Mark]) -> String {
    let mut out = format!("## Zotero annotations\n\n*{file_name}*");
    for m in marks {
        let page = if m.page.is_empty() { String::new() } else { format!(" (p. {})", m.page) };
        let comment = m.comment.trim();
        let body = match m.kind {
            // Highlights and underlines.
            1 | 5 if !m.text.trim().is_empty() => {
                let quote = m.text.trim().lines().map(|l| format!("> {}", l.trim())).collect::<Vec<_>>().join("\n");
                let mut s = format!("{quote}{page}");
                if !comment.is_empty() {
                    s.push_str(&format!("\n\n{comment}"));
                }
                s
            }
            // Sticky notes and text boxes.
            2 | 6 if !comment.is_empty() || !m.text.trim().is_empty() => {
                let said = if comment.is_empty() { m.text.trim() } else { comment };
                format!("Note{page}: {said}")
            }
            3 | 4 => {
                let mut s = format!("*Image annotation{page}*");
                if !comment.is_empty() {
                    s.push_str(&format!(": {comment}"));
                }
                s
            }
            _ => continue,
        };
        out.push_str("\n\n");
        out.push_str(&body);
    }
    out
}

#[derive(Default, Clone)]
struct Tally {
    references: usize,
    pdfs: usize,
    pdfs_missing: usize,
    pdf_bytes: u64,
    notes: usize,
    annotations: usize,
    citation_keys: usize,
}

/// One reference to import with everything that belongs to it.
struct Paper {
    /// The key that remembers which reference this Zotero item became.
    zotero: String,
    bibtex: String,
    citekey: String,
    added: String,
    /// (the key that remembers where this PDF went, Zotero's file)
    pdfs: Vec<(String, PathBuf)>,
    /// (key that keeps it from being added twice, Markdown)
    notes: Vec<(String, String)>,
    projects: BTreeSet<String>,
}

struct Plan {
    papers: Vec<Paper>,
    tallies: BTreeMap<i64, Tally>,
    projects: BTreeSet<String>,
    other_files: usize,
    standalone: usize,
}

struct Options {
    groups: bool,
    notes: bool,
    projects: bool,
}

impl Options {
    fn from(a: &Value) -> Self {
        let on = |k: &str| a.get(k) != Some(&json!(false));
        Options { groups: on("groups"), notes: on("notes"), projects: on("projects") }
    }
}

fn file_path(z: &Zotero, f: &File) -> Option<PathBuf> {
    match f.link {
        0 | 1 => Some(z.dir.join("storage").join(&f.key).join(f.path.strip_prefix("storage:")?)),
        2 => match f.path.strip_prefix("attachments:") {
            Some(relative) => Some(z.base.as_ref()?.join(relative)),
            None => Some(PathBuf::from(&f.path)),
        },
        _ => None,
    }
}

/// A collection as a project name: its parents' names before it, and the
/// group's for a group library.
fn project_name(z: &Zotero, collection: i64) -> String {
    let mut names = Vec::new();
    let mut at = Some(collection);
    let mut library = 0;
    while let Some(id) = at.filter(|_| names.len() < 20) {
        let Some((name, parent, lib)) = z.collections.get(&id) else { break };
        names.push(name.trim().to_string());
        at = *parent;
        library = *lib;
    }
    if let Some(group) = z.groups.get(&library) {
        names.push(group.clone());
    }
    names.reverse();
    names.join(" / ")
}

fn plan(z: &Zotero, o: &Options) -> Result<Plan> {
    let mut plan = Plan { papers: Vec::new(), tallies: BTreeMap::new(), projects: BTreeSet::new(), other_files: 0, standalone: 0 };
    let included = |library: i64| o.groups || !z.groups.contains_key(&library);
    let mut files_of: HashMap<i64, Vec<&File>> = HashMap::new();
    let mut loose: Vec<&File> = Vec::new();
    for f in &z.files {
        if !included(f.library) {
            continue;
        }
        let pdf = f.content_type == "application/pdf" && (0..=2).contains(&f.link);
        match (f.parent, pdf) {
            (Some(p), true) => files_of.entry(p).or_default().push(f),
            (None, true) => loose.push(f),
            (_, false) if (0..=2).contains(&f.link) && f.content_type != "text/html" => plan.other_files += 1,
            _ => {}
        }
    }
    let mut notes_of: HashMap<i64, Vec<&(String, i64, i64, String)>> = HashMap::new();
    for n in &z.notes {
        notes_of.entry(n.2).or_default().push(n);
    }
    let add = |plan: &mut Plan, item_id: i64, library: i64, zkey: &str, added: &str, kind: &str, fields: BTreeMap<String, String>, key: Option<String>, files: Vec<&File>| -> Result<()> {
        let tally = plan.tallies.entry(library).or_default();
        tally.references += 1;
        if key.is_some() {
            tally.citation_keys += 1;
        }
        let citekey = key.unwrap_or_else(|| crate::ingest::citation_key(&json!(fields)));
        let mut paper = Paper {
            zotero: format!("zotero-item:{library}:{zkey}"),
            bibtex: bibtex(kind, &citekey, &fields)?,
            citekey,
            added: added.to_string(),
            pdfs: Vec::new(),
            notes: Vec::new(),
            projects: BTreeSet::new(),
        };
        for f in &files {
            match file_path(z, f).filter(|p| p.is_file()) {
                Some(path) => {
                    tally.pdfs += 1;
                    tally.pdf_bytes += std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
                    paper.pdfs.push((format!("zotero-file:{}:{}", f.library, f.key), path));
                }
                None => tally.pdfs_missing += 1,
            }
        }
        if o.notes {
            for (key, lib, _, html) in notes_of.get(&item_id).into_iter().flatten() {
                for (i, part) in parts(&markdown(html)).into_iter().enumerate().filter(|(_, p)| !p.is_empty()) {
                    paper.notes.push((format!("zotero-note:{lib}:{key}:{i}"), part));
                    tally.notes += 1;
                }
            }
            for f in &files {
                let Some(marks) = z.marks.get(&f.id).filter(|m| !m.is_empty()) else { continue };
                tally.annotations += marks.len();
                let name = f.path.strip_prefix("storage:").unwrap_or(&f.path);
                let name = Path::new(name).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                for (i, part) in parts(&annotations(&name, marks)).into_iter().enumerate() {
                    paper.notes.push((format!("zotero-annotations:{}:{}:{i}", f.library, f.key), part));
                }
            }
        }
        if o.projects {
            let mut collections: Vec<i64> = z.memberships.get(&item_id).cloned().unwrap_or_default();
            for f in &files {
                if f.parent.is_none() {
                    collections.extend(z.memberships.get(&f.id).into_iter().flatten());
                }
            }
            for c in collections {
                paper.projects.insert(project_name(z, c));
            }
            // A group library's papers stay together even outside its collections.
            if let Some(group) = z.groups.get(&library)
                && paper.projects.is_empty()
            {
                paper.projects.insert(group.clone());
            }
            plan.projects.extend(paper.projects.iter().cloned());
        }
        plan.papers.push(paper);
        Ok(())
    };
    for (id, item) in &z.items {
        if !included(item.library) {
            continue;
        }
        let (kind, fields, key) = entry(z, item);
        if !fields.contains_key("title") {
            continue;
        }
        let files = files_of.remove(id).unwrap_or_default();
        add(&mut plan, *id, item.library, &item.key, &item.added, &kind, fields, key, files)?;
    }
    // A PDF without a parent item becomes a reference titled after it, to fill in later.
    for f in loose {
        let name = f.path.strip_prefix("storage:").unwrap_or(&f.path);
        let stem = Path::new(name).file_stem().map(|s| s.to_string_lossy().replace(['_', '+'], " ")).unwrap_or_default();
        let fields = BTreeMap::from([("title".to_string(), stem.trim().to_string())]);
        if stem.trim().is_empty() {
            continue;
        }
        plan.standalone += 1;
        add(&mut plan, f.id, f.library, &f.key, &f.added, "misc", fields, None, vec![f])?;
    }
    Ok(plan)
}

fn library_name(z: &Zotero, library: i64) -> String {
    z.groups.get(&library).cloned().unwrap_or_else(|| "My Library".into())
}

/// What a Zotero library would bring: per library, its references, PDFs
/// (and those not on this computer), notes and annotations, and the
/// collections that would become projects. Reads a copy; changes nothing.
pub fn detect(_lib: &Library, a: &Value) -> Result<Value> {
    let dir = match data_dir(a) {
        Ok(dir) => dir,
        Err(e) if a.get("path").is_none() => {
            return Ok(json!({"found":false,"message":format!("{e:#}")}));
        }
        Err(e) => return Err(e),
    };
    let z = read(&dir)?;
    let all = plan(&z, &Options { groups: true, notes: true, projects: true })?;
    let libraries: Vec<Value> = all
        .tallies
        .iter()
        .map(|(id, t)| {
            json!({"name":library_name(&z, *id),"group":z.groups.contains_key(id),"references":t.references,"pdfs":t.pdfs,"pdfs_missing":t.pdfs_missing,"pdf_bytes":t.pdf_bytes,"notes":t.notes,"annotations":t.annotations,"citation_keys":t.citation_keys})
        })
        .collect();
    let own: BTreeSet<&String> = all.projects.iter().filter(|p| !z.groups.values().any(|g| p.starts_with(g.as_str()))).collect();
    Ok(json!({
        "found": true,
        "path": dir,
        "running": running(&dir),
        "libraries": libraries,
        "projects": all.projects.len(),
        "projects_own": own.len(),
        "standalone": all.standalone,
        "other_files": all.other_files,
        "loose_notes": z.loose_notes,
    }))
}

static IMPORTING: Mutex<()> = Mutex::new(());

fn progress(lib: &Library, what: &str, done: usize, total: usize) {
    lib.chats.publish(
        &json!({"v":1,"event":"zotero","progress":{"what":what,"done":done,"total":total}}).to_string(),
    );
}

/// What earlier imports did, kept in `requests` under Zotero's keys: the
/// reference each item became, and where each PDF went.
fn remembered(lib: &Library, prefix: &str) -> Result<HashMap<String, Value>> {
    let c = crate::db::read_connection(&lib.path)?;
    let mut stmt = c.prepare("SELECT key,result FROM requests WHERE substr(key,1,length(?1))=?1")?;
    let rows = stmt.query_map([prefix], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
    Ok(rows
        .flatten()
        .filter_map(|(k, v)| Some((k, serde_json::from_str(&v).ok()?)))
        .collect())
}

fn remember(c: &Connection, key: &str, result: &Value) -> Result<()> {
    c.execute(
        "INSERT OR REPLACE INTO requests VALUES(?,?,?)",
        params![key, "{}", result.to_string()],
    )?;
    Ok(())
}

/// Import a Zotero library (`path`, or the one found). `pdfs`: "copy" (the
/// default) into Omabib's storage, or "link" to Zotero's files where they
/// are; `groups`, `notes` and `projects` (default true) choose what comes
/// along. Files are copied before anything is written; the references, their
/// PDFs, notes and projects are then saved in one transaction. A Zotero item
/// brought over before is not imported again, and one whose reference was
/// deleted in Omabib since stays deleted.
pub fn import(lib: &Library, a: &Value) -> Result<Value> {
    let _running = IMPORTING
        .try_lock()
        .ok()
        .context("A Zotero import is already running")?;
    let dir = data_dir(a)?;
    let o = Options::from(a);
    progress(lib, "Reading your Zotero library", 0, 0);
    let z = read(&dir)?;
    let plan = plan(&z, &o)?;
    ensure!(!plan.papers.is_empty(), "This Zotero library has no references to import");
    let copy = text(a, "pdfs") != "link";
    let known_items = remembered(lib, "zotero-item:")?;
    let known_files = remembered(lib, "zotero-file:")?;
    let gone = {
        let c = crate::db::read_connection(&lib.path)?;
        let mut gone = HashSet::new();
        for (key, v) in &known_items {
            let exists = c
                .query_row("SELECT 1 FROM refs WHERE id=?", [text(v, "id")], |_| Ok(()))
                .optional()?
                .is_some();
            if !exists {
                gone.insert(key.clone());
            }
        }
        gone
    };
    let total: usize = plan.papers.iter().filter(|p| !gone.contains(&p.zotero)).map(|p| p.pdfs.len()).sum();
    let mut warnings = Vec::new();
    let mut failed = 0;
    let mut files: Vec<Vec<(String, PathBuf, String)>> = Vec::with_capacity(plan.papers.len());
    let mut done = 0;
    for p in &plan.papers {
        let mut here = Vec::new();
        for (key, path) in p.pdfs.iter().filter(|_| !gone.contains(&p.zotero)) {
            done += 1;
            if done % 5 == 0 || done == total {
                progress(lib, if copy { "Copying PDFs" } else { "Checking PDFs" }, done, total);
            }
            // Copied or checked by an earlier import: nothing to do again.
            if let Some(v) = known_files.get(key)
                && let Some(stored) = v["path"].as_str().map(PathBuf::from).filter(|p| p.is_file())
            {
                here.push((key.clone(), stored, text(v, "hash").to_string()));
                continue;
            }
            let found = if copy {
                crate::attachments::store_copy(lib, path, &p.citekey)
            } else {
                path.canonicalize()
                    .map_err(anyhow::Error::from)
                    .and_then(|path| Ok((path.clone(), crate::attachments::inspect(&path)?)))
            };
            match found {
                Ok((stored, hash)) => here.push((key.clone(), stored, hash)),
                Err(e) => {
                    failed += 1;
                    warnings.push(format!("{}: {e:#}", path.display()));
                }
            }
        }
        files.push(here);
    }

    let source = format!("Zotero library {}", dir.display());
    let mut c = lib.writer.lock().unwrap();
    let tx = c.transaction()?;
    let mut projects: HashMap<String, String> = HashMap::new();
    let (mut added, mut merged, mut already, mut deleted) = (0, 0, 0, 0);
    let (mut attached, mut notes, mut created, mut linked) = (0, 0, 0, 0);
    for (i, (p, here)) in plan.papers.iter().zip(&files).enumerate() {
        if i % 50 == 0 {
            progress(lib, "Saving references", i, plan.papers.len());
        }
        let known = known_items.get(&p.zotero).map(|v| text(v, "id").to_string());
        let rid = match known {
            Some(_) if gone.contains(&p.zotero) => {
                deleted += 1;
                continue;
            }
            Some(rid) => {
                already += 1;
                rid
            }
            None => {
                let out = crate::db::import(&tx, &json!({"bibtex":p.bibtex,"source":source}))
                    .with_context(|| format!("Could not import {}", p.citekey))?;
                let item = &out["items"][0];
                let rid = text(item, "id").to_string();
                if item["merged"] == true {
                    merged += 1;
                } else {
                    added += 1;
                    // Newest first in Omabib is newest first as it was in Zotero.
                    if !p.added.is_empty() {
                        tx.execute("UPDATE refs SET created_at=? WHERE id=?", params![p.added, rid])?;
                    }
                }
                remember(&tx, &p.zotero, &json!({"id":rid}))?;
                rid
            }
        };
        for (key, path, hash) in here {
            let have = tx
                .query_row(
                    "SELECT 1 FROM attachments WHERE ref_id=? AND path=?",
                    params![rid, path.to_string_lossy()],
                    |_| Ok(()),
                )
                .optional()?
                .is_some();
            if !have {
                crate::db::attach_within(&tx, &rid, path, "pdf", Some(hash))?;
                attached += 1;
            }
            remember(&tx, key, &json!({"path":path,"hash":hash}))?;
        }
        for name in &p.projects {
            let pid = match projects.get(name) {
                Some(id) => id.clone(),
                None => {
                    let found: Option<String> = tx
                        .query_row("SELECT id FROM projects WHERE name=?", [name], |r| r.get(0))
                        .optional()?;
                    let id = match found {
                        Some(id) => id,
                        None => {
                            let id = crate::db::id();
                            tx.execute("INSERT INTO projects(id,name) VALUES(?,?)", params![id, name])?;
                            created += 1;
                            id
                        }
                    };
                    projects.insert(name.clone(), id.clone());
                    id
                }
            };
            linked += tx.execute(
                "INSERT OR IGNORE INTO associations(ref_id,project_id) VALUES(?,?)",
                params![rid, pid],
            )?;
        }
        for (key, body) in &p.notes {
            let seen = tx
                .query_row("SELECT 1 FROM requests WHERE key=?", [key], |_| Ok(()))
                .optional()?
                .is_some();
            if seen {
                continue;
            }
            let n = crate::db::write_note(
                &tx,
                "add_note",
                &json!({"ref_id":rid,"project_id":null,"body":body,"provenance":"zotero"}),
            )?;
            remember(&tx, key, &json!({"id":n["id"]}))?;
            notes += 1;
        }
    }
    tx.commit()?;
    drop(c);
    lib.load_vocabulary()?;
    let missing: usize = plan.tallies.values().map(|t| t.pdfs_missing).sum();
    warnings.truncate(20);
    Ok(json!({
        "path": dir,
        "references": added,
        "merged": merged,
        "already": already,
        "deleted": deleted,
        "pdfs": attached,
        "pdfs_missing": missing + failed,
        "pdfs_copied": copy,
        "notes": notes,
        "projects": created,
        "project_links": linked,
        "standalone": plan.standalone,
        "other_files": plan.other_files,
        "loose_notes": z.loose_notes,
        "warnings": warnings,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn notes_become_markdown() {
        let html = r#"<div class="zotero-note znv1"><div data-schema-version="9"><h2>Core idea</h2>
<p>Treat each <strong>emotion</strong> as a <em>node</em>&nbsp;in a system &amp; learn it.</p>
<ul><li>first</li><li>second <a href="https://example.org/x?a=1&amp;b=2">link</a></li></ul>
<ol><li>one</li><li>two</li></ol><p><img data-attachment-key="25NXQTFP"></p>
<blockquote><p>quoted</p></blockquote><p>line<br/>break</p></div></div>"#;
        assert_eq!(
            markdown(html),
            "## Core idea\n\nTreat each **emotion** as a *node* in a system & learn it.\n\n- first\n- second [link](https://example.org/x?a=1&b=2)\n\n1. one\n2. two\n\n> quoted\n\nline\nbreak"
        );
        assert_eq!(decode("&#8220;x&#x201D; &bogus; & y"), "\u{201c}x\u{201d} &bogus; & y");
    }

    #[test]
    fn long_notes_split_at_paragraphs() {
        let para = "word ".repeat(2000);
        let text = [para.trim(); 10].join("\n\n");
        let split = parts(&text);
        assert!(split.len() > 1);
        assert!(split.iter().all(|p| p.len() <= NOTE_LIMIT));
        assert_eq!(split.join("\n\n"), text);
        let one = "x".repeat(NOTE_LIMIT * 2 + 5);
        assert_eq!(parts(&one).concat(), one);
    }

    #[test]
    fn dates_prefs_and_keys() {
        assert_eq!(date("2021-03-00 March 2021"), ("2021".into(), "3".into()));
        assert_eq!(date("2026-00-00 2026"), ("2026".into(), String::new()));
        assert_eq!(date("Spring 1998"), ("1998".into(), String::new()));
        let prefs = "user_pref(\"extensions.zotero.dataDir\", \"/home/me/Zotero\");\nuser_pref(\"other\", 1);";
        assert_eq!(pref(prefs, "extensions.zotero.dataDir").as_deref(), Some("/home/me/Zotero"));
        assert_eq!(pref(prefs, "extensions.zotero.baseAttachmentPath"), None);
        assert_eq!(clean_key("smith 2020{x}"), "smith_2020_x_");
        assert_eq!(timestamp("2026-07-16 08:49:57"), "2026-07-16T08:49:57.000Z");
        assert_eq!(timestamp("yesterday"), "");
    }

    #[test]
    fn annotations_quote_with_pages() {
        let marks = vec![
            Mark { kind: 1, text: "A finding.".into(), comment: "Check this".into(), page: "5".into() },
            Mark { kind: 2, text: String::new(), comment: "Sticky".into(), page: "6".into() },
            Mark { kind: 3, text: String::new(), comment: String::new(), page: "7".into() },
        ];
        assert_eq!(
            annotations("paper.pdf", &marks),
            "## Zotero annotations\n\n*paper.pdf*\n\n> A finding. (p. 5)\n\nCheck this\n\nNote (p. 6): Sticky\n\n*Image annotation (p. 7)*"
        );
    }
}
