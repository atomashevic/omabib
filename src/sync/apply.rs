//! Local edits become changes (`flush`); other computers' changes are merged
//! in (`apply`). Every field carries the clock of its last change and the later
//! clock wins, so computers applying the same changes in any order agree.
use super::clock::{Hlc, iso_ms, now_ms};
use super::records::{self, KINDS};
use anyhow::{Result, bail};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet, HashMap};

/// One record's change: new field values with their clocks, or a deletion.
#[derive(Clone, Debug, Default, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Change {
    pub kind: String,
    pub key: String,
    pub fields: Map<String, Value>,
    pub clocks: BTreeMap<String, String>,
    /// The clock each changed field had before this change, as its author saw it.
    pub prev: BTreeMap<String, String>,
    pub deleted: Option<String>,
    pub device: String,
}

impl Change {
    fn latest(&self) -> String {
        self.deleted
            .clone()
            .or_else(|| self.clocks.values().max().cloned())
            .unwrap_or_default()
    }
}

/// The last synced state of a record.
#[derive(Clone, Debug, Default)]
pub struct Base {
    pub data: Map<String, Value>,
    pub clocks: BTreeMap<String, String>,
    pub deleted: Option<String>,
}

pub fn load_base(c: &Connection, kind: &str, key: &str) -> Result<Option<Base>> {
    Ok(c.query_row(
        "SELECT data,clocks,deleted FROM sync_base WHERE kind=? AND key=?",
        [kind, key],
        |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, Option<String>>(2)?,
            ))
        },
    )
    .optional()?
    .map(|(data, clocks, deleted)| Base {
        data: serde_json::from_str(&data).unwrap_or_default(),
        clocks: serde_json::from_str(&clocks).unwrap_or_default(),
        deleted,
    }))
}

pub fn save_base(c: &Connection, kind: &str, key: &str, b: &Base) -> Result<()> {
    c.execute(
        "INSERT INTO sync_base(kind,key,data,clocks,deleted) VALUES(?,?,?,?,?) ON CONFLICT(kind,key) DO UPDATE SET data=excluded.data,clocks=excluded.clocks,deleted=excluded.deleted",
        params![
            kind,
            key,
            Value::Object(b.data.clone()).to_string(),
            serde_json::to_string(&b.clocks)?,
            b.deleted
        ],
    )?;
    Ok(())
}

fn tombstone(c: &Connection, kind: &str, key: &str, hlc: &str) -> Result<()> {
    let mut b = load_base(c, kind, key)?.unwrap_or_default();
    if b.deleted.is_none() {
        b.deleted = Some(hlc.to_string());
        save_base(c, kind, key, &b)?;
    }
    Ok(())
}

fn is_tombstoned(c: &Connection, kind: &str, key: &str) -> Result<bool> {
    Ok(c.query_row(
        "SELECT deleted IS NOT NULL FROM sync_base WHERE kind=? AND key=?",
        [kind, key],
        |r| r.get::<_, bool>(0),
    )
    .optional()?
    .unwrap_or(false))
}

fn alias(c: &Connection, kind: &str, key: &str) -> Result<String> {
    let mut key = key.to_string();
    for _ in 0..16 {
        match c
            .query_row(
                "SELECT target FROM sync_aliases WHERE kind=? AND key=?",
                [kind, &key],
                |r| r.get::<_, String>(0),
            )
            .optional()?
        {
            Some(target) if target != key => key = target,
            _ => break,
        }
    }
    Ok(key)
}

fn add_alias(c: &Connection, kind: &str, from: &str, to: &str) -> Result<()> {
    c.execute(
        "INSERT OR REPLACE INTO sync_aliases(kind,key,target) VALUES(?,?,?)",
        [kind, from, to],
    )?;
    Ok(())
}

fn device_of(hlc: &str) -> &str {
    hlc.splitn(3, '.').nth(2).unwrap_or("")
}

/// Names already given to PDFs in the storage, with their content hashes.
fn blob_names(c: &Connection) -> Result<HashMap<String, String>> {
    let mut stmt =
        c.prepare("SELECT data FROM sync_base WHERE kind='attachment' AND deleted IS NULL")?;
    let mut names = HashMap::new();
    for data in stmt.query_map([], |r| r.get::<_, String>(0))? {
        let v: Value = serde_json::from_str(&data?).unwrap_or_default();
        if let (Some(blob), Some(sha)) = (v["blob"].as_str(), v["sha256"].as_str()) {
            names.insert(blob.to_string(), sha.to_string());
        }
    }
    Ok(names)
}

