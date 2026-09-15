use omabib::db::Library;
use serde_json::{Value, json};
const BIB: &str = r#"@string{journal = "Journal of Testing"}
@article{Smith2024, title={Networks and {AI} in collective creativity}, author={Smith, Jane and Tom{\'a}{\v s}evi{\'c}, Aleksandar}, year={2024}, doi={10.1234/example}, abstract={Group consensus emerges through repeated social interactions.}, journal=journal, customfield={Keep {Case}}}
@book{Book2020, title={Measurement Theory}, author={{World Research Organization}}, year={2020}, publisher={Example}}
@inbook{Chapter2020, title={Latent Oscillators}, crossref={Book2020}, pages={3--9}}"#;
fn setup() -> (tempfile::TempDir, Library, Value) {
    let d = tempfile::tempdir().unwrap();
    let l = Library::open(d.path().join("library.db")).unwrap();
    let r = l.call("import_bibtex", &json!({"bibtex":BIB})).unwrap();
    (d, l, r)
}
fn first(r: &Value) -> &str {
    r["items"][0]["id"].as_str().unwrap()
}
#[test]
fn deleting_a_reference_removes_its_library_data_but_keeps_pdf_files() {
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("library.db");
    let lib = Library::open(&db).unwrap();
    let imported = lib.call("import_bibtex", &json!({"bibtex":"@article{DeleteMe,title={Delete target},year={2026}}\n@article{KeepMe,title={Keep target},year={2026}}"})).unwrap();
    let rid = imported["items"][0]["id"].as_str().unwrap();
    let keep = imported["items"][1]["id"].as_str().unwrap();
    let project = lib.call("create_project", &json!({"name":"Delete test"})).unwrap()["id"].clone();
    let pdf = dir.path().join("paper.pdf");
    std::fs::write(&pdf, b"%PDF-1.4\n").unwrap();
    lib.call("attach", &json!({"ref_id":rid,"path":pdf,"file_type":"pdf"})).unwrap();
    let note = lib.call("add_note", &json!({"ref_id":rid,"project_id":project,"body":"A note to remove","provenance":"test"})).unwrap();
    lib.call("update_note", &json!({"id":note["id"],"project_id":project,"expected_revision":1,"body":"Revised note","provenance":"test"})).unwrap();
    let c = rusqlite::Connection::open(&db).unwrap();
    c.execute("INSERT INTO note_images VALUES(?1,'image/png',1,1,'hash',?2,1,'{}',X'00')",rusqlite::params![note["id"].as_str().unwrap(),pdf.to_str().unwrap()]).unwrap();
    c.execute("INSERT INTO external_summaries(ref_id,source,external_id,source_url,body) VALUES(?1,'alphaXiv','2609.00001','https://www.alphaxiv.org/overview/2609.00001.md','# Report')",[rid]).unwrap();
    drop(c);
    let preview = lib.call("delete_reference_preview", &json!({"id":"DeleteMe"})).unwrap();
    assert_eq!(preview["id"], rid);
    assert_eq!(preview["note_count"], 1);
    assert_eq!(preview["attachment_count"], 1);
    assert_eq!(preview["project_count"], 1);
    assert_eq!(preview["summary_count"], 1);
    let args = json!({"id":rid,"expected_revision":preview["revision"],"confirm_citekey":"DeleteMe","expected_notes":1,"expected_attachments":1,"idempotency_key":"delete-once"});
    for (field, wrong) in [("expected_revision",json!(999)),("confirm_citekey",json!("KeepMe")),("expected_notes",json!(0)),("expected_attachments",json!(0))] {
        let mut bad = args.clone(); bad[field] = wrong;
        assert!(lib.call("delete_reference", &bad).is_err(), "{field}");
        assert!(lib.call("get_reference", &json!({"id":rid})).is_ok());
    }
    let deleted = lib.call("delete_reference", &args).unwrap();
    assert_eq!(deleted["deleted"], true);
    assert_eq!(deleted["notes_deleted"], 1);
    assert_eq!(deleted["attachments_unlinked"], 1);
    assert_eq!(deleted["files_deleted"], false);
    assert_eq!(lib.call("delete_reference", &args).unwrap(), deleted);
    assert!(pdf.exists());
    assert!(lib.call("get_reference", &json!({"id":rid})).is_err());
    assert!(lib.call("get_reference", &json!({"id":keep})).is_ok());
    assert!(lib.call("search", &json!({"query":"Delete target"})).unwrap()["results"].as_array().unwrap().is_empty());
    let c = rusqlite::Connection::open(&db).unwrap();
    for table in ["notes","note_revisions","note_images","attachments","associations","external_summaries"] {
        let count: i64 = c.query_row(&format!("SELECT count(*) FROM {table}"),[],|r|r.get(0)).unwrap();
        assert_eq!(count, 0, "{table}");
    }
    let docs: i64 = c.query_row("SELECT count(*) FROM docs WHERE ref_id=?",[rid],|r|r.get(0)).unwrap();
    assert_eq!(docs, 0);
    let violations: i64 = c.query_row("SELECT count(*) FROM pragma_foreign_key_check",[],|r|r.get(0)).unwrap();
    assert_eq!(violations, 0);
}
#[test]
fn deleting_one_note_keeps_its_reference_and_other_notes() {
    let (dir, lib, refs) = setup();
    let rid = first(&refs);
    let note = lib.call("add_note", &json!({"ref_id":rid,"project_id":null,"body":"Delete this specific assessment","provenance":"test"})).unwrap();
    let keep = lib.call("add_note", &json!({"ref_id":rid,"project_id":null,"body":"Keep this other assessment","provenance":"test"})).unwrap();
    lib.call("update_note", &json!({"id":note["id"],"project_id":null,"expected_revision":1,"body":"Revised specific assessment","provenance":"test"})).unwrap();
    let db = dir.path().join("library.db");
    let c = rusqlite::Connection::open(&db).unwrap();
    c.execute("INSERT INTO note_images VALUES(?1,'image/png',1,1,'hash','/tmp/paper.pdf',1,'{}',X'00')",[note["id"].as_str().unwrap()]).unwrap();
    drop(c);
    let preview = lib.call("delete_note_preview", &json!({"id":note["id"]})).unwrap();
    assert_eq!(preview["ref_id"], rid);
    assert_eq!(preview["revision"], 2);
    assert_eq!(preview["has_image"], true);
    assert!(preview["excerpt"].as_str().unwrap().contains("Revised"));
    let args = json!({"id":note["id"],"expected_revision":2,"confirm_ref_id":rid,"idempotency_key":"delete-note-once"});
    for (field, wrong) in [("expected_revision",json!(1)),("confirm_ref_id",json!("wrong"))] {
        let mut bad = args.clone();bad[field]=wrong;
        assert!(lib.call("delete_note", &bad).is_err(), "{field}");
    }
    let deleted = lib.call("delete_note", &args).unwrap();
    assert_eq!(deleted["image_deleted"], true);
    assert_eq!(lib.call("delete_note", &args).unwrap(), deleted);
    assert!(lib.call("delete_note_preview", &json!({"id":note["id"]})).is_err());
    let reference = lib.call("get_reference", &json!({"id":rid,"include_notes":true})).unwrap();
    assert_eq!(reference["notes"].as_array().unwrap().len(), 1);
    assert_eq!(reference["notes"][0]["id"], keep["id"]);
    assert!(lib.call("search", &json!({"query":"Revised specific assessment"})).unwrap()["results"].as_array().unwrap().is_empty());
    let c = rusqlite::Connection::open(&db).unwrap();
    for table in ["note_revisions","note_images"] {
        let count:i64=c.query_row(&format!("SELECT count(*) FROM {table}"),[],|r|r.get(0)).unwrap();
        assert_eq!(count,0,"{table}");
    }
    let docs:i64=c.query_row("SELECT count(*) FROM docs WHERE note_id=?",[note["id"].as_str().unwrap()],|r|r.get(0)).unwrap();
    assert_eq!(docs,0);
}
#[test]
fn search_and_roundtrip() {
    let (_d, l, r) = setup();
    for q in [
        "Smith2024",
        "10.1234/example",
        "smith consensus",
        "netw",
        "etwork",
        "netwroks",
        "collective creativity",
        "\"social interactions\"",
        "tomasevic",
        "latent",
    ] {
        let v = l.call("search", &json!({"query":q})).unwrap();
        assert!(!v["results"].as_array().unwrap().is_empty(), "{q}: {v}");
    }
    for q in ["\"", "() OR \\", "😊", "'?!", ""] {
        l.call("search", &json!({"query":q})).unwrap();
    }
    let e = l
        .call("export_bibtex", &json!({"ids":["Chapter2020",first(&r)]}))
        .unwrap();
    assert_eq!(e["count"], 3);
    let bib = e["bibtex"].as_str().unwrap();
    assert!(bib.contains("customfield"));
    assert!(bib.contains("Journal of Testing"));
    assert!(biblatex::Bibliography::parse(bib).is_ok());
    let again = l.call("import_bibtex", &json!({"bibtex":BIB})).unwrap();
    assert_eq!(again["items"].as_array().unwrap().len(), 3);
    assert_eq!(l.call("status", &json!({})).unwrap()["references"], 3);
}
#[test]
fn blank_browse_sorts_by_date_added_with_stable_pages() {
    let (d, l, _) = setup();
    let c = rusqlite::Connection::open(d.path().join("library.db")).unwrap();
    for (key, added) in [
        ("Book2020", "2026-09-13T10:00:00.000Z"),
        ("Chapter2020", "2026-09-13T11:00:00.000Z"),
        ("Smith2024", "2026-09-13T12:00:00.000Z"),
    ] {
        c.execute("UPDATE refs SET created_at=? WHERE citekey=?", [added, key])
            .unwrap();
    }
    drop(c);
    let first_page = l
        .call("search", &json!({"query":"","sort":"added_desc","limit":2}))
        .unwrap();
    assert_eq!(first_page["ranking"], "added_desc");
    assert_eq!(first_page["results"][0]["citekey"], "Smith2024");
    assert_eq!(first_page["results"][1]["citekey"], "Chapter2020");
    assert_eq!(
        first_page["results"][0]["created_at"],
        "2026-09-13T12:00:00.000Z"
    );
    let second_page = l
        .call(
            "search",
            &json!({"query":"","sort":"added_desc","limit":2,"cursor":first_page["next_cursor"]}),
        )
        .unwrap();
    assert_eq!(second_page["results"][0]["citekey"], "Book2020");
    assert!(second_page["next_cursor"].is_null());
    let by_key = l.call("search", &json!({"query":"","limit":3})).unwrap();
    assert_eq!(by_key["ranking"], "citekey");
    assert_eq!(by_key["results"][0]["citekey"], "Book2020");
    assert_eq!(by_key["results"][2]["citekey"], "Smith2024");
    let year = l
        .call(
            "search",
            &json!({"query":"","sort":"added_desc","year":"2020"}),
        )
        .unwrap();
    assert_eq!(year["results"][0]["citekey"], "Chapter2020");
    assert_eq!(year["results"].as_array().unwrap().len(), 2);
    let project = l.call("create_project", &json!({"name":"test"})).unwrap();
    let smith = l.call("get_reference", &json!({"id":"Smith2024"})).unwrap();
    l.call(
        "associate",
        &json!({"ref_id":smith["id"],"project_id":project["id"]}),
    )
    .unwrap();
    let scoped = l
        .call(
            "search",
            &json!({"query":"","sort":"added_desc","project_filter":project["id"]}),
        )
        .unwrap();
    assert_eq!(scoped["results"].as_array().unwrap().len(), 1);
    assert_eq!(scoped["results"][0]["id"], smith["id"]);
    assert_eq!(
        l.call("search", &json!({"query":"collective","sort":"added_desc"}))
            .unwrap()["ranking"],
        "bounded_field_weighted"
    );
    assert!(
        l.call("search", &json!({"query":"","sort":"unknown"}))
            .is_err()
    );
}

#[test]
fn old_library_gets_date_added_index_on_open() {
    let d = tempfile::tempdir().unwrap();
    let path = d.path().join("library.db");
    drop(Library::open(&path).unwrap());
    let c = rusqlite::Connection::open(&path).unwrap();
    c.execute_batch("DROP INDEX refs_added;").unwrap();
    drop(c);
    drop(Library::open(&path).unwrap());
    let c = rusqlite::Connection::open(&path).unwrap();
    assert_eq!(
        c.query_row(
            "SELECT count(*) FROM sqlite_master WHERE type='index' AND name='refs_added'",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        1
    );
}
#[test]
fn notes_scope_revisions_retry_and_backup() {
    let (d, l, r) = setup();
    let rid = first(&r);
    let a = l.call("create_project", &json!({"name":"A"})).unwrap();
    let b = l.call("create_project", &json!({"name":"B"})).unwrap();
    let request = json!({"ref_id":rid,"project_id":a["id"],"body":"zebrafish hypothesis","provenance":"human","idempotency_key":"one"});
    let n = l.call("add_note", &request).unwrap();
    assert_eq!(n, l.call("add_note", &request).unwrap());
    let mut bad = request.clone();
    bad["body"] = json!("changed");
    assert!(l.call("add_note", &bad).is_err());
    assert!(
        l.call(
            "add_note",
            &json!({"ref_id":rid,"body":"missing scope","provenance":"agent"})
        )
        .is_err()
    );
    let hits = |p: &Value, all: bool| {
        l.call(
            "search",
            &json!({"query":"zebrafish","project_id":p["id"],"include_other_projects":all}),
        )
        .unwrap()["results"]
            .as_array()
            .unwrap()
            .len()
    };
    assert_eq!(hits(&a, false), 1);
    assert_eq!(hits(&b, false), 0);
    assert_eq!(hits(&b, true), 1);
    let v = l
        .call(
            "get_reference",
            &json!({"id":rid,"project_id":b["id"],"include_notes":true}),
        )
        .unwrap();
    assert_eq!(v["notes"].as_array().unwrap().len(), 0);
    assert_eq!(v["other_project_note_count"], 1);
    let update = json!({"id":n["id"],"project_id":a["id"],"body":"revised zebrafish assessment","provenance":"codex","expected_revision":1});
    assert_eq!(l.call("update_note", &update).unwrap()["revision"], 2);
    assert!(l.call("update_note", &update).is_err());
    let v = l
        .call("get_reference", &json!({"id":rid,"include_history":true}))
        .unwrap();
    assert_eq!(v["history"][0]["body"], "zebrafish hypothesis");
    let backup = d.path().join("backup.db");
    l.call("backup", &json!({"path":backup})).unwrap();
    let restored = Library::open(&backup).unwrap();
    assert_eq!(restored.call("status", &json!({})).unwrap()["notes"], 1);
}
#[test]
fn conflicts_roots_and_budget() {
    let (d, l, r) = setup();
    let p = l
        .call("create_project", &json!({"name":"main","roots":[d.path()]}))
        .unwrap();
    assert_eq!(
        l.call("list_projects", &json!({"cwd":d.path()})).unwrap()["resolved_project_id"],
        p["id"]
    );
    l.call(
        "create_project",
        &json!({"name":"ambiguous","roots":[d.path()]}),
    )
    .unwrap();
    assert_eq!(
        l.call("list_projects", &json!({"cwd":d.path()})).unwrap()["ambiguous"],
        true
    );
    let update=l.call("import_bibtex",&json!({"bibtex":"@article{OtherKey,doi={10.1234/example},title={Disagreement},url={https://example.org}}"})).unwrap();
    assert!(!update["conflicts"].as_array().unwrap().is_empty());
    assert_eq!(
        l.call("get_reference", &json!({"id":first(&r)})).unwrap()["fields"]["url"],
        "https://example.org"
    );
    l.call("add_note",&json!({"ref_id":first(&r),"project_id":p["id"],"body":"a long note ".repeat(1000),"provenance":"test"})).unwrap();
    let context = l
        .call(
            "project_context",
            &json!({"project_id":p["id"],"max_chars":1000}),
        )
        .unwrap();
    assert!(
        context.to_string().chars().count() <= 1000,
        "{}",
        context.to_string().len()
    );
    assert!(
        l.call("attach", &json!({"ref_id":first(&r),"path":"relative.pdf"}))
            .is_err()
    );
    l.call(
        "attach",
        &json!({"ref_id":first(&r),"path":"/nonexistent/paper.pdf"}),
    )
    .unwrap();
    assert_eq!(
        l.call(
            "get_reference",
            &json!({"id":first(&r),"include_attachments":true})
        )
        .unwrap()["attachments"][0]["exists"],
        false
    );
}
#[test]
fn import_is_atomic_and_metadata_revision_safe() {
    let (_d, l, r) = setup();
    let before = l.call("status", &json!({})).unwrap();
    assert!(
        l.call(
            "import_bibtex",
            &json!({"bibtex":"@book{bad,title={Broken"})
        )
        .is_err()
    );
    assert_eq!(before, l.call("status", &json!({})).unwrap());
    let p = json!({"id":first(&r),"bibtex":"@article{Renamed,title={Updated}}","expected_revision":999});
    assert!(l.call("upsert_reference", &p).is_err());
}
#[test]
fn pagination_survives_many_notes_on_one_reference() {
    let (_d, l, r) = setup();
    for i in 0..60 {
        l.call("add_note",&json!({"ref_id":first(&r),"project_id":null,"body":format!("network note {i}"),"provenance":"test"})).unwrap();
    }
    l.call(
        "import_bibtex",
        &json!({"bibtex":"@article{Another,title={Networks}}"}),
    )
    .unwrap();
    let a = l
        .call("search", &json!({"query":"network","limit":1}))
        .unwrap();
    assert!(!a["next_cursor"].is_null(), "{a}");
    let b = l
        .call(
            "search",
            &json!({"query":"network","limit":1,"cursor":a["next_cursor"]}),
        )
        .unwrap();
    assert_eq!(b["results"].as_array().unwrap().len(), 1, "{b}");
    assert_ne!(a["results"][0]["id"], b["results"][0]["id"]);
}
#[test]
fn real_doi_metadata_and_month_names() {
    let d = tempfile::tempdir().unwrap();
    let l = Library::open(d.path().join("library.db")).unwrap();
    l.call(
        "import_bibtex",
        &json!({"bibtex":include_str!("fixtures/networks.bib")}),
    )
    .unwrap();
    for (query, key) in [
        ("barabasi scaling", "Baraba_si_1999"),
        ("regularized correlation", "Epskamp_2018"),
        ("fried tutorial", "Epskamp_2018"),
    ] {
        let r = l.call("search", &json!({"query":query})).unwrap();
        assert_eq!(r["results"][0]["citekey"], key, "{query}: {r}");
    }
    l.call(
        "import_bibtex",
        &json!({"bibtex":"@article{Months,title={Full month names},month=June}"}),
    )
    .unwrap();
}
#[test]
fn different_dois_do_not_merge_on_key_collision() {
    let (_d, l, _) = setup();
    let r=l.call("import_bibtex",&json!({"bibtex":"@article{Smith2024,title={Networks and {AI} in collective creativity},doi={10.1234/different}}"})).unwrap();
    assert_eq!(r["items"][0]["citekey"], "Smith2024_2");
    assert_eq!(l.call("status", &json!({})).unwrap()["references"], 4);
}
#[test]
fn preserve_title_case_and_bibtex_journal() {
    let d = tempfile::tempdir().unwrap();
    let l = Library::open(d.path().join("library.db")).unwrap();
    l.call(
        "import_bibtex",
        &json!({"bibtex":include_str!("fixtures/networks.bib")}),
    )
    .unwrap();
    let r = l
        .call("get_reference", &json!({"id":"Baraba_si_1999"}))
        .unwrap();
    assert_eq!(r["title"], "Emergence of Scaling in Random Networks");
    let e = l
        .call("export_bibtex", &json!({"ids":["Baraba_si_1999"]}))
        .unwrap();
    assert!(
        e["bibtex"]
            .as_str()
            .unwrap()
            .contains("journal = {Science}")
    );
    assert!(!e["bibtex"].as_str().unwrap().contains("journaltitle ="));
}

#[test]
fn import_repairs_duplicates_and_missing_commas() {
    let dir = tempfile::tempdir().unwrap();
    let l = Library::open(dir.path().join("library.db")).unwrap();
    let raw = "\u{feff}@string{venue={Research Journal}}\n@article{Same,title={Networks} author={Smith, Jane},journal=venue,title={Networks}}\n@article{Same,title={Networks},year={2026},abstract={Useful abstract},month=June}\n@article{Alias,title={Networks},year={2026},abstract={Useful abstract},month=June}";
    let r = l.call("import_bibtex", &json!({"bibtex":raw})).unwrap();
    assert_eq!(r["items"].as_array().unwrap().len(), 1, "{r}");
    assert_eq!(r["duplicates_merged"], 2);
    assert_eq!(l.call("status", &json!({})).unwrap()["references"], 1);
    let v = l.call("get_reference", &json!({"id":"Same"})).unwrap();
    assert_eq!(v["fields"]["year"], "2026");
    assert_eq!(v["fields"]["journal"], "Research Journal");
    assert_eq!(v["abstract"], "Useful abstract");
    assert!(
        r["repairs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|x| x["kind"] == "inserted_missing_comma")
    );
    let n = l
        .call(
            "add_note",
            &json!({"ref_id":v["id"],"project_id":null,"body":"Keep my note","provenance":"test"}),
        )
        .unwrap();
    l.call("import_bibtex", &json!({"bibtex":raw})).unwrap();
    let read = l
        .call("get_reference", &json!({"id":"Same","include_notes":true}))
        .unwrap();
    assert_eq!(read["notes"][0]["id"], n["id"]);
}

#[test]
fn duplicate_conflicts_preserve_values_and_distinct_dois() {
    let d = tempfile::tempdir().unwrap();
    let l = Library::open(d.path().join("library.db")).unwrap();
    let r=l.call("import_bibtex",&json!({"bibtex":"@book{K,title={First},year={2020}}\n@book{K,title={Second},publisher={Press}}"})).unwrap();
    assert_eq!(r["items"].as_array().unwrap().len(), 1);
    assert!(!r["conflicts"].as_array().unwrap().is_empty());
    let v = l.call("get_reference", &json!({"id":"K"})).unwrap();
    assert_eq!(v["title"], "First");
    assert_eq!(v["fields"]["publisher"], "Press");
    let r=l.call("import_bibtex",&json!({"bibtex":"@article{D,title={Work},doi={10.1/a}}\n@article{D,title={Work},doi={10.1/b}}"})).unwrap();
    assert_eq!(r["items"].as_array().unwrap().len(), 2);
    assert_eq!(r["duplicates_merged"], 0);
    let before = l.call("status", &json!({})).unwrap();
    assert!(
        l.call(
            "import_bibtex",
            &json!({"bibtex":"@book{Unclosed,title={Broken}"})
        )
        .is_err()
    );
    assert_eq!(l.call("status", &json!({})).unwrap(), before);
}

#[test]
fn repeated_incoming_key_keeps_existing_collision_separate() {
    let d = tempfile::tempdir().unwrap();
    let l = Library::open(d.path().join("library.db")).unwrap();
    l.call(
        "import_bibtex",
        &json!({"bibtex":"@article{K,title={Existing work},author={Old, Author}}"}),
    )
    .unwrap();
    let r=l.call("import_bibtex",&json!({"bibtex":"@article{K,title={Incoming work},author={New, Author}}\n@article{K,title={Incoming work},abstract={New abstract}}"})).unwrap();
    assert_eq!(r["items"].as_array().unwrap().len(), 1);
    assert_eq!(r["duplicates_merged"], 1);
    assert_eq!(
        l.call("get_reference", &json!({"id":"K"})).unwrap()["abstract"],
        ""
    );
    assert_eq!(
        l.call("get_reference", &json!({"id":"K_2"})).unwrap()["abstract"],
        "New abstract"
    );
}

#[test]
fn pdf_attachments_validate_deduplicate_and_unlink_without_deleting() {
    let (d, l, r) = setup();
    let pdf = d.path().join("paper with spaces.pdf");
    std::fs::write(&pdf, b"%PDF-1.4\n%%EOF\n").unwrap();
    let a = l
        .call("add_pdf", &json!({"ref_id":first(&r),"path":pdf}))
        .unwrap();
    let b = l
        .call("add_pdf", &json!({"ref_id":first(&r),"path":pdf}))
        .unwrap();
    assert_eq!(a["id"], b["id"]);
    let v = l
        .call(
            "get_reference",
            &json!({"id":first(&r),"include_attachments":true}),
        )
        .unwrap();
    assert_eq!(v["attachments"].as_array().unwrap().len(), 1);
    assert!(
        l.call(
            "pull_pdf",
            &json!({"ref_id":first(&r),"url":"http://example.invalid/paper.pdf"})
        )
        .is_err()
    );
    let bad = d.path().join("not-a-pdf.pdf");
    std::fs::write(&bad, b"<html>Not a PDF</html>").unwrap();
    assert!(
        l.call("add_pdf", &json!({"ref_id":first(&r),"path":bad}))
            .is_err()
    );
    assert_eq!(
        l.call("remove_pdf", &json!({"attachment_id":a["id"]}))
            .unwrap()["removed"],
        true
    );
    assert_eq!(
        l.call("remove_pdf", &json!({"attachment_id":a["id"]}))
            .unwrap()["removed"],
        false
    );
    assert!(pdf.exists());
}

#[test]
fn metadata_fill_preserves_values_relations_and_revision() {
    let (_d, l, r) = setup();
    let rid = first(&r);
    l.call(
        "add_note",
        &json!({"ref_id":rid,"project_id":null,"body":"Keep my assessment","provenance":"test"}),
    )
    .unwrap();
    let before = l.call("get_reference", &json!({"id":rid})).unwrap();
    let args = json!({"id":rid,"expected_revision":before["revision"],"fields":{"abstract":"Replacement rejected","url":"https://example.org/paper?a=1&b=2","publisher":"Research & Testing {Group}"},"source":"https://api.crossref.org/works/example","idempotency_key":"metadata-once"});
    let result = l.call("apply_metadata", &args).unwrap();
    assert_eq!(result["filled"].as_array().unwrap().len(), 2);
    assert_eq!(l.call("apply_metadata", &args).unwrap(), result);
    let after = l
        .call("get_reference", &json!({"id":rid,"include_notes":true}))
        .unwrap();
    assert_eq!(before["abstract"], after["abstract"]);
    assert_eq!(before["citekey"], after["citekey"]);
    assert_eq!(after["notes"][0]["body"], "Keep my assessment");
    assert_eq!(after["fields"]["url"], "https://example.org/paper?a=1&b=2");
    assert!(omabib::db::parse_bibtex(after["bibtex"].as_str().unwrap()).is_ok());
    let mut stale = args.clone();
    stale.as_object_mut().unwrap().remove("idempotency_key");
    assert!(l.call("apply_metadata", &stale).is_err());
    assert_eq!(
        l.call("search", &json!({"query":"Testing Group"})).unwrap()["results"]
            .as_array()
            .unwrap()
            .len(),
        0
    ); // Publisher is not a search field.
}
#[test]
fn enter_target_pdf_url_doi_and_missing() {
    let (d, l, r) = setup();
    let rid = first(&r);
    assert_eq!(
        l.call("open_target", &json!({"id":rid})).unwrap()["kind"],
        "doi"
    );
    let item = l.call("get_reference", &json!({"id":rid})).unwrap();
    l.call("apply_metadata",&json!({"id":rid,"expected_revision":item["revision"],"fields":{"url":"https://example.org/paper"},"source":"test"})).unwrap();
    assert_eq!(
        l.call("open_target", &json!({"id":rid})).unwrap()["url"],
        "https://example.org/paper"
    );
    let pdf = d.path().join("paper with spaces.pdf");
    std::fs::write(&pdf, b"%PDF-1.4\n%%EOF").unwrap();
    l.call("add_pdf", &json!({"ref_id":rid,"path":pdf}))
        .unwrap();
    let target = l.call("open_target", &json!({"id":rid})).unwrap();
    assert_eq!(target["kind"], "pdf");
    assert!(
        target["url"]
            .as_str()
            .unwrap()
            .contains("paper%20with%20spaces.pdf")
    );
    // prefer:"link" skips the PDF attachment even though one exists.
    assert_eq!(
        l.call("open_target", &json!({"id":rid,"prefer":"link"}))
            .unwrap()["url"],
        "https://example.org/paper"
    );
    std::fs::remove_file(pdf).unwrap();
    assert_eq!(
        l.call("open_target", &json!({"id":rid})).unwrap()["kind"],
        "url"
    );
    assert!(l.call("open_target", &json!({"id":"Book2020"})).is_err());
}

#[test]
fn filled_abstract_is_immediately_searchable() {
    let (_d, l, _) = setup();
    let r = l.call("get_reference", &json!({"id":"Book2020"})).unwrap();
    l.call("apply_metadata",&json!({"id":r["id"],"expected_revision":r["revision"],"fields":{"abstract":"Thermodynamic imaginary scaffolding"},"source":"test"})).unwrap();
    assert_eq!(
        l.call("search", &json!({"query":"thermodynamic scaffolding"}))
            .unwrap()["results"][0]["id"],
        r["id"]
    );
}

#[test]
fn universal_add_previews_bibtex_without_writing() {
    let (_d, l, _) = setup();
    let count = l.call("status", &json!({})).unwrap()["references"].clone();
    let preview=l.call("preview_entry",&json!({"input":"@article{Pasted,title={A paper}}\n@article{Pasted,title={A paper},year={2026}}"})).unwrap();
    assert_eq!(preview["recognized"], "bibtex");
    assert_eq!(preview["saved"], false);
    assert_eq!(l.call("status", &json!({})).unwrap()["references"], count);
    l.call("import_bibtex", &preview).unwrap();
    let r = l.call("get_reference", &json!({"id":"Pasted"})).unwrap();
    assert_eq!(r["year"], "2026");
    for input in [
        "file:///etc/passwd",
        "javascript:alert(1)",
        "not a URL or DOI",
    ] {
        assert!(l.call("preview_entry", &json!({"input":input})).is_err());
    }
}

#[test]
fn pdf_path_and_search_flags_reflect_attachments_and_abstracts() {
    let (d, l, r) = setup();
    let smith = first(&r);
    let book = r["items"][1]["id"].as_str().unwrap();
    // Smith2024 has an abstract already; Book2020 does not.
    let smith_hit = l.call("search", &json!({"query":"collective creativity"})).unwrap()["results"][0].clone();
    assert_eq!(smith_hit["id"], smith);
    assert_eq!(smith_hit["has_abstract"], true);
    assert_eq!(smith_hit["has_pdf"], false);
    let smith_ref = l.call("get_reference", &json!({"id":smith})).unwrap();
    assert_eq!(smith_ref["pdf_path"], Value::Null);

    let pdf = d.path().join("paper.pdf");
    std::fs::write(&pdf, b"%PDF-1.4\n%%EOF\n").unwrap();
    l.call("add_pdf", &json!({"ref_id":book,"path":pdf})).unwrap();
    let book_ref = l.call("get_reference", &json!({"id":book})).unwrap();
    assert_eq!(book_ref["pdf_path"], json!(pdf.to_str().unwrap()));
    let book_hit = l.call("search", &json!({"query":"measurement theory"})).unwrap()["results"][0].clone();
    assert_eq!(book_hit["id"], book);
    assert_eq!(book_hit["has_pdf"], true);
    assert_eq!(book_hit["has_abstract"], false);

    // Once the local file is gone, pdf_path and has_pdf both go false again
    // (removing the link is the only way to make the record forget it).
    std::fs::remove_file(&pdf).unwrap();
    let book_ref2 = l.call("get_reference", &json!({"id":book})).unwrap();
    assert_eq!(book_ref2["pdf_path"], Value::Null);
}

#[test]
fn get_pdf_returns_existing_local_attachment_without_network() {
    let (d, l, r) = setup();
    let book = r["items"][1]["id"].as_str().unwrap();
    let pdf = d.path().join("existing.pdf");
    std::fs::write(&pdf, b"%PDF-1.4\n%%EOF\n").unwrap();
    l.call("add_pdf", &json!({"ref_id":book,"path":pdf.clone()})).unwrap();
    let got = l.call("get_pdf", &json!({"ref_id":book})).unwrap();
    assert_eq!(got["source"], "local");
    assert_eq!(got["path"], json!(pdf.to_str().unwrap()));
}

#[test]
fn get_pdf_reports_no_copy_without_network_when_download_disabled() {
    let (_d, l, r) = setup();
    let book = r["items"][1]["id"].as_str().unwrap();
    assert!(
        l.call("get_pdf", &json!({"ref_id":book,"download":false}))
            .is_err()
    );
}

#[test]
fn add_reference_from_bibtex_attaches_pdf_and_associates_project_atomically() {
    let (d, l, _) = setup();
    let project = l
        .call("create_project", &json!({"name":"Thesis"}))
        .unwrap();
    let pdf = d.path().join("local.pdf");
    std::fs::write(&pdf, b"%PDF-1.4\n%%EOF\n").unwrap();
    let bibtex = "@article{Added2025,title={Added by hand},author={Doe, Jane},year={2025}}";
    let args = json!({
        "input": bibtex,
        "pdf_path": pdf,
        "project_id": project["id"],
        "download_pdf": false,
        "idempotency_key": "add-ref-1",
    });
    let out = l.call("add_reference", &args).unwrap();
    assert_eq!(out["citekey"], "Added2025");
    let r = l
        .call("get_reference", &json!({"id":out["id"]}))
        .unwrap();
    assert_eq!(r["pdf_path"], json!(pdf.to_str().unwrap()));
    let ctx = l
        .call("project_context", &json!({"project_id":project["id"]}))
        .unwrap();
    assert!(
        ctx["items"]
            .as_array()
            .unwrap()
            .iter()
            .any(|i| i["id"] == out["id"])
    );

    // Retrying with the same idempotency key returns the cached result
    // rather than importing a second time.
    let count = l.call("status", &json!({})).unwrap()["references"]
        .as_i64()
        .unwrap();
    let retried = l.call("add_reference", &args).unwrap();
    assert_eq!(retried, out);
    assert_eq!(
        l.call("status", &json!({})).unwrap()["references"],
        json!(count)
    );

    // Reusing the same key with different content is rejected.
    let mut different = args.clone();
    different["input"] = json!("@article{Other,title={Other},year={2026}}");
    assert!(l.call("add_reference", &different).is_err());
}

#[test]
fn add_reference_is_atomic_when_the_pdf_path_is_unreadable() {
    let (_d, l, _) = setup();
    let bibtex = "@article{ShouldNotExist2025,title={Should not be saved},year={2025}}";
    let result = l.call(
        "add_reference",
        &json!({"input":bibtex,"pdf_path":"/nonexistent/absolute/path-omabib-test.pdf","download_pdf":false}),
    );
    assert!(result.is_err());
    assert!(
        l.call("get_reference", &json!({"id":"ShouldNotExist2025"}))
            .is_err()
    );
}

#[test]
fn add_reference_requires_input_or_pdf_path() {
    let (_d, l, _) = setup();
    assert!(l.call("add_reference", &json!({})).is_err());
}

#[test]
fn attention_views_and_overview_flag() {
    let (d, l, r) = setup();
    let book = r["items"][1]["id"].as_str().unwrap().to_string();
    let keys = |v: &Value| -> Vec<String> {
        v["results"]
            .as_array()
            .unwrap()
            .iter()
            .map(|h| h["citekey"].as_str().unwrap().to_string())
            .collect()
    };
    // Browsing (blank query) and ranked search both honor the view.
    let missing = l
        .call("search", &json!({"query":"","view":"missing_abstract","limit":25}))
        .unwrap();
    assert!(!keys(&missing).contains(&"Smith2024".to_string()));
    assert!(keys(&missing).contains(&"Book2020".to_string()));
    let ranked = l
        .call("search", &json!({"query":"networks creativity","view":"missing_abstract"}))
        .unwrap();
    assert!(keys(&ranked).is_empty());

    let pdf = d.path().join("book.pdf");
    std::fs::write(&pdf, b"%PDF-1.4\n%%EOF\n").unwrap();
    l.call("add_pdf", &json!({"ref_id":book,"path":pdf})).unwrap();
    let no_pdf = l
        .call("search", &json!({"query":"","view":"missing_pdf","limit":25}))
        .unwrap();
    assert!(!keys(&no_pdf).contains(&"Book2020".to_string()));
    assert!(keys(&no_pdf).contains(&"Smith2024".to_string()));
    assert!(l.call("search", &json!({"query":"","view":"everything"})).is_err());

    // has_overview follows the cached-summary table.
    let flag = |q: &str| {
        l.call("search", &json!({"query":q}))
            .unwrap()["results"][0]["has_overview"]
            .clone()
    };
    assert_eq!(flag("measurement theory"), json!(false));
    let c = rusqlite::Connection::open(d.path().join("library.db")).unwrap();
    c.execute(
        "INSERT INTO external_summaries(ref_id,source,external_id,source_url,body) VALUES(?,'alphaXiv','x','https://example.org','body')",
        [&book],
    )
    .unwrap();
    assert_eq!(flag("measurement theory"), json!(true));
    let browsed = l.call("search", &json!({"query":"","limit":25})).unwrap();
    let hit = browsed["results"]
        .as_array()
        .unwrap()
        .iter()
        .find(|h| h["citekey"] == "Book2020")
        .unwrap();
    assert_eq!(hit["has_overview"], json!(true));
}

#[test]
fn get_reference_lists_projects_and_added_date() {
    let (_d, l, r) = setup();
    let rid = first(&r);
    let beta = l.call("create_project", &json!({"name":"Beta"})).unwrap();
    let alpha = l.call("create_project", &json!({"name":"Alpha"})).unwrap();
    for p in [&beta, &alpha] {
        l.call("associate", &json!({"ref_id":rid,"project_id":p["id"],"labels":[]}))
            .unwrap();
    }
    let got = l.call("get_reference", &json!({"id":rid})).unwrap();
    let names: Vec<&str> = got["projects"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, ["Alpha", "Beta"]);
    assert!(got["created_at"].as_str().unwrap().starts_with("20"));
}
