#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod engine;
mod secrets;

use engine::{Job, Running};
use std::sync::Arc;
use tauri::{AppHandle, Emitter, State};

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
async fn cookie_preflight() -> Vec<String> {
    engine::cookie_preflight()
}

#[tauri::command]
async fn download_update(app: AppHandle) -> Result<String, String> {
    engine::download_update(&app)
}

/// Starts the installer and closes the program so it can replace the files.
#[tauri::command]
fn install_update(app: AppHandle, installer: String) -> bool {
    let ok = engine::install_update(&installer);
    if ok { app.exit(0); }
    ok
}

/// A small browser window where the person signs in to a site; the cookies are kept for yt-dlp when it is closed.
#[tauri::command]
fn open_login(app: AppHandle, url: String, title: String) {
    use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};
    if let Some(w) = app.get_webview_window("login") { let _ = w.set_focus(); return; }
    let Ok(parsed) = url.parse::<tauri::Url>() else { return };
    if parsed.scheme() != "https" && parsed.scheme() != "http" { return; }
    let _ = WebviewWindowBuilder::new(&app, "login", WebviewUrl::External(parsed))
        .title(title).inner_size(480.0, 720.0).center().build();
}

/// Opens a page in Firefox; if it is not installed, opens the official download page instead.
/// Returns true when Firefox itself was opened.
#[tauri::command]
fn open_in_firefox(url: String) -> bool {
    if !(url.starts_with("https://") || url.starts_with("http://")) { return false; }
    let mut paths: Vec<String> = vec![];
    if cfg!(windows) {
        for var in ["ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA"] {
            if let Ok(base) = std::env::var(var) { paths.push(format!("{base}\\Mozilla Firefox\\firefox.exe")); }
        }
    } else {
        paths.push("/Applications/Firefox.app/Contents/MacOS/firefox".into());
    }
    if let Some(exe) = paths.iter().find(|p| std::path::Path::new(p).exists()) {
        if std::process::Command::new(exe).arg(&url).spawn().is_ok() { return true; }
    }
    open_url("https://www.mozilla.org/firefox/new/".to_string());
    false
}

#[tauri::command]
fn forget_logins(app: AppHandle) {
    use tauri::Manager;
    engine::forget_logins();
    if let Some(w) = app.get_webview_window("main") { let _ = w.clear_all_browsing_data(); }
}

#[tauri::command]
fn take_crash_report() -> Option<String> { engine::take_crash_report() }

#[tauri::command]
fn has_logins() -> bool { engine::login_file().exists() }

#[tauri::command]
fn choose_folder(app: AppHandle, start: String) -> Option<String> {
    use tauri_plugin_dialog::DialogExt;
    app.dialog().file().set_directory(start).blocking_pick_folder().map(|p| p.to_string())
}

fn main() {
    engine::install_crash_hook();
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .manage(Arc::new(Running::default()))
        .on_window_event(|window, event| {
            use tauri::Manager;
            // Closing the main window closes the whole program, like on the Mac.
            if window.label() == "login" {
                if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                    // the cookies are read on another thread (on Windows asking from the main one would hang)
                    api.prevent_close();
                    let app = window.app_handle().clone();
                    std::thread::spawn(move || {
                        if let Some(w) = app.get_webview_window("login") {
                            if let Ok(cookies) = w.cookies() { engine::save_login_cookies(&cookies); }
                            let _ = w.destroy();
                        }
                        let _ = app.emit("login-closed", ());
                    });
                }
            }
            if window.label() == "main" {
                if let tauri::WindowEvent::Destroyed = event {
                    if let Some(state) = window.app_handle().try_state::<Arc<Running>>() { engine::stop_all(state.inner()); }
                    window.app_handle().exit(0);
                }
            }
        })
        .setup(|app| {
            // DEV-TEST-HOOK (debug builds only, not in the shipped release): SCORPENA_AUTOTEST="<url>[ <url>...]" adds links as if pasted.
            #[cfg(debug_assertions)]
            {
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
                    if let Ok(secs) = std::env::var("SCORPENA_CLOSELOGIN") {
                        std::thread::sleep(std::time::Duration::from_secs(secs.parse().unwrap_or(30)));
                        if let Some(w) = win.app_handle().get_webview_window("login") { let _ = w.close(); }
                    }
                });
            }
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![run_job, stop_job, default_folder, choose_folder, reveal, open_window, fetch_preview, probe_quality, fetch_playlist, make_folder, send_telegram, open_url, tools_version, update_tools, stale_partials, remove_partials, environment_line, check_bundled_tools, cookie_preflight, open_login, open_in_firefox, forget_logins, has_logins, take_crash_report, download_update, install_update])
        .run(tauri::generate_context!())
        .expect("error while running Scorpena");
}
