//! Two-way sync of the library through storage the user already has: a folder
//! kept in sync by another app, or Google Drive, Dropbox and OneDrive through
//! rclone. The live database never leaves the computer. Each computer uploads
//! its own immutable change batches and reads everyone else's (see `apply` for
//! the merge rules, `format` for the files).
pub mod apply;
pub mod clock;
mod connect;
pub mod format;
pub mod records;
pub mod store;

use crate::db::Library;
use anyhow::{Context, Result, bail, ensure};
use apply::Change;
use clock::Hlc;
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashMap},
    path::{Path, PathBuf},
    sync::{Arc, Condvar, Mutex, Weak},
    time::{Duration, Instant},
};
use store::{FolderStore, RcloneStore, Store, StoreError};

pub use connect::{Connecting, providers, remotes};

pub const SCHEMA: &str = "CREATE TABLE IF NOT EXISTS sync_state(key TEXT PRIMARY KEY, value TEXT NOT NULL);\
CREATE TABLE IF NOT EXISTS sync_outbox(id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, key TEXT NOT NULL, at TEXT NOT NULL);\
CREATE TABLE IF NOT EXISTS sync_base(kind TEXT NOT NULL, key TEXT NOT NULL, data TEXT NOT NULL, clocks TEXT NOT NULL, deleted TEXT, PRIMARY KEY(kind,key));\
CREATE TABLE IF NOT EXISTS sync_batches(seq INTEGER PRIMARY KEY, body BLOB NOT NULL);\
CREATE TABLE IF NOT EXISTS sync_uploads(path TEXT PRIMARY KEY, kind TEXT NOT NULL, key TEXT NOT NULL);\
CREATE TABLE IF NOT EXISTS sync_conflicts(id TEXT PRIMARY KEY, kind TEXT NOT NULL, ref_id TEXT, summary TEXT NOT NULL, detail TEXT NOT NULL, created_at TEXT NOT NULL);\
CREATE TABLE IF NOT EXISTS sync_aliases(kind TEXT NOT NULL, key TEXT NOT NULL, target TEXT NOT NULL, PRIMARY KEY(kind,key));\
CREATE TABLE IF NOT EXISTS sync_parked(id INTEGER PRIMARY KEY AUTOINCREMENT, change TEXT NOT NULL);\
INSERT OR IGNORE INTO sync_state(key,value) VALUES('record','0');";

/// Tables, the clip column that replaces a local PDF path, and the triggers
/// that note every change to a synced table while sync is on.
pub fn migrate(c: &Connection) -> Result<()> {
    c.execute_batch(SCHEMA)?;
    let has: bool = c
        .prepare("SELECT 1 FROM pragma_table_info('note_images') WHERE name='source_sha256'")?
        .exists([])?;
    if !has {
        c.execute_batch("ALTER TABLE note_images ADD COLUMN source_sha256 TEXT")?;
    }
    for (table, kind, cols) in records::TABLES {
        for (event, row) in [("INSERT", "NEW"), ("UPDATE", "NEW"), ("DELETE", "OLD")] {
            let key = cols
                .iter()
                .map(|c| format!("{row}.{c}"))
                .collect::<Vec<_>>()
                .join(" || '|' || ");
            c.execute_batch(&format!(
                "CREATE TRIGGER IF NOT EXISTS sync_{table}_{} AFTER {event} ON {table} \
                 WHEN (SELECT value FROM sync_state WHERE key='record')='1' \
                 BEGIN INSERT INTO sync_outbox(kind,key,at) VALUES('{kind}',{key},strftime('%Y-%m-%dT%H:%M:%fZ','now')); END;",
                event.to_ascii_lowercase()
            ))?;
        }
    }
    Ok(())
}

// ---- State kept in sync_state ----

fn get(c: &Connection, key: &str) -> Result<Option<String>> {
    Ok(
        c.query_row("SELECT value FROM sync_state WHERE key=?", [key], |r| {
            r.get(0)
        })
        .optional()?,
    )
}

fn set(c: &Connection, key: &str, value: &str) -> Result<()> {
    c.execute(
        "INSERT INTO sync_state(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        [key, value],
    )?;
    Ok(())
}

fn get_i64(c: &Connection, key: &str) -> Result<i64> {
    Ok(get(c, key)?.and_then(|v| v.parse().ok()).unwrap_or(0))
}

fn clock(c: &Connection, me: &str) -> Result<Hlc> {
    Ok(get(c, "hlc")?
        .and_then(|h| Hlc::parse(&h))
        .map(|h| Hlc {
            device: me.into(),
            ..h
        })
        .unwrap_or_else(|| Hlc::zero(me)))
}

fn hostname() -> String {
    std::fs::read_to_string("/proc/sys/kernel/hostname")
        .map(|s| s.trim().to_string())
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "this computer".into())
}

/// The rclone config Omabib keeps for itself, apart from the user's own.
pub fn rclone_config() -> PathBuf {
    if let Some(p) = std::env::var_os("OMABIB_RCLONE_CONFIG").filter(|v| !v.is_empty()) {
        return PathBuf::from(p);
    }
    std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".config"))
        .join("omabib/rclone.conf")
}

/// The storage a provider setting describes.
pub fn open_store(provider: &Value) -> Result<Arc<dyn Store>> {
    Ok(match provider["kind"].as_str() {
        Some("folder") => Arc::new(FolderStore {
            root: PathBuf::from(provider["path"].as_str().context("Sync folder missing")?)
                .join("Omabib"),
        }),
        Some("rclone") => Arc::new(RcloneStore {
            config: rclone_config(),
            root: format!("{}:Omabib", provider["remote"].as_str().unwrap_or("omabib")),
            label: provider["label"]
                .as_str()
                .unwrap_or("the sync storage")
                .to_string(),
        }),
        _ => bail!("Sync is not set up"),
    })
}

// ---- The engine ----

