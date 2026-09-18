//! Connecting a cloud account through rclone's non-interactive config protocol.
//! rclone asks questions as JSON; Omabib answers them, runs the browser sign-in
//! (`rclone authorize … --auth-no-open-browser`) and hands the sign-in link to
//! the window, which opens it. The connection is always the `omabib` remote in
//! Omabib's own rclone config.
use super::store::rclone_binary;
use super::{Sync, rclone_config};
use anyhow::{Context, Result, bail};
use serde_json::{Value, json};
use std::{
    io::{BufRead, BufReader, Read},
    process::{Child, Command, Stdio},
    sync::{Arc, Mutex},
};

/// Omabib's Google app, registered for the "files Omabib creates" permission.
/// Environment variables override it (for development builds).
const GOOGLE_CLIENT_ID: &str = "";
const GOOGLE_CLIENT_SECRET: &str = "";

fn google_client() -> Option<(String, String)> {
    let credentials = rclone_config().parent()?.join("google-client.json");
    let downloaded: Value = std::fs::read(credentials)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or(Value::Null);
    let id = std::env::var("OMABIB_GOOGLE_CLIENT_ID")
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| {
            downloaded["installed"]["client_id"]
                .as_str()
                .unwrap_or(GOOGLE_CLIENT_ID)
                .to_string()
        });
    let secret = std::env::var("OMABIB_GOOGLE_CLIENT_SECRET")
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| {
            downloaded["installed"]["client_secret"]
                .as_str()
                .unwrap_or(GOOGLE_CLIENT_SECRET)
                .to_string()
        });
    (!id.is_empty()).then_some((id, secret))
}

struct Provider {
    id: &'static str,
    label: &'static str,
    rclone_type: &'static str,
    folder: &'static str,
}

const PROVIDERS: [Provider; 3] = [
    Provider {
        id: "drive",
        label: "Google Drive",
        rclone_type: "drive",
        folder: "My Drive → Omabib",
    },
    Provider {
        id: "dropbox",
        label: "Dropbox",
        rclone_type: "dropbox",
        folder: "Dropbox → Omabib",
    },
    Provider {
        id: "onedrive",
        label: "OneDrive",
        rclone_type: "onedrive",
        folder: "OneDrive → Omabib",
    },
];

fn rclone_version() -> Option<String> {
    let out = Command::new(rclone_binary()?)
        .arg("version")
        .output()
        .ok()?;
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .next()
        .and_then(|l| l.split_whitespace().nth(1))
        .map(str::to_owned)
}

/// The choices the Sync dialog offers, and what each one needs.
pub fn providers() -> Value {
    let version = rclone_version();
    let mut list: Vec<Value> = PROVIDERS
        .iter()
        .map(|p| {
            let blocked = (p.id == "drive" && google_client().is_none())
                .then_some("Waiting for Omabib's Google app registration");
            json!({"id":p.id,"label":p.label,"folder":p.folder,"needs_rclone":true,
                "available": version.is_some() && blocked.is_none(), "blocked": blocked})
        })
        .collect();
    list.push(json!({"id":"folder","label":"A folder on this computer","needs_rclone":false,"available":true,
        "folder":"Syncthing, Nextcloud or Dropbox's app keeps it in sync"}));
    list.push(json!({"id":"rclone","label":"Other (advanced)","needs_rclone":true,"available":version.is_some(),
        "folder":"S3, R2, B2, WebDAV or anything rclone reaches"}));
    let remotes: Vec<String> = remotes()
        .unwrap_or_default()
        .into_iter()
        .filter(|r| r != "omabib")
        .collect();
    json!({"rclone": {"installed": version.is_some(), "version": version, "config": rclone_config(), "remotes": remotes},
        "providers": list})
}

/// The remotes in Omabib's rclone config.
pub fn remotes() -> Result<Vec<String>> {
    let bin = rclone_binary().context("rclone is not installed")?;
    let out = Command::new(bin)
        .arg("--config")
        .arg(rclone_config())
        .arg("listremotes")
        .output()?;
    Ok(String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(|l| l.trim().trim_end_matches(':').to_string())
        .filter(|l| !l.is_empty())
        .collect())
}

/// A sign-in in progress, polled through `sync_status` and pushed as events.
pub struct Connecting {
    provider: String,
    label: String,
    state: Mutex<(String, String, Option<String>)>,
    child: Mutex<Option<Child>>,
}

impl Connecting {
    pub fn json(&self) -> Value {
        let (state, message, url) = self.state.lock().unwrap().clone();
        json!({"provider":self.provider,"label":self.label,"state":state,"message":message,"url":url})
    }

