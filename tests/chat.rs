use omabib::chat::{Event, claude, codex};
use omabib::db::Library;
use serde_json::{Value, json};
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

fn fixture(name: &str) -> String {
    std::fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/chat")
            .join(name),
    )
    .unwrap()
}

#[test]
fn claude_adapter_reads_the_recorded_session() {
    let mut parser = claude::Parser::default();
    let events: Vec<Event> = fixture("claude-session.jsonl")
        .lines()
        .flat_map(|l| parser.parse(l))
        .collect();
    let sessions: Vec<_> = events
        .iter()
        .filter(|e| matches!(e, Event::Session(_)))
        .collect();
    assert_eq!(
        sessions.len(),
        1,
        "one session event while the model stays the same"
    );
    let Event::Session(s) = sessions[0] else {
        unreachable!()
    };
    assert_eq!(s["model"], "claude-opus-5");
    assert!(
        !events
            .iter()
            .any(|e| matches!(e, Event::Note(_) | Event::Error(_))),
        "every event type is understood"
    );

    let tools: Vec<&str> = events
        .iter()
        .filter_map(|e| match e {
            Event::ToolCall { name, .. } => Some(name.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(
        tools,
        ["Read", "mcp__omabib__get_reference", "Bash", "WebFetch"],
        "ToolSearch plumbing is hidden"
    );
    let results: Vec<(&str, bool)> = events
        .iter()
        .filter_map(|e| match e {
            Event::ToolResult {
                output, is_error, ..
            } => Some((output.as_str(), *is_error)),
            _ => None,
        })
        .collect();
    assert_eq!(
        results.len(),
        4,
        "every visible call has its result and hidden ones are dropped"
    );
    assert!(
        results
            .iter()
            .any(|(out, err)| *err && out.contains("Denied by fixture"))
    );

    let answers: Vec<&str> = events
        .iter()
        .filter_map(|e| match e {
            Event::Assistant(t) => Some(t.as_str()),
            _ => None,
        })
        .collect();
    assert!(
        answers
            .iter()
            .any(|t| t.contains("Sparse attention is enough"))
    );
    assert!(answers.contains(&"Blue") && answers.contains(&"OK"));

    // Deltas add up to the final text of the message they stream.
    let mut draft = String::new();
    for e in &events {
        match e {
            Event::Delta(t) => draft.push_str(t),
            Event::Assistant(t) => {
                assert_eq!(&draft, t);
                draft.clear();
            }
            _ => {}
        }
    }
    let ends: Vec<&Value> = events
        .iter()
        .filter_map(|e| match e {
            Event::TurnEnd(v) => Some(v),
            _ => None,
        })
        .collect();
    assert_eq!(ends.len(), 6);
    assert_eq!(
        ends.iter().filter(|v| v["interrupted"] == true).count(),
        1,
        "the interrupted turn is marked"
    );
    assert!(ends.iter().all(|v| v["is_error"] == false));
    assert!(ends[0]["usage"]["output_tokens"].as_i64().unwrap() > 0);
}

#[test]
fn claude_adapter_builds_arguments_and_input_lines() {
    let args = claude::args(&claude::Launch {
        session_id: "s-1",
        resume: true,
        folder: Path::new("/data/chats/chat-1"),
        instructions: "Read the context.",
    });
    let joined = args.join(" ");
    assert!(joined.contains("--resume s-1") && !joined.contains("--session-id"));
    assert!(joined.contains("--mcp-config /data/chats/chat-1/mcp.json --strict-mcp-config"));
    assert!(joined.contains("--permission-prompt-tool mcp__omabib__chat_permission"));
    assert!(joined.contains("--allowedTools Read Grep Glob mcp__omabib"));
    let line: Value =
        serde_json::from_str(&claude::user_line("What color?", &[b"png".to_vec()])).unwrap();
    assert_eq!(line["message"]["content"][0]["text"], "What color?");
    assert_eq!(line["message"]["content"][1]["source"]["data"], "cG5n");
    let text: Value = serde_json::from_str(&claude::user_line("Hi", &[])).unwrap();
    assert_eq!(text["message"]["content"], "Hi");
    assert_eq!(
        serde_json::from_str::<Value>(&claude::interrupt_line("i")).unwrap()["request"]["subtype"],
        "interrupt"
    );
}

#[test]
fn codex_adapter_reads_the_recorded_turns() {
    let parse =
        |name: &str| -> Vec<Event> { fixture(name).lines().flat_map(codex::parse).collect() };
    for name in [
        "codex-1-title.jsonl",
        "codex-2-shell.jsonl",
        "codex-3-image.jsonl",
        "codex-4-write.jsonl",
        "codex-5-interrupt.jsonl",
    ] {
        let events = parse(name);
        assert!(
            !events
                .iter()
                .any(|e| matches!(e, Event::Note(_) | Event::Error(_))),
            "{name}: every event is understood"
        );
        assert!(
            matches!(&events[0], Event::Thread(t) if t == "01a0ab16-8113-7aa0-8bf3-e53dbf59ae11")
        );
    }
    let title = parse("codex-1-title.jsonl");
    assert!(title.iter().any(|e| matches!(e, Event::ToolCall { id, name, input } if id == "item_4" && name == "mcp__omabib__get_reference" && input["include_notes"] == true)));
    assert!(
        title
            .iter()
            .any(|e| matches!(e, Event::Assistant(t) if t.contains("Sparse attention is enough")))
    );
    assert!(matches!(title.last(), Some(Event::TurnEnd(v)) if v["usage"]["output_tokens"] == 396));
    let shell = parse("codex-2-shell.jsonl");
    assert!(
        shell
            .iter()
            .any(|e| matches!(e, Event::ToolCall { name, .. } if name == "shell"))
    );
    assert!(shell.iter().any(|e| matches!(e, Event::ToolResult { output, is_error: false, .. } if output == "context.json\n")));
    let write = parse("codex-4-write.jsonl");
    assert!(
        write
            .iter()
            .any(|e| matches!(e, Event::ToolCall { name, .. } if name == "mcp__omabib__add_note"))
    );
    let interrupted = parse("codex-5-interrupt.jsonl");
    assert!(
        !interrupted.iter().any(|e| matches!(e, Event::TurnEnd(_))),
        "an interrupted turn has no completion"
    );

    let args = codex::args(&codex::Turn {
        thread_id: Some("t-1"),
        omabib: Path::new("/bin/omabib"),
        socket: Path::new("/run/omabib/socket"),
        chat_id: "chat-1",
        images: &[Path::new("/tmp/q.png").to_path_buf()],
        prompt: "What color?",
    });
    assert_eq!(&args[..3], ["exec", "resume", "t-1"]);
    assert!(args.contains(&"sandbox_mode=\"read-only\"".to_string()));
    let server = &args[args.iter().position(|a| a == "-c").unwrap() + 1];
    assert!(
        server.contains("OMABIB_CHAT_ID=\"chat-1\"") && server.contains("tool_timeout_sec=900"),
        "{server}"
    );
    assert_eq!(args[args.len() - 3..], ["/tmp/q.png", "--", "What color?"]);
}

#[test]
fn mcp_gate_asks_before_writes_and_answers_claude_prompts() {
    let calls = Mutex::new(Vec::new());
    let waits = Mutex::new(Vec::new());
    let answer = Mutex::new(json!({"allow":true}));
    let call = |name: &str, _: &Value| {
        calls.lock().unwrap().push(name.to_string());
        Ok(json!({"ok":true}))
    };
    let wait = |_: &str, params: &Value| {
        waits.lock().unwrap().push(params.clone());
        Ok(answer.lock().unwrap().clone())
    };
    omabib::mcp::chat_call("c1", "get_reference", &json!({"id":"r"}), call, wait).unwrap();
    omabib::mcp::chat_call("c1", "get_pdf", &json!({"ref_id":"r"}), call, wait).unwrap();
    assert!(
        waits.lock().unwrap().is_empty(),
        "reads and PDF fetches don't ask"
    );
    omabib::mcp::chat_call("c1", "add_note", &json!({"body":"x"}), call, wait).unwrap();
    assert_eq!(waits.lock().unwrap()[0]["tool"], "mcp__omabib__add_note");
    *answer.lock().unwrap() = json!({"allow":false,"message":"No thanks"});
    let denied = omabib::mcp::chat_call("c1", "delete_note", &json!({"id":"n"}), call, wait);
    assert_eq!(denied.unwrap_err().to_string(), "No thanks");
    assert_eq!(
        *calls.lock().unwrap(),
        ["get_reference", "get_pdf", "add_note"],
        "a declined write never runs"
    );
    let prompt = omabib::mcp::chat_call(
        "c1",
        "chat_permission",
        &json!({"tool_name":"WebFetch","input":{"url":"https://example.org"}}),
        call,
        wait,
    )
    .unwrap();
    assert_eq!(prompt, json!({"behavior":"deny","message":"No thanks"}));
    *answer.lock().unwrap() = json!({"allow":true});
    let prompt = omabib::mcp::chat_call(
        "c1",
        "chat_permission",
        &json!({"tool_name":"Bash","input":{"command":"ls"}}),
        call,
        wait,
    )
    .unwrap();
    assert_eq!(
        prompt,
        json!({"behavior":"allow","updatedInput":{"command":"ls"}})
    );
    assert_eq!(waits.lock().unwrap().last().unwrap()["source"], "claude");
}

fn one_page_pdf(path: &Path) {
    let content = b"BT /F1 24 Tf 72 700 Td (Sparse attention is enough) Tj ET\n";
    let objects: Vec<Vec<u8>> = vec![
        b"<< /Type /Catalog /Pages 2 0 R >>".to_vec(),
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>".to_vec(),
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>".to_vec(),
        [format!("<< /Length {} >>\nstream\n", content.len()).into_bytes(), content.to_vec(), b"\nendstream".to_vec()].concat(),
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

fn script(dir: &Path, name: &str, body: &str) -> std::path::PathBuf {
    let path = dir.join(name);
    std::fs::write(&path, body).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

fn wait_for(events: &Arc<Mutex<Vec<Value>>>, what: &str, predicate: impl Fn(&[Value]) -> bool) {
    let end = Instant::now() + Duration::from_secs(10);
    while Instant::now() < end {
        if predicate(&events.lock().unwrap()) {
            return;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    panic!(
        "timed out waiting for {what}: {:#?}",
        events.lock().unwrap()
    );
}

fn kinds(lib: &Library, chat: &Value) -> Vec<String> {
    lib.call("chat_get", &json!({"chat_id":chat})).unwrap()["events"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["kind"].as_str().unwrap().to_string())
        .collect()
}

#[test]
fn chats_stream_persist_resume_cancel_approve_and_delete() {
    let dir = tempfile::tempdir().unwrap();
    let log = dir.path().join("agent.log");
    let claude_bin = script(
        dir.path(),
        "fake-claude",
        &format!(
            r#"#!/bin/sh
echo "START $*" >> {log}
while IFS= read -r line; do
  case "$line" in
    *control_request*)
      printf '%s\n' '{{"type":"control_response","response":{{"subtype":"success"}}}}'
      printf '%s\n' '{{"type":"result","subtype":"error_during_execution","is_error":true,"usage":{{}}}}' ;;
    *slow*)
      printf '%s\n' '{{"type":"stream_event","event":{{"type":"content_block_delta","delta":{{"type":"text_delta","text":"Thinking"}}}}}}' ;;
    *)
      echo "LINE $line" >> {log}
      printf '%s\n' '{{"type":"system","subtype":"init","model":"fake-model","session_id":"s","mcp_servers":[{{"name":"omabib","status":"connected"}}]}}'
      printf '%s\n' '{{"type":"stream_event","event":{{"type":"content_block_delta","delta":{{"type":"text_delta","text":"Hel"}}}}}}'
      printf '%s\n' '{{"type":"stream_event","event":{{"type":"content_block_delta","delta":{{"type":"text_delta","text":"lo"}}}}}}'
      printf '%s\n' '{{"type":"assistant","message":{{"content":[{{"type":"text","text":"Hello"}}]}}}}'
      printf '%s\n' '{{"type":"result","subtype":"success","is_error":false,"usage":{{"input_tokens":1,"output_tokens":2}},"total_cost_usd":0.01}}' ;;
  esac
done
"#,
            log = log.display()
        ),
    );
    let codex_bin = script(
        dir.path(),
        "fake-codex",
        &format!(
            r#"#!/bin/sh
echo "CODEX $*" >> {log}
for last; do :; done
printf '%s\n' '{{"type":"thread.started","thread_id":"thread-fixture"}}'
printf '%s\n' '{{"type":"turn.started"}}'
case "$last" in
  *slow*) sleep 30 ;;
  *) printf '%s\n' '{{"type":"item.completed","item":{{"id":"item_0","type":"agent_message","text":"Codex says hi"}}}}'
     printf '%s\n' '{{"type":"turn.completed","usage":{{"input_tokens":3,"cached_input_tokens":1,"output_tokens":4}}}}' ;;
esac
"#,
            log = log.display()
        ),
    );
    // The only test in this binary that reads these variables.
    unsafe {
        std::env::set_var("OMABIB_CLAUDE_BIN", &claude_bin);
        std::env::set_var("OMABIB_CODEX_BIN", &codex_bin);
        std::env::set_var("OMABIB_BIN", "/usr/bin/omabib-fixture");
        std::env::set_var("OMABIB_CHAT_APPROVAL_TIMEOUT_MS", "300");
    }

    let lib = Arc::new(Library::open(dir.path().join("library.db")).unwrap());
    let rid = lib
        .call(
            "import_bibtex",
            &json!({"bibtex":"@article{chat_fixture,title={Chat fixture}}"}),
        )
        .unwrap()["items"][0]["id"]
        .clone();
    let pdf = dir.path().join("paper.pdf");
    one_page_pdf(&pdf);
    lib.call(
        "attach",
        &json!({"ref_id":rid,"path":pdf,"file_type":"pdf"}),
    )
    .unwrap();
    lib.call("add_note", &json!({"ref_id":rid,"project_id":null,"body":"A note for the context","provenance":"human"})).unwrap();
    let events = Arc::new(Mutex::new(Vec::<Value>::new()));
    let sink = events.clone();
    lib.chats.subscribe(Box::new(move |line| {
        sink.lock()
            .unwrap()
            .push(serde_json::from_str(line).unwrap());
        true
    }));
    let turn_ends = |events: &[Value], chat: &Value| {
        events
            .iter()
            .filter(|e| e["chat_id"] == *chat && e["kind"] == "turn_end")
            .count()
    };

    // Claude: one process for the chat, deltas pushed but not stored.
    let chat = lib
        .call("chat_start", &json!({"ref_id":rid,"agent":"claude"}))
        .unwrap()["chat"]
        .clone();
    let id = chat["id"].clone();
    assert_eq!(chat["agent_label"], "Claude Code");
    lib.call(
        "chat_send",
        &json!({"chat_id":id,"text":"What is this paper?"}),
    )
    .unwrap();
    wait_for(&events, "first Claude turn", |e| turn_ends(e, &id) == 1);
    assert_eq!(
        kinds(&lib, &id),
        ["user", "session", "assistant", "turn_end"]
    );
    let got = events.lock().unwrap().clone();
    let deltas: String = got
        .iter()
        .filter(|e| e["kind"] == "delta")
        .map(|e| e["data"]["text"].as_str().unwrap())
        .collect();
    assert_eq!(deltas, "Hello");
    assert!(
        got.iter()
            .filter(|e| e["kind"] == "delta")
            .all(|e| e["seq"].is_null())
    );
    let folder = dir.path().join("chats").join(id.as_str().unwrap());
    let context: Value =
        serde_json::from_str(&std::fs::read_to_string(folder.join("context.json")).unwrap())
            .unwrap();
    assert_eq!(context["reference"]["id"], rid);
    assert_eq!(
        context["reference"]["notes"][0]["body"],
        "A note for the context"
    );
    assert_eq!(
        std::fs::metadata(folder.join("context.json"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    let mcp: Value =
        serde_json::from_str(&std::fs::read_to_string(folder.join("mcp.json")).unwrap()).unwrap();
    assert_eq!(mcp["mcpServers"]["omabib"]["env"]["OMABIB_CHAT_ID"], id);
    assert_eq!(
        mcp["mcpServers"]["omabib"]["env"]["OMABIB_CHAT_AGENT"],
        "claude"
    );

    // A selection is quoted with its page; a clip goes along as a PNG rendered from the PDF.
    lib.call("chat_send", &json!({"chat_id":id,"text":"And again","selection":{"page":1,"text":"Sparse attention\nis enough"},
        "clip":{"page":1,"rect_pt":{"x":72,"y":80,"width":200,"height":40},"source_pdf":pdf}})).unwrap();
    wait_for(&events, "second Claude turn", |e| turn_ends(e, &id) == 2);
    let logged = std::fs::read_to_string(&log).unwrap();
    assert_eq!(
        logged.matches("START ").count(),
        1,
        "the process is reused: {logged}"
    );
    assert!(logged.contains("--session-id"));
    let sent: Value = serde_json::from_str(
        logged
            .lines()
            .filter_map(|l| l.strip_prefix("LINE "))
            .next_back()
            .unwrap(),
    )
    .unwrap();
    let text = sent["message"]["content"][0]["text"].as_str().unwrap();
    assert!(
        text.starts_with("About this passage (PDF p. 1):\n> Sparse attention\n> is enough\n"),
        "{text}"
    );
    assert!(
        text.ends_with("(The attached image is a region of PDF p. 1.)\nAnd again"),
        "{text}"
    );
    let png = base64::Engine::decode(
        &base64::engine::general_purpose::STANDARD,
        sent["message"]["content"][1]["source"]["data"]
            .as_str()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(&png[..8], b"\x89PNG\r\n\x1a\n");
    let user = &lib
        .call("chat_get", &json!({"chat_id":id,"after_seq":4}))
        .unwrap()["events"][0];
    assert_eq!(user["data"]["selection"]["page"], 1);
    assert!(Path::new(user["data"]["clip"]["file"].as_str().unwrap()).is_file());

    // Stop mid-reply: the interrupt request ends the turn as interrupted.
    lib.call("chat_send", &json!({"chat_id":id,"text":"slow please"}))
        .unwrap();
    wait_for(&events, "slow delta", |e| {
        e.iter()
            .any(|x| x["kind"] == "delta" && x["data"]["text"] == "Thinking")
    });
    assert!(
        lib.call("chat_send", &json!({"chat_id":id,"text":"another"}))
            .is_err(),
        "one turn at a time"
    );
    lib.call("chat_cancel", &json!({"chat_id":id})).unwrap();
    wait_for(&events, "interrupted turn", |e| turn_ends(e, &id) == 3);
    let last = lib
        .call("chat_get", &json!({"chat_id":id,"after_seq":0}))
        .unwrap()["events"]
        .as_array()
        .unwrap()
        .last()
        .unwrap()
        .clone();
    assert_eq!(last["data"]["interrupted"], true);

    // Approvals: a request waits for the reader; allow, deny and expiry.
    let asker = lib.clone();
    let chat_for_thread = id.clone();
    let waiting = std::thread::spawn(move || {
        asker.call("chat_permission_request", &json!({"chat_id":chat_for_thread,"tool":"mcp__omabib__add_note","input":{"body":"Save me"},"source":"omabib"})).unwrap()
    });
    wait_for(&events, "approval request", |e| {
        e.iter().any(|x| x["kind"] == "approval")
    });
    let request = events
        .lock()
        .unwrap()
        .iter()
        .find(|x| x["kind"] == "approval")
        .unwrap()["data"]["request_id"]
        .clone();
    assert_eq!(
        lib.call("chat_get", &json!({"chat_id":id})).unwrap()["chat"]["pending_approvals"],
        json!([request])
    );
    lib.call(
        "chat_approve",
        &json!({"chat_id":id,"request_id":request,"allow":true}),
    )
    .unwrap();
    assert_eq!(waiting.join().unwrap()["allow"], true);
    assert!(
        lib.call(
            "chat_approve",
            &json!({"chat_id":id,"request_id":request,"allow":true})
        )
        .is_err(),
        "answered once"
    );
    let expired = lib
        .call(
            "chat_permission_request",
            &json!({"chat_id":id,"tool":"WebFetch","input":{},"source":"claude"}),
        )
        .unwrap();
    assert_eq!(expired["allow"], false);
    assert!(
        events
            .lock()
            .unwrap()
            .iter()
            .any(|x| x["kind"] == "approval_result" && x["data"]["reason"] == "expired")
    );

    // Terminal handoff continues the same session without the approval queue.
    let resume = lib
        .call("chat_resume_command", &json!({"chat_id":id}))
        .unwrap();
    let argv: Vec<&str> = resume["argv"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap())
        .collect();
    assert_eq!(argv[1], "--resume");
    let terminal: Value =
        serde_json::from_str(&std::fs::read_to_string(folder.join("terminal-mcp.json")).unwrap())
            .unwrap();
    assert!(
        terminal["mcpServers"]["omabib"]["env"]
            .get("OMABIB_CHAT_ID")
            .is_none()
    );

    // Codex: a process per turn; the thread is resumed and instructions sent once.
    let cchat = lib
        .call("chat_start", &json!({"ref_id":rid,"agent":"codex"}))
        .unwrap()["chat"]["id"]
        .clone();
    lib.call("chat_send", &json!({"chat_id":cchat,"text":"Hi Codex"}))
        .unwrap();
    wait_for(&events, "first Codex turn", |e| turn_ends(e, &cchat) == 1);
    lib.call("chat_send", &json!({"chat_id":cchat,"text":"Follow up"}))
        .unwrap();
    wait_for(&events, "second Codex turn", |e| turn_ends(e, &cchat) == 2);
    let logged = std::fs::read_to_string(&log).unwrap();
    let codex_lines: Vec<&str> = logged.lines().filter(|l| l.starts_with("CODEX ")).collect();
    assert!(
        !codex_lines[0].contains("resume") && codex_lines[0].contains("You are helping me read"),
        "{logged}"
    );
    assert!(
        logged.contains("CODEX exec resume thread-fixture --json")
            && logged.contains("-- Follow up"),
        "{logged}"
    );
    assert_eq!(
        kinds(&lib, &cchat),
        [
            "user",
            "assistant",
            "turn_end",
            "user",
            "assistant",
            "turn_end"
        ]
    );
    lib.call("chat_send", &json!({"chat_id":cchat,"text":"slow one"}))
        .unwrap();
    std::thread::sleep(Duration::from_millis(300));
    lib.call("chat_cancel", &json!({"chat_id":cchat})).unwrap();
    wait_for(&events, "interrupted Codex turn", |e| {
        turn_ends(e, &cchat) == 3
    });
    let listed = lib.call("chat_list", &json!({"ref_id":rid})).unwrap();
    assert_eq!(listed["chats"].as_array().unwrap().len(), 2);
    assert_eq!(
        listed["chats"][0]["title"], "Hi Codex",
        "the newest chat first, titled by its first message"
    );

    // Deleting the reference deletes its chats, their folders and stops their processes.
    let preview = lib
        .call("delete_reference_preview", &json!({"id":rid}))
        .unwrap();
    assert_eq!(preview["chat_count"], 2);
    lib.call("delete_reference", &json!({"id":rid,"expected_revision":preview["revision"],"confirm_citekey":"chat_fixture",
        "expected_notes":preview["note_count"],"expected_attachments":preview["attachment_count"],"idempotency_key":"delete-chat-ref"})).unwrap();
    assert!(lib.call("chat_get", &json!({"chat_id":id})).is_err());
    assert!(!folder.exists());
}
