use base64::{Engine, engine::general_purpose::STANDARD};
use omabib::db::Library;
use serde_json::json;

#[test]
fn visual_notes_are_atomic_scoped_retry_safe_and_backed_up() {
    let dir=tempfile::tempdir().unwrap();
    let db=dir.path().join("library.db");
    let lib=Library::open(db).unwrap();
    let rid=lib.call("import_bibtex", &json!({"bibtex":"@article{clip,title={Visual reference}}"})).unwrap()["items"][0]["id"].clone();
    let project=lib.call("create_project", &json!({"name":"Visual project"})).unwrap()["id"].clone();
    let pdf=dir.path().join("paper.pdf"); std::fs::write(&pdf,b"%PDF-1.4\n").unwrap();
    lib.call("attach", &json!({"ref_id":rid,"path":pdf,"file_type":"pdf"})).unwrap();
    let image=dir.path().join("clip.png");
    let png=STANDARD.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=").unwrap();
    std::fs::write(&image,&png).unwrap();
    let args=json!({"ref_id":rid,"project_id":project,"body":"","provenance":"human","image_path":image,"source_pdf":pdf,"page":3,"rectangle":{"x":1,"y":2,"width":100,"height":80},"idempotency_key":"visual-save"});
    let n=lib.call("add_visual_note", &args).unwrap();
    assert_eq!(n["body"], ""); assert_eq!(n["image"]["page"],3);
    assert_eq!(n["image"]["width"],1); assert!(n["image"].get("data").is_none());
    let query=json!({"note_id":n["id"],"project_id":project});
    let result=lib.call("get_note_image", &query).unwrap();
    assert_eq!(STANDARD.decode(result["data"].as_str().unwrap()).unwrap(),png);
    assert!(lib.call("get_note_image", &json!({"note_id":n["id"],"project_id":null})).is_err());
    std::fs::remove_file(&image).unwrap();
    assert_eq!(lib.call("add_visual_note", &args).unwrap()["id"],n["id"]);
    let edited=lib.call("update_note", &json!({"id":n["id"],"project_id":project,"expected_revision":1,"body":"Equation commentary","provenance":"human"})).unwrap();
    assert_eq!(edited["image"],n["image"]);
    let mut bad=args.clone();bad["idempotency_key"]=json!("bad-image");
    std::fs::write(&image,b"not a PNG").unwrap();
    assert!(lib.call("add_visual_note", &bad).is_err());
    assert_eq!(lib.call("status",&json!({})).unwrap()["notes"],1);
    let backup=dir.path().join("backup.db");lib.call("backup",&json!({"path":backup})).unwrap();
    let restored=Library::open(backup).unwrap();
    assert_eq!(restored.call("get_note_image",&query).unwrap()["data"],result["data"]);
}

#[test]
fn pdf_lookup_uses_full_path_and_rejects_ambiguity() {
    let dir = tempfile::tempdir().unwrap();
    let lib = Library::open(dir.path().join("db")).unwrap();
    let refs = lib.call("import_bibtex", &json!({"bibtex":"@article{a,title={A}}\n@article{b,title={B}}"})).unwrap();
    let path = dir.path().join("paper.pdf");
    std::fs::write(&path, b"%PDF-1.4\n").unwrap();
    let a = &refs["items"][0]["id"];
    lib.call("attach", &json!({"ref_id":a,"path":path,"file_type":"pdf"})).unwrap();
    assert_eq!(lib.call("find_reference_by_pdf", &json!({"path":path})).unwrap()["ref_id"], *a);
    let alias = dir.path().join("alias.pdf");
    std::os::unix::fs::symlink(&path, &alias).unwrap();
    assert_eq!(lib.call("find_reference_by_pdf", &json!({"path":alias})).unwrap()["ref_id"], *a);
    std::fs::create_dir(dir.path().join("other")).unwrap();
    let other = dir.path().join("other/paper.pdf");
    std::fs::write(&other,b"%PDF-1.4\n").unwrap();
    assert!(lib.call("find_reference_by_pdf", &json!({"path":other})).is_err());
    lib.call("attach", &json!({"ref_id":refs["items"][1]["id"],"path":path,"file_type":"pdf"})).unwrap();
    assert!(lib.call("find_reference_by_pdf", &json!({"path":path})).is_err());
}