#[derive(Clone, Debug, Default)]
struct Status {
    /// "off", "idle", "syncing", "offline", "auth", "full", "error".
    state: String,
    message: String,
    progress: Option<Value>,
    devices: Vec<Value>,
    last_attempt: Option<Instant>,
    retry_after: Option<Instant>,
}

pub struct Sync {
    path: PathBuf,
    chats: Arc<crate::chat::Chats>,
    cycle: Mutex<()>,
    status: Mutex<Status>,
    wake: (Mutex<bool>, Condvar),
    connect: Mutex<Option<Arc<Connecting>>>,
    started: std::sync::Once,
}

impl Sync {
    pub fn new(path: &std::path::Path, chats: Arc<crate::chat::Chats>) -> Arc<Self> {
        Arc::new(Sync {
            path: path.to_path_buf(),
            chats,
            cycle: Mutex::new(()),
            status: Mutex::new(Status {
                state: "idle".into(),
                ..Default::default()
            }),
            wake: (Mutex::new(false), Condvar::new()),
            connect: Mutex::new(None),
            started: std::sync::Once::new(),
        })
    }

    fn publish(&self) {
        if let Ok(status) = self.status_json() {
            self.chats
                .publish(&json!({"v":1,"event":"sync","status":status}).to_string());
        }
    }
}

/// What a sync did, for the status line.
#[derive(Debug, Default)]
pub struct Summary {
    pub already_running: bool,
    pub sent: usize,
    pub received: usize,
    pub from: Vec<String>,
    pub refs: Vec<String>,
    pub notes: Vec<String>,
    pub conflicts: usize,
}

const DEBOUNCE: Duration = Duration::from_secs(30);
const POLL: Duration = Duration::from_secs(300);

impl Sync {
    /// Runs sync in the background for the service: after edits settle, every
    /// few minutes, and when asked.
    pub fn start(lib: &Arc<Library>) {
        let weak: Weak<Library> = Arc::downgrade(lib);
        let sync = lib.sync.clone();
        lib.sync.started.call_once(|| {
            std::thread::spawn(move || {
                loop {
                    let asked = {
                        let (lock, cv) = &sync.wake;
                        let guard = lock.lock().unwrap();
                        let (mut guard, _) =
                            cv.wait_timeout(guard, Duration::from_secs(10)).unwrap();
                        std::mem::take(&mut *guard)
                    };
                    let Some(lib) = weak.upgrade() else { return };
                    if sync.due(&lib, asked).unwrap_or(false) {
                        let _ = sync.run(&lib);
                    }
                }
            });
        });
    }

    /// Asks the background thread for a sync now.
    pub fn nudge(&self) {
        let (lock, cv) = &self.wake;
        *lock.lock().unwrap() = true;
        cv.notify_all();
    }

    fn due(&self, lib: &Library, asked: bool) -> Result<bool> {
        let c = crate::db::read_connection(&lib.path)?;
        if get(&c, "provider")?.is_none() || get(&c, "library")?.is_none() {
            return Ok(false);
        }
        let status = self.status.lock().unwrap().clone();
        if status.state == "auth" && !asked {
            return Ok(false);
        }
        if let Some(t) = status.retry_after
            && Instant::now() < t
            && !asked
        {
            return Ok(false);
        }
        if asked {
            return Ok(true);
        }
        let waiting: i64 = c.query_row(
            "SELECT (SELECT count(*) FROM sync_batches)+(SELECT count(*) FROM sync_uploads)",
            [],
            |r| r.get(0),
        )?;
        let newest: Option<String> =
            c.query_row("SELECT max(at) FROM sync_outbox", [], |r| r.get(0))?;
        let settled = newest
            .and_then(|at| clock::iso_ms(&at))
            .is_some_and(|ms| clock::now_ms().saturating_sub(ms) >= DEBOUNCE.as_millis() as u64);
        let stale = status.last_attempt.is_none_or(|t| t.elapsed() >= POLL);
        Ok(waiting > 0 || settled || stale)
    }

    fn set_status(&self, state: &str, message: &str) {
        {
            let mut s = self.status.lock().unwrap();
            s.state = state.into();
            s.message = message.into();
            if state != "syncing" {
                s.progress = None;
            }
        }
        self.publish();
    }

    fn progress(&self, what: &str, done: usize, total: usize) {
        self.status.lock().unwrap().progress = Some(json!({"what":what,"done":done,"total":total}));
        self.publish();
    }

    /// One sync, recording its result in the status.
    pub fn run(&self, lib: &Library) -> Result<Summary> {
        // A duplicate request must not alter the active run's status/progress.
        let _guard = match self.cycle.try_lock() {
            Ok(guard) => guard,
            Err(std::sync::TryLockError::WouldBlock) => {
                return Ok(Summary {
                    already_running: true,
                    ..Default::default()
                });
            }
            Err(_) => bail!("Sync lock is poisoned"),
        };
        let started = Instant::now();
        {
            let mut s = self.status.lock().unwrap();
            s.last_attempt = Some(started);
        }
        self.set_status("syncing", "");
        let result = self.cycle(lib);
        match &result {
            Ok(summary) => {
                if let Ok(c) = crate::db::read_connection(&lib.path) {
                    let _ = set(&c, "last_success", &records::now());
                }
                self.status.lock().unwrap().retry_after = None;
                let message = if summary.received > 0 {
                    format!(
                        "Synced {} change{} from {}",
                        summary.received,
                        if summary.received == 1 { "" } else { "s" },
                        summary.from.join(", ")
                    )
                } else {
                    String::new()
                };
                self.set_status("idle", &message);
            }
            Err(e) => {
                let kind = e
                    .downcast_ref::<StoreError>()
                    .map(|s| s.kind)
                    .unwrap_or("error");
                let wait = match kind {
                    "offline" => Duration::from_secs(60),
                    "auth" => Duration::from_secs(3600),
                    _ => Duration::from_secs(300),
                };
                self.status.lock().unwrap().retry_after = Some(Instant::now() + wait);
                let state = match kind {
                    "offline" | "auth" | "full" => kind,
                    "missing" => "error",
                    _ => "error",
                };
                self.set_status(state, &format!("{e:#}"));
            }
        }
        result
    }

