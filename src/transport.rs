use crate::db::Library;
use anyhow::{Result, ensure};
use serde_json::{Value, json};
use std::{
    io::{BufRead, BufReader, Write},
    os::unix::{
        fs::PermissionsExt,
        net::{UnixListener, UnixStream},
    },
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};
pub fn data_path() -> PathBuf {
    std::env::var_os("OMABIB_DB")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            std::env::var_os("XDG_DATA_HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| {
                    PathBuf::from(std::env::var_os("HOME").unwrap()).join(".local/share")
                })
                .join("omabib/library.db")
        })
}
pub fn socket_path() -> PathBuf {
    std::env::var_os("OMABIB_SOCKET")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            std::env::var_os("XDG_RUNTIME_DIR")
                .map(PathBuf::from)
                .unwrap_or_else(|| {
                    PathBuf::from(format!("/tmp/omabib-{}", unsafe { libc::getuid() }))
                })
                .join("omabib/socket")
        })
}
pub fn request(method: &str, params: &Value) -> Result<Value> {
    request_with_timeout(method, params, Duration::from_secs(120))
}
/// For calls that wait on the reader, such as a chat approval.
pub fn request_with_timeout(method: &str, params: &Value, timeout: Duration) -> Result<Value> {
    let mut stream = UnixStream::connect(socket_path()).map_err(|e| {
        // A sandbox (such as an agent's read-only one) refuses the connection outright.
        if e.kind() == std::io::ErrorKind::PermissionDenied {
            anyhow::anyhow!(
                "Omabib's socket is blocked here ({e}); this is likely a sandbox. Use Omabib's MCP tools instead."
            )
        } else {
            anyhow::anyhow!("Omabib service is unavailable. Run: systemctl --user start omabib: {e}")
        }
    })?;
    stream.set_read_timeout(Some(timeout))?;
    writeln!(
        stream,
        "{}",
        json!({"v":1,"id":1,"method":method,"params":params})
    )?;
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line)?;
    let response: Value = serde_json::from_str(&line)?;
    if let Some(e) = response.get("error") {
        anyhow::bail!("{}", e["message"].as_str().unwrap_or("Request failed"));
    }
    Ok(response["result"].clone())
}
pub fn serve(db: PathBuf) -> Result<()> {
    unsafe {
        libc::umask(0o077);
    }
    let path = socket_path();
    let parent = path.parent().unwrap();
    std::fs::create_dir_all(parent)?;
    std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700))?;
    // Keep an advisory lock for the lifetime of the service before touching its socket.
    let lock = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(parent.join("server.lock"))?;
    use std::os::fd::AsRawFd;
    ensure!(
        unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0,
        "Another Omabib service is running"
    );
    let lib = Arc::new(Library::open_with_vocabulary(db, false)?);
    if path.exists() {
        std::fs::remove_file(&path)?;
    }
    let listener = UnixListener::bind(&path)?;
    let loader = lib.clone();
    std::thread::spawn(move || {
        if let Err(e) = loader.load_vocabulary() {
            eprintln!("Vocabulary: {e:#}");
        }
    });
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    let clients = Arc::new(AtomicUsize::new(0));
    eprintln!(
        "Omabib {} listening on {}",
        env!("CARGO_PKG_VERSION"),
        path.display()
    );
    for stream in listener.incoming() {
        let stream = stream?;
        if clients.load(Ordering::Relaxed) >= 64 {
            continue;
        }
        let lib = lib.clone();
        let clients = clients.clone();
        clients.fetch_add(1, Ordering::Relaxed);
        std::thread::spawn(move || {
            if let Err(e) = handle(stream, lib) {
                eprintln!("client: {e:#}");
            }
            clients.fetch_sub(1, Ordering::Relaxed);
        });
    }
    Ok(())
}
fn handle(stream: UnixStream, lib: Arc<Library>) -> Result<()> {
    let writer = Arc::new(Mutex::new(stream.try_clone()?));
    let mut subscription = None;
    let result = serve_connection(stream, &lib, &writer, &mut subscription);
    if let Some(token) = subscription {
        lib.chats.unsubscribe(token);
    }
    result
}
fn serve_connection(
    stream: UnixStream,
    lib: &Arc<Library>,
    writer: &Arc<Mutex<UnixStream>>,
    subscription: &mut Option<u64>,
) -> Result<()> {
    let mut reader = BufReader::new(stream);
    let generation = Arc::new(AtomicUsize::new(0));
    let in_flight = Arc::new(AtomicUsize::new(0));
    loop {
        let mut buf = Vec::new();
        use std::io::Read;
        let n = reader
            .by_ref()
            .take(70 * 1024 * 1024)
            .read_until(b'\n', &mut buf)?;
        if n == 0 {
            break;
        }
        ensure!(buf.last() == Some(&b'\n'), "Request exceeds maximum size");
        let req: Value = match serde_json::from_slice(&buf) {
            Ok(v) => v,
            Err(e) => {
                writeln!(
                    writer.lock().unwrap(),
                    "{}",
                    json!({"v":1,"id":null,"error":{"message":e.to_string()}})
                )?;
                continue;
            }
        };
        if req["method"] == "cancel" {
            generation.fetch_add(1, Ordering::Relaxed);
            continue;
        }
        // Chat events are pushed on this connection as lines with an "event" key.
        if req["method"] == "chat_subscribe" {
            if subscription.is_none() {
                let events = writer.clone();
                *subscription = Some(lib.chats.subscribe(Box::new(move |line| {
                    writeln!(events.lock().unwrap(), "{line}").is_ok()
                })));
            }
            writeln!(writer.lock().unwrap(), "{}", json!({"v":1,"id":req["id"],"result":{"subscribed":true}}))?;
            continue;
        }
        if in_flight.load(Ordering::Relaxed) >= 8 {
            writeln!(
                writer.lock().unwrap(),
                "{}",
                json!({"v":1,"id":req["id"],"error":{"message":"Too many in-flight requests"}})
            )?;
            continue;
        }
        let is_search = req["method"] == "search";
        let ticket = if is_search {
            generation.fetch_add(1, Ordering::Relaxed) + 1
        } else {
            0
        };
        let gen2 = generation.clone();
        let writer = writer.clone();
        let lib = lib.clone();
        let flights = in_flight.clone();
        flights.fetch_add(1, Ordering::Relaxed);
        std::thread::spawn(move || {
            let result = if req["v"] != 1 {
                Err(anyhow::anyhow!("Unsupported protocol version"))
            } else if is_search && gen2.load(Ordering::Relaxed) != ticket {
                Err(anyhow::anyhow!("Search superseded"))
            } else if is_search {
                crate::search::search_cancellable(
                    &lib,
                    &req["params"],
                    Some((gen2.clone(), ticket)),
                )
            } else {
                lib.call(req["method"].as_str().unwrap_or(""), &req["params"])
            };
            if !is_search || gen2.load(Ordering::Relaxed) == ticket {
                let response = match result {
                    Ok(v) => json!({"v":1,"id":req["id"],"result":v}),
                    Err(e) => json!({"v":1,"id":req["id"],"error":{"message":format!("{e:#}")}}),
                };
                let _ = writeln!(writer.lock().unwrap(), "{response}");
            }
            flights.fetch_sub(1, Ordering::Relaxed);
        });
    }
    Ok(())
}
