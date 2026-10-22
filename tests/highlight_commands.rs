//! Highlight commands: list, add, update, and delete. Temp directories only.
use omabib::db::{Library, read_connection};
use omabib::mcp;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Mutex;
use std::time::Duration;

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

struct Paper {
    dir: tempfile::TempDir,
    lib: Library,
    pdf: PathBuf,
    bytes: Vec<u8>,
}

impl Paper {
    fn new(key: &str, title: &str) -> Paper {
        let dir = tempfile::tempdir().unwrap();
        let lib = Library::open_with_vocabulary(dir.path().join("library.db"), false).unwrap();
        let pdf = dir.path().join("paper.pdf");
        one_page_pdf(&pdf, title);
        let bytes = std::fs::read(&pdf).unwrap();
        let bib = format!("@article{{{key},title={{{title}}}}}");
        lib.call("import_bibtex", &json!({"bibtex": bib})).unwrap();
        lib.call("add_pdf", &json!({"ref_id": key, "path": &pdf}))
            .unwrap();
        Paper { dir, lib, pdf, bytes }
    }

    fn attachment(&self, key: &str) -> String {
        self.lib
            .call(
                "get_reference",
                &json!({"id": key, "include_attachments": true, "include_metadata": false}),
            )
            .unwrap()["attachments"][0]["id"]
            .as_str()
            .unwrap()
            .to_string()
    }

    fn add(&self, key: &str, quote: &str) -> Value {
        let attachment = self.attachment(key);
        self.lib
            .call(
                "add_highlight",
                &json!({
                    "ref_id": key,
                    "attachment_id": attachment,
                    "page": 1,
                    "rects": [[10.0, 20.0, 30.0, 40.0], [10.0, 44.0, 80.0, 60.0]],
                    "quote": quote,
                }),
            )
            .unwrap()
    }
}

fn highlight_fields(item: &Value) -> Vec<&str> {
    let mut keys: Vec<&str> = item.as_object().unwrap().keys().map(String::as_str).collect();
    keys.sort();
    keys
}

const LIST_FIELDS: [&str; 11] = [
    "attachment_id",
    "citekey",
    "color",
    "comment",
    "created_at",
    "id",
    "page",
    "quote",
    "ref_id",
    "stale",
    "updated_at",
];

