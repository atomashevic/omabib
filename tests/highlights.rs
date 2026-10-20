//! Highlight storage and the annotation sidecar. Temp directories only.
use omabib::db::{Library, read_connection};
use omabib::highlights;
use omabib::sync::format;
use rusqlite::Connection;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

fn one_page_pdf(path: &Path, text: &str) {
    let content = format!("BT /F1 24 Tf 72 700 Td ({text}) Tj ET\n").into_bytes();
    let objects: Vec<Vec<u8>> = vec![
        b"<< /Type /Catalog /Pages 2 0 R >>".to_vec(),
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>".to_vec(),
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>".to_vec(),
        [format!("<< /Length {} >>\nstream\n", content.len()).into_bytes(), content, b"\nendstream".to_vec()].concat(),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".to_vec(),
    ];
    let mut data = b"%PDF-1.4\n".to_vec();
    let mut offsets = vec![];
    for (i, object) in objects.iter().enumerate() {
        offsets.push(data.len());
        data.extend(format!("{} 0 obj\n", i + 1).bytes());
        data.extend(object);
        data.extend(b"\nendobj\n");
    }
    let xref = data.len();
    data.extend(format!("xref\n0 {}\n0000000000 65535 f \n", objects.len() + 1).bytes());
    for offset in offsets {
        data.extend(format!("{offset:010} 00000 n \n").bytes());
    }
    data.extend(
        format!(
            "trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n",
            objects.len() + 1
        )
        .bytes(),
    );
    std::fs::write(path, data).unwrap();
}

fn user_version(path: &Path) -> i64 {
    read_connection(path)
        .unwrap()
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .unwrap()
}

fn before_highlights(dir: &Path) -> Vec<PathBuf> {
    let backups = dir.join("backups");
    let Ok(entries) = std::fs::read_dir(backups) else {
        return Vec::new();
    };
    let mut found: Vec<PathBuf> = entries
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.starts_with("before-highlights-") && n.ends_with(".db"))
        })
        .collect();
    found.sort();
    found
}

fn table_count(path: &Path, name: &str) -> i64 {
    read_connection(path)
        .unwrap()
        .query_row(
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?1",
            [name],
            |r| r.get(0),
        )
        .unwrap()
}

#[test]
fn user_version_stays_1_and_a_new_library_skips_the_backup() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("library.db");
    let _lib = Library::open_with_vocabulary(&path, false).unwrap();
    assert_eq!(user_version(&path), 1);
    assert_eq!(table_count(&path, "highlights"), 1);
    let fk: i64 = read_connection(&path)
        .unwrap()
        .query_row(
            "SELECT count(*) FROM pragma_foreign_key_list('highlights')",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(fk, 0, "a foreign key would stop an older client deleting a reference");
    assert!(
        before_highlights(dir.path()).is_empty(),
        "a brand-new library does not need a backup"
    );
}

#[test]
fn existing_library_gains_the_table_only_after_the_backup() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("library.db");
    {
        let _lib = Library::open_with_vocabulary(&path, false).unwrap();
    }
    Connection::open(&path)
        .unwrap()
        .execute_batch("DROP TABLE highlights")
        .unwrap();
    assert!(
        before_highlights(dir.path()).is_empty(),
        "dropping the table is not itself the backup"
    );
    let _lib = Library::open_with_vocabulary(&path, false).unwrap();
    let backups = before_highlights(dir.path());
    assert_eq!(backups.len(), 1, "the one-time backup");
    let backup = Connection::open(&backups[0]).unwrap();
    let backup_version: i64 = backup
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .unwrap();
    assert_eq!(backup_version, 1);
    let backed_up: i64 = backup
        .query_row(
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='highlights'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(
        backed_up, 0,
        "the backup file must be the library from before the table was created"
    );
    assert_eq!(table_count(&path, "highlights"), 1);
    assert_eq!(user_version(&path), 1);
    drop(_lib);
    let _again = Library::open_with_vocabulary(&path, false).unwrap();
    assert_eq!(
        before_highlights(dir.path()).len(),
        1,
        "a later open leaves the backup in place and does not take another"
    );
}

