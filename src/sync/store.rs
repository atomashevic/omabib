//! Where the shared library lives: a folder on this computer (kept in sync by
//! Syncthing, Nextcloud or Dropbox's own app) or any rclone remote. Paths are
//! relative to the library's `Omabib` folder and use `/`.
use anyhow::{Context, Result, bail, ensure};
use serde_json::{Value, json};
use std::{
    io::{Read, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{Duration, Instant},
};

#[derive(Clone, Debug, PartialEq)]
pub struct Entry {
    pub name: String,
    pub size: u64,
}

/// A problem reaching the storage, grouped by what the user can do about it.
#[derive(Debug)]
pub struct StoreError {
    /// "auth", "offline", "full", "missing" (rclone not installed) or "error".
    pub kind: &'static str,
    pub message: String,
}

impl std::fmt::Display for StoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for StoreError {}

pub trait Store: Send + Sync {
    /// Files directly inside `dir`; an absent folder is empty.
    fn list(&self, dir: &str) -> Result<Vec<Entry>>;
    fn read(&self, path: &str) -> Result<Vec<u8>>;
    /// Writes the whole file at once; readers never see part of it.
    fn write(&self, path: &str, data: &[u8]) -> Result<()>;
    fn upload(&self, local: &Path, path: &str) -> Result<()>;
    /// Upload a staged tree without deleting unrelated remote files.
    fn upload_batch(&self, root: &Path, paths: &[String]) -> Result<()> {
        for path in paths {
            self.upload(&root.join(path), path)?;
        }
        Ok(())
    }
    fn download(&self, path: &str, local: &Path) -> Result<()>;
    fn remove(&self, path: &str) -> Result<()>;
    /// Total and free bytes, when the storage reports them.
    fn about(&self) -> Result<Value>;
    /// Where the library is, in words ("~/Sync/Omabib", "Google Drive → Omabib").
    fn describe(&self) -> String;
}

fn split(path: &str) -> (&str, &str) {
    path.rsplit_once('/').unwrap_or(("", path))
}

// ---- A folder ----

pub struct FolderStore {
    pub root: PathBuf,
}

impl FolderStore {
    fn at(&self, path: &str) -> Result<PathBuf> {
        ensure!(
            !path.split('/').any(|p| p == ".." || p.is_empty()) || path.is_empty(),
            "Invalid storage path {path}"
        );
        Ok(self.root.join(path))
    }

    fn temporary(target: &Path) -> PathBuf {
        let name = target
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("file");
        target.with_file_name(format!(".{name}.{}.omabib-tmp", uuid::Uuid::new_v4()))
    }
}

/// Files a sync tool is still writing, or copies it made of a conflict.
fn ignored(name: &str) -> bool {
    name.starts_with('.')
        || name.ends_with(".tmp")
        || name.ends_with(".omabib-tmp")
        || name.contains(".sync-conflict-")
        || name.contains("(conflicted copy")
        || name.starts_with("~$")
}

impl Store for FolderStore {
    fn list(&self, dir: &str) -> Result<Vec<Entry>> {
        let path = self.at(dir)?;
        let Ok(entries) = std::fs::read_dir(&path) else {
            return Ok(vec![]);
        };
        let mut out = Vec::new();
        for e in entries {
            let e = e?;
            let name = e.file_name().to_string_lossy().into_owned();
            let meta = e.metadata()?;
            if meta.is_file() && !ignored(&name) {
                out.push(Entry {
                    name,
                    size: meta.len(),
                });
            }
        }
        out.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(out)
    }

    fn read(&self, path: &str) -> Result<Vec<u8>> {
        std::fs::read(self.at(path)?)
            .with_context(|| format!("Could not read {path} from the sync folder"))
    }

    fn write(&self, path: &str, data: &[u8]) -> Result<()> {
        let target = self.at(path)?;
        std::fs::create_dir_all(target.parent().unwrap())?;
        let tmp = Self::temporary(&target);
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(data)?;
        f.sync_all()?;
        std::fs::rename(&tmp, &target)?;
        Ok(())
    }

    fn upload(&self, local: &Path, path: &str) -> Result<()> {
        let target = self.at(path)?;
        std::fs::create_dir_all(target.parent().unwrap())?;
        let tmp = Self::temporary(&target);
        std::fs::copy(local, &tmp)
            .with_context(|| format!("Could not copy {}", local.display()))?;
        std::fs::rename(&tmp, &target)?;
        Ok(())
    }

    fn download(&self, path: &str, local: &Path) -> Result<()> {
        std::fs::copy(self.at(path)?, local)
            .with_context(|| format!("{path} is not in the sync folder yet"))?;
        Ok(())
    }

    fn remove(&self, path: &str) -> Result<()> {
        let _ = std::fs::remove_file(self.at(path)?);
        Ok(())
    }

    fn about(&self) -> Result<Value> {
        let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
        let dir = std::ffi::CString::new(
            self.root
                .ancestors()
                .find(|p| p.exists())
                .unwrap_or(Path::new("/"))
                .as_os_str()
                .as_encoded_bytes(),
        )?;
        ensure!(
            unsafe { libc::statvfs(dir.as_ptr(), &mut st) } == 0,
            "Could not read free space"
        );
        let block = st.f_frsize as u64;
        Ok(json!({"total": st.f_blocks as u64 * block, "free": st.f_bavail as u64 * block}))
    }

    fn describe(&self) -> String {
        let home = std::env::var("HOME").unwrap_or_default();
        let shown = self.root.to_string_lossy().into_owned();
        match shown.strip_prefix(&home) {
            Some(rest) if !home.is_empty() => format!("~{rest}"),
            _ => shown,
        }
    }
}

// ---- rclone ----

pub struct RcloneStore {
    pub config: PathBuf,
    /// "omabib:Omabib" for the connection Omabib made, or "<remote>:Omabib".
    pub root: String,
    pub label: String,
}

pub fn rclone_binary() -> Option<PathBuf> {
    if let Some(p) = std::env::var_os("OMABIB_RCLONE_BIN").filter(|v| !v.is_empty()) {
        return Some(PathBuf::from(p));
    }
    std::env::var_os("PATH")
        .into_iter()
        .flat_map(|p| std::env::split_paths(&p).collect::<Vec<_>>())
        .chain([PathBuf::from("/usr/bin"), PathBuf::from("/usr/local/bin")])
        .map(|d| d.join("rclone"))
        .find(|p| p.is_file())
}

/// Sorts rclone's error text into something the user can act on.
pub fn classify(stderr: &str) -> &'static str {
    let s = stderr.to_ascii_lowercase();
    if [
        "invalid_grant",
        "token expired",
        "couldn't fetch token",
        "cannot fetch token",
        "unauthorized",
        "401",
        "expired_access_token",
        "invalid_access_token",
        "empty token",
        "token has been expired",
        "didn't find section in config file",
    ]
    .iter()
    .any(|k| s.contains(k))
    {
        "auth"
    } else if [
        "no such host",
        "dial tcp",
        "i/o timeout",
        "network is unreachable",
        "connection refused",
        "connection reset",
        "tls handshake timeout",
        "temporary failure in name resolution",
    ]
    .iter()
    .any(|k| s.contains(k))
    {
        "offline"
    } else if [
        "storagequotaexceeded",
        "insufficient_space",
        "quota exceeded",
        "insufficient storage",
        "507",
    ]
    .iter()
    .any(|k| s.contains(k))
    {
        "full"
    } else {
        "error"
    }
}