#[test]
fn add_update_and_delete_go_through_the_same_operations() {
    let paper = Paper::new("okafor_sparse_2026", "Sparse attention");
    let saved = paper.add("okafor_sparse_2026", "line one\nline two");
    assert_eq!(saved["color"], "yellow");
    assert_eq!(saved["comment"], "");
    assert_eq!(saved["quote"], "line one\nline two");
    assert_eq!(saved["page"], 1);
    assert_eq!(saved["rects"][0], json!([10.0, 20.0, 30.0, 40.0]));
    let id = saved["id"].as_str().unwrap();
    let created_at = saved["created_at"].as_str().unwrap().to_string();

    let colored = |color: &str| {
        paper.lib.call(
            "add_highlight",
            &json!({
                "ref_id": "okafor_sparse_2026",
                "attachment_id": saved["attachment_id"],
                "page": 1,
                "rects": [[1, 2, 3, 4]],
                "quote": "in color",
                "color": color,
            }),
        )
    };
    let red = colored("red").unwrap();
    assert_eq!(red["color"], "red", "a new highlight takes the color asked for");
    assert!(colored("orange").is_err(), "only the five highlight colors");
    paper.lib.call("delete_highlight", &json!({"id": red["id"]})).unwrap();
    assert!(
        paper
            .lib
            .call(
                "add_highlight",
                &json!({"ref_id": "missing", "attachment_id": "nope", "page": 1, "rects": [[1, 2, 3, 4]], "quote": "x"}),
            )
            .is_err()
    );
    assert!(
        paper
            .lib
            .call(
                "add_highlight",
                &json!({"ref_id": "okafor_sparse_2026", "attachment_id": saved["attachment_id"], "page": 0, "rects": [[1, 2, 3, 4]], "quote": "x"}),
            )
            .is_err()
    );
    assert!(
        paper
            .lib
            .call(
                "add_highlight",
                &json!({"ref_id": "okafor_sparse_2026", "attachment_id": saved["attachment_id"], "page": 1, "rects": [], "quote": "x"}),
            )
            .is_err()
    );

    let long = "y".repeat(9000);
    let capped = paper
        .lib
        .call(
            "update_highlight",
            &json!({"id": id, "comment": long}),
        )
        .unwrap();
    assert_eq!(capped["comment"].as_str().unwrap().len(), 8 * 1024);
    assert_eq!(capped["created_at"], created_at);
    assert_eq!(capped["quote"], "line one\nline two");
    assert_eq!(capped["rects"][1], json!([10.0, 44.0, 80.0, 60.0]));

    std::thread::sleep(Duration::from_millis(30));
    let edited = paper
        .lib
        .call(
            "update_highlight",
            &json!({"id": id, "color": "purple", "comment": "see the figure"}),
        )
        .unwrap();
    assert_eq!(edited["color"], "purple");
    assert_eq!(edited["comment"], "see the figure");
    assert_eq!(edited["created_at"], created_at);
    assert_ne!(edited["updated_at"], created_at);
    assert!(
        paper
            .lib
            .call("update_highlight", &json!({"id": id, "color": "orange"}))
            .is_err()
    );
    assert!(
        paper
            .lib
            .call("update_highlight", &json!({"id": id}))
            .is_err()
    );
    assert_eq!(
        paper.lib.call("get_reference", &json!({"id": "okafor_sparse_2026"})).unwrap()["title"],
        "Sparse attention"
    );

    let gone = paper
        .lib
        .call("delete_highlight", &json!({"id": id}))
        .unwrap();
    assert_eq!(gone, json!({"id": id, "deleted": true}));
    assert!(paper.lib.call("delete_highlight", &json!({"id": id})).is_err());
    let empty = paper
        .lib
        .call("list_highlights", &json!({"ref_id": "okafor_sparse_2026"}))
        .unwrap();
    assert_eq!(empty["highlights"].as_array().unwrap().len(), 0);
    assert!(empty["next_cursor"].is_null());
    assert_eq!(std::fs::read(&paper.pdf).unwrap(), paper.bytes);
    let version: i64 = read_connection(&paper.lib.path)
        .unwrap()
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .unwrap();
    assert_eq!(version, 1);
    let _ = paper.dir;
}