struct Computer {
    dir: tempfile::TempDir,
    lib: Library,
}

impl Computer {
    fn new(shared: &Path) -> Computer {
        let dir = tempfile::tempdir().unwrap();
        let lib = Library::open_with_vocabulary(dir.path().join("library.db"), false).unwrap();
        lib.call("sync_connect", &json!({"provider":"folder","path":shared}))
            .unwrap();
        Computer { dir, lib }
    }
    fn call(&self, method: &str, a: Value) -> Value {
        self.lib
            .call(method, &a)
            .unwrap_or_else(|e| panic!("{method}: {e:#}"))
    }
    fn sync(&self) -> Value {
        self.call("sync_now", json!({}))
    }
    fn import(&self, bibtex: &str) -> String {
        self.call("import_bibtex", json!({"bibtex":bibtex}))["items"][0]["id"]
            .as_str()
            .unwrap()
            .to_string()
    }
    fn device(&self) -> String {
        self.state("device")
    }
    fn state(&self, key: &str) -> String {
        read_connection(&self.lib.path)
            .unwrap()
            .query_row("SELECT value FROM sync_state WHERE key=?", [key], |r| {
                r.get(0)
            })
            .unwrap()
    }
    fn state_i64(&self, key: &str) -> i64 {
        read_connection(&self.lib.path)
            .unwrap()
            .query_row(
                "SELECT value FROM sync_state WHERE key=?",
                [key],
                |r| r.get::<_, String>(0),
            )
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(0)
    }
}

fn settle(computers: &[&Computer]) {
    for _ in 0..8 {
        let mut quiet = true;
        for c in computers {
            let r = c.sync();
            quiet &= r["sent"] == 0 && r["received"] == 0;
        }
        if quiet {
            return;
        }
    }
    panic!("the computers kept exchanging changes");
}

fn batch_files(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let Ok(devices) = std::fs::read_dir(dir) else {
        return out;
    };
    for device in devices.flatten() {
        if !device.path().is_dir() {
            continue;
        }
        for file in std::fs::read_dir(device.path()).unwrap().flatten() {
            let path = file.path();
            if path.to_string_lossy().ends_with(".jsonl.gz") {
                out.push(path);
            }
        }
    }
    out.sort();
    out
}