    fn cycle(&self, lib: &Library) -> Result<Summary> {
        let (me, provider) = {
            let c = crate::db::read_connection(&lib.path)?;
            (
                get(&c, "device")?.context("Sync is not set up")?,
                serde_json::from_str::<Value>(
                    &get(&c, "provider")?.context("Sync is not set up")?,
                )?,
            )
        };
        let store = open_store(&provider)?;
        // Other computers' new batches, read before taking the write lock.
        let (incoming, names, devices) = self.fetch(lib, store.as_ref(), &me)?;
        let clips = fetch_clips(
            lib,
            store.as_ref(),
            incoming.iter().flat_map(|(_, _, ch)| ch.iter()),
        )?;
        let received: usize = incoming.iter().map(|(_, _, ch)| ch.len()).sum();
        let from: Vec<String> = {
            let mut f: Vec<String> = incoming
                .iter()
                .filter(|(_, _, ch)| !ch.is_empty())
                .map(|(d, _, _)| {
                    names
                        .get(d)
                        .cloned()
                        .unwrap_or_else(|| "another computer".into())
                })
                .collect();
            f.dedup();
            f
        };
        let (sent, outcome) = {
            let mut c = lib.writer.lock().unwrap();
            let tx = c.transaction()?;
            set(&tx, "record", "0")?;
            let mut clock = clock(&tx, &me)?;
            let local = apply::flush(&tx, &me, &mut clock)?;
            if !local.is_empty() {
                let seq = get_i64(&tx, "seq")? + 1;
                let body = format::write_batch(&me, seq, &records::now(), &local)?;
                tx.execute(
                    "INSERT INTO sync_batches(seq,body) VALUES(?,?)",
                    params![seq, body],
                )?;
                set(&tx, "seq", &seq.to_string())?;
            }
            let mut watermarks: BTreeMap<String, i64> = BTreeMap::new();
            let mut all = Vec::new();
            for (device, seq, changes) in incoming {
                let w = watermarks.entry(device).or_insert(0);
                *w = (*w).max(seq);
                all.extend(changes);
            }
            let outcome = apply::apply(&tx, &me, &mut clock, all, &clips, &names)?;
            for (device, seq) in &watermarks {
                set(&tx, &format!("wm:{device}"), &seq.to_string())?;
            }
            set(&tx, "names", &serde_json::to_string(&names)?)?;
            let applied = get_i64(&tx, "applied_since_snapshot")?
                + outcome.applied as i64
                + local.len() as i64;
            set(&tx, "applied_since_snapshot", &applied.to_string())?;
            set(&tx, "hlc", &clock.to_string())?;
            set(&tx, "record", "1")?;
            tx.commit()?;
            (local.len(), outcome)
        };
        if !outcome.chats.is_empty() {
            lib.chats.forget(&outcome.chats);
        }
        if !outcome.refs.is_empty() || !outcome.notes.is_empty() {
            let _ = lib.load_vocabulary();
            lib.chats.publish(
                &json!({"v":1,"event":"library","refs":outcome.refs,"notes":outcome.notes})
                    .to_string(),
            );
        }
        self.upload(lib, store.as_ref(), &me)?;
        self.status.lock().unwrap().devices = devices;
        self.maybe_snapshot(lib, store.as_ref(), &me)?;
        Ok(Summary {
            already_running: false,
            sent,
            received,
            from,
            refs: outcome.refs.into_iter().collect(),
            notes: outcome.notes.into_iter().collect(),
            conflicts: outcome.conflicts,
        })
    }

    /// Batches newer than what this computer has applied, per device, in order.
    #[allow(clippy::type_complexity)]
    fn fetch(
        &self,
        lib: &Library,
        store: &dyn Store,
        me: &str,
    ) -> Result<(
        Vec<(String, i64, Vec<Change>)>,
        HashMap<String, String>,
        Vec<Value>,
    )> {
        let c = crate::db::read_connection(&lib.path)?;
        let mut names: HashMap<String, String> = get(&c, "names")?
            .and_then(|n| serde_json::from_str(&n).ok())
            .unwrap_or_default();
        let mut incoming = Vec::new();
        let mut devices = Vec::new();
        for entry in store.list("devices")? {
            let Some(device) = entry.name.strip_suffix(".json") else {
                continue;
            };
            let manifest: Value =
                serde_json::from_slice(&store.read(&format::device_path(device))?)
                    .unwrap_or_default();
            let name = manifest["name"]
                .as_str()
                .unwrap_or("another computer")
                .to_string();
            names.insert(device.to_string(), name.clone());
            devices.push(json!({"device":device,"name":name,"updated":manifest["updated"],"me":device == me}));
            if device == me {
                continue;
            }
            let applied = get_i64(&c, &format!("wm:{device}"))?;
            let latest = manifest["seq"].as_i64().unwrap_or(0);
            for seq in applied + 1..=latest {
                let bytes = store.read(&format::batch_path(device, seq))?;
                let (_, changes) = format::read_batch(&bytes)?;
                incoming.push((device.to_string(), seq, changes));
            }
        }
        Ok((incoming, names, devices))
    }

