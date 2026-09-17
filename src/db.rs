use anyhow::{Context, Result, bail, ensure};
use biblatex::{Bibliography, ChunksExt};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashSet},
    path::{Path, PathBuf},
    sync::{Mutex, RwLock},
    time::Duration,
};
use symspell::{SymSpell, SymSpellBuilder, UnicodeStringStrategy};
use unicode_normalization::{UnicodeNormalization, char::is_combining_mark};

pub struct Library {
    pub path: PathBuf,
    pub(crate) writer: Mutex<Connection>,
    pub history_lock: Mutex<()>,
    readers: Mutex<Vec<Connection>>,
    pub spell_ready: std::sync::atomic::AtomicBool,
    pub spell: RwLock<SymSpell<UnicodeStringStrategy>>,
    /// MuPDF rendering for reader tabs and clip notes.
    pub pdf: crate::pdf::Pdf,
    /// Claude Code and Codex chats about a reference.
    pub chats: std::sync::Arc<crate::chat::Chats>,
}
pub struct ReadLease<'a> {
    connection: Option<Connection>,
    pool: &'a Mutex<Vec<Connection>>,
}
impl std::ops::Deref for ReadLease<'_> {
    type Target = Connection;
    fn deref(&self) -> &Connection {
        self.connection.as_ref().unwrap()
    }
}
impl Drop for ReadLease<'_> {
    fn drop(&mut self) {
        if let Some(c) = self.connection.take() {
            let _ = c.progress_handler(0, None::<fn() -> bool>);
            let mut pool = self.pool.lock().unwrap();
            if pool.len() < 8 {
                pool.push(c);
            }
        }
    }
}
pub fn parse_bibtex(raw: &str) -> Result<Bibliography> {
    match Bibliography::parse(raw) {
        Ok(b) => Ok(b),
        Err(original) => {
            let months = [
                "January",
                "February",
                "March",
                "April",
                "May",
                "June",
                "July",
                "August",
                "September",
                "October",
                "November",
                "December",
            ];
            let defaults = months
                .iter()
                .map(|m| format!("@string{{{m}=\"{m}\"}}\n"))
                .collect::<String>();
            Bibliography::parse(&(defaults + raw)).map_err(|_| anyhow::anyhow!("{original}"))
        }
    }
}
/// Repair only parser-identified, unambiguous issues; retain source text separately.
fn parse_import(raw: &str) -> Result<(Vec<biblatex::Entry>, Vec<Value>)> {
    use biblatex::{ParseErrorKind, RawBibliography, Token};
    let mut repairs = Vec::new();
    let mut source = raw.trim_start_matches('\u{feff}').to_string();
    if source != raw {
        repairs.push(json!({"kind":"removed_bom"}));
    }
    // Explicit user macros follow these defaults and take precedence.
    let months = [
        "January",
        "February",
        "March",
        "April",
        "May",
        "June",
        "July",
        "August",
        "September",
        "October",
        "November",
        "December",
    ];
    let defaults = months
        .iter()
        .map(|m| format!("@string{{{m}=\"{m}\"}}\n"))
        .collect::<String>();
    source = defaults + &source;
    let mut parsed = loop {
        match RawBibliography::parse(&source) {
            Ok(b) => break b,
            Err(e) => {
                let at = e.span.start;
                let tail = source.get(at..).unwrap_or("");
                let field = tail
                    .split_once('=')
                    .map(|(k, _)| k.trim())
                    .unwrap_or("")
                    .to_string();
                if matches!(e.kind, ParseErrorKind::Expected(Token::Comma))
                    && !field.is_empty()
                    && field
                        .chars()
                        .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
                    && repairs.len() < 100
                {
                    source.insert(at, ',');
                    repairs
                        .push(json!({"kind":"inserted_missing_comma","field":field.to_string()}));
                } else {
                    return Err(e.into());
                }
            }
        }
    };
    let original_keys: Vec<String> = parsed
        .entries
        .iter()
        .map(|e| e.v.key.v.to_string())
        .collect();
    let mut used: HashSet<String> = original_keys.iter().cloned().collect();
    let mut seen = HashSet::new();
    let mut temporary = Vec::new();
    for (i, key) in original_keys.iter().enumerate() {
        let mut name = key.clone();
        if !seen.insert(key.clone()) {
            name = format!("omabib_import_duplicate_{i}");
            while !used.insert(name.clone()) {
                name.push('_');
            }
            repairs.push(json!({"kind":"duplicate_key","citekey":key}));
        }
        temporary.push(name);
    }
    for (i, entry) in parsed.entries.iter_mut().enumerate() {
        entry.v.key.v = &temporary[i];
        let mut positions = BTreeMap::new();
        let mut fields: Vec<biblatex::Pair<'_>> = Vec::new();
        for field in std::mem::take(&mut entry.v.fields) {
            let key = field.key.v.to_ascii_lowercase();
            if let Some(&at) = positions.get(&key) {
                let prior: &biblatex::Pair<'_> = &fields[at];
                let empty =
                    prior.value.v.iter().all(
                        |c| matches!(c.v,biblatex::RawChunk::Normal(t) if t.trim().is_empty()),
                    );
                if empty {
                    fields[at] = field;
                }
                repairs.push(json!({"kind":"duplicate_field","citekey":original_keys[i],"field":key,"resolution":"first nonempty value retained"}));
            } else {
                positions.insert(key, fields.len());
                fields.push(field);
            }
        }
        entry.v.fields = fields;
    }
    let bibliography = Bibliography::from_raw(parsed)?;
    let entries = bibliography
        .iter()
        .cloned()
        .zip(original_keys)
        .map(|(mut e, key)| {
            e.key = key;
            e
        })
        .collect();
    Ok((entries, repairs))
}
pub(crate) fn serialize_entry(e: &biblatex::Entry) -> String {
    let mut out = format!("@{}{{{},\n", e.entry_type, e.key);
    for (key, value) in &e.fields {
        let verbatim = matches!(
            key.as_str(),
            "file"
                | "doi"
                | "uri"
                | "eprint"
                | "verba"
                | "verbb"
                | "verbc"
                | "pdf"
                | "url"
                | "urlraw"
        );
        out.push_str(&format!(
            "{key} = {},\n",
            value.to_biblatex_string(verbatim)
        ));
    }
    out.push('}');
    out
}
pub fn normalize(s: &str) -> String {
    s.nfkd()
        .filter(|c| !is_combining_mark(*c))
        .flat_map(char::to_lowercase)
        .collect()
}
pub fn id() -> String {
    uuid::Uuid::new_v4().to_string()
}
pub fn text<'a>(v: &'a Value, key: &str) -> &'a str {
    v.get(key).and_then(Value::as_str).unwrap_or("")
}
pub fn required<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    let s = text(v, key);
    ensure!(!s.trim().is_empty(), "{key} is required");
    Ok(s)
}
pub fn clip(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}
fn json_field(v: &Value, key: &str, default: Value) -> String {
    v.get(key).unwrap_or(&default).to_string()
}
pub fn normalize_doi(s: &str) -> String {
    s.trim()
        .trim_start_matches("https://doi.org/")
        .trim_start_matches("http://doi.org/")
        .trim_start_matches("doi:")
        .to_lowercase()
}
pub fn read_connection(path: &Path) -> Result<Connection> {
    let c = Connection::open(path)?;
    c.busy_timeout(Duration::from_secs(5))?;
    c.execute_batch("PRAGMA foreign_keys=ON; PRAGMA cache_size=-16000;")?;
    Ok(c)
}
impl Library {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        Self::open_with_vocabulary(path, true)
    }
    pub fn open_with_vocabulary(path: impl AsRef<Path>, eager: bool) -> Result<Self> {
        let path = path.as_ref().to_path_buf();
        if let Some(p) = path.parent() {
            std::fs::create_dir_all(p)?;
        }
        let c = read_connection(&path)?;
        let version: i64 = c.pragma_query_value(None, "user_version", |r| r.get(0))?;
        ensure!(
            version <= 1,
            "Database schema {version} is newer than this Omabib version"
        );
        c.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;")?;
        if version == 0 {
            c.execute_batch("BEGIN IMMEDIATE;")?;
            if let Err(e) = c.execute_batch(include_str!("schema.sql")) {
                let _ = c.execute_batch("ROLLBACK");
                return Err(e.into());
            }
            c.execute_batch("COMMIT;")?;
        }
        // Existing v1 libraries need the browse index too. IF NOT EXISTS is
        // cheap after the first open and keeps the data format unchanged.
        c.execute_batch(
            "CREATE INDEX IF NOT EXISTS refs_added ON refs(created_at DESC, id DESC); CREATE INDEX IF NOT EXISTS attachments_pdf_path ON attachments(path,ref_id) WHERE file_type='pdf';",
        )?;
        c.execute_batch(crate::visual::SCHEMA)?;
        c.execute_batch(crate::alphaxiv::SCHEMA)?;
        c.execute_batch(crate::chat::SCHEMA)?;
        crate::chat::migrate(&c)?;
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
        let chats = crate::chat::Chats::new(&path);
        let lib = Self {
            path,
            writer: Mutex::new(c),
            history_lock: Mutex::new(()),
            readers: Mutex::new(Vec::new()),
            spell_ready: std::sync::atomic::AtomicBool::new(false),
            spell: RwLock::new(
                SymSpellBuilder::default()
                    .max_dictionary_edit_distance(1)
                    .build()
                    .unwrap(),
            ),
            pdf: crate::pdf::Pdf::new(crate::pdf::cache_dir()),
            chats,
        };
        if eager {
            lib.load_vocabulary()?;
        }
        Ok(lib)
    }
    pub fn read(&self) -> Result<ReadLease<'_>> {
        let cached = self.readers.lock().unwrap().pop();
        let c = match cached {
            Some(c) => c,
            None => read_connection(&self.path)?,
        };
        Ok(ReadLease {
            connection: Some(c),
            pool: &self.readers,
        })
    }
    pub fn load_vocabulary(&self) -> Result<()> {
        let _writer_guard = self.writer.lock().unwrap();
        let c = read_connection(&self.path)?;
        let mut s = c.prepare(
            "SELECT term,doc FROM vocabulary WHERE length(term)>=4 AND length(term)<=64",
        )?;
        let mut spell: SymSpell<UnicodeStringStrategy> = SymSpellBuilder::default()
            .max_dictionary_edit_distance(1)
            .build()
            .unwrap();
        for r in s.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))? {
            let (t, n) = r?;
            if t.chars().any(char::is_numeric) {
                continue;
            }
            spell.load_dictionary_line(&format!("{t} {n}"), 0, 1, " ");
        }
        *self.spell.write().unwrap() = spell;
        self.spell_ready
            .store(true, std::sync::atomic::Ordering::Release);
        Ok(())
    }
    fn add_words(&self, s: &str) {
        let mut spell = self.spell.write().unwrap();
        for word in normalize(s).split(|c: char| !c.is_alphanumeric()) {
            if !word.chars().any(char::is_numeric) && (4..=64).contains(&word.chars().count()) {
                spell.load_dictionary_line(&format!("{word} 1"), 0, 1, " ");
            }
        }
    }
    pub fn call(&self, method: &str, a: &Value) -> Result<Value> {
        match method {
            "lookup_metadata" => crate::metadata::lookup(self, a),
            "supplement_metadata" => crate::metadata::supplement(self, a),
            "open_target" => crate::metadata::open_target(self, a),
            "get_repo_config" => crate::history::config(self),
            "set_repo_config" => crate::history::save_config(self, a),
            "sync_repo" => crate::history::sync(self, a),
            "repo_check" => crate::history::check(a),
            "repo_setup" => crate::history::setup(self, a),
            "repo_status" => crate::history::status(self, a),
            "add_pdf" => crate::attachments::add(self, a),
            "pull_pdf" => crate::attachments::pull(self, a),
            "get_note_image" => crate::visual::get(&read_connection(&self.path)?, a),
            "get_alphaxiv_overview" => crate::alphaxiv::get(self, a),
            "render_math" => crate::math::render(a),
            "chat_list" => self.chats.list(a),
            "chat_get" => self.chats.get(a),
            "chat_start" => self.chats.start(self, a),
            "chat_models" => self.chats.models(a),
            "chat_set_model" => self.chats.set_model(a),
            "chat_send" => self.chats.send(self, a),
            "chat_cancel" => self.chats.cancel(a),
            "chat_approve" => self.chats.approve(a),
            "chat_delete" => self.chats.delete(a),
            "chat_resume_command" => self.chats.resume_command(a),
            "chat_permission_request" => self.chats.request_approval(a),
            "pdf_open" => crate::pdf::open(self, a),
            "pdf_render" => crate::pdf::render(self, a),
            "pdf_text" => crate::pdf::text(self, a),
            "pdf_search" => crate::pdf::search(self, a),
            "get_pdf" => crate::attachments::get_pdf(self, a),
            "identify_pdf" => crate::attachments::identify_pdf(a),
            "lookup_abstract" => lookup_abstract(self, a),
            "missing_abstracts" => missing_abstracts(self, a),
            "add_reference" => self.add_reference(a),
            "find_reference_by_pdf" => {
                let path = std::fs::canonicalize(required(a, "path")?)?;
                let c = read_connection(&self.path)?;
                let mut stmt = c.prepare("SELECT DISTINCT ref_id FROM attachments WHERE path=? AND file_type='pdf' LIMIT 2")?;
                let ids = stmt.query_map([path.to_string_lossy().as_ref()], |r| r.get::<_, String>(0))?.collect::<rusqlite::Result<Vec<_>>>()?;
                anyhow::ensure!(ids.len() == 1, "PDF must match exactly one Omabib reference (found {})", ids.len());
                Ok(json!({"ref_id":ids[0]}))
            }
            "get_attachment" => {
                let c = read_connection(&self.path)?;
                c.query_row("SELECT id,ref_id,path,file_type,fingerprint FROM attachments WHERE id=?",[required(a,"id")?],|r|Ok(json!({"id":r.get::<_,String>(0)?,"ref_id":r.get::<_,String>(1)?,"path":r.get::<_,String>(2)?,"file_type":r.get::<_,String>(3)?,"fingerprint":r.get::<_,Option<String>>(4)?}))).context("Unknown attachment")
            }
            "search" => crate::search::search(self, a),
            "get_reference" => get_reference(&read_connection(&self.path)?, a),
            "get_references" => get_references(&read_connection(&self.path)?, a),
            "delete_reference_preview" => delete_reference_preview(&read_connection(&self.path)?, a),
            "delete_note_preview" => delete_note_preview(&read_connection(&self.path)?, a),
            "list_projects" => list_projects(&read_connection(&self.path)?, a),
            "project_context" => self.project_context(a),
            "export_bibtex" => export_bibtex(&read_connection(&self.path)?, a),
            "export_notes" => export_notes(&read_connection(&self.path)?, a),
            "status" => {
                let c = read_connection(&self.path)?;
                Ok(
                    json!({"version":env!("CARGO_PKG_VERSION"),"schema":1,"references":c.query_row("SELECT count(*) FROM refs",[],|r|r.get::<_,i64>(0))?,"notes":c.query_row("SELECT count(*) FROM notes",[],|r|r.get::<_,i64>(0))?}),
                )
            }
            "preview_doi" | "preview_entry" => {
                let mut preview = if method == "preview_entry" {
                    crate::ingest::preview(a)?
                } else {
                    preview_doi(a)?
                };
                let mut c = self.writer.lock().unwrap();
                let tx = c.transaction()?;
                let changes = import(&tx, &preview)?;
                tx.rollback()?;
                preview["conflicts"] = changes["conflicts"].clone();
                preview["repairs"] = changes["repairs"].clone();
                preview["citation_keys"] = json!(
                    changes["items"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|item| item["citekey"].clone())
                        .collect::<Vec<_>>()
                );
                Ok(preview)
            }
            "backup" => {
                let dest = PathBuf::from(required(a, "path")?);
                ensure!(!dest.exists(), "Backup destination already exists");
                use std::os::unix::fs::OpenOptionsExt;
                std::fs::OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .mode(0o600)
                    .open(&dest)?;
                let c = self.writer.lock().unwrap();
                c.backup(rusqlite::MAIN_DB, &dest, None)?;
                Ok(json!({"path":dest}))
            }
            "import_bibtex" | "upsert_reference" | "create_project" | "update_project"
            | "associate" | "add_note" | "add_visual_note" | "update_note" | "attach"
            | "remove_pdf" | "relink_attachment" | "apply_metadata" | "delete_note" => self.write(method, a),
            "delete_reference" => {
                let out = self.write(method, a)?;
                let ids: Vec<String> = out["chats_deleted"].as_array().into_iter().flatten().filter_map(|v| v.as_str().map(str::to_owned)).collect();
                self.chats.forget(&ids);
                Ok(out)
            }
            _ => bail!("Unknown operation: {method}"),
        }
    }
    fn write(&self, method: &str, a: &Value) -> Result<Value> {
        let mut c = self.writer.lock().unwrap();
        let tx = c.transaction()?;
        let payload = json!({"method":method,"params":a}).to_string();
        let key = text(a, "idempotency_key");
        if !key.is_empty()
            && let Some((old, result)) = tx
                .query_row(
                    "SELECT payload,result FROM requests WHERE key=?",
                    [key],
                    |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
                )
                .optional()?
        {
            ensure!(
                old == payload,
                "Idempotency key reused with different request"
            );
            return Ok(serde_json::from_str(&result)?);
        }
        let out = match method {
            "import_bibtex" => import(&tx, a)?,
            "upsert_reference" => upsert(&tx, a)?,
            "apply_metadata" => crate::metadata::apply(&tx, a)?,
            "create_project" => {
                let pid = id();
                let name = required(a, "name")?;
                validate_roots(a)?;
                tx.execute(
                    "INSERT INTO projects(id,name,description,roots) VALUES(?,?,?,?)",
                    params![
                        pid,
                        name,
                        text(a, "description"),
                        json_field(a, "roots", json!([]))
                    ],
                )?;
                json!({"id":pid,"name":name})
            }
            "update_project" => {
                validate_roots(a)?;
                ensure!(
                    tx.execute(
                        "UPDATE projects SET name=?,description=?,roots=? WHERE id=?",
                        params![
                            required(a, "name")?,
                            text(a, "description"),
                            json_field(a, "roots", json!([])),
                            required(a, "id")?
                        ]
                    )? == 1,
                    "Unknown project"
                );
                json!({"id":text(a,"id")})
            }
            "associate" => {
                validate_labels(a)?;
                associate_within(
                    &tx,
                    required(a, "ref_id")?,
                    required(a, "project_id")?,
                    &json_field(a, "labels", json!([])),
                )?;
                json!({"associated":true})
            }
            "add_visual_note" => {
                let n = write_note(&tx, method, a)?;
                crate::visual::insert(&tx, a, text(&n, "id"), &self.pdf)?;
                note(&tx, text(&n, "id"))?
            }
            "add_note" | "update_note" => write_note(&tx, method, a)?,
            "delete_note" => {
                ensure!(!key.is_empty(), "idempotency_key required for deletion");
                let preview = delete_note_preview(&tx, a)?;
                ensure!(
                    a.get("expected_revision").and_then(Value::as_i64) == preview["revision"].as_i64(),
                    "Note changed since preview; reopen Delete note"
                );
                ensure!(
                    a.get("confirm_ref_id").and_then(Value::as_str) == preview["ref_id"].as_str(),
                    "Reference confirmation does not match this note"
                );
                let nid = required(&preview, "id")?;
                tx.execute("DELETE FROM note_revisions WHERE note_id=?", [nid])?;
                tx.execute("DELETE FROM note_images WHERE note_id=?", [nid])?;
                tx.execute("DELETE FROM docs WHERE note_id=?", [nid])?;
                ensure!(tx.execute("DELETE FROM notes WHERE id=?", [nid])? == 1, "Note not found");
                json!({"id":nid,"ref_id":preview["ref_id"],"deleted":true,"image_deleted":preview["has_image"]})
            }
            "delete_reference" => {
                ensure!(!key.is_empty(), "idempotency_key required for deletion");
                let preview = delete_reference_preview(&tx, a)?;
                ensure!(
                    a.get("expected_revision").and_then(Value::as_i64) == preview["revision"].as_i64(),
                    "Reference changed since preview; reopen Delete item"
                );
                ensure!(
                    a.get("confirm_citekey").and_then(Value::as_str) == preview["citekey"].as_str(),
                    "Citation key confirmation does not match"
                );
                ensure!(
                    a.get("expected_notes").and_then(Value::as_i64) == preview["note_count"].as_i64()
                        && a.get("expected_attachments").and_then(Value::as_i64) == preview["attachment_count"].as_i64(),
                    "Notes or attachments changed since preview; reopen Delete item"
                );
                let rid = required(&preview, "id")?;
                let chat_ids = {
                    let mut stmt = tx.prepare("SELECT id FROM chats WHERE ref_id=?")?;
                    stmt.query_map([rid], |r| r.get::<_, String>(0))?.collect::<rusqlite::Result<Vec<_>>>()?
                };
                for sql in [
                    "DELETE FROM chat_events WHERE chat_id IN (SELECT id FROM chats WHERE ref_id=?)",
                    "DELETE FROM chats WHERE ref_id=?",
                    "DELETE FROM note_revisions WHERE note_id IN (SELECT id FROM notes WHERE ref_id=?)",
                    "DELETE FROM note_images WHERE note_id IN (SELECT id FROM notes WHERE ref_id=?)",
                    "DELETE FROM docs WHERE ref_id=?",
                    "DELETE FROM notes WHERE ref_id=?",
                    "DELETE FROM attachments WHERE ref_id=?",
                    "DELETE FROM associations WHERE ref_id=?",
                    "DELETE FROM external_summaries WHERE ref_id=?",
                ] {
                    tx.execute(sql, [rid])?;
                }
                ensure!(tx.execute("DELETE FROM refs WHERE id=?", [rid])? == 1, "Reference not found");
                json!({"id":rid,"citekey":preview["citekey"],"deleted":true,"notes_deleted":preview["note_count"],"attachments_unlinked":preview["attachment_count"],"chats_deleted":chat_ids,"files_deleted":false})
            }
            "remove_pdf" => {
                let id = required(a, "attachment_id")?;
                let removed = tx.execute(
                    "DELETE FROM attachments WHERE id=? AND file_type='pdf'",
                    [id],
                )?;
                json!({"attachment_id":id,"removed":removed>0,"file_deleted":false})
            }
            "relink_attachment" => {
                let id = required(a, "id")?;
                let path = required(a, "path")?;
                ensure!(
                    Path::new(path).is_absolute() && Path::new(path).is_file(),
                    "PDF path is unavailable"
                );
                ensure!(
                    tx.execute(
                        "UPDATE attachments SET path=?,fingerprint=? WHERE id=?",
                        params![path, required(a, "fingerprint")?, id]
                    )? == 1,
                    "Unknown attachment"
                );
                json!({"id":id,"path":path,"exists":true})
            }
            "attach" => {
                let path = PathBuf::from(required(a, "path")?);
                ensure!(path.is_absolute(), "Attachment path must be absolute");
                attach_within(
                    &tx,
                    required(a, "ref_id")?,
                    &path,
                    a.get("file_type").and_then(Value::as_str).unwrap_or("pdf"),
                    a.get("fingerprint").and_then(Value::as_str),
                )?
            }
            _ => unreachable!(),
        };
        if !key.is_empty() {
            tx.execute(
                "INSERT INTO requests VALUES(?,?,?)",
                params![key, payload, out.to_string()],
            )?;
        }
        tx.commit()?;
        drop(c);
        if method == "import_bibtex" || method == "upsert_reference" || method == "apply_metadata" || method == "delete_reference" || method == "delete_note" {
            self.load_vocabulary()?;
        } else if method.ends_with("note") {
            self.add_words(text(a, "body"));
        }
        Ok(out)
    }
    fn project_context(&self, a: &Value) -> Result<Value> {
        let project = required(a, "project_id")?;
        let budget = a
            .get("max_chars")
            .and_then(Value::as_u64)
            .unwrap_or(8000)
            .clamp(1000, 32000) as usize;
        let mut query = a.clone();
        query["project_filter"] = json!(project);
        query["limit"] = json!(25);
        let result = crate::search::search(self, &query)?;
        let mut items = Vec::new();
        let mut next = result["next_cursor"].clone();
        let offset = a.get("cursor").and_then(Value::as_u64).unwrap_or(0);
        for hit in result["results"].as_array().unwrap() {
            let mut item = get_reference(
                &read_connection(&self.path)?,
                &json!({"id":hit["id"],"project_id":project,"include_notes":true,"include_metadata":false,"note_limit":3,"note_chars":400}),
            )?;
            item["title"] = json!(clip(text(&item, "title"), 200));
            item["authors"] = json!(clip(text(&item, "authors"), 140));
            if let Some(notes) = item["notes"].as_array_mut() {
                for n in notes {
                    let compact = json!({"id":n["id"],"project_id":n["project_id"],"body":n["body"],"evidence":n["evidence"],"truncated":n["truncated"]});
                    *n = compact;
                }
            }
            for key in ["revision", "entry_type"] {
                item.as_object_mut().unwrap().remove(key);
            }
            if items.is_empty() {
                while item.to_string().chars().count() + 180 > budget
                    && item["notes"].as_array().is_some_and(|n| !n.is_empty())
                {
                    item["notes"].as_array_mut().unwrap().pop();
                    item["notes_truncated"] = json!(true);
                }
            }
            items.push(item);
            if json!({"project_id":project,"items":items,"next_cursor":next,"truncated":true})
                .to_string()
                .chars()
                .count()
                > budget
            {
                items.pop();
                next = json!(offset + items.len() as u64);
                break;
            }
        }
        Ok(
            json!({"project_id":project,"items":items,"next_cursor":next,"truncated":!next.is_null(),"max_chars":budget}),
        )
    }
    fn idempotent_result(&self, key: &str, payload: &str) -> Result<Option<Value>> {
        let c = self.writer.lock().unwrap();
        if let Some((old, result)) = c
            .query_row(
                "SELECT payload,result FROM requests WHERE key=?",
                [key],
                |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
            )
            .optional()?
        {
            ensure!(
                old == payload,
                "Idempotency key reused with different request"
            );
            return Ok(Some(serde_json::from_str(&result)?));
        }
        Ok(None)
    }
    /// Add a reference from a DOI, arXiv ID, URL, BibTeX entry or PDF file in
    /// one call: identify it, fetch its abstract and an open-access PDF link
    /// (network work, done before any lock is held), then import it, attach
    /// a PDF and link it to a project inside one write transaction.
    pub fn add_reference(&self, a: &Value) -> Result<Value> {
        let key = text(a, "idempotency_key").to_string();
        let payload = json!({"method":"add_reference","params":a}).to_string();
        if !key.is_empty()
            && let Some(cached) = self.idempotent_result(&key, &payload)?
        {
            return Ok(cached);
        }
        let input = a
            .get("input")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty());
        let pdf_path = a
            .get("pdf_path")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty());
        ensure!(
            input.is_some() || pdf_path.is_some(),
            "Provide input (a DOI, arXiv ID, URL or BibTeX entry) or pdf_path"
        );
        let download_pdf = a.get("download_pdf") != Some(&json!(false));

        let preview = if let Some(input) = input {
            crate::ingest::preview(&json!({"input":input}))?
        } else {
            let identified = crate::attachments::identify_pdf(&json!({"path":pdf_path.unwrap()}))?;
            let candidates = identified["candidates"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            ensure!(
                !candidates.is_empty(),
                "Could not identify this PDF. Pass its DOI, arXiv ID or a URL as input instead."
            );
            ensure!(
                candidates.len() == 1,
                "This PDF's title matched more than one candidate; call identify_pdf first, then pass the correct DOI or URL as input."
            );
            let item = candidates.into_iter().next().unwrap();
            json!({"bibtex":item["bibtex"],"items":[item]})
        };
        let first_item = preview["items"][0].clone();

        let mut attach_path = pdf_path.map(PathBuf::from);
        if let Some(p) = &attach_path {
            ensure!(p.is_absolute(), "pdf_path must be absolute");
        }
        if attach_path.is_none()
            && download_pdf
            && let Some(url) = first_item["pdf_url"].as_str().filter(|s| !s.is_empty())
            && let Ok((path, _)) =
                crate::attachments::download_and_store(self, url, text(&first_item, "citekey"))
        {
            attach_path = Some(path);
        }

        let mut c = self.writer.lock().unwrap();
        let tx = c.transaction()?;
        if !key.is_empty()
            && let Some((old, result)) = tx
                .query_row(
                    "SELECT payload,result FROM requests WHERE key=?",
                    [&key],
                    |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
                )
                .optional()?
        {
            ensure!(
                old == payload,
                "Idempotency key reused with different request"
            );
            return Ok(serde_json::from_str(&result)?);
        }
        let changes = import(&tx, &preview)?;
        let item = changes["items"]
            .as_array()
            .and_then(|xs| xs.first())
            .cloned()
            .context("Nothing was imported")?;
        let ref_id = text(&item, "id").to_string();
        let mut attachment = Value::Null;
        if let Some(p) = &attach_path {
            let canonical = p.canonicalize().context("Cannot read pdf_path")?;
            let hash = crate::attachments::inspect(&canonical)?;
            attachment = attach_within(&tx, &ref_id, &canonical, "pdf", Some(&hash))?;
        }
        if let Some(pid) = a.get("project_id").and_then(Value::as_str) {
            associate_within(&tx, &ref_id, pid, "[]")?;
        }
        let out = json!({
            "id": ref_id,
            "citekey": item["citekey"],
            "merged": item["merged"],
            "conflicts": changes["conflicts"],
            "repairs": changes["repairs"],
            "abstract_source": first_item["abstract_source"],
            "attachment": attachment,
            "warnings": first_item["warnings"],
        });
        if !key.is_empty() {
            tx.execute(
                "INSERT INTO requests VALUES(?,?,?)",
                params![key, payload, out.to_string()],
            )?;
        }
        tx.commit()?;
        drop(c);
        self.load_vocabulary()?;
        Ok(out)
    }
}
fn validate_roots(a: &Value) -> Result<()> {
    if let Some(roots) = a.get("roots") {
        for r in roots.as_array().context("roots must be an array")? {
            ensure!(
                Path::new(r.as_str().context("root must be a string")?).is_absolute(),
                "Project roots must be absolute"
            );
        }
    }
    Ok(())
}
fn validate_labels(a: &Value) -> Result<()> {
    if let Some(labels) = a.get("labels") {
        ensure!(
            labels
                .as_array()
                .is_some_and(|xs| xs.iter().all(Value::is_string)),
            "labels must be strings"
        );
    }
    Ok(())
}
/// Link a reference to a project, replacing that association's labels.
/// Shared by the `associate` operation and `add_reference`'s optional
/// `project_id`, both of which run inside an already-open transaction.
fn associate_within(c: &Connection, ref_id: &str, project_id: &str, labels: &str) -> Result<()> {
    c.execute("INSERT INTO associations VALUES(?,?,?) ON CONFLICT(ref_id,project_id) DO UPDATE SET labels=excluded.labels",params![ref_id,project_id,labels])?;
    Ok(())
}
/// Record a pointer to a PDF (or other file) for a reference, deduplicating
/// on (ref_id, path). Shared by the `attach` operation and `add_reference`,
/// both of which run inside an already-open transaction.
fn attach_within(
    c: &Connection,
    ref_id: &str,
    path: &Path,
    file_type: &str,
    fingerprint: Option<&str>,
) -> Result<Value> {
    let aid = id();
    c.execute("INSERT INTO attachments VALUES(?,?,?,?,?) ON CONFLICT(ref_id,path) DO UPDATE SET file_type=excluded.file_type,fingerprint=excluded.fingerprint",params![aid,ref_id,path.to_string_lossy(),file_type,fingerprint])?;
    let actual_id: String = c.query_row(
        "SELECT id FROM attachments WHERE ref_id=? AND path=?",
        params![ref_id, path.to_string_lossy()],
        |r| r.get(0),
    )?;
    Ok(json!({"id":actual_id,"ref_id":ref_id,"path":path,"exists":path.is_file()}))
}
fn insert_doc(c: &Connection, rid: &str) -> Result<()> {
    let (key, title, authors, ab, fields): (String, String, String, String, String) = c.query_row(
        "SELECT citekey,title,authors,abstract,fields FROM refs WHERE id=?",
        [rid],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
    )?;
    let fields: Value = serde_json::from_str(&fields)?;
    c.execute(
        "DELETE FROM docs INDEXED BY docs_ref WHERE ref_id=? AND note_id IS NULL",
        [rid],
    )?;
    c.execute("INSERT INTO docs(ref_id,citekey,title,authors,abstract,keywords,body) VALUES(?,?,?,?,?,?, '')",params![rid,normalize(&key),normalize(&title),normalize(&authors),normalize(&ab),normalize(&[text(&fields,"keywords"),text(&fields,"isbn"),text(&fields,"eprint"),text(&fields,"url")].join(" "))])?;
    c.execute(
        "UPDATE docs SET citekey=?,title=?,authors=? WHERE ref_id=? AND note_id IS NOT NULL",
        params![normalize(&key), normalize(&title), normalize(&authors), rid],
    )?;
    Ok(())
}
fn import(c: &Connection, a: &Value) -> Result<Value> {
    let raw = required(a, "bibtex")?;
    ensure!(raw.len() <= 64 * 1024 * 1024, "Import exceeds 64 MiB");
    let (bib, repairs) = parse_import(raw).map_err(|e| anyhow::anyhow!("Invalid BibTeX: {e}"))?;
    let mut imported = Vec::new();
    let mut conflicts = Vec::new();
    let import_id = id();
    c.execute(
        "INSERT INTO imports(id,source,original) VALUES(?,?,?)",
        params![import_id, text(a, "source"), raw],
    )?;
    let mut keys = BTreeMap::new();
    let mut batch_keys = HashSet::new();
    let mut signatures: BTreeMap<String, String> = BTreeMap::new();
    let mut duplicates_merged = 0;
    let mut result_ids = HashSet::new();
    for entry in bib.iter() {
        let mut fields = BTreeMap::new();
        for (k, v) in &entry.fields {
            fields.insert(k.clone(), v.format_verbatim());
        }
        let signature = json!([entry.entry_type.to_string(), fields]).to_string();
        let repeated_key = !batch_keys.insert(entry.key.clone());
        let title = entry
            .get("title")
            .map(|v| v.format_verbatim())
            .unwrap_or_default();
        let authors = entry
            .get("author")
            .map(|v| v.format_verbatim())
            .unwrap_or_default();
        let doi = fields
            .get("doi")
            .map(|s| normalize_doi(s))
            .filter(|s| !s.is_empty());
        let existing: Option<String> = if let Some(d) = &doi {
            c.query_row("SELECT id FROM refs WHERE doi=?", [d], |r| r.get(0))
                .optional()?
        } else {
            None
        };
        let lookup_key = keys.get(&entry.key).unwrap_or(&entry.key);
        let by_key: Option<(String, String, String)> = c
            .query_row(
                "SELECT id,fields,title FROM refs WHERE citekey=?",
                [lookup_key],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?;
        let existing = existing
            .or_else(|| signatures.get(&signature).cloned())
            .or_else(|| {
                by_key
                    .as_ref()
                    .filter(|(_, f, t)| {
                        f == &json!(fields).to_string()
                            || ((repeated_key
                                || (!title.is_empty() && normalize(t) == normalize(&title)))
                                && {
                                    let old: Value = serde_json::from_str(f).unwrap_or(Value::Null);
                                    let compatible_doi = doi.as_ref().is_none_or(|d| {
                                        text(&old, "doi").is_empty()
                                            || normalize_doi(text(&old, "doi")) == *d
                                    });
                                    compatible_doi
                                        && (repeated_key
                                            || authors.is_empty()
                                            || normalize(text(&old, "author"))
                                                == normalize(&authors))
                                })
                    })
                    .map(|v| v.0.clone())
            });
        if let Some(rid) = existing {
            let old: String =
                c.query_row("SELECT bibtex FROM refs WHERE id=?", [&rid], |r| r.get(0))?;
            let mut oldbib =
                parse_bibtex(&old).map_err(|e| anyhow::anyhow!("Stored BibTeX: {e}"))?;
            let oldentry = oldbib.iter_mut().next().context("Stored entry empty")?;
            for (k, v) in &entry.fields {
                match oldentry.fields.get(k){None=>{oldentry.fields.insert(k.clone(),v.clone());},Some(x)if x.format_verbatim().trim().is_empty()=>{oldentry.fields.insert(k.clone(),v.clone());},Some(x)if x.format_verbatim()!=v.format_verbatim()=>conflicts.push(json!({"id":rid,"field":k,"existing":x.format_verbatim(),"incoming":v.format_verbatim()})),_=>{}}
            }
            if serialize_entry(oldentry) != old {
                save_entry(c, &rid, oldentry, false, text(a, "source"))?;
            }
            keys.entry(entry.key.clone())
                .or_insert_with(|| oldentry.key.clone());
            signatures.insert(signature, rid.clone());
            if !result_ids.insert(rid.clone()) {
                duplicates_merged += 1;
            } else {
                imported.push(json!({"id":rid,"citekey":oldentry.key,"merged":true}));
            }
        } else {
            let mut e = entry.clone();
            let base = e.key.clone();
            let mut n = 2;
            while c
                .query_row("SELECT 1 FROM refs WHERE citekey=?", [&e.key], |_| Ok(()))
                .optional()?
                .is_some()
            {
                e.key = format!("{base}_{n}");
                n += 1;
            }
            let rid = id();
            save_entry(c, &rid, &e, true, text(a, "source"))?;
            keys.entry(base.clone()).or_insert_with(|| e.key.clone());
            signatures.insert(signature, rid.clone());
            result_ids.insert(rid.clone());
            imported.push(json!({"id":rid,"citekey":e.key,"original_key":base,"merged":false}));
        }
        let _ = authors;
    }
    // Rewrite imported cross-reference links when an incoming key was renamed.
    for item in &imported {
        if item["merged"] == true {
            continue;
        }
        let rid = text(item, "id");
        let raw: String = c.query_row("SELECT bibtex FROM refs WHERE id=?", [rid], |r| r.get(0))?;
        let mut b = parse_bibtex(&raw).map_err(|e| anyhow::anyhow!("{e}"))?;
        let e = b.iter_mut().next().unwrap();
        let mut changed = false;
        for field in ["crossref", "xref"] {
            if let Some(value) = e.get(field) {
                let old = value.format_verbatim();
                if let Some(new) = keys.get(&old)
                    && new != &old
                {
                    let parsed = parse_bibtex(&format!("@misc{{temp,{field}={{{new}}}}}")).unwrap();
                    e.set(field, parsed.iter().next().unwrap().fields[field].clone());
                    changed = true;
                }
            }
        }
        if changed {
            save_entry(c, rid, e, false, text(a, "source"))?;
        }
    }
    Ok(
        json!({"import_id":import_id,"items":imported,"conflicts":conflicts,"repairs":repairs,"duplicates_merged":duplicates_merged}),
    )
}
pub(crate) fn save_entry(
    c: &Connection,
    rid: &str,
    e: &biblatex::Entry,
    new: bool,
    source: &str,
) -> Result<()> {
    let fields: BTreeMap<String, String> = e
        .fields
        .iter()
        .map(|(k, v)| (k.clone(), v.format_verbatim()))
        .collect();
    let title = e
        .get("title")
        .map(|x| x.format_verbatim())
        .unwrap_or_default();
    let authors = e
        .get("author")
        .map(|x| x.format_verbatim())
        .unwrap_or_default();
    let ab = e
        .get("abstract")
        .map(|x| x.format_verbatim())
        .unwrap_or_default();
    let doi = fields
        .get("doi")
        .map(|s| normalize_doi(s))
        .filter(|s| !s.is_empty());
    let year = fields
        .get("year")
        .cloned()
        .or_else(|| fields.get("date").map(|s| clip(s, 4)))
        .unwrap_or_default();
    let kind = e.entry_type.to_string().to_lowercase();
    let bib = serialize_entry(e);
    if new {
        c.execute("INSERT INTO refs(id,citekey,entry_type,title,authors,abstract,year,doi,fields,bibtex,source) VALUES(?,?,?,?,?,?,?,?,?,?,?)",params![rid,e.key,kind,title,authors,ab,year,doi,json!(fields).to_string(),bib,source])?;
    } else {
        c.execute("UPDATE refs SET citekey=?,entry_type=?,title=?,authors=?,abstract=?,year=?,doi=?,fields=?,bibtex=?,revision=revision+1,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?",params![e.key,kind,title,authors,ab,year,doi,json!(fields).to_string(),bib,rid])?;
    }
    insert_doc(c, rid)
}
fn upsert(c: &Connection, a: &Value) -> Result<Value> {
    let b = parse_bibtex(required(a, "bibtex")?).map_err(|e| anyhow::anyhow!("{e}"))?;
    ensure!(b.len() == 1, "Provide exactly one BibTeX entry");
    let rid = text(a, "id");
    if rid.is_empty() {
        return import(c, a);
    }
    let revision: i64 = c.query_row("SELECT revision FROM refs WHERE id=?", [rid], |r| r.get(0))?;
    ensure!(
        a.get("expected_revision").and_then(Value::as_i64) == Some(revision),
        "Revision conflict: current revision is {revision}"
    );
    save_entry(c, rid, b.iter().next().unwrap(), false, text(a, "source"))?;
    Ok(json!({"id":rid,"revision":revision+1}))
}
fn write_note(c: &Connection, method: &str, a: &Value) -> Result<Value> {
    validate_labels(a)?;
    let body = a
        .get("body")
        .and_then(Value::as_str)
        .context("Note body required; may be empty for a visual note")?;
    ensure!(
        !body.trim().is_empty()
            || method == "add_visual_note"
            || (method == "update_note" && crate::visual::metadata(c, text(a, "id"))?.is_some()),
        "Note body is empty"
    );
    ensure!(body.len() <= 65536, "Note exceeds 64 KiB");
    required(a, "provenance")?;
    ensure!(
        a.get("project_id").is_some(),
        "Explicit project_id required; use null for a global note"
    );
    let project = if a["project_id"].is_null() {
        None
    } else {
        Some(required(a, "project_id")?)
    };
    let nid;
    if method == "add_note" || method == "add_visual_note" {
        nid = id();
        c.execute("INSERT INTO notes(id,ref_id,project_id,body,labels,evidence,provenance) VALUES(?,?,?,?,?,?,?)",params![nid,required(a,"ref_id")?,project,body,json_field(a,"labels",json!([])),a.get("evidence").and_then(Value::as_str),text(a,"provenance")])?;
    } else {
        nid = required(a, "id")?.to_string();
        let old = note(c, &nid)?;
        let rev = old["revision"].as_i64().unwrap();
        ensure!(
            a.get("expected_revision").and_then(Value::as_i64) == Some(rev),
            "Revision conflict: current revision is {rev}"
        );
        c.execute(
            "INSERT INTO note_revisions VALUES(?,?,?)",
            params![nid, rev, old.to_string()],
        )?;
        c.execute("UPDATE notes SET project_id=?,body=?,labels=?,evidence=?,provenance=?,revision=revision+1,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?",params![project,body,json_field(a,"labels",json!([])),a.get("evidence").and_then(Value::as_str),text(a,"provenance"),nid])?;
    }
    let n = note(c, &nid)?;
    let rid = text(&n, "ref_id");
    if let Some(p) = project {
        c.execute(
            "INSERT OR IGNORE INTO associations(ref_id,project_id) VALUES(?,?)",
            params![rid, p],
        )?;
    }
    c.execute("DELETE FROM docs WHERE note_id=?", [&nid])?;
    let (key, title, authors): (String, String, String) = c.query_row(
        "SELECT citekey,title,authors FROM refs WHERE id=?",
        [rid],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
    )?;
    c.execute("INSERT INTO docs(ref_id,note_id,project_id,citekey,title,authors,abstract,keywords,body) VALUES(?,?,?,?,?,?,'',?,?)",params![rid,nid,project,normalize(&key),normalize(&title),normalize(&authors),normalize(&json_field(a,"labels",json!([]))),normalize(body)])?;
    Ok(n)
}
pub fn note(c: &Connection, nid: &str) -> Result<Value> {
    let mut result: Value = c.query_row("SELECT id,ref_id,project_id,body,labels,evidence,provenance,revision,created_at,updated_at FROM notes WHERE id=?",[nid],|r|Ok(json!({"id":r.get::<_,String>(0)?,"ref_id":r.get::<_,String>(1)?,"project_id":r.get::<_,Option<String>>(2)?,"body":r.get::<_,String>(3)?,"labels":serde_json::from_str::<Value>(&r.get::<_,String>(4)?).unwrap_or(json!([])),"evidence":r.get::<_,Option<String>>(5)?,"provenance":r.get::<_,String>(6)?,"revision":r.get::<_,i64>(7)?,"created_at":r.get::<_,String>(8)?,"updated_at":r.get::<_,String>(9)?})))?;
    if let Some(image) = crate::visual::metadata(c, nid)? {
        result["image"] = image;
    }
    Ok(result)
}
fn delete_note_preview(c: &Connection, a: &Value) -> Result<Value> {
    let id = required(a, "id")?;
    c.query_row(
        "SELECT n.id,n.ref_id,r.citekey,n.project_id,coalesce(p.name,'Global'),n.revision,substr(n.body,1,200),\
         EXISTS(SELECT 1 FROM note_images WHERE note_id=n.id) \
         FROM notes n JOIN refs r ON r.id=n.ref_id LEFT JOIN projects p ON p.id=n.project_id WHERE n.id=?",
        [id],
        |r| Ok(json!({"id":r.get::<_,String>(0)?,"ref_id":r.get::<_,String>(1)?,
            "citekey":r.get::<_,String>(2)?,"project_id":r.get::<_,Option<String>>(3)?,
            "project_name":r.get::<_,String>(4)?,"revision":r.get::<_,i64>(5)?,
            "excerpt":r.get::<_,String>(6)?,"has_image":r.get::<_,bool>(7)?})),
    ).context("Note not found")
}
fn delete_reference_preview(c: &Connection, a: &Value) -> Result<Value> {
    let target = required(a, "id")?;
    let (id, citekey, title, revision): (String, String, String, i64) = c
        .query_row(
            "SELECT id,citekey,title,revision FROM refs WHERE id=?1 OR citekey=?1",
            [target],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
        )
        .context("Reference not found")?;
    let (note_count, attachment_count, project_count, summary_count, chat_count): (i64, i64, i64, i64, i64) = c
        .query_row(
            "SELECT (SELECT count(*) FROM notes WHERE ref_id=?1), \
             (SELECT count(*) FROM attachments WHERE ref_id=?1), \
             (SELECT count(*) FROM associations WHERE ref_id=?1), \
             (SELECT count(*) FROM external_summaries WHERE ref_id=?1), \
             (SELECT count(*) FROM chats WHERE ref_id=?1)",
            [&id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
        )?;
    Ok(json!({"id":id,"citekey":citekey,"title":title,"revision":revision,
        "note_count":note_count,"attachment_count":attachment_count,
        "project_count":project_count,"summary_count":summary_count,"chat_count":chat_count}))
}

fn get_references(c: &Connection, a: &Value) -> Result<Value> {
    let ids = a.get("ids").and_then(Value::as_array).context("ids must be an array")?;
    ensure!((1..=25).contains(&ids.len()), "Provide between 1 and 25 reference IDs");
    ensure!(ids.iter().all(|id| id.as_str().is_some_and(|s| !s.trim().is_empty())), "Each reference ID must be a non-empty string");
    let mut args = a.clone();
    args.as_object_mut().unwrap().remove("ids");
    // One connection and snapshot for the complete batch; preserve each item's
    // identity even if another ID is missing or has been deleted.
    let tx = c.unchecked_transaction()?;
    let results = ids.iter().map(|id| {
        args["id"] = id.clone();
        match get_reference(&tx, &args) {
            Ok(reference) => json!({"id":id,"reference":reference}),
            Err(error) => json!({"id":id,"error":format!("{error:#}")}),
        }
    }).collect::<Vec<_>>();
    tx.commit()?;
    Ok(json!({"results":results}))
}

pub fn get_reference(c: &Connection, a: &Value) -> Result<Value> {
    let rid = required(a, "id")?;
    let mut out=c.query_row("SELECT id,citekey,title,authors,year,entry_type,abstract,fields,bibtex,revision,source FROM refs WHERE id=? OR citekey=?",params![rid,rid],|r|Ok(json!({"id":r.get::<_,String>(0)?,"citekey":r.get::<_,String>(1)?,"title":r.get::<_,String>(2)?,"authors":r.get::<_,String>(3)?,"year":r.get::<_,String>(4)?,"entry_type":r.get::<_,String>(5)?,"abstract":r.get::<_,String>(6)?,"fields":serde_json::from_str::<Value>(&r.get::<_,String>(7)?).unwrap_or(json!({})),"bibtex":r.get::<_,String>(8)?,"revision":r.get::<_,i64>(9)?,"source":r.get::<_,String>(10)?}))).context("Reference not found")?;
    let rid = text(&out, "id").to_string();
    // Projects and the added date are small and always useful to show.
    let mut projects = c.prepare(
        "SELECT p.id,p.name FROM associations a JOIN projects p ON p.id=a.project_id WHERE a.ref_id=? ORDER BY p.name",
    )?;
    out["projects"] = json!(
        projects
            .query_map([&rid], |r| Ok(json!({"id":r.get::<_,String>(0)?,"name":r.get::<_,String>(1)?})))?
            .collect::<rusqlite::Result<Vec<_>>>()?
    );
    out["created_at"] = json!(c.query_row("SELECT created_at FROM refs WHERE id=?", [&rid], |r| r
        .get::<_, String>(0))?);
    // Always surface a readable PDF path (if any) for agents; full
    // attachment detail (IDs, fingerprints, missing files) stays opt-in.
    out["pdf_path"] = c
        .query_row(
            "SELECT path FROM attachments WHERE ref_id=? AND file_type='pdf' ORDER BY rowid",
            [&rid],
            |r| r.get::<_, String>(0),
        )
        .optional()?
        .filter(|p| Path::new(p).is_file())
        .map_or(Value::Null, |p| json!(p));
    if a.get("include_metadata") == Some(&json!(false)) {
        for key in ["abstract", "fields", "bibtex", "source"] {
            out.as_object_mut().unwrap().remove(key);
        }
    }
    if a.get("include_attachments") == Some(&json!(true)) {
        let mut s =
            c.prepare("SELECT id,path,file_type,fingerprint FROM attachments WHERE ref_id=?")?;
        out["attachments"]=json!(s.query_map([&rid],|r|{let p:String=r.get(1)?;Ok(json!({"id":r.get::<_,String>(0)?,"path":p,"exists":Path::new(&p).is_file(),"file_type":r.get::<_,String>(2)?,"fingerprint":r.get::<_,Option<String>>(3)?}))})?.collect::<rusqlite::Result<Vec<_>>>()?);
    }
    if a.get("include_notes") == Some(&json!(true)) {
        let project = a.get("project_id").and_then(Value::as_str);
        let all = a.get("include_other_projects") == Some(&json!(true));
        let limit = a
            .get("note_limit")
            .and_then(Value::as_u64)
            .unwrap_or(10)
            .clamp(1, 25);
        let offset = a.get("note_cursor").and_then(Value::as_u64).unwrap_or(0);
        let chars = a
            .get("note_chars")
            .and_then(Value::as_u64)
            .unwrap_or(1000)
            .clamp(100, 65536) as usize;
        let mut s=c.prepare("SELECT id FROM notes WHERE ref_id=? AND (? OR project_id IS NULL OR project_id=?) ORDER BY updated_at DESC,id LIMIT ? OFFSET ?")?;
        let ids = s
            .query_map(
                params![rid, all, project, (limit + 1) as i64, offset as i64],
                |r| r.get::<_, String>(0),
            )?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let more = ids.len() > limit as usize;
        let mut notes = Vec::new();
        for nid in ids.iter().take(limit as usize) {
            let mut n = note(c, nid)?;
            let body = text(&n, "body").to_string();
            n["body"] = json!(clip(&body, chars));
            n["truncated"] = json!(body.chars().count() > chars);
            if let Some(pid) = n["project_id"].as_str() {
                n["project_name"] = json!(c.query_row(
                    "SELECT name FROM projects WHERE id=?",
                    [pid],
                    |r| r.get::<_, String>(0)
                )?);
            }
            notes.push(n);
        }
        out["notes"] = json!(notes);
        out["next_note_cursor"] = if more {
            json!(offset + limit)
        } else {
            Value::Null
        };
        out["other_project_note_count"]=json!(c.query_row("SELECT count(*) FROM notes WHERE ref_id=? AND project_id IS NOT NULL AND (? IS NULL OR project_id!=?)",params![rid,project,project],|r|r.get::<_,i64>(0))?);
    }
    if a.get("include_history") == Some(&json!(true)) {
        let mut s=c.prepare("SELECT snapshot FROM note_revisions WHERE note_id IN (SELECT id FROM notes WHERE ref_id=?) ORDER BY note_id,revision DESC LIMIT 25")?;
        out["history"] = json!(
            s.query_map([rid], |r| Ok(serde_json::from_str::<Value>(
                &r.get::<_, String>(0)?
            )
            .unwrap_or(Value::Null)))?
                .collect::<rusqlite::Result<Vec<_>>>()?
        );
    }
    Ok(out)
}
fn list_projects(c: &Connection, a: &Value) -> Result<Value> {
    let mut s = c.prepare("SELECT id,name,description,roots FROM projects ORDER BY name")?;
    let projects=s.query_map([],|r|Ok(json!({"id":r.get::<_,String>(0)?,"name":r.get::<_,String>(1)?,"description":r.get::<_,String>(2)?,"roots":serde_json::from_str::<Value>(&r.get::<_,String>(3)?).unwrap_or(json!([]))})))?.collect::<rusqlite::Result<Vec<_>>>()?;
    let cwd = text(a, "cwd");
    let mut matches = Vec::new();
    let mut longest = 0;
    if !cwd.is_empty() {
        let cwd = std::fs::canonicalize(cwd).context("Cannot resolve working directory")?;
        for p in &projects {
            for r in p["roots"].as_array().unwrap() {
                let path = PathBuf::from(r.as_str().unwrap());
                let root = std::fs::canonicalize(&path).unwrap_or(path);
                if cwd.starts_with(&root) {
                    let n = root.components().count();
                    if n > longest {
                        longest = n;
                        matches.clear();
                    }
                    if n == longest && !matches.contains(&p["id"]) {
                        matches.push(p["id"].clone());
                    }
                }
            }
        }
    }
    Ok(
        json!({"projects":projects,"resolved_project_id":if matches.len()==1{matches[0].clone()}else{Value::Null},"ambiguous":matches.len()>1,"candidates":matches}),
    )
}
fn selected_ids(c: &Connection, a: &Value) -> Result<Vec<String>> {
    if let Some(ids) = a.get("ids") {
        let xs = ids.as_array().context("ids must be an array")?;
        ensure!(xs.len() <= 100000, "Too many references");
        return xs
            .iter()
            .map(|x| {
                x.as_str()
                    .map(str::to_string)
                    .context("id must be a string")
            })
            .collect();
    }
    let p = required(a, "project_id")?;
    let mut s = c.prepare("SELECT ref_id FROM associations WHERE project_id=? ORDER BY ref_id")?;
    Ok(s.query_map([p], |r| r.get(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?)
}
fn export_bibtex(c: &Connection, a: &Value) -> Result<Value> {
    let mut pending = selected_ids(c, a)?;
    let mut seen = HashSet::new();
    let mut entries = BTreeMap::new();
    while let Some(rid) = pending.pop() {
        if !seen.insert(rid.clone()) {
            continue;
        }
        let v = get_reference(c, &json!({"id":rid}))?;
        for field in ["crossref", "xref", "xdata"] {
            if let Some(s) = v["fields"][field].as_str() {
                for key in s.split(',').map(str::trim) {
                    ensure!(
                        c.query_row("SELECT 1 FROM refs WHERE citekey=?", [key], |_| Ok(()))
                            .optional()?
                            .is_some(),
                        "Missing bibliography dependency: {key}"
                    );
                    pending.push(key.into());
                }
            }
        }
        entries.insert(
            text(&v, "citekey").to_string(),
            parse_bibtex(text(&v, "bibtex"))?
                .iter()
                .next()
                .context("Empty entry")?
                .to_bibtex_string()
                .map_err(|e| anyhow::anyhow!("Cannot export BibTeX: {e}"))?,
        );
    }
    Ok(
        json!({"bibtex":entries.values().cloned().collect::<Vec<_>>().join("\n\n"),"count":entries.len()}),
    )
}
fn export_notes(c: &Connection, a: &Value) -> Result<Value> {
    let mut output = String::new();
    for rid in selected_ids(c, a)? {
        let r = get_reference(c, &json!({"id":rid}))?;
        output.push_str(&format!(
            "# {} [{}]\n\n",
            text(&r, "title"),
            text(&r, "citekey")
        ));
        let mut s=c.prepare("SELECT id FROM notes WHERE ref_id=? AND (? OR project_id IS NULL OR project_id=?) ORDER BY project_id,created_at,id")?;
        let ids = s
            .query_map(
                params![
                    rid,
                    a["include_other_projects"] == true,
                    a.get("project_id").and_then(Value::as_str)
                ],
                |r| r.get::<_, String>(0),
            )?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        for nid in ids {
            let n = note(c, &nid)?;
            let project = if let Some(p) = n["project_id"].as_str() {
                c.query_row("SELECT name FROM projects WHERE id=?", [p], |r| {
                    r.get::<_, String>(0)
                })?
            } else {
                "Global".into()
            };
            output.push_str(&format!(
                "## {project}\n\n{}\n\nSource: {}; evidence: {}; note: {}; revision: {}\n\n",
                text(&n, "body"),
                text(&n, "provenance"),
                text(&n, "evidence"),
                nid,
                n["revision"]
            ));
        }
    }
    Ok(json!({"markdown":output}))
}
fn preview_doi(a: &Value) -> Result<Value> {
    let doi = normalize_doi(required(a, "doi")?);
    ensure!(
        doi.starts_with("10.") && doi.contains('/') && !doi.chars().any(char::is_whitespace),
        "Invalid DOI"
    );
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(15))
        .user_agent("Omabib/0.1 (local bibliography manager)")
        .build()?;
    let response = client
        .get(format!("https://doi.org/{doi}"))
        .header("Accept", "application/x-bibtex")
        .send()?
        .error_for_status()?;
    use std::io::Read;
    let mut raw = String::new();
    response.take(1024 * 1024 + 1).read_to_string(&mut raw)?;
    ensure!(raw.len() <= 1024 * 1024, "DOI response too large");
    parse_bibtex(&raw).map_err(|e| anyhow::anyhow!("DOI returned invalid BibTeX: {e}"))?;
    Ok(json!({"doi":doi,"bibtex":raw,"saved":false,"source":format!("https://doi.org/{doi}")}))
}
/// List references with no abstract yet, for `enrich --abstracts`. Goes
/// through the service's own connection (this library's `path`) rather
/// than a path the caller guesses, so the CLI never risks reading a
/// different database than the one it will then write through.
fn missing_abstracts(lib: &Library, a: &Value) -> Result<Value> {
    let c = read_connection(&lib.path)?;
    let limit = a
        .get("limit")
        .and_then(Value::as_i64)
        .unwrap_or(5000)
        .clamp(1, 20000);
    let mut s =
        c.prepare("SELECT id,citekey FROM refs WHERE abstract='' ORDER BY citekey LIMIT ?")?;
    let items = s
        .query_map([limit], |r| {
            Ok(json!({"id":r.get::<_,String>(0)?,"citekey":r.get::<_,String>(1)?}))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let total: i64 = c.query_row("SELECT count(*) FROM refs WHERE abstract=''", [], |r| {
        r.get(0)
    })?;
    Ok(json!({"items":items,"total":total}))
}
/// Preview an abstract for one reference that already has an exact DOI or
/// arXiv identifier, without writing anything. Used by `enrich --abstracts`
/// and `apply_metadata` to backfill abstracts across the whole library.
fn lookup_abstract(lib: &Library, a: &Value) -> Result<Value> {
    let r = get_reference(&read_connection(&lib.path)?, a)?;
    let doi = crate::metadata::inferred_doi(&r);
    ensure!(
        !doi.is_empty(),
        "This reference has no DOI or arXiv identifier to look up an abstract by"
    );
    let arxiv_id = crate::metadata::arxiv_from_doi(&doi);
    let (found, warnings) = crate::abstracts::find_abstract(&doi, &arxiv_id)?;
    Ok(json!({
        "id": r["id"],
        "expected_revision": r["revision"],
        "abstract": found.as_ref().map(|f| f.text.clone()),
        "source": found.as_ref().map(|f| f.source.clone()),
        "warnings": warnings,
    }))
}