#[test]
fn list_highlights_orders_by_update_then_id_and_pages() {
    let paper = Paper::new("one", "First paper");
    let second_pdf = paper.dir.path().join("other.pdf");
    one_page_pdf(&second_pdf, "Second paper");
    paper
        .lib
        .call("import_bibtex", &json!({"bibtex": "@article{two,title={Second paper}}"}))
        .unwrap();
    paper
        .lib
        .call("add_pdf", &json!({"ref_id": "two", "path": &second_pdf}))
        .unwrap();
    let a = paper.add("one", "alpha");
    let b = paper.add("one", "beta");
    let c = paper.add("two", "gamma");
    let set = |id: &str, at: &str| {
        let conn = rusqlite::Connection::open(&paper.lib.path).unwrap();
        conn.busy_timeout(Duration::from_secs(5)).unwrap();
        conn.execute(
            "UPDATE highlights SET updated_at=?1 WHERE id=?2",
            rusqlite::params![at, id],
        )
        .unwrap();
    };
    set(a["id"].as_str().unwrap(), "2026-01-01T00:00:00.000Z");
    set(b["id"].as_str().unwrap(), "2026-01-03T00:00:00.000Z");
    set(c["id"].as_str().unwrap(), "2026-01-02T00:00:00.000Z");

    let page = paper
        .lib
        .call("list_highlights", &json!({"limit": 2}))
        .unwrap();
    let ids: Vec<&str> = page["highlights"]
        .as_array()
        .unwrap()
        .iter()
        .map(|h| h["id"].as_str().unwrap())
        .collect();
    assert_eq!(ids, vec![b["id"].as_str().unwrap(), c["id"].as_str().unwrap()]);
    assert_eq!(highlight_fields(&page["highlights"][0]), LIST_FIELDS.to_vec());
    assert!(page["highlights"][0].get("rects").is_none());
    assert_eq!(page["highlights"][0]["citekey"], "one");
    assert_eq!(page["highlights"][0]["stale"], false);
    assert_eq!(page["next_cursor"], 2);

    let rest = paper
        .lib
        .call("list_highlights", &json!({"limit": 2, "cursor": page["next_cursor"]}))
        .unwrap();
    assert_eq!(rest["highlights"][0]["id"], a["id"]);
    assert!(rest["next_cursor"].is_null());

    let one = paper
        .lib
        .call("list_highlights", &json!({"ref_id": "one"}))
        .unwrap();
    assert_eq!(one["highlights"].as_array().unwrap().len(), 2);
    assert!(one["highlights"].as_array().unwrap().iter().all(|h| h["citekey"] == "one"));
    let by_key = paper
        .lib
        .call("list_highlights", &json!({"ref_id": "two"}))
        .unwrap();
    assert_eq!(by_key["highlights"][0]["quote"], "gamma");
    assert!(paper.lib.call("list_highlights", &json!({"ref_id": "missing"})).is_err());
    assert!(paper.lib.call("list_highlights", &json!({"limit": 0})).is_err());
    assert!(paper.lib.call("list_highlights", &json!({"limit": 101})).is_err());

    // Same timestamp: the greater id comes first.
    set(a["id"].as_str().unwrap(), "2026-05-01T00:00:00.000Z");
    set(b["id"].as_str().unwrap(), "2026-05-01T00:00:00.000Z");
    let tied = paper
        .lib
        .call("list_highlights", &json!({"ref_id": "one", "limit": 2}))
        .unwrap();
    let mut expected = vec![a["id"].as_str().unwrap(), b["id"].as_str().unwrap()];
    expected.sort_by(|x, y| y.cmp(x));
    let got: Vec<&str> = tied["highlights"]
        .as_array()
        .unwrap()
        .iter()
        .map(|h| h["id"].as_str().unwrap())
        .collect();
    assert_eq!(got, expected);
    assert_eq!(std::fs::read(&paper.pdf).unwrap(), paper.bytes);
    assert!(!std::fs::read(&second_pdf).unwrap().is_empty());
}

#[test]
fn a_replaced_pdf_is_marked_stale_and_get_reference_is_unchanged() {
    let paper = Paper::new("k", "Kept");
    let saved = paper.add("k", "word");
    let reference = paper
        .lib
        .call(
            "get_reference",
            &json!({"id": "k", "include_notes": true, "include_attachments": true, "include_metadata": true}),
        )
        .unwrap();
    assert!(reference.get("highlights").is_none());
    assert_eq!(reference["title"], "Kept");
    assert!(reference.get("quote").is_none());

    let listed = paper.lib.call("list_highlights", &json!({})).unwrap();
    assert_eq!(listed["highlights"][0]["stale"], false);
    assert_eq!(listed["highlights"][0]["id"], saved["id"]);

    paper
        .lib
        .call(
            "relink_attachment",
            &json!({"id": saved["attachment_id"], "path": &paper.pdf, "fingerprint": "replaced"}),
        )
        .unwrap();
    let stale = paper.lib.call("list_highlights", &json!({"ref_id": "k"})).unwrap();
    assert_eq!(stale["highlights"][0]["stale"], true);
    assert_eq!(stale["highlights"][0]["quote"], "word");

    paper
        .lib
        .call(
            "relink_attachment",
            &json!({
                "id": saved["attachment_id"],
                "path": &paper.pdf,
                "fingerprint": saved["source_sha256"],
            }),
        )
        .unwrap();
    let fresh = paper.lib.call("list_highlights", &json!({"ref_id": "k"})).unwrap();
    assert_eq!(fresh["highlights"][0]["stale"], false);

    paper
        .lib
        .call("remove_pdf", &json!({"attachment_id": saved["attachment_id"]}))
        .unwrap();
    let missing = paper.lib.call("list_highlights", &json!({})).unwrap();
    assert_eq!(missing["highlights"][0]["stale"], true);
    assert_eq!(std::fs::read(&paper.pdf).unwrap(), paper.bytes);
}