fn manifest(shared: &Path, device: &str) -> Value {
    let bytes = std::fs::read(shared.join(format!("Omabib/devices/{device}.json"))).unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

#[test]
fn two_libraries_sync_a_highlight_and_keep_both_field_edits() {
    let shared = tempfile::tempdir().unwrap();
    let a = Computer::new(shared.path());
    let rid = a.import("@article{okafor_sparse_2026,title={Sparse attention is enough}}");
    let pdf = a.dir.path().join("paper.pdf");
    one_page_pdf(&pdf, "Sparse attention is enough");
    let pdf_bytes = std::fs::read(&pdf).unwrap();
    let attachment = a.call("add_pdf", json!({"ref_id": &rid, "path": &pdf}))["id"]
        .as_str()
        .unwrap()
        .to_string();
    a.call("sync_start", json!({"mode":"new"}));
    let b = Computer::new(shared.path());
    b.call("sync_start", json!({"mode":"join"}));

    let seq_before = a.state_i64("seq");
    let manifest_before = manifest(shared.path(), &a.device());
    let main_before = batch_files(&shared.path().join("Omabib/changes"));
    let highlight = highlights::create(
        &a.lib,
        &rid,
        &attachment,
        1,
        &[[72.0, 680.0, 240.0, 710.0]],
        "line one\nline two",
    )
    .unwrap();
    let id = highlight["id"].as_str().unwrap().to_string();
    assert_eq!(highlight["color"], "yellow");
    assert_eq!(highlight["comment"], "");
    assert_eq!(highlight["quote"], "line one\nline two");
    let created_at = highlight["created_at"].as_str().unwrap().to_string();

    a.sync();
    b.sync();
    assert_eq!(a.state_i64("seq"), seq_before, "a highlight must not advance the main sequence");
    assert!(a.state_i64("ann_seq") > 0);
    let manifest_after = manifest(shared.path(), &a.device());
    assert_eq!(manifest_after["seq"], manifest_before["seq"]);
    assert!(manifest_after["ann_seq"].as_i64().unwrap() > manifest_before["ann_seq"].as_i64().unwrap_or(0));
    assert_eq!(
        batch_files(&shared.path().join("Omabib/changes")),
        main_before,
        "a highlight-only edit writes no main batch"
    );
    let ann_files = batch_files(&shared.path().join("Omabib/annotations/changes"));
    assert!(!ann_files.is_empty(), "the highlight travels in the sidecar");
    for path in &ann_files {
        let (header, changes) = format::read_batch(&std::fs::read(path).unwrap()).unwrap();
        assert_eq!(header["format"], 1);
        assert!(changes.iter().all(|c| c.kind == "highlight"));
    }
    let on_b = highlights::get(&b.lib, &id).unwrap().unwrap();
    assert_eq!(on_b["quote"], "line one\nline two");
    assert_eq!(on_b["color"], "yellow");
    let created_clock = clocks(&a, &id)["created_at"].as_str().unwrap().to_string();

    // A main batch, written after the highlight, stays format 1 and has no highlight line.
    a.call(
        "add_note",
        json!({"ref_id": &rid, "project_id": null, "body": "A note", "provenance": "human"}),
    );
    a.sync();
    b.sync();
    let main_files = batch_files(&shared.path().join("Omabib/changes"));
    assert!(main_files.len() > main_before.len());
    for path in &main_files {
        let (header, changes) = format::read_batch(&std::fs::read(path).unwrap()).unwrap();
        assert_eq!(header["format"], 1, "{path:?}");
        assert!(
            changes.iter().all(|c| c.kind != "highlight"),
            "main batch contains a highlight: {path:?}"
        );
    }

    highlights::update(&a.lib, &id, Some("red"), None).unwrap();
    highlights::update(&b.lib, &id, None, Some("see the figure")).unwrap();
    settle(&[&a, &b]);
    let left = highlights::get(&a.lib, &id).unwrap().unwrap();
    let right = highlights::get(&b.lib, &id).unwrap().unwrap();
    assert_eq!(left["color"], "red");
    assert_eq!(right["color"], "red");
    assert_eq!(left["comment"], "see the figure");
    assert_eq!(right["comment"], "see the figure");
    assert_eq!(left["created_at"], created_at);
    assert_eq!(right["created_at"], created_at);
    assert_eq!(left["quote"], "line one\nline two");
    assert_eq!(left["updated_at"], right["updated_at"]);
    let synced = clocks(&a, &id);
    assert_eq!(clocks(&b, &id), synced);
    assert_eq!(synced["created_at"], created_clock);
    assert!(synced["color"].as_str().unwrap().ends_with(&a.device()));
    assert!(synced["comment"].as_str().unwrap().ends_with(&b.device()));
    let later = synced["color"]
        .as_str()
        .unwrap()
        .max(synced["comment"].as_str().unwrap());
    assert_eq!(synced["updated_at"], later);
    let in_main: i64 = read_connection(&a.lib.path)
        .unwrap()
        .query_row(
            "SELECT count(*) FROM sync_base WHERE kind='highlight'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(in_main, 0, "highlight rows stay out of sync_base");

    let preview = a.call("delete_reference_preview", json!({"id": &rid}));
    a.call(
        "delete_reference",
        json!({"id": &rid, "expected_revision": preview["revision"], "confirm_citekey": preview["citekey"],
            "expected_notes": preview["note_count"], "expected_attachments": preview["attachment_count"],
            "idempotency_key": "delete-the-highlighted-reference"}),
    );
    settle(&[&a, &b]);
    assert!(highlights::get(&a.lib, &id).unwrap().is_none());
    assert!(highlights::get(&b.lib, &id).unwrap().is_none());
    let gone: Option<String> = read_connection(&b.lib.path)
        .unwrap()
        .query_row(
            "SELECT deleted FROM ann_base WHERE kind='highlight' AND key=?",
            [&id],
            |r| r.get(0),
        )
        .unwrap();
    assert!(gone.is_some(), "the other computer keeps the tombstone");
    let ann_after = batch_files(&shared.path().join("Omabib/annotations/changes"));
    let tombstoned = ann_after.iter().any(|path| {
        let (_, changes) = format::read_batch(&std::fs::read(path).unwrap()).unwrap();
        changes
            .iter()
            .any(|c| c.kind == "highlight" && c.key == id && c.deleted.is_some())
    });
    assert!(tombstoned, "deleting the reference tombstones its highlights");
    for path in batch_files(&shared.path().join("Omabib/changes")) {
        let (header, changes) = format::read_batch(&std::fs::read(path).unwrap()).unwrap();
        assert_eq!(header["format"], 1);
        assert!(changes.iter().all(|c| c.kind != "highlight"));
    }
    assert_eq!(std::fs::read(&pdf).unwrap(), pdf_bytes);
    assert_eq!(user_version(&a.lib.path), 1);
    assert_eq!(user_version(&b.lib.path), 1);
}

fn clocks(c: &Computer, id: &str) -> serde_json::Map<String, Value> {
    let raw: String = read_connection(&c.lib.path)
        .unwrap()
        .query_row(
            "SELECT clocks FROM ann_base WHERE kind='highlight' AND key=?",
            [id],
            |r| r.get(0),
        )
        .unwrap();
    serde_json::from_str(&raw).unwrap()
}

#[test]
fn an_older_format_1_batch_still_applies_without_a_sidecar() {
    let shared = tempfile::tempdir().unwrap();
    let a = Computer::new(shared.path());
    let id = a.import("@article{k,title={Old title},author={Doe, J.},year={2020}}");
    a.call("sync_start", json!({"mode":"new"}));
    let ann = shared.path().join("Omabib/annotations");
    if ann.exists() {
        std::fs::remove_dir_all(&ann).unwrap();
    }
    let b = Computer::new(shared.path());
    b.call("sync_start", json!({"mode":"join"}));
    assert_eq!(
        b.call("get_reference", json!({"id": &id}))["title"],
        "Old title"
    );

    let mut ch = omabib::sync::apply::Change {
        kind: "ref".into(),
        key: id.clone(),
        device: "olddevice".into(),
        ..Default::default()
    };
    let hlc = "9999999999999.00000.olddevice";
    ch.fields.insert(
        "bibtex".into(),
        json!("@article{k,\nauthor = {Doe, J.},\ntitle = {Title from the old batch},\nyear = {2021},\n}"),
    );
    ch.fields
        .insert("title".into(), json!("Title from the old batch"));
    ch.fields.insert("year".into(), json!("2021"));
    ch.clocks = ch.fields.keys().map(|k| (k.clone(), hlc.into())).collect();
    let bytes = format::write_batch("olddevice", 1, "now", &[ch]).unwrap();
    let (header, changes) = format::read_batch(&bytes).unwrap();
    assert_eq!(header["format"], 1);
    assert!(changes.iter().all(|c| c.kind != "highlight"));
    let root = shared.path().join("Omabib");
    std::fs::create_dir_all(root.join("changes/olddevice")).unwrap();
    std::fs::write(root.join("changes/olddevice/0000000001.jsonl.gz"), bytes).unwrap();
    std::fs::write(
        root.join("devices/olddevice.json"),
        format!(r#"{{"device":"olddevice","name":"old","seq":1,"hlc":"{hlc}"}}"#),
    )
    .unwrap();
    settle(&[&a, &b]);
    for c in [&a, &b] {
        let r = c.call("get_reference", json!({"id": &id}));
        assert_eq!(r["title"], "Title from the old batch", "{r}");
        assert_eq!(user_version(&c.lib.path), 1);
    }
}

#[test]
fn deleting_a_reference_the_old_way_drops_highlights_on_the_next_open() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("library.db");
    let pdf = dir.path().join("paper.pdf");
    one_page_pdf(&pdf, "Keep these bytes");
    let pdf_bytes = std::fs::read(&pdf).unwrap();
    let highlight_id = {
        let lib = Library::open_with_vocabulary(&path, false).unwrap();
        let rid = lib
            .call(
                "import_bibtex",
                &json!({"bibtex":"@article{k,title={Kept}}"}),
            )
            .unwrap()["items"][0]["id"]
            .as_str()
            .unwrap()
            .to_string();
        let attachment = lib
            .call("add_pdf", &json!({"ref_id": &rid, "path": &pdf}))
            .unwrap()["id"]
            .as_str()
            .unwrap()
            .to_string();
        let highlight = highlights::create(
            &lib,
            &rid,
            &attachment,
            1,
            &[[10.0, 10.0, 40.0, 20.0]],
            "word",
        )
        .unwrap();
        let id = highlight["id"].as_str().unwrap().to_string();
        drop(lib);
        let c = Connection::open(&path).unwrap();
        c.execute_batch("PRAGMA foreign_keys=ON").unwrap();
        c.execute("DELETE FROM docs WHERE ref_id=?", [&rid]).unwrap();
        c.execute("DELETE FROM attachments WHERE ref_id=?", [&rid])
            .unwrap();
        assert_eq!(
            c.execute("DELETE FROM refs WHERE id=?", [&rid]).unwrap(),
            1,
            "an older client deletes the reference without a highlights foreign key"
        );
        let left: i64 = c
            .query_row("SELECT count(*) FROM highlights", [], |r| r.get(0))
            .unwrap();
        assert_eq!(left, 1, "the older client leaves the highlight row behind");
        id
    };
    let lib = Library::open_with_vocabulary(&path, false).unwrap();
    assert!(highlights::get(&lib, &highlight_id).unwrap().is_none());
    assert_eq!(user_version(&path), 1);
    assert_eq!(std::fs::read(&pdf).unwrap(), pdf_bytes);
}

#[test]
fn pdf_bytes_stay_untouched_by_creating_editing_and_deleting_a_highlight() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("library.db");
    let pdf = dir.path().join("paper.pdf");
    one_page_pdf(&pdf, "Do not rewrite me");
    let before = std::fs::read(&pdf).unwrap();
    let lib = Library::open_with_vocabulary(&path, false).unwrap();
    let rid = lib
        .call(
            "import_bibtex",
            &json!({"bibtex":"@article{k,title={Paper}}"}),
        )
        .unwrap()["items"][0]["id"]
        .as_str()
        .unwrap()
        .to_string();
    let attachment = lib
        .call("add_pdf", &json!({"ref_id": &rid, "path": &pdf}))
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();
    let highlight = highlights::create(
        &lib,
        &rid,
        &attachment,
        1,
        &[[1.0, 2.0, 3.0, 4.0], [5.0, 6.0, 7.0, 8.0]],
        "alpha\nbeta",
    )
    .unwrap();
    let id = highlight["id"].as_str().unwrap();
    highlights::update(&lib, id, Some("blue"), Some("a comment")).unwrap();
    highlights::delete(&lib, id).unwrap();
    assert_eq!(std::fs::read(&pdf).unwrap(), before);
    assert_eq!(user_version(&path), 1);
}
