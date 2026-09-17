//! Codex in `exec --json` mode: one process per turn, resumed by thread ID.
//!
//! Events are recorded in tests/fixtures/chat/codex-*.jsonl. Codex sends whole
//! messages rather than token deltas, and runs shell commands in a read-only
//! sandbox, so only Omabib's own writes reach the approval queue.
use super::Event;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

pub struct Turn<'a> {
    pub thread_id: Option<&'a str>,
    pub omabib: &'a Path,
    pub socket: &'a Path,
    pub chat_id: &'a str,
    pub images: &'a [PathBuf],
    pub prompt: &'a str,
    pub model: Option<&'a str>,
    pub effort: Option<&'a str>,
}

/// The TOML inline table for `-c`, strings quoted as JSON (valid TOML basic strings).
pub fn mcp_server(omabib: &Path, socket: &Path, chat_id: Option<&str>) -> String {
    let q = |s: &str| serde_json::to_string(s).unwrap();
    let mut env = format!("OMABIB_SOCKET={}", q(&socket.to_string_lossy()));
    if let Some(id) = chat_id {
        env.push_str(&format!(
            ",OMABIB_CHAT_ID={},OMABIB_CHAT_AGENT=\"codex\"",
            q(id)
        ));
    }
    // Approvals can take minutes; Codex's default MCP call timeout is far shorter.
    format!(
        "mcp_servers.omabib={{command={},args=[\"mcp\"],enabled=true,tool_timeout_sec=900,env={{{env}}}}}",
        q(&omabib.to_string_lossy())
    )
}

/// `-m` and the reasoning effort override, for a turn or a terminal resume.
pub fn model_args(model: Option<&str>, effort: Option<&str>) -> Vec<String> {
    let mut args = Vec::new();
    if let Some(model) = model {
        args.extend(["-m".into(), model.into()]);
    }
    if let Some(effort) = effort {
        args.extend([
            "-c".into(),
            format!(
                "model_reasoning_effort={}",
                serde_json::to_string(effort).unwrap()
            ),
        ]);
    }
    args
}

pub fn args(t: &Turn) -> Vec<String> {
    let mut args: Vec<String> = vec!["exec".into()];
    if let Some(thread) = t.thread_id {
        args.extend(["resume".into(), thread.into()]);
    }
    args.extend([
        "--json".into(),
        "--skip-git-repo-check".into(),
        "-c".into(),
        mcp_server(t.omabib, t.socket, Some(t.chat_id)),
        "-c".into(),
        "sandbox_mode=\"read-only\"".into(),
    ]);
    args.extend(model_args(t.model, t.effort));
    for image in t.images {
        args.extend(["-i".into(), image.to_string_lossy().into_owned()]);
    }
    args.extend(["--".into(), t.prompt.into()]);
    args
}

/// The pickable models from `codex debug models`, in Codex's own order.
pub fn models(catalog: &Value) -> Vec<Value> {
    let mut models: Vec<&Value> = catalog["models"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|m| m["visibility"] == "list" && m["slug"].is_string())
        .collect();
    models.sort_by_key(|m| m["priority"].as_i64().unwrap_or(i64::MAX));
    models
        .into_iter()
        .map(|m| {
            json!({
                "id": m["slug"],
                "label": m["display_name"].as_str().or(m["slug"].as_str()),
                "efforts": m["supported_reasoning_levels"].as_array().into_iter().flatten()
                    .filter_map(|l| l["effort"].as_str()).collect::<Vec<_>>(),
                "default_effort": m["default_reasoning_level"],
            })
        })
        .collect()
}

/// The top-level `model` and `model_reasoning_effort` of Codex's config.toml:
/// what a turn without overrides uses.
pub fn configured_default(config: &str) -> (Option<String>, Option<String>) {
    let (mut model, mut effort) = (None, None);
    for line in config.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            break;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let value = value.trim();
        let value = value
            .strip_prefix('"')
            .and_then(|v| v.split_once('"'))
            .map(|(v, _)| v.to_string());
        match key.trim() {
            "model" => model = model.or(value),
            "model_reasoning_effort" => effort = effort.or(value),
            _ => {}
        }
    }
    (model, effort)
}

pub fn parse(line: &str) -> Vec<Event> {
    let Ok(e) = serde_json::from_str::<Value>(line) else {
        return vec![];
    };
    let text = |v: &Value| v.as_str().unwrap_or("").to_string();
    let item = &e["item"];
    match e["type"].as_str().unwrap_or("") {
        "thread.started" => vec![Event::Thread(text(&e["thread_id"]))],
        "turn.started" => vec![Event::Status("thinking".into())],
        "item.started" => match item["type"].as_str().unwrap_or("") {
            "command_execution" => vec![Event::ToolCall {
                id: text(&item["id"]),
                name: "shell".into(),
                input: json!({"command": item["command"]}),
            }],
            "mcp_tool_call" => vec![Event::ToolCall {
                id: text(&item["id"]),
                name: format!("mcp__{}__{}", text(&item["server"]), text(&item["tool"])),
                input: item["arguments"].clone(),
            }],
            _ => vec![Event::Status("thinking".into())],
        },
        "item.completed" => match item["type"].as_str().unwrap_or("") {
            "agent_message" => vec![Event::Assistant(text(&item["text"]))],
            "reasoning" => vec![Event::Status("thinking".into())],
            "command_execution" => vec![Event::ToolResult {
                id: text(&item["id"]),
                output: text(&item["aggregated_output"]),
                is_error: item["exit_code"].as_i64().is_some_and(|c| c != 0)
                    || item["status"] == "failed",
            }],
            "mcp_tool_call" => {
                let output = item["result"]["content"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|p| p["text"].as_str())
                    .collect::<Vec<_>>()
                    .join("\n");
                let error = text(&item["error"]["message"]);
                vec![Event::ToolResult {
                    id: text(&item["id"]),
                    is_error: !error.is_empty() || item["status"] == "failed",
                    output: if error.is_empty() { output } else { error },
                }]
            }
            other => vec![Event::Note(format!("Unrecognized Codex item: {other}"))],
        },
        "turn.completed" => vec![Event::TurnEnd(json!({
            "interrupted": false,
            "is_error": false,
            "usage": {
                // Codex counts cached input inside input_tokens.
                "input_tokens": e["usage"]["input_tokens"],
                "cached_input_tokens": e["usage"]["cached_input_tokens"],
                "output_tokens": e["usage"]["output_tokens"],
            },
        }))],
        "turn.failed" | "error" => {
            let message = [&e["error"]["message"], &e["message"]]
                .iter()
                .find_map(|v| v.as_str())
                .unwrap_or("Codex reported an error")
                .to_string();
            vec![Event::Error(message)]
        }
        other => vec![Event::Note(format!("Unrecognized Codex event: {other}"))],
    }
}