    /// Sends files, then batches, then this computer's manifest, so a batch
    /// never names a file that isn't there yet.
    fn upload(&self, lib: &Library, store: &dyn Store, me: &str) -> Result<()> {
        let c = crate::db::read_connection(&lib.path)?;
        let uploads: Vec<(String, String, String)> = c
            .prepare("SELECT path,kind,key FROM sync_uploads ORDER BY path")?
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
            .collect::<rusqlite::Result<_>>()?;
        let mut present: HashMap<String, std::collections::HashSet<String>> = HashMap::new();
        // Bound staging disk use and report progress after each successful batch.
        for (batch_index, batch) in uploads.chunks(8).enumerate() {
            let staging = tempfile::Builder::new()
                .prefix("omabib-upload-")
                .tempdir()?;
            let mut paths = Vec::new();
            self.progress("Uploading files", batch_index * 8, uploads.len());
            for (path, kind, key) in batch {
                ensure!(
                    Path::new(path)
                        .components()
                        .all(|p| matches!(p, std::path::Component::Normal(_))),
                    "Invalid upload path"
                );
                let (dir, name) = path.rsplit_once('/').unwrap_or(("", path));
                if !present.contains_key(dir) {
                    let names = store.list(dir)?.into_iter().map(|e| e.name).collect();
                    present.insert(dir.to_string(), names);
                }
                if !present[dir].contains(name) {
                    let target = staging.path().join(path);
                    std::fs::create_dir_all(target.parent().unwrap())?;
                    match kind.as_str() {
                        "attachment" => {
                            let local: Option<String> = c
                                .query_row("SELECT path FROM attachments WHERE id=?", [key], |r| {
                                    r.get(0)
                                })
                                .optional()?;
                            if let Some(local) = local.filter(|p| std::path::Path::new(p).is_file())
                            {
                                if std::fs::hard_link(&local, &target).is_err() {
                                    std::fs::copy(&local, &target)?;
                                }
                                paths.push(path.clone());
                            } else {
                                bail!("PDF waiting for upload is missing on this computer: {path}");
                            }
                        }
                        "image" => {
                            let data: Option<Vec<u8>> = c
                                .query_row(
                                    "SELECT data FROM note_images WHERE note_id=?",
                                    [key],
                                    |r| r.get(0),
                                )
                                .optional()?;
                            if let Some(data) = data {
                                std::fs::write(&target, data)?;
                                paths.push(path.clone());
                            } else {
                                bail!("Clip waiting for upload is missing: {path}");
                            }
                        }
                        _ => bail!("Unknown upload kind: {kind}"),
                    }
                }
            }
            // Keep the entire queue on failure. A retry skips completed remote files.
            store.upload_batch(staging.path(), &paths)?;
            for (path, _, _) in batch {
                lib.writer
                    .lock()
                    .unwrap()
                    .execute("DELETE FROM sync_uploads WHERE path=?", [path])?;
            }
            self.progress(
                "Uploading files",
                (batch_index * 8 + batch.len()).min(uploads.len()),
                uploads.len(),
            );
        }
        let batches: Vec<(i64, Vec<u8>)> = c
            .prepare("SELECT seq,body FROM sync_batches ORDER BY seq")?
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<rusqlite::Result<_>>()?;
        let mut sent = get_i64(&c, "uploaded")?;
        for (seq, body) in batches {
            store.write(&format::batch_path(me, seq), &body)?;
            let w = lib.writer.lock().unwrap();
            w.execute("DELETE FROM sync_batches WHERE seq=?", [seq])?;
            set(&w, "uploaded", &seq.to_string())?;
            sent = seq;
        }
        let manifest = json!({"device":me,"name":hostname(),"seq":sent,"updated":records::now(),
            "hlc":get(&c, "hlc")?,"app":format!("omabib {}", env!("CARGO_PKG_VERSION"))});
        store.write(&format::device_path(me), manifest.to_string().as_bytes())?;
        Ok(())
    }

    fn maybe_snapshot(&self, lib: &Library, store: &dyn Store, me: &str) -> Result<()> {
        let c = crate::db::read_connection(&lib.path)?;
        let applied = get_i64(&c, "applied_since_snapshot")?;
        let old = get(&c, "last_snapshot")?
            .and_then(|t| clock::iso_ms(&t))
            .is_none_or(|ms| clock::now_ms().saturating_sub(ms) > 7 * 86_400_000);
        if applied < 1000 && !(old && applied > 0) {
            return Ok(());
        }
        write_snapshot(lib, store, me)?;
        let w = lib.writer.lock().unwrap();
        set(&w, "applied_since_snapshot", "0")?;
        set(&w, "last_snapshot", &records::now())?;
        Ok(())
    }

    // ---- Operations ----

    pub fn status_json(&self) -> Result<Value> {
        let c = crate::db::read_connection(&self.path)?;
        let provider: Option<Value> =
            get(&c, "provider")?.and_then(|p| serde_json::from_str(&p).ok());
        let joined = get(&c, "library")?.is_some();
        let count = |sql: &str| -> i64 { c.query_row(sql, [], |r| r.get(0)).unwrap_or(0) };
        let s = self.status.lock().unwrap().clone();
        let connecting = self.connect.lock().unwrap().as_ref().map(|j| j.json());
        let place = provider
            .as_ref()
            .and_then(|p| open_store(p).ok())
            .map(|st| st.describe());
        Ok(json!({
            "configured": provider.is_some() && joined,
            "connected": provider.is_some(),
            "provider": provider,
            "where": place,
            "state": if provider.is_none() || !joined { "off" } else { s.state.as_str() },
            "message": s.message,
            "progress": s.progress,
            "last_success": get(&c, "last_success")?,
            "pending": count("SELECT (SELECT count(*) FROM sync_outbox)+(SELECT count(*) FROM sync_batches)+(SELECT count(*) FROM sync_uploads)"),
            "conflicts": count("SELECT count(*) FROM sync_conflicts"),
            "devices": s.devices,
            "device_name": hostname(),
            "pdfs": {
                "here": count("SELECT count(*) FROM attachments WHERE file_type='pdf' AND path NOT LIKE 'omabib-sync:%'"),
                "cloud_only": count("SELECT count(*) FROM attachments WHERE file_type='pdf' AND path LIKE 'omabib-sync:%'"),
            },
            "connecting": connecting,
        }))
    }

