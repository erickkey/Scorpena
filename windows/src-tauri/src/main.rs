#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod engine;
mod secrets;

use engine::{Job, Running};
use std::sync::Arc;
use tauri::{AppHandle, State};

#[tauri::command]
fn run_job(app: AppHandle, state: State<'_, Arc<Running>>, job: Job) {
    engine::run_job(app, state.inner().clone(), job);
}

#[tauri::command]
fn stop_job(state: State<'_, Arc<Running>>, id: String) {
    engine::stop_job(state.inner(), &id);
}

#[tauri::command]
fn default_folder() -> String {
    engine::default_downloads().to_string_lossy().into_owned()
}

#[tauri::command]
fn reveal(path: String) {
    if cfg!(windows) {
        let _ = std::process::Command::new("explorer").arg(format!("/select,{path}")).spawn();
    } else {
        let _ = std::process::Command::new("open").args(["-R", &path]).spawn();
    }
}

#[tauri::command]
fn open_window(app: AppHandle, label: String, page: String, title: String, width: f64, height: f64) {
    use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};
    if let Some(w) = app.get_webview_window(&label) {
        let _ = w.show();
        let _ = w.set_focus();
        return;
    }
    let _ = WebviewWindowBuilder::new(&app, &label, WebviewUrl::App(page.into()))
        .title(title)
        .inner_size(width, height)
        .resizable(false)
        .maximizable(false)
        .minimizable(false)
        .center()
        .build();
}

/// Title and cover picture of a link (for the cards of the queue and the history).
#[tauri::command]
async fn fetch_preview(url: String) -> Option<(String, String)> {
    let mut cmd = std::process::Command::new(engine::tool("yt-dlp"));
    cmd.args(["--no-playlist", "--skip-download", "--no-warnings", "--socket-timeout", "15",
        "--print", "%(title)s", "--print", "%(thumbnail)s"]);
    cmd.args(engine::js_runtime_args_pub());
    cmd.arg(&url);
    engine::hide_window(&mut cmd);
    let out = cmd.output().ok()?;
    if !out.status.success() { return None; }
    let text = String::from_utf8_lossy(&out.stdout).to_string();
    let mut lines = text.lines();
    let title = lines.next()?.trim().to_string();
    let thumb = lines.next().unwrap_or("").trim().to_string();
    Some((title, if thumb == "NA" { String::new() } else { thumb }))
}

#[tauri::command]
async fn probe_quality(url: String) -> Option<engine::Quality> {
    engine::probe_quality(&url)
}

#[tauri::command]
async fn fetch_playlist(list_url: String) -> Option<engine::PlaylistInfo> {
    engine::fetch_playlist(&list_url, 1000)
}

#[tauri::command]
fn make_folder(path: String) {
    let _ = std::fs::create_dir_all(path);
}

/// Feedback and error reports go straight to the developer's Telegram bot, like on the Mac.
#[tauri::command]
async fn send_telegram(text: String) -> bool {
    let url = format!("https://api.telegram.org/bot{}/sendMessage", secrets::TELEGRAM_BOT_TOKEN);
    ureq::post(&url)
        .timeout(std::time::Duration::from_secs(15))
        .send_json(serde_json::json!({ "chat_id": secrets::TELEGRAM_CHAT_ID, "text": text }))
        .is_ok()
}

#[tauri::command]
fn open_url(url: String) {
    if !(url.starts_with("https://") || url.starts_with("http://")) { return; }
    if cfg!(windows) {
        let _ = std::process::Command::new("cmd").args(["/C", "start", "", &url]).spawn();
    } else {
        let _ = std::process::Command::new("open").arg(&url).spawn();
    }
}

#[tauri::command]
async fn tools_version() -> Option<String> {
    engine::ytdlp_version()
}

#[tauri::command]
async fn update_tools(app: AppHandle) -> engine::ToolOutcome {
    engine::update_tools(&app)
}

#[tauri::command]
fn stale_partials(days: u64) -> engine::Stale {
    engine::stale_partials(days)
}

#[tauri::command]
fn remove_partials(paths: Vec<String>) {
    engine::remove_partials(paths);
}

#[tauri::command]
async fn environment_line() -> String {
    engine::environment_line()
}

#[tauri::command]
async fn check_bundled_tools() -> Vec<String> {
    engine::check_bundled_tools()
}

#[tauri::command]
fn choose_folder(app: AppHandle, start: String) -> Option<String> {
    use tauri_plugin_dialog::DialogExt;
    app.dialog().file().set_directory(start).blocking_pick_folder().map(|p| p.to_string())
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .manage(Arc::new(Running::default()))
        .setup(|app| {
            // DEV-TEST-HOOK (remove before shipping): SCORPENA_AUTOTEST="<url>[ <url>...]" adds links as if pasted.
            if let Ok(links) = std::env::var("SCORPENA_AUTOTEST") {
                use tauri::Manager;
                let win = app.get_webview_window("main").unwrap();
                std::thread::spawn(move || {
                    std::thread::sleep(std::time::Duration::from_secs(2));
                    if let Ok(pre) = std::env::var("SCORPENA_PRE") {
                        let _ = win.eval(&pre);
                        std::thread::sleep(std::time::Duration::from_millis(300));
                    }
                    let list: Vec<String> = links.split(' ').map(|l| format!("'{l}'")).collect();
                    let js = format!("[{}].forEach((l,i)=>setTimeout(()=>{{const u=document.getElementById('url');u.value=l;u.dispatchEvent(new Event('input'));document.getElementById('go').click();}},i*400));", list.join(","));
                    let _ = win.eval(&js);
                    if let Ok(extra) = std::env::var("SCORPENA_EVAL") {
                        std::thread::sleep(std::time::Duration::from_secs(4));
                        let _ = win.eval(&extra);
                    }
                });
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![run_job, stop_job, default_folder, choose_folder, reveal, open_window, fetch_preview, probe_quality, fetch_playlist, make_folder, send_telegram, open_url, tools_version, update_tools, stale_partials, remove_partials, environment_line, check_bundled_tools])
        .run(tauri::generate_context!())
        .expect("error while running Scorpena");
}
