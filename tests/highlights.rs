//! Highlight storage and the annotation sidecar. Temp directories only.
use omabib::db::{Library, read_connection};
use omabib::highlights;
use omabib::sync::apply::Change;
use omabib::sync::format;
use rusqlite::Connection;
use serde_json::{Map, Value, json};
use std::os::unix::fs::PermissionsExt;
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
fn existing_library_gains_the_highlights_table_without_a_backup() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("library.db");
    {
        let _lib = Library::open_with_vocabulary(&path, false).unwrap();
    }
    Connection::open(&path)
        .unwrap()
        .execute_batch("DROP TABLE highlights")
        .unwrap();
    assert!(before_highlights(dir.path()).is_empty());
    let _lib = Library::open_with_vocabulary(&path, false).unwrap();
    assert!(
        before_highlights(dir.path()).is_empty(),
        "adding the empty table does not write a backup"
    );
    assert_eq!(table_count(&path, "highlights"), 1);
    assert_eq!(user_version(&path), 1);
    drop(_lib);
    let _again = Library::open_with_vocabulary(&path, false).unwrap();
    assert!(before_highlights(dir.path()).is_empty());
    assert_eq!(user_version(&path), 1);
}

#[test]
fn existing_library_opens_when_the_backups_folder_is_unwritable() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("library.db");
    {
        let _lib = Library::open_with_vocabulary(&path, false).unwrap();
    }
    Connection::open(&path)
        .unwrap()
        .execute_batch("DROP TABLE highlights")
        .unwrap();
    let backups = dir.path().join("backups");
    std::fs::create_dir_all(&backups).unwrap();
    let mut perms = std::fs::metadata(&backups).unwrap().permissions();
    perms.set_mode(0o500);
    std::fs::set_permissions(&backups, perms).unwrap();
    struct WritableOnDrop<'a>(&'a Path);
    impl Drop for WritableOnDrop<'_> {
        fn drop(&mut self) {
            if let Ok(meta) = std::fs::metadata(self.0) {
                let mut perms = meta.permissions();
                perms.set_mode(0o700);
                let _ = std::fs::set_permissions(self.0, perms);
            }
        }
    }
    let _restore = WritableOnDrop(&backups);
    let _lib = Library::open_with_vocabulary(&path, false).unwrap();
    assert_eq!(table_count(&path, "highlights"), 1);
    assert_eq!(user_version(&path), 1);
    assert!(
        before_highlights(dir.path()).is_empty(),
        "an unwritable backups folder must not block open and must not be required"
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

fn add_highlight_on(c: &Computer, citekey: &str, title: &str) -> (String, String, String) {
    let rid = c.import(&format!("@article{{{citekey},title={{{title}}}}}"));
    let pdf = c.dir.path().join(format!("{citekey}.pdf"));
    one_page_pdf(&pdf, title);
    let attachment = c.call("add_pdf", json!({"ref_id": &rid, "path": &pdf}))["id"]
        .as_str()
        .unwrap()
        .to_string();
    let id = highlights::create(
        &c.lib,
        &rid,
        &attachment,
        1,
        &[[72.0, 680.0, 240.0, 710.0]],
        title,
    )
    .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();
    (rid, attachment, id)
}

fn count_sql(path: &Path, sql: &str) -> i64 {
    read_connection(path)
        .unwrap()
        .query_row(sql, [], |r| r.get(0))
        .unwrap()
}

fn stamped(kind: &str, key: &str, device: &str, hlc: &str, fields: Map<String, Value>) -> Change {
    let clocks = fields
        .keys()
        .map(|k| (k.clone(), hlc.to_string()))
        .collect();
    Change {
        kind: kind.into(),
        key: key.into(),
        fields,
        clocks,
        device: device.into(),
        ..Default::default()
    }
}

fn highlight_fields(ref_id: Option<&str>, quote: &str) -> Map<String, Value> {
    let mut fields = Map::new();
    if let Some(ref_id) = ref_id {
        fields.insert("ref_id".into(), json!(ref_id));
    }
    fields.insert("attachment_id".into(), json!("att-1"));
    fields.insert("source_sha256".into(), json!("abc"));
    fields.insert("page".into(), json!(1));
    fields.insert("rects".into(), json!([[10.0, 20.0, 30.0, 40.0]]));
    fields.insert("quote".into(), json!(quote));
    fields.insert("color".into(), json!("yellow"));
    fields.insert("comment".into(), json!(""));
    fields.insert("created_at".into(), json!("2026-01-01T00:00:00.000Z"));
    fields.insert("updated_at".into(), json!("2026-01-01T00:00:00.000Z"));
    fields
}

/// Writes `main` and `ann` only when provided, then sets this device's manifest.
fn write_remote(
    shared: &Path,
    device: &str,
    seq: i64,
    ann_seq: i64,
    main: Option<&[Change]>,
    ann: Option<&[Change]>,
) {
    let root = shared.join("Omabib");
    if let Some(main) = main {
        let dir = root.join(format!("changes/{device}"));
        std::fs::create_dir_all(&dir).unwrap();
        let bytes = format::write_batch(device, seq, "now", main).unwrap();
        std::fs::write(dir.join(format!("{seq:010}.jsonl.gz")), bytes).unwrap();
    }
    if let Some(ann) = ann {
        let dir = root.join(format!("annotations/changes/{device}"));
        std::fs::create_dir_all(&dir).unwrap();
        let bytes = format::write_batch(device, ann_seq, "now", ann).unwrap();
        std::fs::write(dir.join(format!("{ann_seq:010}.jsonl.gz")), bytes).unwrap();
    }
    std::fs::write(
        root.join(format!("devices/{device}.json")),
        json!({
            "device": device,
            "name": device,
            "seq": seq,
            "ann_seq": ann_seq,
            "hlc": format!("0000000009000.00000.{device}"),
        })
        .to_string(),
    )
    .unwrap();
}

#[test]
fn join_through_the_sidecar_snapshot_exchanges_later_edits() {
    let shared = tempfile::tempdir().unwrap();
    let a = Computer::new(shared.path());
    let (_rid, _attachment, id) = add_highlight_on(&a, "before", "Before join");
    a.call("sync_start", json!({"mode": "new"}));
    let snaps = std::fs::read_dir(shared.path().join("Omabib/annotations/snapshots")).unwrap();
    assert!(
        snaps
            .flatten()
            .any(|e| e.file_name().to_string_lossy().ends_with(".jsonl.gz")),
        "the highlight is in the sidecar snapshot"
    );
    let b = Computer::new(shared.path());
    b.call("sync_start", json!({"mode": "join"}));
    let joined = highlights::get(&b.lib, &id)
        .unwrap()
        .expect("join absorbs the sidecar snapshot");
    assert_eq!(joined["quote"], "Before join");
    assert_eq!(joined["color"], "yellow");
    let rid = joined["ref_id"].as_str().unwrap().to_string();
    let attachment = joined["attachment_id"].as_str().unwrap().to_string();

    highlights::update(&a.lib, &id, Some("green"), None).unwrap();
    let second = highlights::create(
        &b.lib,
        &rid,
        &attachment,
        1,
        &[[10.0, 10.0, 40.0, 20.0]],
        "From B",
    )
    .unwrap();
    let second_id = second["id"].as_str().unwrap().to_string();
    settle(&[&a, &b]);
    for c in [&a, &b] {
        let first = highlights::get(&c.lib, &id).unwrap().unwrap();
        let other = highlights::get(&c.lib, &second_id).unwrap().unwrap();
        assert_eq!(first["color"], "green", "{}", c.device());
        assert_eq!(first["quote"], "Before join");
        assert_eq!(other["quote"], "From B");
        assert_eq!(other["ref_id"], rid);
    }
    assert!(a.state_i64(&format!("awm:{}", b.device())) >= 1);
    assert!(b.state_i64(&format!("awm:{}", a.device())) >= 1);
}

#[test]
fn merge_keeps_highlights_from_both_libraries() {
    let shared = tempfile::tempdir().unwrap();
    let a = Computer::new(shared.path());
    let (_rid_a, _, id_a) = add_highlight_on(&a, "alpha", "Alpha paper");
    a.call("sync_start", json!({"mode": "new"}));
    let b = Computer::new(shared.path());
    let (_rid_b, _, id_b) = add_highlight_on(&b, "beta", "Beta paper");
    b.call("sync_start", json!({"mode": "merge"}));
    settle(&[&a, &b]);
    for c in [&a, &b] {
        assert_eq!(
            highlights::get(&c.lib, &id_a).unwrap().unwrap()["quote"],
            "Alpha paper"
        );
        assert_eq!(
            highlights::get(&c.lib, &id_b).unwrap().unwrap()["quote"],
            "Beta paper"
        );
    }
}

#[test]
fn a_highlight_for_a_missing_reference_stays_parked_until_it_arrives() {
    let shared = tempfile::tempdir().unwrap();
    let a = Computer::new(shared.path());
    a.call("sync_start", json!({"mode": "new"}));
    let ref_id = "ref-arrives-later";
    let hid = "hl-waiting";
    let hlc = "0000000005000.00000.other";
    let highlight = stamped(
        "highlight",
        hid,
        "other",
        hlc,
        highlight_fields(Some(ref_id), "waiting"),
    );
    write_remote(shared.path(), "other", 0, 1, None, Some(&[highlight]));
    a.sync();
    assert!(highlights::get(&a.lib, hid).unwrap().is_none());
    assert_eq!(count_sql(&a.lib.path, "SELECT count(*) FROM highlights"), 0);
    assert_eq!(count_sql(&a.lib.path, "SELECT count(*) FROM ann_parked"), 1);

    let mut ref_fields = Map::new();
    ref_fields.insert("citekey".into(), json!("arriveslater"));
    ref_fields.insert(
        "bibtex".into(),
        json!("@article{arriveslater,title={Arrives later},author={Doe, J.},year={2024}}"),
    );
    ref_fields.insert("title".into(), json!("Arrives later"));
    ref_fields.insert("entry_type".into(), json!("article"));
    ref_fields.insert("authors".into(), json!("Doe, J."));
    ref_fields.insert("abstract".into(), json!(""));
    ref_fields.insert("year".into(), json!("2024"));
    ref_fields.insert("source".into(), json!(""));
    ref_fields.insert("fields".into(), json!({}));
    let reference = stamped(
        "ref",
        ref_id,
        "other",
        "0000000006000.00000.other",
        ref_fields,
    );
    write_remote(shared.path(), "other", 1, 1, Some(&[reference]), None);
    a.sync();
    let row = highlights::get(&a.lib, hid).unwrap().expect("the highlight lands");
    assert_eq!(row["ref_id"], ref_id);
    assert_eq!(row["quote"], "waiting");
    assert_eq!(count_sql(&a.lib.path, "SELECT count(*) FROM ann_parked"), 0);
    assert_eq!(
        a.call("get_reference", json!({"id": ref_id}))["title"],
        "Arrives later"
    );
}

#[test]
fn a_highlight_change_with_no_reference_is_parked() {
    let shared = tempfile::tempdir().unwrap();
    let a = Computer::new(shared.path());
    a.call("sync_start", json!({"mode": "new"}));
    let hid = "hl-no-ref";
    let highlight = stamped(
        "highlight",
        hid,
        "other",
        "0000000005000.00000.other",
        highlight_fields(None, "orphan"),
    );
    write_remote(shared.path(), "other", 0, 1, None, Some(&[highlight]));
    a.sync();
    assert!(highlights::get(&a.lib, hid).unwrap().is_none());
    assert_eq!(
        count_sql(&a.lib.path, "SELECT count(*) FROM highlights WHERE ref_id=''"),
        0
    );
    assert_eq!(count_sql(&a.lib.path, "SELECT count(*) FROM ann_parked"), 1);
}

#[test]
fn a_recording_library_tombstones_highlights_deleted_the_old_way() {
    let shared = tempfile::tempdir().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("library.db");
    let pdf = dir.path().join("paper.pdf");
    one_page_pdf(&pdf, "Recorded");
    let (rid, highlight_id) = {
        let lib = Library::open_with_vocabulary(&path, false).unwrap();
        lib.call(
            "sync_connect",
            &json!({"provider": "folder", "path": shared.path()}),
        )
        .unwrap();
        let rid = lib
            .call(
                "import_bibtex",
                &json!({"bibtex": "@article{oldway,title={Recorded}}"}),
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
        let id = highlights::create(
            &lib,
            &rid,
            &attachment,
            1,
            &[[10.0, 10.0, 40.0, 20.0]],
            "Recorded",
        )
        .unwrap()["id"]
            .as_str()
            .unwrap()
            .to_string();
        lib.call("sync_start", &json!({"mode": "new"})).unwrap();
        (rid, id)
    };
    {
        let c = Connection::open(&path).unwrap();
        c.execute_batch("PRAGMA foreign_keys=ON").unwrap();
        c.execute("DELETE FROM docs WHERE ref_id=?", [&rid]).unwrap();
        c.execute("DELETE FROM attachments WHERE ref_id=?", [&rid])
            .unwrap();
        assert_eq!(
            c.execute("DELETE FROM refs WHERE id=?", [&rid]).unwrap(),
            1
        );
        let left: i64 = c
            .query_row("SELECT count(*) FROM highlights", [], |r| r.get(0))
            .unwrap();
        assert_eq!(left, 1, "the older client leaves the highlight row behind");
    }
    let lib = Library::open_with_vocabulary(&path, false).unwrap();
    assert!(highlights::get(&lib, &highlight_id).unwrap().is_none());
    lib.call("sync_now", &json!({})).unwrap();
    let tombstoned = batch_files(&shared.path().join("Omabib/annotations/changes"))
        .iter()
        .any(|p| {
            let (_, changes) = format::read_batch(&std::fs::read(p).unwrap()).unwrap();
            changes
                .iter()
                .any(|c| c.kind == "highlight" && c.key == highlight_id && c.deleted.is_some())
        });
    assert!(
        tombstoned,
        "the next sync writes a highlight tombstone into annotations/changes/"
    );
    assert_eq!(user_version(&path), 1);
}