    /// Connects a folder right away, or starts the browser sign-in for a provider.
    pub fn connect(self: &Arc<Self>, lib: &Library, a: &Value) -> Result<Value> {
        let provider = crate::db::required(a, "provider")?;
        if provider == "folder" {
            let path = PathBuf::from(crate::db::required(a, "path")?);
            ensure!(path.is_absolute(), "Choose a folder by its full path");
            std::fs::create_dir_all(path.join("Omabib"))
                .with_context(|| format!("Could not use {}", path.display()))?;
            let probe = path.join("Omabib").join(".omabib-write-test");
            std::fs::write(&probe, b"")
                .with_context(|| format!("Omabib can't write to {}", path.display()))?;
            let _ = std::fs::remove_file(probe);
            let setting = json!({"kind":"folder","path":path,"label":"Folder"});
            let w = lib.writer.lock().unwrap();
            set(&w, "provider", &setting.to_string())?;
            drop(w);
            return self.status_json();
        }
        if provider == "rclone" {
            // A remote the user set up in Omabib's rclone config (S3, WebDAV, …).
            let remote = crate::db::required(a, "remote")?
                .trim_end_matches(':')
                .to_string();
            ensure!(
                connect::remotes()?.contains(&remote),
                "There is no rclone remote called {remote} in {}",
                rclone_config().display()
            );
            let setting =
                json!({"kind":"rclone","remote":remote,"provider":"rclone","label":remote});
            open_store(&setting)?.list("")?;
            self.connected(&setting)?;
            return self.status_json();
        }
        if let Some(old) = self.connect.lock().unwrap().take() {
            old.cancel();
        }
        let job = connect::start(self.clone(), provider)?;
        *self.connect.lock().unwrap() = Some(job);
        self.status_json()
    }

    pub fn connect_cancel(&self) -> Result<Value> {
        if let Some(job) = self.connect.lock().unwrap().take() {
            job.cancel();
        }
        self.status_json()
    }

    /// Called by the sign-in job once the provider answers.
    pub(crate) fn connected(&self, setting: &Value) -> Result<()> {
        let c = crate::db::read_connection(&self.path)?;
        set(&c, "provider", &setting.to_string())?;
        self.set_status("idle", "");
        Ok(())
    }

    /// What is already in the storage: nothing, or a library with its size and
    /// who synced it last.
    pub fn inspect(&self, lib: &Library) -> Result<Value> {
        let c = crate::db::read_connection(&lib.path)?;
        let provider: Value =
            serde_json::from_str(&get(&c, "provider")?.context("Choose where to sync first")?)?;
        let store = open_store(&provider)?;
        let local = json!({
            "references": c.query_row("SELECT count(*) FROM refs", [], |r| r.get::<_, i64>(0))?,
            "notes": c.query_row("SELECT count(*) FROM notes", [], |r| r.get::<_, i64>(0))?,
            "pdfs": c.query_row("SELECT count(*) FROM attachments WHERE file_type='pdf'", [], |r| r.get::<_, i64>(0))?,
        });
        let Ok(library) = store.read("library.json") else {
            return Ok(json!({"exists": false, "local": local, "where": store.describe()}));
        };
        let library: Value = serde_json::from_slice(&library)?;
        let snapshot = latest_snapshot(store.as_ref())?;
        let header = match &snapshot {
            Some(name) => format::read_snapshot(&store.read(&format!("snapshots/{name}"))?)?.0,
            None => Value::Null,
        };
        let mut last: Option<Value> = None;
        for e in store.list("devices")? {
            if let Ok(bytes) = store.read(&format!("devices/{}", e.name))
                && let Ok(m) = serde_json::from_slice::<Value>(&bytes)
                && last
                    .as_ref()
                    .is_none_or(|l| m["updated"].as_str() > l["updated"].as_str())
            {
                last = Some(m);
            }
        }
        Ok(json!({
            "exists": true,
            "library": library,
            "counts": header["counts"],
            "last_device": last.as_ref().map(|l| l["name"].clone()),
            "last_updated": last.as_ref().map(|l| l["updated"].clone()),
            "local": local,
            "where": store.describe(),
        }))
    }