    fn set(&self, sync: &Sync, state: &str, message: &str, url: Option<String>) {
        *self.state.lock().unwrap() = (state.into(), message.into(), url);
        sync.publish();
    }

    fn cancelled(&self) -> bool {
        self.state.lock().unwrap().0 == "cancelled"
    }

    pub fn cancel(&self) {
        self.state.lock().unwrap().0 = "cancelled".into();
        if let Some(mut child) = self.child.lock().unwrap().take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

fn rclone(args: &[String]) -> Result<Value> {
    let bin = rclone_binary().context("rclone is not installed")?;
    let out = Command::new(bin)
        .arg("--config")
        .arg(rclone_config())
        .args(args)
        .stdin(Stdio::null())
        .output()?;
    let stdout = String::from_utf8_lossy(&out.stdout);
    let start = stdout.find('{');
    match start {
        Some(i) => Ok(serde_json::from_str(&stdout[i..])
            .with_context(|| format!("rclone answered unexpectedly: {}", stdout.trim()))?),
        None => {
            let err = String::from_utf8_lossy(&out.stderr);
            bail!(
                "rclone could not set up the connection: {}",
                err.lines().last().unwrap_or("no answer")
            )
        }
    }
}

/// The `rclone authorize` arguments rclone puts in its `config_token` question.
pub fn authorize_args(help: &str) -> Option<Vec<String>> {
    let at = help.find("rclone authorize ")?;
    let rest = &help[at + "rclone authorize ".len()..];
    let line = rest.lines().next()?;
    let mut args = Vec::new();
    let mut chars = line.chars().peekable();
    while let Some(&ch) = chars.peek() {
        if ch == '"' {
            chars.next();
            let arg: String = chars.by_ref().take_while(|&c| c != '"').collect();
            args.push(arg);
        } else if ch.is_whitespace() {
            chars.next();
        } else {
            let arg: String = chars.by_ref().take_while(|c| !c.is_whitespace()).collect();
            args.push(arg);
        }
    }
    (!args.is_empty()).then_some(args)
}

/// The token between rclone's "Paste the following…" markers.
pub fn token_from(stdout: &str) -> Option<String> {
    if let (Some(a), Some(b)) = (stdout.find("--->"), stdout.find("<---End paste")) {
        return Some(stdout[a + 4..b].trim().to_string()).filter(|t| !t.is_empty());
    }
    let t = stdout.trim();
    (t.starts_with('{') && t.ends_with('}')).then(|| t.to_string())
}

/// Starts connecting a provider in the background.
pub fn start(sync: Arc<Sync>, provider: &str) -> Result<Arc<Connecting>> {
    let p = PROVIDERS
        .iter()
        .find(|p| p.id == provider)
        .with_context(|| format!("Unknown storage {provider}"))?;
    rclone_binary().context("Install rclone first")?;
    let mut params: Vec<String> = Vec::new();
    if p.id == "drive" {
        let (id, secret) = google_client()
            .context("Google Drive needs Omabib's Google app, which isn't registered yet")?;
        params.extend(["scope".into(), "drive.file".into(), "client_id".into(), id]);
        if !secret.is_empty() {
            params.extend(["client_secret".into(), secret]);
        }
    }
    let job = Arc::new(Connecting {
        provider: p.id.into(),
        label: p.label.into(),
        state: Mutex::new(("starting".into(), String::new(), None)),
        child: Mutex::new(None),
    });
    let setting = json!({"kind":"rclone","remote":"omabib","provider":p.id,"label":p.label});
    let rclone_type = p.rclone_type.to_string();
    let worker = job.clone();
    std::thread::spawn(move || {
        let result = run(&sync, &worker, &rclone_type, &params);
        if worker.cancelled() {
            return;
        }
        match result.and_then(|_| check(&setting)) {
            Ok(()) => {
                let _ = sync.connected(&setting);
                worker.set(&sync, "done", "", None);
            }
            Err(e) => worker.set(&sync, "error", &format!("{e:#}"), None),
        }
    });
    Ok(job)
}

fn run(sync: &Sync, job: &Connecting, rclone_type: &str, params: &[String]) -> Result<()> {
    if let Some(parent) = rclone_config().parent() {
        std::fs::create_dir_all(parent)?;
    }
    let _ = rclone(&["config".into(), "delete".into(), "omabib".into()]);
    let mut args: Vec<String> = vec![
        "config".into(),
        "create".into(),
        "omabib".into(),
        rclone_type.into(),
    ];
    args.extend(params.iter().cloned());
    args.push("--non-interactive".into());
    let mut answer = rclone(&args)?;
    for _ in 0..20 {
        if job.cancelled() {
            bail!("Cancelled");
        }
        if let Some(e) = answer["Error"].as_str().filter(|e| !e.is_empty()) {
            bail!("{e}");
        }
        let state = answer["State"].as_str().unwrap_or("").to_string();
        if state.is_empty() {
            return Ok(());
        }
        let option = &answer["Option"];
        let name = option["Name"].as_str().unwrap_or("");
        let result = match name {
            // No browser "here": rclone then says how to sign in, which Omabib does.
            "config_is_local" => "false".to_string(),
            "config_token" => {
                let help = option["Help"].as_str().unwrap_or("");
                let auth = authorize_args(help).context("rclone did not say how to sign in")?;
                sign_in(sync, job, &auth)?
            }
            _ => match &option["Default"] {
                Value::Bool(b) => b.to_string(),
                Value::Null => option["Examples"][0]["Value"]
                    .as_str()
                    .unwrap_or("")
                    .to_string(),
                Value::String(s) if s.is_empty() => option["Examples"][0]["Value"]
                    .as_str()
                    .unwrap_or("")
                    .to_string(),
                Value::String(s) => s.clone(),
                other => other.to_string(),
            },
        };
        let mut next: Vec<String> = vec![
            "config".into(),
            "update".into(),
            "omabib".into(),
            "--continue".into(),
            "--state".into(),
            state,
            "--result".into(),
            result,
            "--non-interactive".into(),
        ];
        next.extend(params.iter().cloned());
        answer = rclone(&next)?;
    }
    bail!("rclone kept asking questions")
}

/// Runs the browser sign-in and returns the token rclone prints afterwards.
fn sign_in(sync: &Sync, job: &Connecting, auth: &[String]) -> Result<String> {
    let bin = rclone_binary().context("rclone is not installed")?;
    let mut child = Command::new(bin)
        .arg("--config")
        .arg(rclone_config())
        .arg("authorize")
        .args(auth)
        .arg("--auth-no-open-browser")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let stderr = child.stderr.take().unwrap();
    let mut stdout = child.stdout.take().unwrap();
    *job.child.lock().unwrap() = Some(child);
    let out = std::thread::spawn(move || {
        let mut s = String::new();
        let _ = stdout.read_to_string(&mut s);
        s
    });
    let mut last = String::new();
    for line in BufReader::new(stderr).lines() {
        let line = line?;
        if let Some(i) = line.find("http://127.0.0.1:") {
            let url = line[i..]
                .split_whitespace()
                .next()
                .unwrap_or("")
                .to_string();
            job.set(sync, "browser", "", Some(url));
        } else if !line.trim().is_empty() {
            last = line;
        }
    }
    let stdout = out.join().unwrap_or_default();
    let child = job.child.lock().unwrap().take();
    if let Some(mut child) = child {
        let status = child.wait()?;
        if !status.success() && !job.cancelled() {
            bail!("The sign-in didn't finish: {}", last.trim());
        }
    }
    if job.cancelled() {
        bail!("Cancelled");
    }
    job.set(sync, "finishing", "", None);
    token_from(&stdout).context("rclone did not return a sign-in token")
}

/// A quick look at the new connection: its root must list.
fn check(setting: &Value) -> Result<()> {
    let store = super::open_store(setting)?;
    store.list("")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_rclone_sign_in_instructions() {
        let help = "Execute the following on the machine with the web browser (same rclone\nversion recommended):\n\n\trclone authorize \"drive\" \"eyJzY29wZSI6ImRyaXZlLmZpbGUifQ\"\n\nThen paste the result.\n";
        assert_eq!(
            authorize_args(help).unwrap(),
            vec![
                "drive".to_string(),
                "eyJzY29wZSI6ImRyaXZlLmZpbGUifQ".to_string()
            ]
        );
        assert_eq!(
            authorize_args("\trclone authorize \"dropbox\"\n\nThen paste").unwrap(),
            vec!["dropbox".to_string()]
        );
        let out = "Paste the following into your remote machine --->\n{\"access_token\":\"x\",\"expiry\":\"2026\"}\n<---End paste\n";
        assert_eq!(
            token_from(out).unwrap(),
            "{\"access_token\":\"x\",\"expiry\":\"2026\"}"
        );
        assert!(token_from("nothing").is_none());
    }
}