/// The last meaningful line of rclone's error output, without its timestamp
/// and log level: "2026/09/18 12:46:04 NOTICE: Failed to cat …: last error was: X" → "X".
fn last_error(stderr: &str) -> String {
    let clean = |l: &str| -> String {
        let mut l = l.trim();
        let b = l.as_bytes();
        if b.len() > 20 && b[4] == b'/' && b[7] == b'/' && b[10] == b' ' {
            l = &l[20..];
        }
        for prefix in ["ERROR : ", "NOTICE: ", "Fatal error: ", "CRITICAL: "] {
            if let Some(rest) = l.strip_prefix(prefix) {
                l = rest;
            }
        }
        if let Some((_, rest)) = l.split_once("last error was: ") {
            l = rest;
        }
        l.trim().to_string()
    };
    stderr
        .lines()
        .rev()
        .map(clean)
        .find(|l| !l.is_empty())
        .unwrap_or_else(|| "rclone failed".into())
}

impl RcloneStore {
    fn remote(&self, path: &str) -> String {
        if path.is_empty() {
            self.root.clone()
        } else {
            format!("{}/{path}", self.root)
        }
    }

    /// Runs rclone with this store's config; exit code 3 or 4 (not found) is Ok(None).
    fn run(
        &self,
        args: &[&str],
        input: Option<&[u8]>,
        timeout: Duration,
    ) -> Result<Option<Vec<u8>>> {
        let binary = rclone_binary().ok_or(StoreError {
            kind: "missing",
            message: "rclone is not installed".into(),
        })?;
        let mut cmd = Command::new(binary);
        cmd.arg("--config")
            .arg(&self.config)
            .args(["--low-level-retries", "3", "--retries", "1"])
            .args(args)
            .stdin(if input.is_some() {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let mut child = cmd.spawn()?;
        if let Some(data) = input {
            let mut stdin = child.stdin.take().unwrap();
            let data = data.to_vec();
            std::thread::spawn(move || {
                let _ = stdin.write_all(&data);
            });
        }
        let mut stdout = child.stdout.take().unwrap();
        let mut stderr = child.stderr.take().unwrap();
        let out = std::thread::spawn(move || {
            let mut b = Vec::new();
            let _ = stdout.read_to_end(&mut b);
            b
        });
        let err = std::thread::spawn(move || {
            let mut s = String::new();
            let _ = stderr.read_to_string(&mut s);
            s
        });
        let deadline = Instant::now() + timeout;
        let status = loop {
            if let Some(status) = child.try_wait()? {
                break status;
            }
            if Instant::now() > deadline {
                let _ = child.kill();
                let _ = child.wait();
                bail!(StoreError {
                    kind: "offline",
                    message: format!("{} did not answer in time", self.label),
                });
            }
            std::thread::sleep(Duration::from_millis(30));
        };
        let out = out.join().unwrap_or_default();
        let err = err.join().unwrap_or_default();
        match status.code() {
            Some(0) => Ok(Some(out)),
            Some(3) | Some(4) => Ok(None),
            _ => bail!(StoreError {
                kind: classify(&err),
                message: last_error(&err),
            }),
        }
    }
}

const SHORT: Duration = Duration::from_secs(120);
const LONG: Duration = Duration::from_secs(1800);

impl Store for RcloneStore {
    fn upload_batch(&self, root: &Path, paths: &[String]) -> Result<()> {
        if paths.is_empty() {
            return Ok(());
        }
        // A single process shares its remote directory cache and connections.
        // The private staging tree contains exactly this batch's files.
        self.run(
            &[
                "copy",
                &root.to_string_lossy(),
                &self.root,
                "--transfers",
                "4",
                "--checkers",
                "4",
                "--checksum",
                "--immutable",
                "--no-update-dir-modtime",
            ],
            None,
            LONG,
        )?
        .context("Could not upload file batch")?;
        Ok(())
    }
    fn list(&self, dir: &str) -> Result<Vec<Entry>> {
        let Some(out) = self.run(
            &["lsjson", "--files-only", "--no-mimetype", &self.remote(dir)],
            None,
            SHORT,
        )?
        else {
            return Ok(vec![]);
        };
        let items: Vec<Value> = serde_json::from_slice(&out)?;
        let mut entries: Vec<Entry> = items
            .iter()
            .filter_map(|i| {
                let name = i["Name"].as_str()?.to_string();
                (!ignored(&name)).then(|| Entry {
                    name,
                    size: i["Size"].as_u64().unwrap_or(0),
                })
            })
            .collect();
        entries.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(entries)
    }

    fn read(&self, path: &str) -> Result<Vec<u8>> {
        self.run(&["cat", &self.remote(path)], None, SHORT)?
            .with_context(|| format!("{path} is not in {} yet", self.label))
    }

    fn write(&self, path: &str, data: &[u8]) -> Result<()> {
        self.run(&["rcat", &self.remote(path)], Some(data), SHORT)?
            .with_context(|| format!("Could not write {path} to {}", self.label))?;
        Ok(())
    }

    fn upload(&self, local: &Path, path: &str) -> Result<()> {
        self.run(
            &["copyto", &local.to_string_lossy(), &self.remote(path)],
            None,
            LONG,
        )?
        .with_context(|| format!("Could not upload {}", local.display()))?;
        Ok(())
    }

    fn download(&self, path: &str, local: &Path) -> Result<()> {
        self.run(
            &["copyto", &self.remote(path), &local.to_string_lossy()],
            None,
            LONG,
        )?
        .with_context(|| format!("{path} is not in {} yet", self.label))?;
        Ok(())
    }

    fn remove(&self, path: &str) -> Result<()> {
        self.run(&["deletefile", &self.remote(path)], None, SHORT)?;
        Ok(())
    }

    fn about(&self) -> Result<Value> {
        let remote = self.root.split(':').next().unwrap_or("omabib").to_string() + ":";
        let out = self
            .run(&["about", "--json", &remote], None, SHORT)?
            .unwrap_or_default();
        Ok(serde_json::from_slice(&out).unwrap_or(Value::Null))
    }

    fn describe(&self) -> String {
        format!(
            "{} → {}",
            self.label,
            split(&self.root).1.rsplit(':').next().unwrap_or("Omabib")
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rclone_batch_copies_nested_files_and_retries_safely() {
        if rclone_binary().is_none() {
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("stage");
        std::fs::create_dir_all(source.join("pdfs")).unwrap();
        std::fs::create_dir_all(source.join("clips")).unwrap();
        let paths = vec!["pdfs/a paper.pdf".to_string(), "clips/a.png".to_string()];
        for path in &paths {
            std::fs::write(source.join(path), path.as_bytes()).unwrap();
        }
        let destination = dir.path().join("remote");
        std::fs::create_dir_all(&destination).unwrap();
        std::fs::write(destination.join("unrelated"), b"keep").unwrap();
        let store = RcloneStore {
            config: dir.path().join("rclone.conf"),
            root: destination.to_string_lossy().into_owned(),
            label: "test".into(),
        };
        for _ in 0..2 {
            store.upload_batch(&source, &paths).unwrap();
        }
        for path in &paths {
            assert_eq!(
                std::fs::read(destination.join(path)).unwrap(),
                path.as_bytes()
            );
        }
        assert_eq!(
            std::fs::read(destination.join("unrelated")).unwrap(),
            b"keep"
        );
        std::fs::write(source.join(&paths[0]), b"different data").unwrap();
        assert!(store.upload_batch(&source, &paths).is_err());
        assert_eq!(
            std::fs::read(destination.join(&paths[0])).unwrap(),
            paths[0].as_bytes()
        );
    }

    #[test]
    fn folder_store_hides_unfinished_and_conflict_files() {
        let dir = tempfile::tempdir().unwrap();
        let store = FolderStore {
            root: dir.path().join("Omabib"),
        };
        assert!(store.list("devices").unwrap().is_empty());
        store.write("devices/a.json", b"{}").unwrap();
        std::fs::write(dir.path().join("Omabib/devices/.a.json.x.omabib-tmp"), b"").unwrap();
        std::fs::write(
            dir.path()
                .join("Omabib/devices/a.sync-conflict-20260918.json"),
            b"",
        )
        .unwrap();
        assert_eq!(
            store.list("devices").unwrap(),
            vec![Entry {
                name: "a.json".into(),
                size: 2
            }]
        );
        assert_eq!(store.read("devices/a.json").unwrap(), b"{}");
        assert!(store.read("devices/b.json").is_err());
        assert!(store.write("../escape", b"").is_err());
        assert!(store.about().unwrap()["free"].as_u64().unwrap() > 0);
    }

    #[test]
    fn rclone_errors_are_sorted_by_what_to_do() {
        assert_eq!(
            classify(
                "oauth2: cannot fetch token: 400 Bad Request\nResponse: {\"error\":\"invalid_grant\"}"
            ),
            "auth"
        );
        assert_eq!(
            classify("dial tcp: lookup www.googleapis.com: no such host"),
            "offline"
        );
        assert_eq!(
            classify(
                "googleapi: Error 403: The user's Drive storage quota has been exceeded., storageQuotaExceeded"
            ),
            "full"
        );
        assert_eq!(classify("something else"), "error");
        assert_eq!(
            last_error(
                "2026/09/18 12:46:04 ERROR : error listing: directory not found\n2026/09/18 12:46:04 NOTICE: Failed to lsjson with 2 errors: last error was: error in ListJSON: directory not found\n"
            ),
            "error in ListJSON: directory not found"
        );
    }
}