    /// Starts syncing: a new shared library from this one, or joining the one in
    /// the storage (replacing, merging with, or filling an empty local library).
    pub fn begin(&self, lib: &Library, a: &Value) -> Result<Value> {
        let mode = crate::db::required(a, "mode")?;
        let (provider, local_refs) = {
            let c = crate::db::read_connection(&lib.path)?;
            let provider: Value =
                serde_json::from_str(&get(&c, "provider")?.context("Choose where to sync first")?)?;
            (
                provider,
                c.query_row("SELECT count(*) FROM refs", [], |r| r.get::<_, i64>(0))?,
            )
        };
        let store = open_store(&provider)?;
        let exists = store.read("library.json").is_ok();
        let _guard = self.cycle.lock().unwrap();
        let me = uuid::Uuid::new_v4().to_string();
        match mode {
            "new" => {
                ensure!(
                    !exists,
                    "This storage already has an Omabib library; join it instead"
                );
                {
                    let mut c = lib.writer.lock().unwrap();
                    let tx = c.transaction()?;
                    reset(&tx)?;
                    set(&tx, "device", &me)?;
                    let mut clock = Hlc::zero(&me);
                    apply::adopt_all(&tx, &me, &mut clock)?;
                    set(&tx, "hlc", &clock.to_string())?;
                    set(&tx, "library", &uuid::Uuid::new_v4().to_string())?;
                    set(&tx, "record", "1")?;
                    tx.commit()?;
                }
                self.set_status("syncing", "Uploading your library");
                self.upload(lib, store.as_ref(), &me)?;
                write_snapshot(lib, store.as_ref(), &me)?;
                let c = crate::db::read_connection(&lib.path)?;
                let library = json!({"format":format::FORMAT,"library_id":get(&c, "library")?,
                    "created":records::now(),"created_by":hostname()});
                store.write("library.json", library.to_string().as_bytes())?;
            }
            "join" | "merge" | "replace" => {
                ensure!(exists, "There is no Omabib library in this storage yet");
                ensure!(
                    mode != "join" || local_refs == 0,
                    "This computer already has references; choose Merge or Replace"
                );
                let library: Value = serde_json::from_slice(&store.read("library.json")?)?;
                let name = latest_snapshot(store.as_ref())?
                    .context("The shared library has no snapshot yet")?;
                self.set_status("syncing", "Downloading the library");
                let (header, changes) =
                    format::read_snapshot(&store.read(&format!("snapshots/{name}"))?)?;
                let clips = fetch_clips(lib, store.as_ref(), changes.iter())?;
                if local_refs > 0 {
                    backup(lib, mode)?;
                }
                let mut c = lib.writer.lock().unwrap();
                let tx = c.transaction()?;
                reset(&tx)?;
                if mode == "replace" {
                    clear_library(&tx)?;
                }
                set(&tx, "device", &me)?;
                let mut clock = Hlc::zero(&me);
                for a in header["aliases"].as_array().into_iter().flatten() {
                    tx.execute(
                        "INSERT OR REPLACE INTO sync_aliases(kind,key,target) VALUES(?,?,?)",
                        params![a[0].as_str(), a[1].as_str(), a[2].as_str()],
                    )?;
                }
                let names: HashMap<String, String> = HashMap::new();
                apply::apply(&tx, &me, &mut clock, changes, &clips, &names)?;
                if let Some(w) = header["watermarks"].as_object() {
                    for (device, seq) in w {
                        set(
                            &tx,
                            &format!("wm:{device}"),
                            &seq.as_i64().unwrap_or(0).to_string(),
                        )?;
                    }
                }
                if mode == "merge" {
                    // What only this computer has goes up as new records.
                    for kind in records::KINDS {
                        for key in records::keys(&tx, kind)? {
                            if apply::load_base(&tx, kind, &key)?.is_none() {
                                tx.execute(
                                    "INSERT INTO sync_outbox(kind,key,at) VALUES(?,?,strftime('%Y-%m-%dT%H:%M:%fZ','now'))",
                                    [kind, &key],
                                )?;
                            }
                        }
                    }
                }
                set(&tx, "hlc", &clock.to_string())?;
                set(&tx, "library", library["library_id"].as_str().unwrap_or(""))?;
                set(&tx, "record", "1")?;
                tx.commit()?;
                drop(c);
                let _ = lib.load_vocabulary();
                lib.chats.publish(
                    &json!({"v":1,"event":"library","refs":[],"notes":[],"reload":true})
                        .to_string(),
                );
            }
            _ => bail!("Unknown sync mode {mode}"),
        }
        drop(_guard);
        self.run(lib)?;
        self.status_json()
    }

