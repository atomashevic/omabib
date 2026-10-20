//! Highlight sync, kept out of `sync_base` and `changes/` so an older client
//! never has to read a highlight line. Batches live under `annotations/changes/`
//! and a join can start from `annotations/snapshots/`. Field clocks and
//! last-writer-wins are the same rule notes use: a color edit and a comment
//! edit from two computers both stay, and `updated_at` keeps the later one.
use super::apply::{Base, Change};
use super::clock::{self, Hlc};
use super::format;
use super::store::Store;
use anyhow::Result;
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Map, Value, json};
use std::collections::HashMap;

pub const SCHEMA: &str = "\
CREATE TABLE IF NOT EXISTS ann_outbox(id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, key TEXT NOT NULL, at TEXT NOT NULL);\
CREATE TABLE IF NOT EXISTS ann_base(kind TEXT NOT NULL, key TEXT NOT NULL, data TEXT NOT NULL, clocks TEXT NOT NULL, deleted TEXT, PRIMARY KEY(kind,key));\
CREATE TABLE IF NOT EXISTS ann_batches(seq INTEGER PRIMARY KEY, body BLOB NOT NULL);\
CREATE TABLE IF NOT EXISTS ann_parked(id INTEGER PRIMARY KEY AUTOINCREMENT, change TEXT NOT NULL);";

fn recording(c: &Connection) -> Result<bool> {
    Ok(super::get(c, "record")?.as_deref() == Some("1"))
}