/// A readable storage name for a PDF: the citekey, or the citekey and the start
/// of its hash when another file already has that name.
fn blob_name(
    c: &Connection,
    ref_id: &str,
    sha: &str,
    used: &HashMap<String, String>,
) -> Result<String> {
    if let Some((name, _)) = used.iter().find(|(_, s)| s.as_str() == sha) {
        return Ok(name.clone());
    }
    let citekey: String = c
        .query_row("SELECT citekey FROM refs WHERE id=?", [ref_id], |r| {
            r.get(0)
        })
        .optional()?
        .unwrap_or_else(|| ref_id.to_string());
    let safe: String = citekey
        .chars()
        .map(|ch| {
            if ch.is_alphanumeric() || "-_.".contains(ch) {
                ch
            } else {
                '_'
            }
        })
        .collect();
    let plain = format!("pdfs/{safe}.pdf");
    Ok(match used.get(&plain) {
        Some(other) if other != sha => format!("pdfs/{safe}-{}.pdf", &sha[..sha.len().min(8)]),
        _ => plain,
    })
}

fn queue_upload(c: &Connection, path: &str, kind: &str, key: &str) -> Result<()> {
    c.execute(
        "INSERT OR REPLACE INTO sync_uploads(path,kind,key) VALUES(?,?,?)",
        [path, kind, key],
    )?;
    Ok(())
}

/// Turns the outbox into changes, updating the base as if they were synced.
pub fn flush(c: &Connection, me: &str, clock: &mut Hlc) -> Result<Vec<Change>> {
    let mut stmt = c.prepare("SELECT id,kind,key,at FROM sync_outbox ORDER BY id")?;
    let rows = stmt
        .query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(3)?,
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    drop(stmt);
    let Some(last) = rows.last().map(|r| r.0) else {
        return Ok(vec![]);
    };
    let mut order: Vec<(String, String)> = Vec::new();
    let mut at: HashMap<(String, String), u64> = HashMap::new();
    for (_, kind, key, stamp) in rows {
        let ms = iso_ms(&stamp).unwrap_or_else(now_ms);
        let entry = (kind, key);
        if !at.contains_key(&entry) {
            order.push(entry.clone());
        }
        let slot = at.entry(entry).or_insert(ms);
        *slot = (*slot).max(ms);
    }
    let mut used = blob_names(c)?;
    let mut changes = Vec::new();
    let mut regroup: Vec<Claims> = Vec::new();
    // Parents first, so a batch creates records in an order that applies cleanly.
    order.sort_by_key(|(kind, _)| KINDS.iter().position(|k| k == kind).unwrap_or(99));
    for (kind, key) in order {
        let edited = at[&(kind.clone(), key.clone())];
        let current = records::read(c, &kind, &key)?;
        let base = load_base(c, &kind, &key)?;
        match (current, base) {
            (None, None) => {}
            (_, Some(b)) if b.deleted.is_some() => {}
            (None, Some(mut b)) => {
                if kind == "ref" {
                    regroup.push(claims(&b.data));
                }
                *clock = clock.tick(edited, me);
                let hlc = clock.to_string();
                b.deleted = Some(hlc.clone());
                save_base(c, &kind, &key, &b)?;
                changes.push(Change {
                    kind,
                    key,
                    deleted: Some(hlc),
                    device: me.into(),
                    ..Default::default()
                });
            }
            (Some(mut current), base) => {
                let mut b = base.unwrap_or_default();
                if kind == "ref" && !b.data.is_empty() {
                    // A shared citekey or DOI shown differently here is not an edit.
                    let (citekey, doi) = shown(c, &key, &b.data)?;
                    for (f, v) in [("citekey", citekey), ("doi", doi)] {
                        if current.get(f) == Some(&v)
                            && let Some(synced) = b.data.get(f)
                        {
                            current.insert(f.into(), synced.clone());
                        }
                    }
                    regroup.push(claims(&b.data));
                    regroup.push(claims(&current));
                }
                let mut changed = Map::new();
                for (f, v) in current {
                    if b.data.get(&f) != Some(&v) {
                        changed.insert(f, v);
                    }
                }
                if kind == "attachment" {
                    let sha = changed
                        .get("sha256")
                        .or_else(|| b.data.get("sha256"))
                        .and_then(Value::as_str)
                        .map(str::to_owned);
                    let pdf = changed
                        .get("file_type")
                        .or_else(|| b.data.get("file_type"))
                        .and_then(Value::as_str)
                        .is_some_and(|t| t.eq_ignore_ascii_case("pdf"));
                    if let Some(sha) = sha.filter(|_| pdf)
                        && (changed.contains_key("sha256") || !b.data.contains_key("blob"))
                    {
                        let ref_id = changed
                            .get("ref_id")
                            .or_else(|| b.data.get("ref_id"))
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_string();
                        let name = blob_name(c, &ref_id, &sha, &used)?;
                        if !used.contains_key(&name) {
                            queue_upload(c, &name, &kind, &key)?;
                        }
                        used.insert(name.clone(), sha);
                        changed.insert("blob".into(), json!(name));
                    }
                }
                if kind == "image"
                    && let Some(sha) = changed.get("sha256").and_then(Value::as_str)
                {
                    queue_upload(c, &format!("clips/{sha}.png"), &kind, &key)?;
                }
                if changed.is_empty() {
                    continue;
                }
                *clock = clock.tick(edited, me);
                let hlc = clock.to_string();
                let mut change = Change {
                    kind: kind.clone(),
                    key: key.clone(),
                    device: me.into(),
                    ..Default::default()
                };
                for (f, v) in changed {
                    if let Some(p) = b.clocks.get(&f) {
                        change.prev.insert(f.clone(), p.clone());
                    }
                    b.data.insert(f.clone(), v.clone());
                    b.clocks.insert(f.clone(), hlc.clone());
                    change.clocks.insert(f.clone(), hlc.clone());
                    change.fields.insert(f, v);
                }
                save_base(c, &kind, &key, &b)?;
                changes.push(change);
            }
        }
    }
    c.execute("DELETE FROM sync_outbox WHERE id<=?", [last])?;
    reconcile(c, &regroup)?;
    Ok(changes)
}