    pub fn conflicts(&self, lib: &Library) -> Result<Value> {
        let c = crate::db::read_connection(&lib.path)?;
        let mut stmt = c.prepare(
            "SELECT id,kind,ref_id,summary,detail,created_at FROM sync_conflicts ORDER BY created_at DESC",
        )?;
        let rows = stmt
            .query_map([], |r| {
                Ok(json!({"id":r.get::<_, String>(0)?,"kind":r.get::<_, String>(1)?,"ref_id":r.get::<_, Option<String>>(2)?,
                    "summary":r.get::<_, String>(3)?,"detail":serde_json::from_str::<Value>(&r.get::<_, String>(4)?).unwrap_or(Value::Null),
                    "created_at":r.get::<_, String>(5)?}))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(json!({"conflicts": rows}))
    }

    /// Settles a conflict with the user's choice, through ordinary edits that sync.
    pub fn resolve(&self, lib: &Library, a: &Value) -> Result<Value> {
        let id = crate::db::required(a, "id")?;
        let action = crate::db::required(a, "action")?;
        let (kind, detail): (String, String) = {
            let c = crate::db::read_connection(&lib.path)?;
            c.query_row(
                "SELECT kind,detail FROM sync_conflicts WHERE id=?",
                [id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?
            .context("This conflict was already settled")?
        };
        let detail: Value = serde_json::from_str(&detail)?;
        let mut ref_id = Value::Null;
        match (kind.as_str(), action) {
            (_, "dismiss") | ("note_copy", "keep_both") => {}
            ("note_copy", "keep_other") | ("note_copy", "keep_this") => {
                let copy = detail["copy_id"].as_str().unwrap_or("");
                let original = detail["note_id"].as_str().unwrap_or("");
                let read = |id: &str| -> Result<Option<Value>> {
                    let c = crate::db::read_connection(&lib.path)?;
                    Ok(crate::db::note(&c, id).ok())
                };
                if action == "keep_this"
                    && let (Some(o), Some(cp)) = (read(original)?, read(copy)?)
                {
                    lib.call("update_note", &json!({"id":original,"expected_revision":o["revision"],"body":cp["body"],
                        "labels":cp["labels"],"evidence":cp["evidence"],"provenance":cp["provenance"],"project_id":o["project_id"]}))?;
                }
                if let Some(cp) = read(copy)? {
                    lib.call("delete_note", &json!({"id":copy,"expected_revision":cp["revision"],"confirm_ref_id":cp["ref_id"],
                        "idempotency_key":format!("sync-resolve-{id}")}))?;
                }
            }
            ("deleted", "restore") => {
                let w = lib.writer.lock().unwrap();
                ref_id = json!(apply::restore(&w, &detail)?);
                drop(w);
                let _ = lib.load_vocabulary();
            }
            _ => bail!("Unknown choice {action}"),
        }
        lib.writer
            .lock()
            .unwrap()
            .execute("DELETE FROM sync_conflicts WHERE id=?", [id])?;
        self.nudge();
        Ok(json!({"id":id,"resolved":true,"ref_id":ref_id}))
    }

    /// Downloads every PDF that is only in the storage.
    pub fn download_all(&self, lib: &Library) -> Result<Value> {
        let ids: Vec<String> = {
            let c = crate::db::read_connection(&lib.path)?;
            c.prepare(
                "SELECT id FROM attachments WHERE file_type='pdf' AND path LIKE 'omabib-sync:%'",
            )?
            .query_map([], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?
        };
        let mut done = 0;
        let mut failed = Vec::new();
        for (i, id) in ids.iter().enumerate() {
            self.progress("Downloading PDFs", i, ids.len());
            match fetch_attachment(lib, id) {
                Ok(Some(_)) => done += 1,
                Ok(None) => {}
                Err(e) => failed.push(format!("{e:#}")),
            }
        }
        self.set_status(
            "idle",
            &format!("Downloaded {done} PDF{}", if done == 1 { "" } else { "s" }),
        );
        Ok(json!({"downloaded":done,"failed":failed}))
    }

    /// Stops syncing this computer. The library itself is left as it is.
    pub fn disconnect(&self, lib: &Library) -> Result<Value> {
        let _guard = self.cycle.lock().unwrap();
        if let Some(job) = self.connect.lock().unwrap().take() {
            job.cancel();
        }
        let provider = {
            let w = lib.writer.lock().unwrap();
            let p = get(&w, "provider")?;
            reset(&w)?;
            w.execute("DELETE FROM sync_state WHERE key='provider'", [])?;
            p
        };
        if let Some(p) = provider.and_then(|p| serde_json::from_str::<Value>(&p).ok())
            && p["kind"] == "rclone"
            && p["remote"] == "omabib"
            && let Some(bin) = store::rclone_binary()
        {
            let _ = std::process::Command::new(bin)
                .arg("--config")
                .arg(rclone_config())
                .args(["config", "delete", "omabib"])
                .output();
        }
        *self.status.lock().unwrap() = Status {
            state: "off".into(),
            ..Default::default()
        };
        self.status_json()
    }
}

/// Forgets everything about a previous sync except where to sync.
fn reset(c: &Connection) -> Result<()> {
    c.execute_batch(
        "DELETE FROM sync_outbox; DELETE FROM sync_base; DELETE FROM sync_batches; DELETE FROM sync_uploads; DELETE FROM sync_aliases; DELETE FROM sync_parked; \
         DELETE FROM sync_state WHERE key NOT IN ('provider');",
    )?;
    set(c, "record", "0")
}

/// Empties the synced tables before a replace. Chats go with their papers.
fn clear_library(c: &Connection) -> Result<()> {
    c.execute_batch(
        "DELETE FROM chat_events; DELETE FROM chats; DELETE FROM note_revisions; DELETE FROM note_images; DELETE FROM docs; \
         DELETE FROM notes; DELETE FROM attachments; DELETE FROM associations; DELETE FROM external_summaries; \
         DELETE FROM refs; DELETE FROM projects;",
    )?;
    Ok(())
}

fn backup(lib: &Library, why: &str) -> Result<PathBuf> {
    let dir = lib.path.parent().unwrap().join("backups");
    std::fs::create_dir_all(&dir)?;
    let stamp = records::now().replace([':', '.'], "-");
    let path = dir.join(format!("before-sync-{why}-{stamp}.db"));
    lib.call("backup", &json!({"path":path}))?;
    // Keep the three newest sync backups.
    let mut old: Vec<PathBuf> = std::fs::read_dir(&dir)?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.starts_with("before-sync-") && n.ends_with(".db"))
        })
        .collect();
    old.sort();
    while old.len() > 3 {
        let _ = std::fs::remove_file(old.remove(0));
    }
    Ok(path)
}

fn latest_snapshot(store: &dyn Store) -> Result<Option<String>> {
    Ok(store
        .list("snapshots")?
        .into_iter()
        .map(|e| e.name)
        .filter(|n| n.ends_with(".jsonl.gz"))
        .max())
}

/// Writes the whole synced state, so another computer can join from it.
fn write_snapshot(lib: &Library, store: &dyn Store, me: &str) -> Result<()> {
    let c = crate::db::read_connection(&lib.path)?;
    let mut stmt = c.prepare("SELECT kind,key FROM sync_base ORDER BY kind,key")?;
    let keys: Vec<(String, String)> = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<rusqlite::Result<_>>()?;
    let mut rows = Vec::with_capacity(keys.len());
    for (kind, key) in keys {
        if let Some(b) = apply::load_base(&c, &kind, &key)? {
            rows.push((kind, key, b));
        }
    }
    let mut watermarks = serde_json::Map::new();
    let mut stmt = c.prepare("SELECT key,value FROM sync_state WHERE key LIKE 'wm:%'")?;
    for row in stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))? {
        let (k, v) = row?;
        watermarks.insert(k[3..].to_string(), json!(v.parse::<i64>().unwrap_or(0)));
    }
    watermarks.insert(me.into(), json!(get_i64(&c, "uploaded")?));
    let aliases: Vec<Value> = c
        .prepare("SELECT kind,key,target FROM sync_aliases ORDER BY kind,key")?
        .query_map([], |r| {
            Ok(json!([
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?
            ]))
        })?
        .collect::<rusqlite::Result<_>>()?;
    let live = |kind: &str| {
        rows.iter()
            .filter(|(k, _, b)| k == kind && b.deleted.is_none())
            .count()
    };
    let hlc = get(&c, "hlc")?.unwrap_or_default();
    let header = json!({"format":format::FORMAT,"device":me,"hlc":hlc,"created":records::now(),
        "watermarks":watermarks,"aliases":aliases,"counts":{"references":live("ref"),"notes":live("note"),"pdfs":live("attachment"),"projects":live("project")}});
    let bytes = format::write_snapshot(&header, &rows)?;
    let name = format!("{}-{me}.jsonl.gz", hlc.split('.').next().unwrap_or("0"));
    store.write(&format!("snapshots/{name}"), &bytes)?;
    // Keep this computer's two newest snapshots.
    let mine: Vec<String> = store
        .list("snapshots")?
        .into_iter()
        .map(|e| e.name)
        .filter(|n| n.ends_with(&format!("-{me}.jsonl.gz")))
        .collect();
    for old in mine.iter().rev().skip(2) {
        store.remove(&format!("snapshots/{old}"))?;
    }
    Ok(())
}

