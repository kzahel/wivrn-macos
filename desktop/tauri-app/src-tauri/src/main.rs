use chrono::{DateTime, Local};
use serde::{Deserialize, Serialize};
use std::{
    collections::VecDeque,
    io::{BufRead, BufReader, Read},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{Arc, Mutex},
};
use tauri::{Manager, RunEvent, State};

const TARGET_TRIPLE: &str = env!("TARGET_TRIPLE");
const LOG_LIMIT: usize = 400;

#[derive(Default)]
struct AppState {
    child: Mutex<Option<ManagedChild>>,
    logs: Arc<Mutex<VecDeque<String>>>,
    last_exit: Mutex<Option<String>>,
}

struct ManagedChild {
    child: Child,
    pid: u32,
    started_at: DateTime<Local>,
    sidecar_path: PathBuf,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StartOptions {
    enable_audio: bool,
    no_encrypt: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct HostStatus {
    running: bool,
    pid: Option<u32>,
    config_path: String,
    sidecar_path: Option<String>,
    started_at: Option<String>,
    last_exit: Option<String>,
    logs: Vec<String>,
}

#[tauri::command]
fn get_status(app: tauri::AppHandle, state: State<'_, AppState>) -> Result<HostStatus, String> {
    reap_exited_child(&state)?;
    let config_path = ensure_default_config(&app)?;
    let sidecar = resolve_sidecar(&app, "binaries/wivrn-server-headless").ok();

    let child = state.child.lock().map_err(|e| e.to_string())?;
    let logs = state.logs.lock().map_err(|e| e.to_string())?;
    let last_exit = state.last_exit.lock().map_err(|e| e.to_string())?;

    Ok(HostStatus {
        running: child.is_some(),
        pid: child.as_ref().map(|managed| managed.pid),
        config_path: config_path.display().to_string(),
        sidecar_path: child
            .as_ref()
            .map(|managed| managed.sidecar_path.display().to_string())
            .or_else(|| sidecar.map(|path| path.display().to_string())),
        started_at: child
            .as_ref()
            .map(|managed| managed.started_at.format("%Y-%m-%d %H:%M:%S").to_string()),
        last_exit: last_exit.clone(),
        logs: logs.iter().cloned().collect(),
    })
}

#[tauri::command]
fn start_server(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
    options: StartOptions,
) -> Result<(), String> {
    reap_exited_child(&state)?;

    {
        let child = state.child.lock().map_err(|e| e.to_string())?;
        if child.is_some() {
            return Ok(());
        }
    }

    let config_path = ensure_default_config(&app)?;
    let sidecar_path = resolve_sidecar(&app, "binaries/wivrn-server-headless")?;

    let mut command = Command::new(&sidecar_path);
    command.arg("--config").arg(&config_path);
    if options.no_encrypt {
        command.arg("--no-encrypt");
    }
    if options.enable_audio {
        command.arg("--enable-audio");
    }
    command.stdout(Stdio::piped()).stderr(Stdio::piped());

    append_log(
        &state.logs,
        format!(
            "Starting {} with config {}",
            sidecar_path.display(),
            config_path.display()
        ),
    )?;

    let mut child = command
        .spawn()
        .map_err(|e| format!("Failed to start headless server: {e}"))?;
    let pid = child.id();

    if let Some(stdout) = child.stdout.take() {
        spawn_log_reader(stdout, "stdout", state.logs.clone());
    }
    if let Some(stderr) = child.stderr.take() {
        spawn_log_reader(stderr, "stderr", state.logs.clone());
    }

    let managed = ManagedChild {
        child,
        pid,
        started_at: Local::now(),
        sidecar_path,
    };

    let mut slot = state.child.lock().map_err(|e| e.to_string())?;
    *slot = Some(managed);
    Ok(())
}

#[tauri::command]
fn stop_server(state: State<'_, AppState>) -> Result<(), String> {
    stop_child(&state)
}

#[tauri::command]
fn restart_server(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
    options: StartOptions,
) -> Result<(), String> {
    stop_child(&state)?;
    start_server(app, state, options)
}

fn main() {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .manage(AppState::default())
        .invoke_handler(tauri::generate_handler![
            get_status,
            start_server,
            stop_server,
            restart_server
        ])
        .build(tauri::generate_context!())
        .expect("failed to build Tauri app");

    app.run(|app_handle, event| {
        if let RunEvent::ExitRequested { .. } = event {
            let state = app_handle.state::<AppState>();
            let _ = stop_child(&state);
        }
    });
}

fn stop_child(state: &State<'_, AppState>) -> Result<(), String> {
    let mut child = state.child.lock().map_err(|e| e.to_string())?;
    if let Some(mut managed) = child.take() {
        append_log(
            &state.logs,
            format!("Stopping server process {}", managed.pid),
        )?;
        let _ = managed.child.kill();
        let status = managed
            .child
            .wait()
            .map_err(|e| format!("Failed waiting for server exit: {e}"))?;
        let message = format!("Exited with {status}");
        *state.last_exit.lock().map_err(|e| e.to_string())? = Some(message.clone());
        append_log(&state.logs, message)?;
    }
    Ok(())
}

fn reap_exited_child(state: &State<'_, AppState>) -> Result<(), String> {
    let mut child = state.child.lock().map_err(|e| e.to_string())?;
    if let Some(managed) = child.as_mut() {
        if let Some(status) = managed
            .child
            .try_wait()
            .map_err(|e| format!("Failed checking server status: {e}"))?
        {
            let message = format!("Exited with {status}");
            *state.last_exit.lock().map_err(|e| e.to_string())? = Some(message.clone());
            append_log(&state.logs, message)?;
            *child = None;
        }
    }
    Ok(())
}

fn append_log(logs: &Arc<Mutex<VecDeque<String>>>, line: impl Into<String>) -> Result<(), String> {
    let timestamp = Local::now().format("%H:%M:%S");
    let mut logs = logs.lock().map_err(|e| e.to_string())?;
    logs.push_back(format!("[{timestamp}] {}", line.into()));
    while logs.len() > LOG_LIMIT {
        logs.pop_front();
    }
    Ok(())
}

fn spawn_log_reader<R>(reader: R, name: &'static str, logs: Arc<Mutex<VecDeque<String>>>)
where
    R: Read + Send + 'static,
{
    std::thread::spawn(move || {
        let reader = BufReader::new(reader);
        for line in reader.lines() {
            match line {
                Ok(line) => {
                    let _ = append_log(&logs, format!("{name}: {line}"));
                }
                Err(error) => {
                    let _ = append_log(&logs, format!("{name}: log read failed: {error}"));
                    break;
                }
            }
        }
    });
}

fn ensure_default_config(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    let config_dir = app.path().app_config_dir().map_err(|e| e.to_string())?;
    std::fs::create_dir_all(&config_dir).map_err(|e| e.to_string())?;
    let config_path = config_dir.join("server.json");
    if !config_path.exists() {
        let default_config = serde_json::json!({
            "port": 9757,
            "tcp-only": false
        });
        let json = serde_json::to_string_pretty(&default_config).map_err(|e| e.to_string())?;
        std::fs::write(&config_path, format!("{json}\n")).map_err(|e| e.to_string())?;
    }
    Ok(config_path)
}

fn resolve_sidecar(app: &tauri::AppHandle, name: &str) -> Result<PathBuf, String> {
    let resource_dir = app.path().resource_dir().map_err(|e| e.to_string())?;
    let exe_dir = std::env::current_exe()
        .ok()
        .and_then(|path| path.parent().map(Path::to_path_buf));

    let basename = Path::new(name)
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or(name);

    let mut candidates = Vec::new();
    for dir in [Some(&resource_dir), exe_dir.as_ref()]
        .into_iter()
        .flatten()
    {
        candidates.push(dir.join(format!("{name}-{TARGET_TRIPLE}")));
        candidates.push(dir.join(name));
        candidates.push(dir.join(format!("{basename}-{TARGET_TRIPLE}")));
        candidates.push(dir.join(basename));
    }

    for candidate in &candidates {
        if candidate.exists() {
            return Ok(candidate.clone());
        }
    }

    Err(format!(
        "Sidecar not found. Searched:\n{}",
        candidates
            .iter()
            .map(|candidate| format!("  {}", candidate.display()))
            .collect::<Vec<_>>()
            .join("\n")
    ))
}
