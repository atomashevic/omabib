//! Sync through an rclone older than 1.66, which rejects `--no-update-dir-modtime`.
//! A stand-in rclone reports 1.60.1, fails on that flag like the real one, and
//! passes everything else to the installed rclone.
use omabib::db::Library;
use serde_json::json;
use std::os::unix::fs::PermissionsExt;

/// A path inside a single-quoted shell word.
fn shell_quote(path: &std::path::Path) -> String {
    format!("'{}'", path.display().to_string().replace('\'', "'\\''"))
}

#[test]
fn a_pdf_syncs_through_rclone_1_60() {
    let Some(real) = omabib::sync::store::rclone_binary() else {
        eprintln!("rclone not installed; skipped");
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    let fake = dir.path().join("rclone");
    std::fs::write(
        &fake,
        format!(
            "#!/bin/sh\n\
             for a in \"$@\"; do\n  \
               if [ \"$a\" = --no-update-dir-modtime ]; then echo 'Fatal error: unknown flag: --no-update-dir-modtime' >&2; exit 1; fi\n\
             done\n\
             if [ \"$1\" = version ]; then echo 'rclone v1.60.1'; exit 0; fi\n\
             exec {} \"$@\"\n",
            shell_quote(&real)
        ),
    )
    .unwrap();
    std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
    let cloud = dir.path().join("cloud");
    std::fs::create_dir_all(&cloud).unwrap();
    let config = dir.path().join("rclone.conf");
    std::fs::write(
        &config,
        format!("[shared]\ntype = alias\nremote = {}\n", cloud.display()),
    )
    .unwrap();
    // The only test in this binary, so nothing else reads these meanwhile.
    unsafe {
        std::env::set_var("OMABIB_RCLONE_BIN", &fake);
        std::env::set_var("OMABIB_RCLONE_CONFIG", &config);
    }
    let lib = Library::open_with_vocabulary(dir.path().join("library.db"), false).unwrap();
    let call = |method: &str, a: serde_json::Value| {
        lib.call(method, &a)
            .unwrap_or_else(|e| panic!("{method}: {e:#}"))
    };
    let rid = call(
        "import_bibtex",
        json!({"bibtex":"@article{old_rclone,title={Old rclone},doi={10.7/old}}"}),
    )["items"][0]["id"]
        .as_str()
        .unwrap()
        .to_string();
    let pdf = dir.path().join("paper.pdf");
    std::fs::write(&pdf, b"%PDF-1.4\n%%EOF\n").unwrap();
    call("add_pdf", json!({"ref_id":rid,"path":pdf}));
    call(
        "sync_connect",
        json!({"provider":"rclone","remote":"shared"}),
    );
    call("sync_start", json!({"mode":"new"}));
    assert!(cloud.join("Omabib/library.json").is_file());
    assert!(cloud.join("Omabib/pdfs/old_rclone.pdf").is_file());
}
