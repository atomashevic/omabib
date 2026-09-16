//! Claude Code in headless streaming mode: one long-lived process per chat.
//!
//! Input and output are the `stream-json` formats of `claude -p` (recorded in
//! tests/fixtures/chat/claude-session.jsonl). Each user message is one stdin line;
//! a turn ends with a `result` event.
use super::Event;
use serde_json::{Value, json};
use std::collections::HashSet;
use std::path::Path;

/// Tools Claude Code uses internally to load other tools; not worth a row in the chat.
const HIDDEN_TOOLS: &[&str] = &["ToolSearch"];

pub struct Launch<'a> {
    pub session_id: &'a str,
    pub resume: bool,
    pub folder: &'a Path,
    pub instructions: &'a str,
}

pub fn args(l: &Launch) -> Vec<String> {
    let mut args: Vec<String> = [
        "-p",
        "--input-format",
        "stream-json",
        "--output-format",
        "stream-json",
        "--include-partial-messages",
        "--verbose",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    args.push(if l.resume { "--resume" } else { "--session-id" }.into());
    args.push(l.session_id.into());
    args.extend([
        "--mcp-config".into(),
        l.folder.join("mcp.json").to_string_lossy().into_owned(),
        "--strict-mcp-config".into(),
        "--add-dir".into(),
        l.folder.to_string_lossy().into_owned(),
        // Reading is free. Omabib's own write tools ask inside its MCP server;
        // anything else Claude wants goes through the permission tool.
        "--allowedTools".into(),
        "Read".into(),
        "Grep".into(),
        "Glob".into(),
        "mcp__omabib".into(),
        "--permission-prompt-tool".into(),
        "mcp__omabib__chat_permission".into(),
        "--append-system-prompt".into(),
        l.instructions.into(),
    ]);
    args
}

/// One user message as a stdin line: text, then any images as base64 PNG blocks.
pub fn user_line(text: &str, images: &[Vec<u8>]) -> String {
    use base64::Engine;
    let content = if images.is_empty() {
        json!(text)
    } else {
        let mut blocks = vec![json!({"type":"text","text":text})];
        for png in images {
            blocks.push(json!({"type":"image","source":{"type":"base64","media_type":"image/png","data":base64::engine::general_purpose::STANDARD.encode(png)}}));
        }
        json!(blocks)
    };
    json!({"type":"user","message":{"role":"user","content":content}}).to_string()
}

pub fn interrupt_line(request_id: &str) -> String {
    json!({"type":"control_request","request_id":request_id,"request":{"subtype":"interrupt"}})
        .to_string()
}

#[derive(Default)]
pub struct Parser {
    hidden: HashSet<String>,
    announced_model: Option<String>,
}

impl Parser {
    pub fn parse(&mut self, line: &str) -> Vec<Event> {
        let Ok(e) = serde_json::from_str::<Value>(line) else {
            return vec![];
        };
        let text = |v: &Value| v.as_str().unwrap_or("").to_string();
        match e["type"].as_str().unwrap_or("") {
            "system" => match e["subtype"].as_str().unwrap_or("") {
                "init" => {
                    let mut out = Vec::new();
                    let model = text(&e["model"]);
                    if self.announced_model.as_deref() != Some(model.as_str()) {
                        self.announced_model = Some(model.clone());
                        out.push(Event::Session(json!({
                            "agent":"claude","model":model,"version":e["claude_code_version"],"session_id":e["session_id"]
                        })));
                    }
                    for server in e["mcp_servers"].as_array().into_iter().flatten() {
                        if server["name"] == "omabib" && server["status"] != "connected" {
                            out.push(Event::Error(format!(
                                "Omabib's tools did not connect ({}); Claude can still read the context file",
                                text(&server["status"])
                            )));
                        }
                    }
                    out
                }
                "status" | "thinking_tokens" => vec![Event::Status("thinking".into())],
                _ => vec![],
            },
            "stream_event" => {
                let ev = &e["event"];
                match ev["type"].as_str().unwrap_or("") {
                    "content_block_delta" => match ev["delta"]["type"].as_str().unwrap_or("") {
                        "text_delta" => vec![Event::Delta(text(&ev["delta"]["text"]))],
                        "thinking_delta" => vec![Event::Status("thinking".into())],
                        _ => vec![],
                    },
                    "content_block_start" if ev["content_block"]["type"] == "tool_use" => {
                        vec![Event::Status("tool".into())]
                    }
                    _ => vec![],
                }
            }
            "assistant" => {
                let mut out = Vec::new();
                for block in e["message"]["content"].as_array().into_iter().flatten() {
                    match block["type"].as_str().unwrap_or("") {
                        "text" if !text(&block["text"]).trim().is_empty() => {
                            out.push(Event::Assistant(text(&block["text"])))
                        }
                        "tool_use" => {
                            let (id, name) = (text(&block["id"]), text(&block["name"]));
                            if HIDDEN_TOOLS.contains(&name.as_str()) {
                                self.hidden.insert(id);
                            } else {
                                out.push(Event::ToolCall {
                                    id,
                                    name,
                                    input: block["input"].clone(),
                                });
                            }
                        }
                        _ => {}
                    }
                }
                out
            }
            "user" => {
                let mut out = Vec::new();
                for block in e["message"]["content"].as_array().into_iter().flatten() {
                    if block["type"] != "tool_result" {
                        continue;
                    }
                    let id = text(&block["tool_use_id"]);
                    if self.hidden.remove(&id) {
                        continue;
                    }
                    let output = match &block["content"] {
                        Value::String(s) => s.clone(),
                        Value::Array(parts) => parts
                            .iter()
                            .filter_map(|p| p["text"].as_str())
                            .collect::<Vec<_>>()
                            .join("\n"),
                        _ => String::new(),
                    };
                    out.push(Event::ToolResult {
                        id,
                        output,
                        is_error: block["is_error"] == true,
                    });
                }
                out
            }
            "result" => vec![Event::TurnEnd(json!({
                "interrupted": e["subtype"] == "error_during_execution",
                "is_error": e["is_error"] == true && e["subtype"] != "error_during_execution",
                "error": if e["is_error"] == true && e["subtype"] != "error_during_execution" { e["result"].clone() } else { Value::Null },
                "usage": {
                    "input_tokens": e["usage"]["input_tokens"],
                    "cache_read_input_tokens": e["usage"]["cache_read_input_tokens"],
                    "cache_creation_input_tokens": e["usage"]["cache_creation_input_tokens"],
                    "output_tokens": e["usage"]["output_tokens"],
                },
                "session_cost_usd": e["total_cost_usd"],
            }))],
            // Hooks, rate-limit notices and control replies don't belong in the transcript.
            "rate_limit_event" | "control_response" => vec![],
            other => vec![Event::Note(format!(
                "Unrecognized Claude Code event: {other}"
            ))],
        }
    }
}