/// Marks every local record as synced at one clock: the start of a new shared library.
pub fn adopt_all(c: &Connection, me: &str, clock: &mut Hlc) -> Result<usize> {
    c.execute("DELETE FROM sync_outbox", [])?;
    let mut n = 0;
    for kind in KINDS {
        for key in records::keys(c, kind)? {
            c.execute(
                "INSERT INTO sync_outbox(kind,key,at) VALUES(?,?,strftime('%Y-%m-%dT%H:%M:%fZ','now'))",
                [kind, &key],
            )?;
            n += 1;
        }
    }
    flush(c, me, clock)?;
    Ok(n)
}

/// What an apply changed, for the window and the status line.
#[derive(Debug, Default)]
pub struct Outcome {
    pub applied: usize,
    pub refs: BTreeSet<String>,
    pub notes: BTreeSet<String>,
    pub chats: Vec<String>,
    pub conflicts: usize,
}

struct Applier<'a> {
    c: &'a Connection,
    me: &'a str,
    clips: &'a HashMap<String, Vec<u8>>,
    names: &'a HashMap<String, String>,
    out: Outcome,
}

/// Merges other computers' changes into the library. Runs inside the caller's
/// transaction with change recording switched off.
pub fn apply(
    c: &Connection,
    me: &str,
    clock: &mut Hlc,
    changes: Vec<Change>,
    clips: &HashMap<String, Vec<u8>>,
    names: &HashMap<String, String>,
) -> Result<Outcome> {
    let rank = |kind: &str| KINDS.iter().position(|k| *k == kind).unwrap_or(99);
    // Changes set aside earlier for a missing parent get another try.
    let mut changes = changes;
    let parked: Vec<String> = c
        .prepare("SELECT change FROM sync_parked ORDER BY id")?
        .query_map([], |r| r.get(0))?
        .collect::<rusqlite::Result<_>>()?;
    c.execute("DELETE FROM sync_parked", [])?;
    for p in parked {
        if let Ok(ch) = serde_json::from_str::<Change>(&p) {
            changes.push(ch);
        }
    }
    let (mut upserts, mut deletes): (Vec<Change>, Vec<Change>) =
        changes.into_iter().partition(|ch| ch.deleted.is_none());
    upserts.sort_by_key(|ch| (rank(&ch.kind), ch.latest()));
    // Parents first: a reference's deletion saves its newer notes along with it,
    // and its cascade tombstones the children, whose own deletions then do nothing.
    deletes.sort_by_key(|ch| (rank(&ch.kind), ch.latest()));
    let mut a = Applier {
        c,
        me,
        clips,
        names,
        out: Outcome::default(),
    };
    for ch in upserts.iter().chain(deletes.iter()) {
        if let Some(h) = Hlc::parse(&ch.latest()) {
            *clock = clock.observe(&h);
        }
        if ch.deleted.is_some() {
            a.delete(ch)?;
        } else {
            a.upsert(ch)?;
        }
        a.out.applied += 1;
    }
    Ok(a.out)
}