#[test]
fn mcp_marks_delete_highlight_destructive_and_leaves_get_reference() {
    let tools = mcp::tools();
    let tool = |name: &str| -> Value {
        tools.iter().find(|t| t["name"] == name).unwrap().clone()
    };
    assert_eq!(tool("list_highlights")["annotations"]["readOnlyHint"], true);
    assert_eq!(tool("list_highlights")["annotations"]["destructiveHint"], false);
    assert_eq!(tool("add_highlight")["annotations"]["readOnlyHint"], false);
    assert_eq!(tool("add_highlight")["annotations"]["destructiveHint"], false);
    assert_eq!(tool("update_highlight")["annotations"]["readOnlyHint"], false);
    assert_eq!(tool("update_highlight")["annotations"]["destructiveHint"], false);
    assert_eq!(tool("delete_highlight")["annotations"]["destructiveHint"], true);
    assert_eq!(tool("delete_highlight")["annotations"]["readOnlyHint"], false);
    assert_eq!(tool("delete_note")["annotations"]["destructiveHint"], true);

    let mut reference: Vec<_> = tool("get_reference")["inputSchema"]["properties"]
        .as_object()
        .unwrap()
        .keys()
        .cloned()
        .collect();
    reference.sort();
    assert_eq!(
        reference,
        [
            "id",
            "include_attachments",
            "include_metadata",
            "include_notes",
            "include_other_projects",
            "note_chars",
            "note_cursor",
            "note_limit",
            "project_id",
        ]
    );

    let ran = Mutex::new(false);
    let asked = Mutex::new(false);
    let err = mcp::chat_call(
        "c",
        "delete_highlight",
        &json!({"id": "h"}),
        |_, _| {
            *ran.lock().unwrap() = true;
            Ok(json!({}))
        },
        |_, params| {
            *asked.lock().unwrap() = true;
            assert_eq!(params["tool"], "mcp__omabib__delete_highlight");
            Ok(json!({"allow": false, "message": "No"}))
        },
    );
    assert_eq!(err.unwrap_err().to_string(), "No");
    assert!(*asked.lock().unwrap());
    assert!(!*ran.lock().unwrap());
    mcp::chat_call(
        "c",
        "list_highlights",
        &json!({}),
        |name, _| {
            assert_eq!(name, "list_highlights");
            Ok(json!({"highlights": []}))
        },
        |_, _| panic!("listing highlights is a read"),
    )
    .unwrap();
}

struct Sandbox {
    dir: tempfile::TempDir,
}

impl Sandbox {
    fn new() -> Sandbox {
        Sandbox {
            dir: tempfile::tempdir().unwrap(),
        }
    }
    fn path(&self, rel: &str) -> PathBuf {
        self.dir.path().join(rel)
    }
    fn command(&self, args: &[&str]) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_omabib"));
        command
            .args(args)
            .env("OMABIB_SOCKET", self.path("run/omabib/socket"))
            .env("OMABIB_DB", self.path("library.db"))
            .env("XDG_STATE_HOME", self.path("state"))
            .env("XDG_CONFIG_HOME", self.path("config"))
            .env_remove("OMABIB_NO_AUTOSTART");
        command
    }
    fn call(&self, method: &str, params: &Value) -> Value {
        let out = self
            .command(&["call", method, &params.to_string()])
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{method}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        serde_json::from_slice(&out.stdout).unwrap()
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        let Ok(text) = std::fs::read_to_string(self.path("run/omabib/server.lock")) else {
            return;
        };
        let Ok(pid) = text.trim().parse::<i32>() else {
            return;
        };
        unsafe { libc::kill(pid, libc::SIGTERM) };
    }
}

