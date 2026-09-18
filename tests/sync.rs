//! Several libraries syncing through one shared folder, as separate computers would.
use omabib::db::{Library, read_connection};
use omabib::sync::records;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::Path;

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

struct Computer {
    _dir: tempfile::TempDir,
    lib: Library,
}

impl Computer {
    fn new(shared: &Path) -> Computer {
        let dir = tempfile::tempdir().unwrap();
        let lib = Library::open_with_vocabulary(dir.path().join("library.db"), false).unwrap();
        lib.call("sync_connect", &json!({"provider":"folder","path":shared}))
            .unwrap();
        Computer { _dir: dir, lib }
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
    fn note(&self, ref_id: &str, body: &str) -> String {
        self.call(
            "add_note",
            json!({"ref_id":ref_id,"project_id":null,"body":body,"provenance":"human"}),
        )["id"]
            .as_str()
            .unwrap()
            .to_string()
    }
    fn edit_note(&self, id: &str, body: &str) {
        let c = read_connection(&self.lib.path).unwrap();
        let n = omabib::db::note(&c, id).unwrap();
        self.call(
            "update_note",
            json!({"id":id,"expected_revision":n["revision"],"body":body,"provenance":"human","project_id":n["project_id"]}),
        );
    }
    fn delete_ref(&self, id: &str) {
        let p = self.call("delete_reference_preview", json!({"id":id}));
        self.call(
            "delete_reference",
            json!({"id":id,"expected_revision":p["revision"],"confirm_citekey":p["citekey"],
                "expected_notes":p["note_count"],"expected_attachments":p["attachment_count"],
                "idempotency_key":format!("del-{id}-{}", uuid::Uuid::new_v4())}),
        );
    }
    fn count(&self, sql: &str) -> i64 {
        read_connection(&self.lib.path)
            .unwrap()
            .query_row(sql, [], |r| r.get(0))
            .unwrap()
    }
    /// Every synced record, as other computers should see it.
    fn dump(&self) -> BTreeMap<(String, String), Value> {
        let c = read_connection(&self.lib.path).unwrap();
        let mut out = BTreeMap::new();
        for kind in records::KINDS {
            for key in records::keys(&c, kind).unwrap() {
                let mut r = records::read(&c, kind, &key).unwrap().unwrap();
                // Revision counters and timestamps of the local copy are not synced facts.
                r.remove("updated_at");
                out.insert((kind.to_string(), key), Value::Object(r));
            }
        }
        out
    }
}

/// Syncs round after round until nobody sends or receives anything.
fn settle(computers: &[&Computer]) {
    for _ in 0..10 {
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

fn assert_same(a: &Computer, b: &Computer) {
    let (da, db) = (a.dump(), b.dump());
    let only_a: Vec<_> = da.iter().filter(|(k, _)| !db.contains_key(*k)).collect();
    let only_b: Vec<_> = db.iter().filter(|(k, _)| !da.contains_key(*k)).collect();
    let differ: Vec<_> = da
        .iter()
        .filter_map(|(k, v)| db.get(k).filter(|w| *w != v).map(|w| (k, v, w)))
        .collect();
    assert!(
        only_a.is_empty() && only_b.is_empty() && differ.is_empty(),
        "only on the first: {only_a:#?}\nonly on the second: {only_b:#?}\ndiffering: {differ:#?}"
    );
}

#[test]
fn two_computers_share_a_library_through_a_folder() {
    let shared = tempfile::tempdir().unwrap();
    let a = Computer::new(shared.path());
    let rid = a.import("@article{okafor_sparse_2026,title={Sparse attention is enough},doi={10.1/sparse},year={2026}}");
    let note = a.note(&rid, "Table 2 is the headline result.");
    let project = a.call(
        "create_project",
        json!({"name":"GRL","description":"reading list"}),
    )["id"]
        .as_str()
        .unwrap()
        .to_string();
    a.call(
        "associate",
        json!({"ref_id":rid,"project_id":project,"labels":["core"]}),
    );
    let pdf = a._dir.path().join("paper.pdf");
    one_page_pdf(&pdf, "Sparse attention is enough");
    a.call("add_pdf", json!({"ref_id":rid,"path":pdf}));
    a.call(
        "add_visual_note",
        json!({"ref_id":rid,"project_id":null,"body":"The key figure","provenance":"human","source_pdf":pdf,"page":1,
            "rect_pt":{"x":72,"y":80,"width":200,"height":40}}),
    );

    // The first computer starts the shared library; nothing new is left to send.
    let status = a.call("sync_start", json!({"mode":"new"}));
    assert_eq!(status["configured"], true);
    assert_eq!(status["pending"], 0, "{status}");
    for f in [
        "library.json",
        "devices",
        "snapshots",
        "pdfs/okafor_sparse_2026.pdf",
        "clips",
    ] {
        assert!(
            shared.path().join("Omabib").join(f).exists(),
            "{f} in the folder"
        );
    }

    // A second computer joins with an empty library.
    let b = Computer::new(shared.path());
    let seen = b.call("sync_inspect", json!({}));
    assert_eq!(seen["exists"], true);
    assert_eq!(seen["counts"]["references"], 1);
    b.call("sync_start", json!({"mode":"join"}));
    assert_same(&a, &b);
    assert_eq!(
        b.count("SELECT count(*) FROM note_images WHERE length(data) > 100"),
        1,
        "the clip image came along"
    );
    // The PDF downloads when opened, keeps its content and lets the clip find it again.
    assert_eq!(
        b.count("SELECT count(*) FROM attachments WHERE path LIKE 'omabib-sync:%'"),
        1
    );
    let got = b.call("get_pdf", json!({"ref_id":rid,"download":false}));
    assert_eq!(got["source"], "cloud");
    assert_eq!(
        std::fs::read(got["path"].as_str().unwrap()).unwrap(),
        std::fs::read(&pdf).unwrap()
    );
    assert_eq!(
        b.count("SELECT count(*) FROM note_images WHERE source_pdf LIKE '%.pdf'"),
        1
    );
    b.sync();
    assert_same(&a, &b);

    // Edits flow both ways.
    b.edit_note(&note, "Table 2 is the headline result (edited on B).");
    b.sync();
    let before = a.count("SELECT count(*) FROM notes");
    a.sync();
    assert_eq!(a.count("SELECT count(*) FROM notes"), before);
    let c = read_connection(&a.lib.path).unwrap();
    assert_eq!(
        omabib::db::note(&c, &note).unwrap()["body"],
        "Table 2 is the headline result (edited on B)."
    );
    let hits = a.call("search", json!({"query":"edited"}));
    assert!(
        hits.to_string().contains(&rid),
        "the search index follows applied edits: {hits}"
    );

    // The same note edited on both before syncing: the later edit wins
    // everywhere and the other is kept as one copy.
    a.edit_note(&note, "Edited on A.");
    std::thread::sleep(std::time::Duration::from_millis(5));
    b.edit_note(&note, "Edited on B, later.");
    settle(&[&a, &b]);
    assert_same(&a, &b);
    let c = read_connection(&a.lib.path).unwrap();
    assert_eq!(
        omabib::db::note(&c, &note).unwrap()["body"],
        "Edited on B, later."
    );
    assert_eq!(
        a.count("SELECT count(*) FROM notes WHERE body='Edited on A.'"),
        1
    );
    assert_eq!(
        a.count("SELECT count(*) FROM sync_conflicts WHERE kind='note_copy'"),
        1
    );
    assert_eq!(b.count("SELECT count(*) FROM sync_conflicts"), 0);
    let conflict = a.call("sync_conflicts", json!({}))["conflicts"][0].clone();
    a.call(
        "sync_resolve",
        json!({"id":conflict["id"],"action":"keep_other"}),
    );
    settle(&[&a, &b]);
    assert_eq!(
        b.count("SELECT count(*) FROM notes WHERE body='Edited on A.'"),
        0,
        "the copy's removal syncs"
    );
    assert_same(&a, &b);

    // A deletion wins; edits made here after it are kept for Restore.
    let other = a.import("@article{lindqvist_tides_2024,title={Tidal coupling},year={2024}}");
    let other_note = a.note(&other, "Useful methods section.");
    settle(&[&a, &b]);
    a.delete_ref(&other);
    a.sync();
    std::thread::sleep(std::time::Duration::from_millis(5));
    b.edit_note(&other_note, "Useful methods section, and Table 3.");
    b.sync();
    a.sync();
    assert_eq!(
        b.count(&format!("SELECT count(*) FROM refs WHERE id='{other}'")),
        0
    );
    let conflicts = b.call("sync_conflicts", json!({}))["conflicts"].clone();
    assert_eq!(conflicts.as_array().unwrap().len(), 1, "{conflicts}");
    assert_eq!(conflicts[0]["kind"], "deleted");
    let restored = b.call(
        "sync_resolve",
        json!({"id":conflicts[0]["id"],"action":"restore"}),
    );
    assert!(restored["ref_id"].is_string());
    settle(&[&a, &b]);
    assert_eq!(
        a.count("SELECT count(*) FROM notes WHERE body='Useful methods section, and Table 3.'"),
        1
    );
    assert_same(&a, &b);
    assert_eq!(a.count("SELECT count(*) FROM sync_outbox"), 0);
}

#[test]
fn shared_citekeys_and_dois_settle_the_same_way_everywhere() {
    let shared = tempfile::tempdir().unwrap();
    let a = Computer::new(shared.path());
    a.call("sync_start", json!({"mode":"new"}));
    let b = Computer::new(shared.path());
    b.call("sync_start", json!({"mode":"join"}));

    // The same paper added on both before syncing: both stay, the lower ID shows the DOI.
    let ra = a.import("@article{smith_same_2024,title={Same paper},doi={10.9/same}}");
    let na = a.note(&ra, "Note from A");
    let rb =
        b.import("@article{smith_same_2024b,title={Same paper, B's metadata},doi={10.9/same}}");
    let nb = b.note(&rb, "Note from B");
    // Different papers that happen to share a citation key.
    a.import("@article{chen_models_2025,title={Lattice models},doi={10.9/lattice}}");
    b.import("@article{chen_models_2025,title={Opinion models},doi={10.9/opinion}}");
    // Projects with one name become one.
    a.call("create_project", json!({"name":"Thesis"}));
    b.call("create_project", json!({"name":"Thesis"}));
    settle(&[&a, &b]);
    assert_same(&a, &b);
    let (low, high) = if ra < rb { (&ra, &rb) } else { (&rb, &ra) };
    for c in [&a, &b] {
        assert_eq!(
            c.count(&format!(
                "SELECT count(*) FROM refs WHERE id='{low}' AND doi='10.9/same'"
            )),
            1
        );
        assert_eq!(
            c.count(&format!(
                "SELECT count(*) FROM refs WHERE id='{high}' AND doi IS NULL"
            )),
            1
        );
        assert_eq!(
            c.count("SELECT count(*) FROM refs WHERE citekey='chen_models_2025'"),
            1
        );
        assert_eq!(
            c.count("SELECT count(*) FROM refs WHERE citekey LIKE 'chen_models_2025_%'"),
            1
        );
        assert_eq!(
            c.count("SELECT count(*) FROM projects WHERE name='Thesis'"),
            1
        );
        assert_eq!(
            c.count(&format!(
                "SELECT count(*) FROM sync_conflicts WHERE kind='duplicate' AND ref_id='{high}'"
            )),
            1,
            "the possible duplicate is pointed out"
        );
        let conn = read_connection(&c.lib.path).unwrap();
        assert_eq!(omabib::db::note(&conn, &na).unwrap()["ref_id"], ra.as_str());
        assert_eq!(omabib::db::note(&conn, &nb).unwrap()["ref_id"], rb.as_str());
    }
    // Deleting the reference that shows the DOI hands it to the other, everywhere.
    a.delete_ref(low);
    settle(&[&a, &b]);
    assert_same(&a, &b);
    for c in [&a, &b] {
        assert_eq!(
            c.count(&format!(
                "SELECT count(*) FROM refs WHERE id='{high}' AND doi='10.9/same'"
            )),
            1
        );
    }
}

/// A tiny deterministic random source for the fuzz test.
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
}

fn ids(c: &Computer, sql: &str) -> Vec<String> {
    let conn = read_connection(&c.lib.path).unwrap();
    let mut stmt = conn.prepare(sql).unwrap();
    stmt.query_map([], |r| r.get(0))
        .unwrap()
        .map(|r| r.unwrap())
        .collect()
}

#[test]
fn three_computers_agree_after_random_edits_and_syncs() {
    for seed in [7u64, 1234, 99991] {
        let shared = tempfile::tempdir().unwrap();
        let a = Computer::new(shared.path());
        a.import("@article{seed_paper,title={Seed}}");
        a.call("sync_start", json!({"mode":"new"}));
        let b = Computer::new(shared.path());
        b.call("sync_start", json!({"mode":"join"}));
        let c = Computer::new(shared.path());
        c.import("@article{local_only,title={Only on C},doi={10.5/c}}");
        c.call("sync_start", json!({"mode":"merge"}));
        let all = [&a, &b, &c];
        let mut rng = Rng(seed);
        for step in 0..150 {
            let who = all[rng.below(3)];
            let refs = ids(who, "SELECT id FROM refs ORDER BY id");
            let notes = ids(who, "SELECT id FROM notes ORDER BY id");
            let projects = ids(who, "SELECT id FROM projects ORDER BY id");
            let pick = |rng: &mut Rng, v: &Vec<String>| {
                (!v.is_empty()).then(|| v[rng.below(v.len())].clone())
            };
            let result: anyhow::Result<Value> = match rng.below(10) {
                0 | 1 => {
                    let key = ["alpha", "beta", "gamma", "delta"][rng.below(4)];
                    let doi = ["", "10.1/x", "10.1/y", "10.1/z"][rng.below(4)];
                    let doi = if doi.is_empty() { String::new() } else { format!(",doi={{{doi}}}") };
                    who.lib.call("import_bibtex", &json!({"bibtex":format!("@article{{{key}_{step},title={{Paper {step}}}{doi}}}")}))
                }
                2 | 3 => match pick(&mut rng, &refs) {
                    Some(r) => who.lib.call("add_note", &json!({"ref_id":r,"project_id":null,"body":format!("note {step}"),"provenance":"human"})),
                    None => continue,
                },
                4 | 5 => match pick(&mut rng, &notes) {
                    Some(n) => {
                        let conn = read_connection(&who.lib.path).unwrap();
                        let cur = omabib::db::note(&conn, &n).unwrap();
                        who.lib.call("update_note", &json!({"id":n,"expected_revision":cur["revision"],"body":format!("edit {step}"),"provenance":"human","project_id":cur["project_id"]}))
                    }
                    None => continue,
                },
                6 => match pick(&mut rng, &refs) {
                    Some(r) => {
                        who.delete_ref(&r);
                        Ok(Value::Null)
                    }
                    None => continue,
                },
                7 => {
                    let name = ["P1", "P2"][rng.below(2)];
                    who.lib.call("create_project", &json!({"name":name}))
                }
                8 => match (pick(&mut rng, &refs), pick(&mut rng, &projects)) {
                    (Some(r), Some(p)) => who.lib.call("associate", &json!({"ref_id":r,"project_id":p,"labels":[format!("l{step}")]})),
                    _ => continue,
                },
                _ => who.lib.call("sync_now", &json!({})),
            };
            // Some random edits are refused (a taken project name); that's fine.
            let _ = result;
        }
        settle(&all);
        assert_same(&a, &b);
        assert_same(&a, &c);
        for x in all {
            assert_eq!(
                x.count("SELECT count(*) FROM sync_outbox"),
                0,
                "seed {seed}: nothing left to send"
            );
            let dupes = x.count("SELECT count(*) FROM (SELECT doi FROM refs WHERE doi IS NOT NULL GROUP BY doi HAVING count(*)>1)");
            assert_eq!(dupes, 0);
        }
        // A computer joining now from the snapshot and the batches agrees too.
        let d = Computer::new(shared.path());
        d.call("sync_start", json!({"mode":"join"}));
        settle(&[&d]);
        assert_same(&a, &d);
    }
}

/// The same library shared through rclone (its local backend stands in for a
/// cloud account). Skipped when rclone isn't installed.
#[test]
fn two_computers_share_a_library_through_rclone() {
    if omabib::sync::store::rclone_binary().is_none() {
        eprintln!("rclone not installed; skipped");
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let remote_dir = dir.path().join("cloud");
    std::fs::create_dir_all(&remote_dir).unwrap();
    let config = dir.path().join("rclone.conf");
    std::fs::write(
        &config,
        format!(
            "[shared]\ntype = alias\nremote = {}\n",
            remote_dir.display()
        ),
    )
    .unwrap();
    // The only test in this binary that reads this variable.
    unsafe { std::env::set_var("OMABIB_RCLONE_CONFIG", &config) };
    let join = |c: &Computer| {
        c.call(
            "sync_connect",
            json!({"provider":"rclone","remote":"shared"}),
        );
    };
    let a = {
        let d = tempfile::tempdir().unwrap();
        let lib = Library::open_with_vocabulary(d.path().join("library.db"), false).unwrap();
        Computer { _dir: d, lib }
    };
    join(&a);
    let rid = a.import("@article{rclone_paper,title={Through rclone},doi={10.7/rclone}}");
    let pdf = a._dir.path().join("paper.pdf");
    one_page_pdf(&pdf, "Through rclone");
    a.call("add_pdf", json!({"ref_id":rid,"path":pdf}));
    a.note(&rid, "Written on A");
    let status = a.call("sync_start", json!({"mode":"new"}));
    assert_eq!(status["where"], "shared → Omabib");
    assert!(remote_dir.join("Omabib/library.json").is_file());
    assert!(remote_dir.join("Omabib/pdfs/rclone_paper.pdf").is_file());
    let b = {
        let d = tempfile::tempdir().unwrap();
        let lib = Library::open_with_vocabulary(d.path().join("library.db"), false).unwrap();
        Computer { _dir: d, lib }
    };
    join(&b);
    assert_eq!(b.call("sync_inspect", json!({}))["counts"]["references"], 1);
    b.call("sync_start", json!({"mode":"join"}));
    assert_same(&a, &b);
    assert_eq!(
        b.call("get_pdf", json!({"ref_id":rid,"download":false}))["source"],
        "cloud"
    );
    b.note(&rid, "Written on B");
    settle(&[&a, &b]);
    assert_same(&a, &b);
    assert_eq!(a.count("SELECT count(*) FROM notes"), 2);
    // A connection that isn't in the config is refused with its name.
    let err = b
        .lib
        .call(
            "sync_connect",
            &json!({"provider":"rclone","remote":"nowhere"}),
        )
        .unwrap_err();
    assert!(format!("{err:#}").contains("nowhere"), "{err:#}");
}