fn load(c: &Connection, key: &str) -> Result<Option<Base>> {
    Ok(c.query_row(
        "SELECT data,clocks,deleted FROM ann_base WHERE kind='highlight' AND key=?",
        [key],
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

fn save(c: &Connection, key: &str, b: &Base) -> Result<()> {
    c.execute(
        "INSERT INTO ann_base(kind,key,data,clocks,deleted) VALUES('highlight',?,?,?,?) ON CONFLICT(kind,key) DO UPDATE SET data=excluded.data,clocks=excluded.clocks,deleted=excluded.deleted",
        params![
            key,
            Value::Object(b.data.clone()).to_string(),
            serde_json::to_string(&b.clocks)?,
            b.deleted
        ],
    )?;
    Ok(())
}

fn latest(ch: &Change) -> String {
    ch.deleted
        .clone()
        .or_else(|| ch.clocks.values().max().cloned())
        .unwrap_or_default()
}

pub fn ids(c: &Connection) -> Result<Vec<String>> {
    let mut stmt = c.prepare("SELECT id FROM highlights")?;
    let ids = stmt
        .query_map([], |r| r.get(0))?
        .collect::<rusqlite::Result<Vec<String>>>()?;
    Ok(ids)
}

fn read_row(c: &Connection, key: &str) -> Result<Option<Map<String, Value>>> {
    let row = c
        .query_row(
            "SELECT ref_id,attachment_id,source_sha256,page,rects,quote,color,comment,created_at,updated_at FROM highlights WHERE id=?",
            [key],
            |r| {
                Ok(json!({
                    "ref_id": r.get::<_, String>(0)?,
                    "attachment_id": r.get::<_, String>(1)?,
                    "source_sha256": r.get::<_, String>(2)?,
                    "page": r.get::<_, i64>(3)?,
                    "rects": serde_json::from_str::<Value>(&r.get::<_, String>(4)?).unwrap_or(Value::Null),
                    "quote": r.get::<_, String>(5)?,
                    "color": r.get::<_, String>(6)?,
                    "comment": r.get::<_, String>(7)?,
                    "created_at": r.get::<_, String>(8)?,
                    "updated_at": r.get::<_, String>(9)?,
                }))
            },
        )
        .optional()?;
    Ok(row.and_then(|v| match v {
        Value::Object(m) => Some(m),
        _ => None,
    }))
}

fn write_row(c: &Connection, key: &str, r: &Map<String, Value>) -> Result<()> {
    let text = |k: &str| {
        r.get(k)
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string()
    };
    let rects = r.get("rects").cloned().unwrap_or(json!([])).to_string();
    c.execute(
        "INSERT INTO highlights(id,ref_id,attachment_id,source_sha256,page,rects,quote,color,comment,created_at,updated_at) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11) \
         ON CONFLICT(id) DO UPDATE SET ref_id=excluded.ref_id,attachment_id=excluded.attachment_id,source_sha256=excluded.source_sha256,page=excluded.page,rects=excluded.rects,quote=excluded.quote,color=excluded.color,comment=excluded.comment,created_at=excluded.created_at,updated_at=excluded.updated_at",
        params![
            key,
            text("ref_id"),
            text("attachment_id"),
            text("source_sha256"),
            r.get("page").and_then(Value::as_i64).unwrap_or(0),
            rects,
            text("quote"),
            text("color"),
            text("comment"),
            text("created_at"),
            text("updated_at"),
        ],
    )?;
    Ok(())
}

/// Turns the highlight outbox into changes. Does not touch `sync_outbox`.
pub fn flush(c: &Connection, me: &str, clock: &mut Hlc) -> Result<Vec<Change>> {
    let mut stmt = c.prepare("SELECT id,key,at FROM ann_outbox ORDER BY id")?;
    let rows = stmt
        .query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    drop(stmt);
    let Some(last) = rows.last().map(|r| r.0) else {
        return Ok(vec![]);
    };
    let mut order = Vec::new();
    let mut at: HashMap<String, u64> = HashMap::new();
    for (_, key, stamp) in rows {
        let ms = clock::iso_ms(&stamp).unwrap_or_else(clock::now_ms);
        if !at.contains_key(&key) {
            order.push(key.clone());
        }
        let slot = at.entry(key).or_insert(ms);
        *slot = (*slot).max(ms);
    }
    let mut changes = Vec::new();
    for key in order {
        let edited = at[&key];
        let current = read_row(c, &key)?;
        let base = load(c, &key)?;
        match (current, base) {
            (None, None) => {}
            (_, Some(b)) if b.deleted.is_some() => {}
            (None, Some(mut b)) => {
                *clock = clock.tick(edited, me);
                let hlc = clock.to_string();
                b.deleted = Some(hlc.clone());
                save(c, &key, &b)?;
                changes.push(Change {
                    kind: "highlight".into(),
                    key,
                    deleted: Some(hlc),
                    device: me.into(),
                    ..Default::default()
                });
            }
            (Some(current), base) => {
                let mut b = base.unwrap_or_default();
                let mut changed = Map::new();
                for (f, v) in current {
                    if b.data.get(&f) != Some(&v) {
                        changed.insert(f, v);
                    }
                }
                if changed.is_empty() {
                    continue;
                }
                *clock = clock.tick(edited, me);
                let hlc = clock.to_string();
                let mut change = Change {
                    kind: "highlight".into(),
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
                save(c, &key, &b)?;
                changes.push(change);
            }
        }
    }
    c.execute("DELETE FROM ann_outbox WHERE id<=?", [last])?;
    Ok(changes)
}

/// Marks every local highlight as synced at one clock, for a new shared library.
pub fn adopt_all(c: &Connection, me: &str, clock: &mut Hlc) -> Result<usize> {
    c.execute("DELETE FROM ann_outbox", [])?;
    let keys = ids(c)?;
    for key in &keys {
        c.execute(
            "INSERT INTO ann_outbox(kind,key,at) VALUES('highlight',?,strftime('%Y-%m-%dT%H:%M:%fZ','now'))",
            [key],
        )?;
    }
    let n = keys.len();
    flush(c, me, clock)?;
    Ok(n)
}

/// Local highlights a merge has not seen yet go up with the next sync.
pub fn queue_untracked(c: &Connection) -> Result<()> {
    for key in ids(c)? {
        if load(c, &key)?.is_none() {
            c.execute(
                "INSERT INTO ann_outbox(kind,key,at) VALUES('highlight',?,strftime('%Y-%m-%dT%H:%M:%fZ','now'))",
                [key],
            )?;
        }
    }
    Ok(())
}

fn ref_state(c: &Connection, ref_id: &str) -> Result<&'static str> {
    let tomb = c
        .query_row(
            "SELECT deleted IS NOT NULL FROM sync_base WHERE kind='ref' AND key=?",
            [ref_id],
            |r| r.get::<_, bool>(0),
        )
        .optional()?
        .unwrap_or(false);
    if tomb {
        return Ok("tomb");
    }
    let alive = c
        .query_row("SELECT 1 FROM refs WHERE id=?", [ref_id], |_| Ok(()))
        .optional()?
        .is_some();
    Ok(if alive { "alive" } else { "missing" })
}

fn tombstone(c: &Connection, key: &str, hlc: &str) -> Result<()> {
    let mut b = load(c, key)?.unwrap_or_default();
    if b.deleted.is_none() {
        b.deleted = Some(hlc.to_string());
        save(c, key, &b)?;
    }
    c.execute("DELETE FROM highlights WHERE id=?", [key])?;
    Ok(())
}

fn upsert(c: &Connection, ch: &Change) -> Result<()> {
    let mut b = load(c, &ch.key)?.unwrap_or_default();
    if b.deleted.is_some() {
        return Ok(());
    }
    let carried = ch
        .fields
        .get("ref_id")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty());
    let based = b
        .data
        .get("ref_id")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty());
    let Some(ref_id) = carried.or(based) else {
        // No reference on the change and none stored yet. Park it; an empty
        // ref_id would be an orphan row.
        c.execute(
            "INSERT INTO ann_parked(change) VALUES(?)",
            [serde_json::to_string(ch)?],
        )?;
        return Ok(());
    };
    let ref_id = ref_id.to_string();
    match ref_state(c, &ref_id)? {
        "tomb" => return tombstone(c, &ch.key, &latest(ch)),
        "missing" => {
            c.execute(
                "INSERT INTO ann_parked(change) VALUES(?)",
                [serde_json::to_string(ch)?],
            )?;
            return Ok(());
        }
        _ => {}
    }
    let mut accepted = Map::new();
    for (f, v) in &ch.fields {
        let Some(h) = ch.clocks.get(f) else { continue };
        if b.clocks.get(f).is_none_or(|mine| h > mine) {
            accepted.insert(f.clone(), v.clone());
        }
    }
    let present = c
        .query_row("SELECT 1 FROM highlights WHERE id=?", [&ch.key], |_| Ok(()))
        .optional()?
        .is_some();
    if accepted.is_empty() && present {
        return Ok(());
    }
    for (f, v) in &accepted {
        if let Some(h) = ch.clocks.get(f) {
            b.clocks.insert(f.clone(), h.clone());
        }
        b.data.insert(f.clone(), v.clone());
    }
    write_row(c, &ch.key, &b.data)?;
    save(c, &ch.key, &b)?;
    Ok(())
}

fn delete_change(c: &Connection, ch: &Change) -> Result<()> {
    let b = load(c, &ch.key)?.unwrap_or_default();
    if b.deleted.is_some() {
        return Ok(());
    }
    tombstone(c, &ch.key, &latest(ch))
}

/// Merges highlight changes. The caller has already applied the main batch, so
/// a reference deleted there is already gone.
pub fn apply(c: &Connection, _me: &str, clock: &mut Hlc, mut changes: Vec<Change>) -> Result<usize> {
    let parked: Vec<String> = c
        .prepare("SELECT change FROM ann_parked ORDER BY id")?
        .query_map([], |r| r.get(0))?
        .collect::<rusqlite::Result<_>>()?;
    c.execute("DELETE FROM ann_parked", [])?;
    for p in parked {
        if let Ok(ch) = serde_json::from_str::<Change>(&p) {
            changes.push(ch);
        }
    }
    let (mut upserts, mut deletes): (Vec<Change>, Vec<Change>) =
        changes.into_iter().partition(|ch| ch.deleted.is_none());
    upserts.sort_by_key(latest);
    deletes.sort_by_key(latest);
    let mut n = 0;
    for ch in upserts.iter().chain(deletes.iter()) {
        if let Some(h) = Hlc::parse(&latest(ch)) {
            *clock = clock.observe(&h);
        }
        if ch.deleted.is_some() {
            delete_change(c, ch)?;
        } else {
            upsert(c, ch)?;
        }
        n += 1;
    }
    Ok(n)
}

/// A reference removed while recording is off (a change from another computer)
/// drops its highlights here. While recording is on, the table trigger queues
/// the tombstone instead.
pub fn tombstone_for_ref(c: &Connection, ref_id: &str, hlc: &str) -> Result<()> {
    if recording(c)? {
        return Ok(());
    }
    let keys: Vec<String> = c
        .prepare("SELECT key FROM ann_base WHERE kind='highlight' AND deleted IS NULL AND json_extract(data,'$.ref_id')=?")?
        .query_map([ref_id], |r| r.get(0))?
        .collect::<rusqlite::Result<_>>()?;
    for key in keys {
        tombstone(c, &key, hlc)?;
    }
    Ok(())
}

/// An older client can delete a reference without knowing about highlights.
/// The next open drops those rows. A synced library queues the tombstone; one
/// that is not recording just forgets them, so a later snapshot cannot bring
/// them back.
pub fn drop_orphans(c: &Connection) -> Result<()> {
    if !recording(c)? {
        let hlc = super::get(c, "hlc")?.unwrap_or_else(|| "0000000000001.00000.local".into());
        let keys: Vec<String> = c
            .prepare("SELECT key FROM ann_base WHERE kind='highlight' AND deleted IS NULL AND json_extract(data,'$.ref_id') NOT IN (SELECT id FROM refs)")?
            .query_map([], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?;
        for key in keys {
            tombstone(c, &key, &hlc)?;
        }
    }
    c.execute(
        "DELETE FROM highlights WHERE ref_id NOT IN (SELECT id FROM refs)",
        [],
    )?;
    Ok(())
}

fn latest_snapshot(store: &dyn Store) -> Result<Option<String>> {
    Ok(store
        .list("annotations/snapshots")?
        .into_iter()
        .map(|e| e.name)
        .filter(|n| n.ends_with(".jsonl.gz"))
        .max())
}

/// The join sidecar, or every annotation batch when there is no sidecar yet.
pub fn absorb(c: &Connection, store: &dyn Store, me: &str, clock: &mut Hlc) -> Result<()> {
    // Newest sidecar from any device, not the main snapshot this join used; parking holds a highlight whose reference has not arrived.
    if let Some(name) = latest_snapshot(store)? {
        let bytes = store.read(&format!("annotations/snapshots/{name}"))?;
        let (header, changes) = format::read_snapshot(&bytes)?;
        apply(c, me, clock, changes)?;
        if let Some(w) = header["watermarks"].as_object() {
            for (device, seq) in w {
                super::set(
                    c,
                    &format!("awm:{device}"),
                    &seq.as_i64().unwrap_or(0).to_string(),
                )?;
            }
        }
        return Ok(());
    }
    let mut all = Vec::new();
    for entry in store.list("devices")? {
        let Some(device) = entry.name.strip_suffix(".json") else {
            continue;
        };
        let manifest: Value = serde_json::from_slice(&store.read(&format::device_path(device))?)
            .unwrap_or_default();
        let latest = manifest["ann_seq"].as_i64().unwrap_or(0);
        for seq in 1..=latest {
            let bytes = store.read(&format::annotation_batch_path(device, seq))?;
            let (_, changes) = format::read_batch(&bytes)?;
            all.extend(changes);
        }
        super::set(c, &format!("awm:{device}"), &latest.to_string())?;
    }
    apply(c, me, clock, all)?;
    Ok(())
}

/// Writes the highlight sidecar next to the main snapshot.
pub fn write_snapshot(c: &Connection, store: &dyn Store, me: &str) -> Result<()> {
    let mut stmt = c.prepare("SELECT key FROM ann_base WHERE kind='highlight' ORDER BY key")?;
    let keys: Vec<String> = stmt
        .query_map([], |r| r.get(0))?
        .collect::<rusqlite::Result<_>>()?;
    let mut rows = Vec::new();
    for key in keys {
        if let Some(b) = load(c, &key)? {
            rows.push(("highlight".to_string(), key, b));
        }
    }
    let mut watermarks = Map::new();
    let mut stmt = c.prepare("SELECT key,value FROM sync_state WHERE key LIKE 'awm:%'")?;
    for row in stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))? {
        let (k, v) = row?;
        watermarks.insert(k[4..].to_string(), json!(v.parse::<i64>().unwrap_or(0)));
    }
    watermarks.insert(me.into(), json!(super::get_i64(c, "ann_uploaded")?));
    let hlc = super::get(c, "hlc")?.unwrap_or_default();
    let header = json!({"format": format::FORMAT, "device": me, "hlc": hlc, "created": super::records::now(), "watermarks": watermarks});
    let bytes = format::write_snapshot(&header, &rows)?;
    let name = format!(
        "{}-{me}.jsonl.gz",
        hlc.split('.').next().unwrap_or("0")
    );
    store.write(&format!("annotations/snapshots/{name}"), &bytes)?;
    let mine: Vec<String> = store
        .list("annotations/snapshots")?
        .into_iter()
        .map(|e| e.name)
        .filter(|n| n.ends_with(&format!("-{me}.jsonl.gz")))
        .collect();
    for old in mine.iter().rev().skip(2) {
        store.remove(&format!("annotations/snapshots/{old}"))?;
    }
    Ok(())
}