#[test]
fn omabib_call_and_schema_use_the_highlight_commands() {
    let sandbox = Sandbox::new();
    let schema = sandbox
        .command(&[
            "schema",
            "list_highlights",
            "add_highlight",
            "update_highlight",
            "delete_highlight",
        ])
        .output()
        .unwrap();
    assert!(schema.status.success(), "{}", String::from_utf8_lossy(&schema.stderr));
    let schema: Value = serde_json::from_slice(&schema.stdout).unwrap();
    let tools = schema["tools"].as_array().unwrap();
    assert_eq!(tools.len(), 4);
    let named = |name: &str| tools.iter().find(|t| t["name"] == name).unwrap();
    assert_eq!(named("list_highlights")["annotations"]["readOnlyHint"], true);
    assert_eq!(named("delete_highlight")["annotations"]["destructiveHint"], true);
    assert_eq!(named("add_highlight")["annotations"]["destructiveHint"], false);

    let pdf = sandbox.path("paper.pdf");
    one_page_pdf(&pdf, "Command");
    let before = std::fs::read(&pdf).unwrap();
    sandbox.call("import_bibtex", &json!({"bibtex": "@article{cmd,title={Command}}"}));
    let attachment = sandbox.call("add_pdf", &json!({"ref_id": "cmd", "path": pdf}));
    let saved = sandbox.call(
        "add_highlight",
        &json!({
            "ref_id": "cmd",
            "attachment_id": attachment["id"],
            "page": 1,
            "rects": [[1.0, 2.0, 3.0, 4.0]],
            "quote": "Command",
        }),
    );
    assert_eq!(saved["color"], "yellow");
    let listed = sandbox.call("list_highlights", &json!({}));
    assert_eq!(listed["highlights"][0]["citekey"], "cmd");
    assert_eq!(listed["highlights"][0]["quote"], "Command");
    assert_eq!(listed["highlights"][0]["stale"], false);
    let edited = sandbox.call(
        "update_highlight",
        &json!({"id": saved["id"], "color": "blue", "comment": "from the command"}),
    );
    assert_eq!(edited["color"], "blue");
    assert_eq!(edited["comment"], "from the command");
    let deleted = sandbox.call("delete_highlight", &json!({"id": saved["id"]}));
    assert_eq!(deleted["deleted"], true);
    let after = sandbox.call("list_highlights", &json!({"ref_id": "cmd"}));
    assert_eq!(after["highlights"].as_array().unwrap().len(), 0);
    assert_eq!(std::fs::read(&pdf).unwrap(), before);
    let reference = sandbox.call("get_reference", &json!({"id": "cmd"}));
    assert!(reference.get("highlights").is_none());
}

#[test]
fn pdf_highlights_returns_boxes_only_while_the_file_matches() {
    let paper = Paper::new("paint", "Paint");
    let saved = paper.add("paint", "line");
    let painted = paper
        .lib
        .call(
            "pdf_highlights",
            &json!({"ref_id": "paint", "attachment_id": saved["attachment_id"]}),
        )
        .unwrap();
    let rows = painted["highlights"].as_array().unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["id"], saved["id"]);
    assert_eq!(rows[0]["quote"], "line");
    assert_eq!(rows[0]["color"], "yellow");
    assert_eq!(rows[0]["rects"][0], json!([10.0, 20.0, 30.0, 40.0]));
    assert_eq!(rows[0]["rects"][1], json!([10.0, 44.0, 80.0, 60.0]));
    assert!(rows[0].get("stale").is_none());

    paper
        .lib
        .call(
            "relink_attachment",
            &json!({"id": saved["attachment_id"], "path": &paper.pdf, "fingerprint": "replaced"}),
        )
        .unwrap();
    let hidden = paper
        .lib
        .call(
            "pdf_highlights",
            &json!({"ref_id": "paint", "attachment_id": saved["attachment_id"]}),
        )
        .unwrap();
    assert!(hidden["highlights"].as_array().unwrap().is_empty());
    assert_eq!(std::fs::read(&paper.pdf).unwrap(), paper.bytes);
    assert!(!mcp::tools().iter().any(|t| t["name"] == "pdf_highlights"));
}