/// Clip images named by incoming changes that this computer doesn't have.
fn fetch_clips<'a>(
    lib: &Library,
    store: &dyn Store,
    changes: impl Iterator<Item = &'a Change>,
) -> Result<HashMap<String, Vec<u8>>> {
    let c = crate::db::read_connection(&lib.path)?;
    let mut clips = HashMap::new();
    for ch in changes {
        if ch.kind != "image" {
            continue;
        }
        let Some(sha) = ch.fields.get("sha256").and_then(Value::as_str) else {
            continue;
        };
        if clips.contains_key(sha)
            || c.query_row(
                "SELECT 1 FROM note_images WHERE sha256=?",
                [sha],
                |_| Ok(()),
            )
            .optional()?
            .is_some()
        {
            continue;
        }
        clips.insert(sha.to_string(), store.read(&format!("clips/{sha}.png"))?);
    }
    Ok(clips)
}

/// Downloads a PDF that is only in the sync storage, for `get_pdf`. None when
/// sync isn't on or this attachment was never uploaded.
pub fn fetch_attachment(lib: &Library, attachment_id: &str) -> Result<Option<PathBuf>> {
    let (provider, blob, sha, citekey) = {
        let c = crate::db::read_connection(&lib.path)?;
        let Some(provider) =
            get(&c, "provider")?.and_then(|p| serde_json::from_str::<Value>(&p).ok())
        else {
            return Ok(None);
        };
        let Some(b) = apply::load_base(&c, "attachment", attachment_id)? else {
            return Ok(None);
        };
        let (Some(blob), Some(sha)) = (
            b.data
                .get("blob")
                .and_then(Value::as_str)
                .map(str::to_owned),
            b.data
                .get("sha256")
                .and_then(Value::as_str)
                .map(str::to_owned),
        ) else {
            return Ok(None);
        };
        let citekey: String = c
            .query_row(
                "SELECT r.citekey FROM attachments a JOIN refs r ON r.id=a.ref_id WHERE a.id=?",
                [attachment_id],
                |r| r.get(0),
            )
            .optional()?
            .unwrap_or_else(|| "reference".into());
        (provider, blob, sha, citekey)
    };
    let store = open_store(&provider)?;
    let temporary = crate::attachments::temp(lib)?;
    let result = (|| {
        store.download(&blob, &temporary)?;
        let (path, hash) = crate::attachments::finish(lib, &temporary, &citekey)?;
        ensure!(
            hash == sha,
            "The PDF in the sync storage doesn't match its record"
        );
        Ok(path)
    })();
    if temporary.exists() {
        let _ = std::fs::remove_file(&temporary);
    }
    let path = result?;
    let w = lib.writer.lock().unwrap();
    // Another link of this paper to the same file may already have the path.
    w.execute(
        "UPDATE OR IGNORE attachments SET path=? WHERE id=?",
        params![path.to_string_lossy(), attachment_id],
    )?;
    // Clips from this PDF can be drawn on it again.
    w.execute(
        "UPDATE note_images SET source_pdf=? WHERE source_sha256=? AND source_pdf=''",
        params![path.to_string_lossy(), sha],
    )?;
    Ok(Some(path))
}

#[cfg(test)]
mod upload_tests {
    use super::*;

    #[test]
    fn failed_batch_stays_queued_and_can_be_retried() {
        let dir = tempfile::tempdir().unwrap();
        let lib = Library::open_with_vocabulary(dir.path().join("library.db"), false).unwrap();
        let reference = lib
            .call(
                "import_bibtex",
                &json!({"bibtex":"@article{batch,title={Batch}}"}),
            )
            .unwrap();
        let rid = reference["items"][0]["id"].as_str().unwrap();
        for i in 0..9 {
            let local = dir.path().join(format!("{i}.pdf"));
            std::fs::write(&local, format!("pdf {i}")).unwrap();
            let c = lib.writer.lock().unwrap();
            c.execute(
                "INSERT INTO attachments(id,ref_id,path,file_type) VALUES(?,?,?,'pdf')",
                params![format!("a{i}"), rid, local.to_string_lossy()],
            )
            .unwrap();
            c.execute(
                "INSERT INTO sync_uploads(path,kind,key) VALUES(?,'attachment',?)",
                params![format!("pdfs/{i}.pdf"), format!("a{i}")],
            )
            .unwrap();
        }
        let broken = dir.path().join("not-a-directory");
        std::fs::write(&broken, b"blocked").unwrap();
        assert!(
            lib.sync
                .upload(&lib, &FolderStore { root: broken }, "test")
                .is_err()
        );
        let count = || {
            lib.writer
                .lock()
                .unwrap()
                .query_row("SELECT count(*) FROM sync_uploads", [], |r| {
                    r.get::<_, i64>(0)
                })
                .unwrap()
        };
        assert_eq!(count(), 9);
        let good = FolderStore {
            root: dir.path().join("cloud"),
        };
        lib.sync.upload(&lib, &good, "test").unwrap();
        assert_eq!(count(), 0);
        for i in 0..9 {
            assert_eq!(
                good.read(&format!("pdfs/{i}.pdf")).unwrap(),
                format!("pdf {i}").as_bytes()
            );
        }
    }

    #[test]
    fn duplicate_sync_preserves_active_status() {
        let dir = tempfile::tempdir().unwrap();
        let lib = Library::open_with_vocabulary(dir.path().join("library.db"), false).unwrap();
        let sync = &lib.sync;
        let _guard = sync.cycle.lock().unwrap();
        sync.set_status("syncing", "Uploading your library");
        sync.progress("Uploading files", 8, 16);
        let before = sync.status_json().unwrap();
        let result = lib.call("sync_now", &json!({})).unwrap();
        assert_eq!(result["already_running"], true);
        assert_eq!(sync.status_json().unwrap(), before);
        let status = sync.status.lock().unwrap();
        assert!(status.last_attempt.is_none());
        assert!(status.retry_after.is_none());
    }
}
