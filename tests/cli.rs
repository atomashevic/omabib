//! The `omabib` command as users run it: starting the service on demand and
//! handing window requests to the standalone app. Every path points into a
//! temporary folder, so a real library or service is never touched.
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{Duration, Instant};

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
    fn omabib(&self, args: &[&str]) -> Command {
        let mut c = Command::new(env!("CARGO_BIN_EXE_omabib"));
        c.args(args)
            .env("OMABIB_SOCKET", self.path("run/omabib/socket"))
            .env("OMABIB_DB", self.path("library.db"))
            .env("XDG_STATE_HOME", self.path("state"))
            .env("XDG_CONFIG_HOME", self.path("config"))
            .env_remove("OMABIB_NO_AUTOSTART");
        c
    }
    fn run(&self, args: &[&str]) -> Output {
        self.omabib(args).output().unwrap()
    }
    /// The process holding the service lock, once one does.
    fn service_pid(&self) -> Option<i32> {
        std::fs::read_to_string(self.path("run/omabib/server.lock"))
            .ok()?
            .trim()
            .parse()
            .ok()
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        if let Some(pid) = self.service_pid() {
            unsafe { libc::kill(pid, libc::SIGTERM) };
        }
    }
}

fn wait_for(what: &str, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn the_cli_starts_the_service_when_none_is_running() {
    let s = Sandbox::new();
    let out = s.run(&["status"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let status: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(status["references"], 0, "{status}");

    let pid = s.service_pid().expect("the service records its pid");
    let log = std::fs::read_to_string(s.path("state/omabib/service.log")).unwrap();
    assert!(log.contains("listening on"), "{log}");

    // Later commands use the running service instead of starting another.
    assert!(s.run(&["status"]).status.success());
    assert_eq!(s.service_pid(), Some(pid));
    assert!(!std::fs::read_to_string(s.path("state/omabib/service.log"))
        .unwrap()
        .contains("Another Omabib service"));
}

#[test]
fn autostart_can_be_turned_off() {
    let s = Sandbox::new();
    let out = s
        .omabib(&["status"])
        .env("OMABIB_NO_AUTOSTART", "1")
        .output()
        .unwrap();
    assert!(!out.status.success());
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains("Start it with: omabib serve"), "{err}");
    assert!(s.service_pid().is_none());
}

#[test]
fn window_commands_go_to_the_standalone_app() {
    let s = Sandbox::new();
    let calls = s.path("calls");
    let app = s.path("omabib-desktop");
    std::fs::write(
        &app,
        format!("#!/bin/sh\necho \"$*\" >> '{}'\n", calls.display()),
    )
    .unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&app, std::fs::Permissions::from_mode(0o755)).unwrap();
    let launched = |expected: &str| {
        let calls: &Path = &calls;
        wait_for(expected, || {
            std::fs::read_to_string(calls).is_ok_and(|c| c.lines().any(|l| l == expected))
        });
    };

    let open = s.omabib(&["open"]).env("OMABIB_DESKTOP_BIN", &app).output().unwrap();
    assert!(open.status.success(), "{}", String::from_utf8_lossy(&open.stderr));
    launched("--toggle");
    let add = s.omabib(&["add"]).env("OMABIB_DESKTOP_BIN", &app).output().unwrap();
    assert!(add.status.success(), "{}", String::from_utf8_lossy(&add.stderr));
    launched("--add");
    // Opening the window needs no library service.
    assert!(s.service_pid().is_none());
}