impl Applier<'_> {
    /// The change with merged-away IDs replaced by the ones they merged into.
    fn resolved(&self, ch: &Change) -> Result<(String, Map<String, Value>)> {
        let c = self.c;
        let key = if ch.kind == "assoc" {
            let (r, p) = records::split_assoc(&ch.key)?;
            format!("{}|{}", alias(c, "ref", r)?, alias(c, "project", p)?)
        } else if ch.kind == "summary" {
            alias(c, "ref", &ch.key)?
        } else {
            alias(c, &ch.kind, &ch.key)?
        };
        let mut fields = ch.fields.clone();
        for (field, kind) in [("ref_id", "ref"), ("project_id", "project")] {
            if let Some(id) = fields.get(field).and_then(Value::as_str) {
                let target = alias(c, kind, id)?;
                fields.insert(field.into(), json!(target));
            }
        }
        if ch.kind == "assoc" {
            let (r, p) = records::split_assoc(&key)?;
            fields.insert("ref_id".into(), json!(r));
            fields.insert("project_id".into(), json!(p));
        }
        Ok((key, fields))
    }

    fn touched(&mut self, kind: &str, key: &str, data: &Map<String, Value>) {
        match kind {
            "ref" | "summary" => {
                self.out.refs.insert(key.to_string());
            }
            "note" => {
                self.out.notes.insert(key.to_string());
                if let Some(r) = data.get("ref_id").and_then(Value::as_str) {
                    self.out.refs.insert(r.to_string());
                }
            }
            _ => {
                if let Some(r) = data.get("ref_id").and_then(Value::as_str) {
                    self.out.refs.insert(r.to_string());
                }
            }
        }
    }

    fn upsert(&mut self, ch: &Change) -> Result<()> {
        let c = self.c;
        let kind = ch.kind.as_str();
        let (key, fields) = self.resolved(ch)?;
        let mut b = load_base(c, kind, &key)?.unwrap_or_default();
        if b.deleted.is_some() {
            return Ok(());
        }
        // A child whose parent was deleted is deleted too; one whose parent never
        // arrived waits (it is re-sent with the next snapshot).
        let mut probe = b.data.clone();
        probe.extend(fields.clone());
        for (pk, pkey) in records::parent(kind, &key, &probe) {
            if is_tombstoned(c, &pk, &pkey)? {
                return tombstone(c, kind, &key, &ch.latest());
            }
            if !records::exists(c, &pk, &pkey)? {
                // Kept until its parent arrives in a later batch.
                c.execute(
                    "INSERT INTO sync_parked(change) VALUES(?)",
                    [serde_json::to_string(ch)?],
                )?;
                return Ok(());
            }
        }
        let mut accepted = Map::new();
        for (f, v) in fields {
            let Some(h) = ch.clocks.get(&f) else { continue };
            if b.clocks.get(&f).is_none_or(|mine| h > mine) {
                accepted.insert(f, v);
            }
        }
        let present = records::exists(c, kind, &key)?;
        if accepted.is_empty() && present {
            return Ok(());
        }
        if kind == "note"
            && accepted.contains_key("body")
            && let Some(mine) = b.clocks.get("body")
            && device_of(mine) == self.me
            && ch.prev.get("body") != Some(mine)
            && present
        {
            self.keep_conflicting_copy(&key, ch)?;
        }
        let before = claims(&b.data);
        for (f, v) in accepted {
            b.clocks.insert(f.clone(), ch.clocks[&f].clone());
            b.data.insert(f, v);
        }
        let key = if kind == "project" {
            self.settle_project(&key, &mut b)?
        } else {
            key
        };
        if kind == "project" {
            // Roots are paths on each computer: keep the union.
            let local: Vec<Value> = records::read(c, kind, &key)?
                .and_then(|r| r.get("roots").and_then(Value::as_array).cloned())
                .unwrap_or_default();
            if let Some(Value::Array(roots)) = b.data.get_mut("roots") {
                for r in local {
                    if !roots.contains(&r) {
                        roots.push(r);
                    }
                }
            }
        }
        if kind == "ref" {
            // The citekey and DOI are handed out by `reconcile`, since another
            // reference may claim the same ones.
            let mut data = b.data.clone();
            data.insert("citekey".into(), json!(format!("~{key}")));
            data.insert("doi".into(), Value::Null);
            records::write(c, kind, &key, &data, self.clips)?;
            save_base(c, kind, &key, &b)?;
            let touched = reconcile(c, &[before, claims(&b.data)])?;
            self.out.refs.extend(touched);
        } else {
            records::write(c, kind, &key, &b.data, self.clips)?;
        }
        if kind == "project" {
            // The union is local; keep flush from sending it back.
            if let Some(r) = records::read(c, kind, &key)? {
                b.data.insert("roots".into(), r["roots"].clone());
            }
        }
        if kind == "attachment" {
            self.restore_downloaded(&key, &b)?;
        }
        save_base(c, kind, &key, &b)?;
        let data = b.data.clone();
        self.touched(kind, &key, &data);
        Ok(())
    }

    /// Our edit to a note lost to one made elsewhere without seeing it: keep
    /// ours as a new note, which then syncs like any other.
    fn keep_conflicting_copy(&mut self, key: &str, ch: &Change) -> Result<()> {
        let c = self.c;
        let Some(mine) = records::read(c, "note", key)? else {
            return Ok(());
        };
        let copy = uuid::Uuid::new_v4().to_string();
        records::write(c, "note", &copy, &mine, self.clips)?;
        c.execute(
            "INSERT INTO sync_outbox(kind,key,at) VALUES('note',?,strftime('%Y-%m-%dT%H:%M:%fZ','now'))",
            [&copy],
        )?;
        let ref_id = mine.get("ref_id").and_then(Value::as_str).unwrap_or("");
        let title: String = c
            .query_row("SELECT title FROM refs WHERE id=?", [ref_id], |r| r.get(0))
            .optional()?
            .unwrap_or_default();
        let device = self
            .names
            .get(&ch.device)
            .cloned()
            .unwrap_or_else(|| "another computer".into());
        c.execute(
            "INSERT INTO sync_conflicts(id,kind,ref_id,summary,detail,created_at) VALUES(?,'note_copy',?,?,?,strftime('%Y-%m-%dT%H:%M:%fZ','now'))",
            params![
                uuid::Uuid::new_v4().to_string(),
                ref_id,
                format!("A note on “{title}” was also edited on {device}"),
                json!({"note_id": key, "copy_id": copy, "device": device}).to_string(),
            ],
        )?;
        self.out.conflicts += 1;
        self.out.notes.insert(copy);
        Ok(())
    }

    /// Two projects with the same name become one, under the lower ID. Projects
    /// are never deleted, so a merge can't be undone by a deletion elsewhere.
    fn settle_project(&mut self, key: &str, b: &mut Base) -> Result<String> {
        let c = self.c;
        let name = b
            .data
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let Some(other) = c
            .query_row(
                "SELECT id FROM projects WHERE name=? AND id<>?",
                [&name, key],
                |r| r.get::<_, String>(0),
            )
            .optional()?
        else {
            return Ok(key.to_string());
        };
        if let Some(theirs) = load_base(c, "project", &other)? {
            merge_fields(b, &theirs);
        }
        let (keep, gone) = if key < other.as_str() {
            (key.to_string(), other.clone())
        } else {
            (other.clone(), key.to_string())
        };
        if gone == other {
            // The local project merges into the incoming one.
            c.execute(
                "UPDATE projects SET name='~merging~' || id WHERE id=?",
                [&gone],
            )?;
            records::write(c, "project", &keep, &b.data, self.clips)?;
            let refs: Vec<String> = c
                .prepare("SELECT ref_id FROM associations WHERE project_id=?")?
                .query_map([&gone], |r| r.get(0))?
                .collect::<rusqlite::Result<_>>()?;
            for r in refs {
                let (from, to) = (format!("{r}|{gone}"), format!("{r}|{keep}"));
                let mut merged = load_base(c, "assoc", &to)?.unwrap_or_default();
                let theirs = load_base(c, "assoc", &from)?.unwrap_or_else(|| Base {
                    data: records::read(c, "assoc", &from)
                        .ok()
                        .flatten()
                        .unwrap_or_default(),
                    ..Default::default()
                });
                merge_fields(&mut merged, &theirs);
                merged.data.insert("project_id".into(), json!(keep));
                records::delete(c, "assoc", &from)?;
                records::write(c, "assoc", &to, &merged.data, self.clips)?;
                c.execute(
                    "DELETE FROM sync_base WHERE kind='assoc' AND key=?",
                    [&from],
                )?;
                save_base(c, "assoc", &to, &merged)?;
            }
            for sql in [
                "UPDATE notes SET project_id=?1 WHERE project_id=?2",
                "UPDATE docs SET project_id=?1 WHERE project_id=?2",
                "DELETE FROM projects WHERE id=?2",
            ] {
                c.execute(sql, [&keep, &gone])?;
            }
            let notes: Vec<String> = c
                .prepare("SELECT key FROM sync_base WHERE kind='note' AND json_extract(data,'$.project_id')=?")?
                .query_map([&gone], |r| r.get(0))?
                .collect::<rusqlite::Result<_>>()?;
            for n in notes {
                if let Some(mut nb) = load_base(c, "note", &n)? {
                    nb.data.insert("project_id".into(), json!(keep));
                    save_base(c, "note", &n, &nb)?;
                }
            }
        }
        c.execute(
            "DELETE FROM sync_base WHERE kind='project' AND key=?",
            [&gone],
        )?;
        add_alias(c, "project", &gone, &keep)?;
        Ok(keep)
    }

    /// A PDF with this content already on disk is used instead of downloading it again.
    fn restore_downloaded(&self, key: &str, b: &Base) -> Result<()> {
        let c = self.c;
        let Some(sha) = b.data.get("sha256").and_then(Value::as_str) else {
            return Ok(());
        };
        let local: Option<String> = c
            .query_row(
                "SELECT path FROM attachments WHERE fingerprint=? AND id<>? AND path NOT LIKE 'omabib-sync:%' LIMIT 1",
                [sha, key],
                |r| r.get(0),
            )
            .optional()?;
        if let Some(path) = local.filter(|p| std::path::Path::new(p).is_file()) {
            c.execute(
                "UPDATE OR IGNORE attachments SET path=? WHERE id=? AND path LIKE 'omabib-sync:%'",
                [&path, key],
            )?;
        }
        Ok(())
    }

    fn delete(&mut self, ch: &Change) -> Result<()> {
        let c = self.c;
        let kind = ch.kind.as_str();
        let (key, _) = self.resolved(ch)?;
        let hlc = ch.deleted.clone().unwrap_or_default();
        let b = load_base(c, kind, &key)?.unwrap_or_default();
        if b.deleted.is_some() {
            return Ok(());
        }
        if records::exists(c, kind, &key)? {
            self.save_newer_edits(kind, &key, &hlc)?;
            let data = records::read(c, kind, &key)?.unwrap_or_default();
            self.touched(kind, &key, &data);
            let (gone, chats) = records::delete(c, kind, &key)?;
            for (k, x) in gone {
                tombstone(c, &k, &x, &hlc)?;
            }
            self.out.chats.extend(chats);
        }
        tombstone(c, kind, &key, &hlc)?;
        if kind == "ref" {
            let touched = reconcile(c, &[claims(&b.data)])?;
            self.out.refs.extend(touched);
        }
        Ok(())
    }

    /// Before a deletion from elsewhere removes a reference or note, keeps a copy of
    /// anything this computer changed after that deletion was made.
    fn save_newer_edits(&mut self, kind: &str, key: &str, hlc: &str) -> Result<()> {
        let c = self.c;
        if kind != "ref" && kind != "note" {
            return Ok(());
        }
        let newer = |kind: &str, key: &str| -> Result<bool> {
            Ok(load_base(c, kind, key)?.is_some_and(|b| {
                b.clocks
                    .values()
                    .any(|h| device_of(h) == self.me && h.as_str() > hlc)
            }))
        };
        let mut notes = Vec::new();
        let note_ids: Vec<String> = if kind == "ref" {
            let mut stmt = c.prepare("SELECT id FROM notes WHERE ref_id=?")?;
            stmt.query_map([key], |r| r.get(0))?
                .collect::<rusqlite::Result<_>>()?
        } else {
            vec![key.to_string()]
        };
        let mut any = kind == "ref" && newer("ref", key)?;
        for id in note_ids {
            if newer("note", &id)? {
                any = true;
            }
            if let Some(n) = records::read(c, "note", &id)? {
                notes.push(json!({"id": id, "record": n}));
            }
        }
        if !any {
            return Ok(());
        }
        let reference = if kind == "ref" {
            records::read(c, "ref", key)?
        } else {
            None
        };
        let ref_id = if kind == "ref" {
            key.to_string()
        } else {
            notes
                .first()
                .and_then(|n| n["record"]["ref_id"].as_str())
                .unwrap_or("")
                .to_string()
        };
        let title = reference
            .as_ref()
            .and_then(|r| r.get("title").and_then(Value::as_str).map(str::to_owned))
            .or_else(|| {
                c.query_row("SELECT title FROM refs WHERE id=?", [&ref_id], |r| r.get(0))
                    .ok()
            })
            .unwrap_or_default();
        let device = self
            .names
            .get(device_of(hlc))
            .cloned()
            .unwrap_or_else(|| "another computer".into());
        let summary = if kind == "ref" {
            format!("“{title}” was deleted on {device} after you changed it here")
        } else {
            format!("A note on “{title}” was deleted on {device} after you changed it here")
        };
        c.execute(
            "INSERT INTO sync_conflicts(id,kind,ref_id,summary,detail,created_at) VALUES(?,'deleted',?,?,?,strftime('%Y-%m-%dT%H:%M:%fZ','now'))",
            params![
                uuid::Uuid::new_v4().to_string(),
                ref_id,
                summary,
                json!({"kind": kind, "key": key, "reference": reference, "notes": notes, "device": device}).to_string(),
            ],
        )?;
        self.out.conflicts += 1;
        Ok(())
    }
}

/// The citekey and DOI a reference's synced state claims.
type Claims = (Option<String>, Option<String>);

fn claims(data: &Map<String, Value>) -> Claims {
    let get = |k: &str| {
        data.get(k)
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
    };
    (get("citekey"), get("doi"))
}

/// References claiming `value` for `field`, lowest ID first: synced ones by
/// their synced value, others (not yet sent) by what they show.
fn members(c: &Connection, field: &str, value: &str) -> Result<Vec<String>> {
    let sql = format!(
        "SELECT key FROM sync_base WHERE kind='ref' AND deleted IS NULL AND json_extract(data,'$.{field}')=?1 AND key IN (SELECT id FROM refs) \
         UNION SELECT id FROM refs WHERE {field}=?1 AND id NOT IN (SELECT key FROM sync_base WHERE kind='ref') ORDER BY 1"
    );
    let ids = c
        .prepare(&sql)?
        .query_map([value], |r| r.get(0))?
        .collect::<rusqlite::Result<Vec<String>>>()?;
    Ok(ids)
}

fn suffixed(citekey: &str, id: &str) -> String {
    format!("{citekey}_{}", &id[..4.min(id.len())])
}

/// What a reference shows for its synced citekey and DOI: the lowest ID among
/// those claiming the same one keeps it; the others get a suffixed citekey and
/// no DOI. Every computer derives the same from the same records.
fn shown(c: &Connection, key: &str, data: &Map<String, Value>) -> Result<(Value, Value)> {
    let (citekey, doi) = claims(data);
    let citekey = match citekey {
        Some(k) if members(c, "citekey", &k)?.first().is_some_and(|f| f != key) => {
            json!(suffixed(&k, key))
        }
        other => json!(other),
    };
    let doi = match doi {
        Some(d) if members(c, "doi", &d)?.first().is_some_and(|f| f != key) => Value::Null,
        other => json!(other),
    };
    Ok((citekey, doi))
}

/// Hands out citekeys and DOIs among the references claiming these values.
/// Returns the references whose shown values changed.
fn reconcile(c: &Connection, groups: &[Claims]) -> Result<Vec<String>> {
    let mut touched = Vec::new();
    for (field, value) in groups
        .iter()
        .flat_map(|(k, d)| [("citekey", k.clone()), ("doi", d.clone())])
        .filter_map(|(f, v)| v.map(|v| (f, v)))
        .collect::<std::collections::BTreeSet<_>>()
    {
        let ids = members(c, field, &value)?;
        let current = |id: &str| -> Result<Option<String>> {
            Ok(
                c.query_row(&format!("SELECT {field} FROM refs WHERE id=?"), [id], |r| {
                    r.get(0)
                })
                .optional()?
                .flatten(),
            )
        };
        let wanted: Vec<(String, Option<String>)> = ids
            .iter()
            .enumerate()
            .map(|(i, id)| {
                let v = match (i, field) {
                    (0, _) => Some(value.clone()),
                    (_, "citekey") => Some(suffixed(&value, id)),
                    _ => None,
                };
                (id.clone(), v)
            })
            .collect();
        let mut changed = Vec::new();
        for (id, v) in &wanted {
            if current(id)? != *v {
                changed.push((id.clone(), v.clone()));
            }
        }
        // Two references with one DOI may be one paper added twice: let the user look.
        if field == "doi" && ids.len() > 1 {
            let title = |id: &str| -> String {
                c.query_row("SELECT title FROM refs WHERE id=?", [id], |r| r.get(0))
                    .unwrap_or_default()
            };
            for id in &ids[1..] {
                c.execute(
                    "INSERT OR IGNORE INTO sync_conflicts(id,kind,ref_id,summary,detail,created_at) VALUES(?,'duplicate',?,?,?,strftime('%Y-%m-%dT%H:%M:%fZ','now'))",
                    params![
                        format!("duplicate-{id}"),
                        id,
                        format!("“{}” may be the same paper as “{}” (same DOI)", title(id), title(&ids[0])),
                        json!({"ref_id": id, "same_as": ids[0], "doi": value}).to_string(),
                    ],
                )?;
            }
        }
        if changed.is_empty() {
            continue;
        }
        // Free the values first so handing them out never collides.
        for (id, _) in &changed {
            let placeholder = if field == "citekey" {
                Some(format!("~{id}"))
            } else {
                None
            };
            c.execute(
                &format!("UPDATE refs SET {field}=? WHERE id=?"),
                params![placeholder, id],
            )?;
        }
        for (id, v) in &changed {
            if field == "citekey"
                && let Some(v) = v
                && c.query_row(
                    "SELECT 1 FROM refs WHERE citekey=? AND id<>?",
                    [v, id],
                    |_| Ok(()),
                )
                .optional()?
                .is_some()
            {
                // A different reference already shows this suffixed key; keep a unique one.
                c.execute(
                    "UPDATE refs SET citekey=? WHERE id=?",
                    params![format!("{v}_{}", &id[4..8.min(id.len())]), id],
                )?;
            } else {
                c.execute(
                    &format!("UPDATE refs SET {field}=? WHERE id=?"),
                    params![v, id],
                )?;
            }
            crate::db::insert_doc(c, id)?;
            touched.push(id.clone());
        }
    }
    Ok(touched)
}

/// Takes each of `other`'s fields where its clock is later.
fn merge_fields(b: &mut Base, other: &Base) {
    for (f, v) in &other.data {
        let theirs = other.clocks.get(f);
        let ours = b.clocks.get(f);
        let take = match (theirs, ours) {
            (Some(t), Some(o)) => t > o,
            (Some(_), None) => true,
            (None, _) => !b.data.contains_key(f),
        };
        if take {
            b.data.insert(f.clone(), v.clone());
            if let Some(t) = theirs {
                b.clocks.insert(f.clone(), t.clone());
            }
        }
    }
}

/// Restores records saved from a deletion as new ones, which then sync.
pub fn restore(c: &Connection, detail: &Value) -> Result<Option<String>> {
    let clips = HashMap::new();
    let mut ref_id = detail["notes"]
        .get(0)
        .and_then(|n| n["record"]["ref_id"].as_str())
        .map(str::to_owned);
    if let Some(Value::Object(r)) = detail.get("reference") {
        let id = uuid::Uuid::new_v4().to_string();
        let mut r = r.clone();
        let citekey = r
            .get("citekey")
            .and_then(Value::as_str)
            .unwrap_or("restored")
            .to_string();
        if c.query_row("SELECT 1 FROM refs WHERE citekey=?", [&citekey], |_| Ok(()))
            .optional()?
            .is_some()
        {
            r.insert("citekey".into(), json!(format!("{citekey}_restored")));
        }
        if let Some(doi) = r.get("doi").and_then(Value::as_str)
            && c.query_row("SELECT 1 FROM refs WHERE doi=?", [doi], |_| Ok(()))
                .optional()?
                .is_some()
        {
            r.insert("doi".into(), Value::Null);
        }
        records::write(c, "ref", &id, &r, &clips)?;
        ref_id = Some(id);
    }
    let Some(ref_id) = ref_id else {
        return Ok(None);
    };
    if c.query_row("SELECT 1 FROM refs WHERE id=?", [&ref_id], |_| Ok(()))
        .optional()?
        .is_none()
    {
        bail!("The reference this note belonged to no longer exists");
    }
    for n in detail["notes"].as_array().into_iter().flatten() {
        if let Some(Value::Object(mut record)) = n.get("record").cloned() {
            record.insert("ref_id".into(), json!(ref_id));
            if let Some(p) = record.get("project_id").and_then(Value::as_str)
                && c.query_row("SELECT 1 FROM projects WHERE id=?", [p], |_| Ok(()))
                    .optional()?
                    .is_none()
            {
                record.insert("project_id".into(), Value::Null);
            }
            records::write(
                c,
                "note",
                &uuid::Uuid::new_v4().to_string(),
                &record,
                &clips,
            )?;
        }
    }
    Ok(Some(ref_id))
}
