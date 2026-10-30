//! The download engine: runs yt-dlp the way the Mac version does (same options, same file names,
//! same «try without cookies first, then the browsers» order) and reports back to the page.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter};

#[derive(Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Job {
    pub id: String,
    pub url: String,
    pub dest: String,
    pub max_height: Option<u32>,
    pub audio: bool,
    pub strip_audio: bool,
    pub video_format: String,
    pub audio_format: String,
    /// Speed limit in kilobits per second, 0 = none.
    pub limit_kbit: u32,
    /// Browsers that were signed in at the first launch, best first.
    #[serde(default)]
    pub cookie_order: Vec<String>,
    /// The browser whose cookies worked last time ("" = none).
    #[serde(default)]
    pub last_cookie: String,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct Progress {
    id: String,
    percent: f64,
    speed: String,
    eta: String,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct Line {
    id: String,
    line: String,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct Done {
    id: String,
    ok: bool,
    /// "" | "h264" | "h264-failed" | "no-ffmpeg"
    note: String,
    /// The browser whose cookies were used ("" = none).
    cookie: String,
    /// "" | "auth" | "network" | "unavailable" | "unsupported" | "format" | "forbidden" | "disk" | "other"
    reason: String,
    file: Option<String>,
    name: Option<String>,
    log_tail: String,
}

#[derive(Default)]
pub struct Running {
    children: Mutex<HashMap<String, Arc<Mutex<Option<Child>>>>>,
    stopped: Mutex<std::collections::HashSet<String>>,
}

pub fn tools_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("SCORPENA_TOOLS") {
        return PathBuf::from(dir);
    }
    let exe = std::env::current_exe().unwrap_or_default();
    exe.parent().map(|p| p.join("bin")).unwrap_or_default()
}

pub fn tool(name: &str) -> PathBuf {
    let file = if cfg!(windows) { format!("{name}.exe") } else { name.to_string() };
    tools_dir().join(file)
}

pub fn data_dir() -> PathBuf {
    let base = if cfg!(windows) {
        std::env::var("APPDATA").unwrap_or_default()
    } else {
        format!("{}/Library/Application Support", std::env::var("HOME").unwrap_or_default())
    };
    let dir = std::env::var("SCORPENA_DATA").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from(base).join("Scorpena"));
    let _ = std::fs::create_dir_all(&dir);
    dir
}

pub fn default_downloads() -> PathBuf {
    if let Ok(dir) = std::env::var("SCORPENA_DEV_DIR") {
        return PathBuf::from(dir);
    }
    let home = std::env::var(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).unwrap_or_default();
    PathBuf::from(home).join("Downloads")
}

/// Browsers whose cookies can be tried (the ones that are installed).
pub fn installed_browsers() -> Vec<String> {
    let mut out = vec![];
    if cfg!(windows) {
        let local = std::env::var("LOCALAPPDATA").unwrap_or_default();
        let roaming = std::env::var("APPDATA").unwrap_or_default();
        let checks = [
            ("chrome", format!("{local}\\Google\\Chrome\\User Data")),
            ("edge", format!("{local}\\Microsoft\\Edge\\User Data")),
            ("firefox", format!("{roaming}\\Mozilla\\Firefox\\Profiles")),
            ("brave", format!("{local}\\BraveSoftware\\Brave-Browser\\User Data")),
            ("opera", format!("{roaming}\\Opera Software\\Opera Stable")),
            ("vivaldi", format!("{local}\\Vivaldi\\User Data")),
            ("yandex", format!("{local}\\Yandex\\YandexBrowser\\User Data")),
        ];
        for (name, path) in checks {
            if Path::new(&path).exists() {
                out.push(name.to_string());
            }
        }
    } else {
        let home = std::env::var("HOME").unwrap_or_default();
        out.push("safari".to_string());
        for (name, rel) in [("chrome", "Library/Application Support/Google/Chrome"), ("firefox", "Library/Application Support/Firefox/Profiles")] {
            if Path::new(&format!("{home}/{rel}")).exists() {
                out.push(name.to_string());
            }
        }
    }
    out
}

/// Cookies saved from the sign-in window. On Windows the file is encrypted with the Windows account of the
/// person (DPAPI), so it can only be read by that person on that computer.
pub fn login_file() -> PathBuf { data_dir().join(if cfg!(windows) { "login-cookies.dat" } else { "login-cookies.txt" }) }

#[cfg(windows)]
mod dpapi {
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{CryptProtectData, CryptUnprotectData, CRYPT_INTEGER_BLOB};

    fn blob(data: &[u8]) -> CRYPT_INTEGER_BLOB { CRYPT_INTEGER_BLOB { cbData: data.len() as u32, pbData: data.as_ptr() as *mut u8 } }
    fn take(out: CRYPT_INTEGER_BLOB) -> Vec<u8> {
        let v = unsafe { std::slice::from_raw_parts(out.pbData, out.cbData as usize).to_vec() };
        unsafe { LocalFree(out.pbData as _); }
        v
    }
    pub fn protect(data: &[u8]) -> Option<Vec<u8>> {
        let input = blob(data);
        let mut out = CRYPT_INTEGER_BLOB { cbData: 0, pbData: std::ptr::null_mut() };
        let ok = unsafe { CryptProtectData(&input, std::ptr::null(), std::ptr::null(), std::ptr::null(), std::ptr::null(), 0, &mut out) };
        if ok == 0 { None } else { Some(take(out)) }
    }
    pub fn unprotect(data: &[u8]) -> Option<Vec<u8>> {
        let input = blob(data);
        let mut out = CRYPT_INTEGER_BLOB { cbData: 0, pbData: std::ptr::null_mut() };
        let ok = unsafe { CryptUnprotectData(&input, std::ptr::null_mut(), std::ptr::null(), std::ptr::null(), std::ptr::null(), 0, &mut out) };
        if ok == 0 { None } else { Some(take(out)) }
    }
}

fn read_login() -> Option<String> {
    let raw = std::fs::read(login_file()).ok()?;
    #[cfg(windows)]
    let raw = dpapi::unprotect(&raw)?;   // not readable (other account / damaged): the person just signs in again
    String::from_utf8(raw).ok()
}

static LOGIN_LOCK: Mutex<()> = Mutex::new(());

fn write_login(text: &str) {
    let _guard = LOGIN_LOCK.lock();
    #[cfg(windows)]
    let Some(bytes) = dpapi::protect(text.as_bytes()) else { return };
    #[cfg(not(windows))]
    let bytes = text.as_bytes().to_vec();
    let _ = std::fs::write(login_file(), bytes);
}

/// Sources to try after «no cookies»: the sign-in window first, then the installed browsers.
pub fn cookie_sources() -> Vec<String> {
    let mut out = vec![];
    if login_file().exists() { out.push("login".to_string()); }
    out.extend(installed_browsers());
    out
}

/// yt-dlp arguments for one of those sources. For the sign-in window the cookies are decrypted into a
/// temporary file that exists only while this value lives; afterwards what yt-dlp refreshed is encrypted back.
pub struct CookieArgs { pub args: Vec<String>, temp: Option<PathBuf> }

impl Drop for CookieArgs {
    fn drop(&mut self) {
        if let Some(t) = &self.temp {
            if let Ok(text) = std::fs::read_to_string(t) { if text.lines().filter(|l| !l.starts_with('#') && l.contains('\t')).count() > 0 { write_login(&text); } }
            let _ = std::fs::remove_file(t);
        }
    }
}

pub fn cookie_args(source: &str) -> CookieArgs {
    if source == "login" {
        static COUNTER: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
        let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let temp = std::env::temp_dir().join(format!("scorpena-login-{}-{n}.txt", std::process::id()));
        if let Some(text) = read_login() {
            if std::fs::write(&temp, text).is_ok() {
                return CookieArgs { args: vec!["--cookies".into(), temp.to_string_lossy().into_owned()], temp: Some(temp) };
            }
        }
        return CookieArgs { args: vec![], temp: None };
    }
    CookieArgs { args: vec!["--cookies-from-browser".into(), source.to_string()], temp: None }
}

/// Merges cookies taken from the sign-in window into the saved file (same domain+path+name is replaced).
pub fn save_login_cookies(cookies: &[tauri::webview::cookie::Cookie<'static>]) {
    let mut lines: Vec<(String, String)> = vec![];
    if let Some(text) = read_login() {
        for l in text.lines() {
            let f: Vec<&str> = l.split('\t').collect();
            if f.len() >= 7 { lines.push((format!("{}\t{}\t{}", f[0].trim_start_matches("#HttpOnly_"), f[2], f[5]), l.to_string())); }
        }
    }
    let soon = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0) + 30 * 86400;
    for c in cookies {
        let Some(domain) = c.domain() else { continue };
        if c.value().is_empty() { continue; }
        let path_s = c.path().unwrap_or("/");
        let expiry = c.expires_datetime().map(|t| t.unix_timestamp()).unwrap_or(soon);
        let line = format!("{}{}\t{}\t{}\t{}\t{}\t{}\t{}",
            if c.http_only().unwrap_or(false) { "#HttpOnly_" } else { "" }, domain,
            if domain.starts_with('.') { "TRUE" } else { "FALSE" }, path_s,
            if c.secure().unwrap_or(false) { "TRUE" } else { "FALSE" }, expiry, c.name(), c.value());
        let key = format!("{}\t{}\t{}", domain, path_s, c.name());
        lines.retain(|(k, _)| *k != key);
        lines.push((key, line));
    }
    let body: Vec<String> = lines.into_iter().map(|(_, l)| l).collect();
    write_login(&format!("# Netscape HTTP Cookie File\n{}\n", body.join("\n")));
}

pub fn forget_logins() { let _ = std::fs::remove_file(login_file()); }

pub fn js_runtime_args_pub() -> Vec<String> { js_runtime_args() }
pub fn hide_window(cmd: &mut Command) { no_window(cmd) }

fn js_runtime_args() -> Vec<String> {
    let deno = tool("deno");
    if deno.exists() {
        vec!["--js-runtimes".into(), format!("deno:{}", deno.display())]
    } else {
        vec![]
    }
}

pub fn build_args(job: &Job, staging: &Path, temp: &Path) -> Vec<String> {
    let s = |x: &str| x.to_string();
    let mut a: Vec<String> = vec![
        s("--newline"), s("--no-color"), s("--no-playlist"),
        s("--ffmpeg-location"), tools_dir().to_string_lossy().into_owned(),
        s("--concurrent-fragments"), s(if job.limit_kbit > 0 { "1" } else { "5" }),
        s("--retries"), s("60"), s("--fragment-retries"), s("60"),
        s("--retry-sleep"), s("http:exp=1:20"), s("--retry-sleep"), s("fragment:exp=1:20"),
        s("--socket-timeout"), s("20"),
        s("--progress-template"),
        s("download:SCORPENA|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s"),
    ];
    if job.limit_kbit > 0 {
        a.extend([s("--limit-rate"), (job.limit_kbit * 125).to_string()]);
    }
    a.extend(js_runtime_args());
    let out = |template: &str| -> Vec<String> {
        vec![s("-P"), format!("home:{}", staging.display()), s("-P"), format!("temp:{}", temp.display()), s("-o"), s(template)]
    };
    if job.audio {
        let tags = ["--embed-metadata", "--embed-thumbnail", "--convert-thumbnails", "jpg"];
        match job.audio_format.as_str() {
            "wav" => a.extend([s("-f"), s("ba/b"), s("-x"), s("--audio-format"), s("wav")]),
            "m4a" => {
                a.extend([s("-f"), s("ba[ext=m4a]/ba/b"), s("-x"), s("--audio-format"), s("m4a")]);
                a.extend(tags.map(s));
            }
            _ => {
                a.extend([s("-f"), s("ba/b"), s("-x"), s("--audio-format"), s("mp3"), s("--audio-quality"), s("320K")]);
                a.extend(tags.map(s));
            }
        }
        a.extend(out("%(title)s (Scorpena video downloader).%(ext)s"));
    } else {
        let hf = job.max_height.map(|h| format!("[height<={h}]")).unwrap_or_default();
        let has_h = job.max_height.is_some();
        let (spec, sort) = match job.video_format.as_str() {
            "webm" => (
                if job.strip_audio { format!("bv*[ext=webm]{hf}/bv*{hf}/b{hf}") }
                else { format!("bv*[ext=webm]{hf}+ba[ext=webm]/bv*{hf}+ba/b{hf}/bv*+ba/b") },
                s("res,vcodec:vp9,br"),
            ),
            "mkv" => (
                if job.strip_audio { if has_h { format!("bv*{hf}/b{hf}") } else { s("bv*/b") } }
                else if has_h { format!("bv*{hf}+ba/b{hf}/bv*+ba/b") } else { s("bv*+ba/b") },
                s("res,br"),
            ),
            _ if job.strip_audio => (
                if has_h { format!("bv*{hf}/b{hf}") } else { s("bv*[vcodec^=avc1]/b[vcodec^=avc1]/bv*") },
                s(if has_h { "res,vcodec:h264,ext:mp4,br" } else { "vcodec:h264,res,ext:mp4,br" }),
            ),
            _ if has_h => (format!("bv*{hf}+ba/b{hf}/bv*+ba/b"), s("res,vcodec:h264,ext:mp4,br")),
            _ => (s("bv*[vcodec^=avc1]+ba/b[vcodec^=avc1]/bv*+ba/b"), s("vcodec:h264,res,ext:mp4,br")),
        };
        a.extend([s("-f"), spec, s("-S"), sort]);
        let f = job.video_format.as_str();
        let (merge, mode) = match f {
            "mov" => ("mov", "--remux-video"),
            "mkv" => ("mkv", "--remux-video"),
            "webm" => ("webm", "--recode-video"),
            _ => ("mp4", "--remux-video"),
        };
        a.extend([s("--merge-output-format"), s(merge), s(mode), s(merge)]);
        a.extend(out("%(width&{}x|)s%(height&{} |)s%(title)s (Scorpena video downloader).%(ext)s"));
    }
    a
}

fn is_auth_wall(l: &str) -> bool {
    (l.contains("confirm you") && l.contains("bot"))
        || l.contains("login_required")
        || l.contains("sign in to confirm your age")
        || l.contains("this video may be inappropriate")
        || l.contains("members-only") || l.contains("join this channel")
        || l.contains("account cookies are no longer valid")
        || l.contains("access denied")
        || l.contains("only available for authorized")
        || l.contains("available only for") || l.contains("only for friends")
        || l.contains("please log in") || l.contains("log in to")
        || l.contains("removed from public access")
        || l.contains("only works when logged")
        || l.contains("provide account credentials")
        || l.contains("unable to fetch new oauth tokens")
}

fn failure_reason(log: &str) -> &'static str {
    let l = log.to_lowercase();
    if l.contains("video unavailable") || l.contains("this video is not available") { return "unavailable"; }
    if l.contains("is not a valid url") || l.contains("unsupported url") { return "unsupported"; }
    if l.contains("requested format is not available") { return "format"; }
    if l.contains("unable to download") && (l.contains("http error 403") || l.contains("403 forbidden")) { return "forbidden"; }
    if l.contains("unable to resolve host") || l.contains("could not resolve host") || l.contains("could not contact dns")
        || l.contains("network is unreachable") || l.contains("connection refused")
        || l.contains("nodename nor servname") || l.contains("internet connection appears to be offline") { return "network"; }
    if l.contains("no space left") || l.contains("disk full") { return "disk"; }
    "other"
}

#[cfg(windows)]
fn no_window(cmd: &mut Command) {
    use std::os::windows::process::CommandExt;
    cmd.creation_flags(0x0800_0000);
}
#[cfg(not(windows))]
fn no_window(_: &mut Command) {}

pub fn kill_tree(child: &mut Child) {
    let pid = child.id();
    if cfg!(windows) {
        let mut c = Command::new("taskkill");
        c.args(["/PID", &pid.to_string(), "/T", "/F"]);
        no_window(&mut c);
        let _ = c.output();
    } else {
        let _ = Command::new("pkill").args(["-P", &pid.to_string()]).output();
    }
    let _ = child.kill();
}

/// Moves a finished file out of the hidden staging folder into the chosen folder, never overwriting.
fn deliver(staging: &Path, dest: &Path) -> Option<PathBuf> {
    let _ = std::fs::create_dir_all(dest);
    let mut newest: Option<(std::time::SystemTime, PathBuf)> = None;
    for entry in std::fs::read_dir(staging).ok()?.flatten() {
        let p = entry.path();
        let name = p.file_name()?.to_string_lossy().to_string();
        if name.starts_with('.') || name.ends_with(".part") || name.ends_with(".ytdl") { continue; }
        let t = entry.metadata().ok()?.modified().ok()?;
        if newest.as_ref().map_or(true, |(n, _)| t > *n) { newest = Some((t, p)); }
    }
    let (_, file) = newest?;
    let stem = file.file_stem()?.to_string_lossy().to_string();
    let ext = file.extension().map(|e| e.to_string_lossy().to_string()).unwrap_or_default();
    let mut target = dest.join(file.file_name()?);
    let mut n = 2;
    while target.exists() {
        target = dest.join(if ext.is_empty() { format!("{stem} ({n})") } else { format!("{stem} ({n}).{ext}") });
        n += 1;
    }
    if std::fs::rename(&file, &target).is_err() {
        std::fs::copy(&file, &target).ok()?;
        let _ = std::fs::remove_file(&file);
    }
    let _ = std::fs::remove_dir_all(staging);
    Some(target)
}

pub fn run_job(app: AppHandle, state: Arc<Running>, job: Job) {
    std::thread::spawn(move || {
        let partial = data_dir().join("Partial");
        let temp = partial.join("temp");
        let staging = partial.join(format!("ready-{}", job.id));
        let _ = std::fs::create_dir_all(&temp);
        let _ = std::fs::create_dir_all(&staging);
        state.stopped.lock().unwrap().remove(&job.id);

        // No cookies first; then the installed browsers.
        let mut browsers = cookie_sources();
        browsers.sort_by_key(|b| job.cookie_order.iter().position(|x| x == b).unwrap_or(usize::MAX));
        if let Some(i) = browsers.iter().position(|b| *b == job.last_cookie) { let good = browsers.remove(i); browsers.insert(0, good); }
        let mut sources: Vec<Option<String>> = vec![None];
        sources.extend(browsers.into_iter().map(Some));
        let mut used_cookie = String::new();
        let mut log_all = String::new();
        let mut reason = String::from("other");
        let mut ok = false;

        let mut index = 0;
        let mut saw_auth = false;
        while index < sources.len() {
            let source = sources[index].clone();
            index += 1;
            let mut args = build_args(&job, &staging, &temp);
            let mut _cookies = None;   // keeps the decrypted sign-in cookies alive until this attempt is over
            if let Some(browser) = &source {
                let c = cookie_args(browser);
                args.extend(c.args.clone());
                _cookies = Some(c);
                let _ = app.emit("job-attempt", Line { id: job.id.clone(), line: browser.clone() });
            }
            args.push(job.url.clone());

            let mut cmd = Command::new(tool("yt-dlp"));
            cmd.args(&args).stdout(Stdio::piped()).stderr(Stdio::piped());
            let path = format!("{}{}{}", tools_dir().display(), if cfg!(windows) { ";" } else { ":" }, std::env::var("PATH").unwrap_or_default());
            cmd.env("PATH", path);
            no_window(&mut cmd);
            let mut child = match cmd.spawn() {
                Ok(c) => c,
                Err(e) => {
                    let _ = app.emit("job-done", Done { id: job.id.clone(), ok: false, note: String::new(), cookie: String::new(), reason: "other".into(), file: None, name: None, log_tail: format!("yt-dlp не запустился: {e}") });
                    return;
                }
            };
            let stdout = child.stdout.take().unwrap();
            let stderr = child.stderr.take().unwrap();
            let slot = Arc::new(Mutex::new(Some(child)));
            state.children.lock().unwrap().insert(job.id.clone(), slot.clone());

            let err_log = Arc::new(Mutex::new(String::new()));
            let err_log2 = err_log.clone();
            let err_thread = std::thread::spawn(move || {
                for line in BufReader::new(stderr).lines().map_while(Result::ok) {
                    let mut g = err_log2.lock().unwrap();
                    g.push_str(&line);
                    g.push('\n');
                }
            });
            let mut out_log = String::new();
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                if let Some(rest) = line.strip_prefix("SCORPENA|") {
                    let p: Vec<&str> = rest.split('|').collect();
                    if p.len() == 3 {
                        let percent = p[0].trim().trim_end_matches('%').parse().unwrap_or(0.0);
                        let _ = app.emit("job-progress", Progress { id: job.id.clone(), percent, speed: p[1].trim().into(), eta: p[2].trim().into() });
                    }
                } else {
                    if line.starts_with('[') || line.contains("Retrying") || line.contains("Got error") {
                        let _ = app.emit("job-line", Line { id: job.id.clone(), line: line.clone() });
                    }
                    out_log.push_str(&line);
                    out_log.push('\n');
                }
            }
            let status = slot.lock().unwrap().as_mut().and_then(|c| c.wait().ok());
            let _ = err_thread.join();
            state.children.lock().unwrap().remove(&job.id);

            if state.stopped.lock().unwrap().remove(&job.id) {
                return; // paused or cancelled: the page knows, nothing to report
            }
            let attempt_log = format!("{}{}", out_log, err_log.lock().unwrap());
            log_all.push_str(&attempt_log);
            if status.map(|s| s.success()).unwrap_or(false) {
                ok = true;
                used_cookie = source.clone().unwrap_or_default();
                break;
            }
            let lower = attempt_log.to_lowercase();
            let permission_blocked = lower.contains("operation not permitted") && lower.contains("cookie");
            if is_auth_wall(&lower) { saw_auth = true; }
            if (is_auth_wall(&lower) || permission_blocked) && index < sources.len() {
                continue;
            }
            reason = if is_auth_wall(&lower) || permission_blocked || saw_auth { "auth".into() } else { failure_reason(&attempt_log).into() };
            break;
        }

        let tail: String = log_all.lines().rev().take(30).collect::<Vec<_>>().into_iter().rev().collect::<Vec<_>>().join("\n");
        let mut note = String::new();
        if ok && !job.audio && (job.video_format == "mp4" || job.video_format == "mov") {
            note = to_h264(&app, &state, &job.id, &staging);
            if state.stopped.lock().unwrap().remove(&job.id) { return; }
        }
        if ok {
            match deliver(&staging, Path::new(&job.dest)) {
                Some(file) => {
                    let name = file.file_name().map(|n| n.to_string_lossy().to_string());
                    let _ = app.emit("job-done", Done { id: job.id.clone(), ok: true, note: note.clone(), cookie: used_cookie.clone(), reason: "".into(), file: Some(file.to_string_lossy().into()), name, log_tail: tail });
                }
                None => {
                    let _ = app.emit("job-done", Done { id: job.id.clone(), ok: false, note: String::new(), cookie: String::new(), reason: "other".into(), file: None, name: None, log_tail: tail });
                }
            }
        } else {
            let _ = std::fs::remove_dir(&staging);
            let _ = app.emit("job-done", Done { id: job.id.clone(), ok: false, note: String::new(), cookie: String::new(), reason, file: None, name: None, log_tail: tail });
        }
    });
}

pub fn stop_job(state: &Arc<Running>, id: &str) {
    state.stopped.lock().unwrap().insert(id.to_string());
    if let Some(slot) = state.children.lock().unwrap().get(id) {
        if let Some(child) = slot.lock().unwrap().as_mut() {
            kill_tree(child);
        }
    }
}

// ---------- reading information about a link (no download) ----------

fn run_info(args: &[String]) -> Option<Vec<u8>> {
    let mut cmd = Command::new(tool("yt-dlp"));
    cmd.args(args).stdout(Stdio::piped()).stderr(Stdio::null());
    let path = format!("{}{}{}", tools_dir().display(), if cfg!(windows) { ";" } else { ":" }, std::env::var("PATH").unwrap_or_default());
    cmd.env("PATH", path);
    no_window(&mut cmd);
    let out = cmd.output().ok()?;
    if out.status.success() { Some(out.stdout) } else { None }
}

/// Cookie choices for reading a link: none first, then the installed browsers.
fn cookie_sets() -> Vec<Option<String>> {
    let mut sets: Vec<Option<String>> = vec![None];
    sets.extend(cookie_sources().into_iter().map(Some));
    sets
}

fn round_height(h: i64) -> i64 {
    [4320, 2160, 1440, 1080, 720, 480, 360, 240, 144].into_iter().min_by_key(|r| (r - h).abs()).unwrap_or(h)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Quality {
    title: String,
    heights: Vec<i64>,
    sizes: HashMap<String, i64>,
    duration: Option<f64>,
}

pub fn probe_quality(url: &str) -> Option<Quality> {
    for source in cookie_sets() {
        let cookies = source.as_deref().map(cookie_args);
        let mut args: Vec<String> = vec!["-J".into(), "--no-warnings".into(), "--no-playlist".into(), "--no-progress".into()];
        args.extend(js_runtime_args());
        if let Some(c) = &cookies { args.extend(c.args.clone()); }
        args.push(url.to_string());
        let Some(data) = run_info(&args) else { continue };
        let Ok(json) = serde_json::from_slice::<serde_json::Value>(&data) else { continue };
        let title = json["title"].as_str().unwrap_or("видео").to_string();
        let mut heights = std::collections::BTreeSet::new();
        let mut video_size: HashMap<i64, i64> = HashMap::new();
        let mut best_audio = 0i64;
        for f in json["formats"].as_array().cloned().unwrap_or_default() {
            let vcodec = f["vcodec"].as_str();
            let acodec = f["acodec"].as_str();
            let size = f["filesize"].as_i64().or_else(|| f["filesize_approx"].as_f64().map(|x| x as i64));
            if vcodec.map_or(false, |v| v != "none") {
                if let Some(h) = f["height"].as_i64().filter(|h| *h > 0) {
                    let rh = round_height(h);
                    heights.insert(rh);
                    if let Some(s) = size { if s > *video_size.get(&rh).unwrap_or(&0) { video_size.insert(rh, s); } }
                }
            }
            if acodec.map_or(false, |a| a != "none") && vcodec.map_or(true, |v| v == "none") {
                if let Some(s) = size { if s > best_audio { best_audio = s; } }
            }
        }
        if let Some(h) = json["height"].as_i64().filter(|h| *h > 0) { heights.insert(round_height(h)); }
        let sizes = heights.iter().filter_map(|h| video_size.get(h).map(|v| (h.to_string(), v + best_audio))).collect();
        let mut heights: Vec<i64> = heights.into_iter().collect();
        heights.sort_by(|a, b| b.cmp(a));
        if heights.is_empty() { continue; }
        return Some(Quality { title, heights, sizes, duration: json["duration"].as_f64() });
    }
    None
}

#[derive(Serialize)]
pub struct Entry { url: String, title: Option<String> }

#[derive(Serialize)]
pub struct PlaylistInfo { title: Option<String>, entries: Vec<Entry>, total: usize }

pub fn fetch_playlist(list_url: &str, limit: usize) -> Option<PlaylistInfo> {
    for source in cookie_sets() {
        let cookies = source.as_deref().map(cookie_args);
        let mut args: Vec<String> = vec!["--flat-playlist".into(), "--no-warnings".into(), "--print".into(), "%(url)s\t%(title)s\t%(playlist_title)s".into()];
        args.extend(js_runtime_args());
        if let Some(c) = &cookies { args.extend(c.args.clone()); }
        args.push(list_url.to_string());
        let Some(data) = run_info(&args) else { continue };
        let text = String::from_utf8_lossy(&data).to_string();
        let clean = |s: Option<&&str>| s.map(|x| x.trim()).filter(|x| !x.is_empty() && *x != "NA").map(|x| x.to_string());
        let mut title: Option<String> = None;
        let mut entries = vec![];
        for line in text.lines() {
            let parts: Vec<&str> = line.split('\t').collect();
            let Some(url) = clean(parts.first()).filter(|u| u.starts_with("http")) else { continue };
            if title.is_none() { title = clean(parts.get(2)); }
            entries.push(Entry { url, title: clean(parts.get(1)) });
        }
        if entries.is_empty() { continue; }
        let total = entries.len();
        entries.truncate(limit);
        return Some(PlaylistInfo { title, entries, total });
    }
    None
}

// ---------- the bundled tools: version and update ----------

pub fn ytdlp_version() -> Option<String> {
    let mut cmd = Command::new(tool("yt-dlp"));
    cmd.arg("--version").stdout(Stdio::piped()).stderr(Stdio::null());
    no_window(&mut cmd);
    let out = cmd.output().ok()?;
    if !out.status.success() { return None; }
    Some(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

#[derive(Serialize, Clone)]
pub struct ToolOutcome {
    /// "upToDate" | "updated" | "keptOld" | "offline" | "failed"
    pub kind: String,
    pub from: String,
    pub to: String,
}

fn outcome(kind: &str, from: &str, to: &str) -> ToolOutcome {
    ToolOutcome { kind: kind.into(), from: from.into(), to: to.into() }
}

fn asset_name() -> &'static str {
    if cfg!(windows) { "yt-dlp.exe" } else { "yt-dlp_macos" }
}

/// Checks GitHub for a newer yt-dlp and installs it when it passes a self-check; otherwise keeps the old one.
pub fn update_tools(app: &AppHandle) -> ToolOutcome {
    let stage = |n: u32| { let _ = app.emit("tool-stage", n); };
    stage(1);
    let tag = match ureq::get("https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")
        .set("User-Agent", "Scorpena-app").timeout(std::time::Duration::from_secs(12)).call()
    {
        Ok(r) => r.into_json::<serde_json::Value>().ok().and_then(|j| j["tag_name"].as_str().map(|s| s.to_string())),
        Err(ureq::Error::Transport(_)) => return outcome("offline", "", ""),
        Err(_) => None,
    };
    let Some(tag) = tag else { return outcome("failed", "", "") };
    let current = ytdlp_version().unwrap_or_default();
    if current == tag { return outcome("upToDate", &current, &tag); }

    stage(2);
    let base = format!("https://github.com/yt-dlp/yt-dlp/releases/download/{tag}");
    let download = |name: &str| -> Option<Vec<u8>> {
        let r = ureq::get(&format!("{base}/{name}")).set("User-Agent", "Scorpena-app").timeout(std::time::Duration::from_secs(180)).call().ok()?;
        let mut buf = Vec::new();
        std::io::Read::read_to_end(&mut r.into_reader(), &mut buf).ok()?;
        Some(buf)
    };
    let Some(bytes) = download(asset_name()) else { return outcome("failed", &current, &tag) };
    let Some(sums) = download("SHA2-256SUMS") else { return outcome("failed", &current, &tag) };
    {
        use sha2::{Digest, Sha256};
        let hash: String = Sha256::digest(&bytes).iter().map(|b| format!("{b:02x}")).collect();
        let sums = String::from_utf8_lossy(&sums).to_string();
        let expected = sums.lines().find_map(|l| { let mut p = l.split_whitespace(); let h = p.next()?; let n = p.next()?; (n.trim_start_matches('*') == asset_name()).then(|| h.to_string()) });
        if expected.as_deref() != Some(hash.as_str()) { return outcome("failed", &current, &tag); }
    }

    stage(3);
    let live = tool("yt-dlp");
    let fresh = live.with_extension(if cfg!(windows) { "new.exe" } else { "new" });
    if std::fs::write(&fresh, &bytes).is_err() { return outcome("failed", &current, &tag); }
    #[cfg(unix)]
    { use std::os::unix::fs::PermissionsExt; let _ = std::fs::set_permissions(&fresh, std::fs::Permissions::from_mode(0o755)); }
    let check = |path: &Path| -> bool {
        let mut v = Command::new(path); v.arg("--version").stdout(Stdio::piped()).stderr(Stdio::null()); no_window(&mut v);
        if !v.output().map(|o| String::from_utf8_lossy(&o.stdout).trim() == tag).unwrap_or(false) { return false; }
        // it must really work with YouTube before it replaces the old one
        let mut t = Command::new(path);
        t.args(["--simulate", "--no-warnings", "--no-playlist", "--socket-timeout", "20"]).args(js_runtime_args());
        t.arg("https://www.youtube.com/watch?v=jNQXAC9IVRw").stdout(Stdio::null()).stderr(Stdio::null());
        no_window(&mut t);
        t.status().map(|s| s.success()).unwrap_or(false)
    };
    if !check(&fresh) { let _ = std::fs::remove_file(&fresh); return outcome("keptOld", &current, &tag); }

    let old = live.with_extension("old");
    let _ = std::fs::remove_file(&old);
    if std::fs::rename(&live, &old).is_err() { let _ = std::fs::remove_file(&fresh); return outcome("failed", &current, &tag); }
    if std::fs::rename(&fresh, &live).is_err() {
        let _ = std::fs::rename(&old, &live);
        return outcome("failed", &current, &tag);
    }
    // the replaced file must still report the new version, otherwise the old one goes back
    if ytdlp_version().as_deref() != Some(tag.as_str()) {
        let _ = std::fs::remove_file(&live);
        let _ = std::fs::rename(&old, &live);
        return outcome("keptOld", &current, &tag);
    }
    let _ = std::fs::remove_file(&old);
    outcome("updated", &current, &tag)
}

// ---------- cleanup: old leftovers of unfinished downloads ----------

#[derive(Serialize)]
pub struct Stale { paths: Vec<String>, bytes: u64 }

fn dir_size(p: &Path) -> u64 {
    match std::fs::metadata(p) {
        Ok(m) if m.is_dir() => std::fs::read_dir(p).map(|d| d.flatten().map(|e| dir_size(&e.path())).sum()).unwrap_or(0),
        Ok(m) => m.len(),
        Err(_) => 0,
    }
}

/// Items in the partial-download folders that were not touched for `days` days.
pub fn stale_partials(days: u64) -> Stale {
    let partial = data_dir().join("Partial");
    let cutoff = std::time::SystemTime::now() - std::time::Duration::from_secs(days * 86400);
    let mut paths = vec![];
    let mut bytes = 0;
    for root in [partial.clone(), partial.join("temp")] {
        for e in std::fs::read_dir(&root).into_iter().flatten().flatten() {
            let p = e.path();
            if p.file_name().map_or(false, |n| n == "temp") { continue; }
            let old = e.metadata().and_then(|m| m.modified()).map(|t| t < cutoff).unwrap_or(false);
            if old { bytes += dir_size(&p); paths.push(p.to_string_lossy().into()); }
        }
    }
    Stale { paths, bytes }
}

pub fn remove_partials(paths: Vec<String>) {
    let partial = data_dir().join("Partial");
    for p in paths {
        let path = PathBuf::from(&p);
        if !path.starts_with(&partial) { continue; }   // only ever touches its own folder
        if path.is_dir() { let _ = std::fs::remove_dir_all(&path); } else { let _ = std::fs::remove_file(&path); }
    }
}

// ---------- information for automatic anonymous reports ----------

pub fn environment_line() -> String {
    let os = if cfg!(windows) {
        let mut c = Command::new("cmd");
        c.args(["/C", "ver"]).stdout(Stdio::piped()).stderr(Stdio::null());
        no_window(&mut c);
        c.output().ok().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).filter(|s| !s.is_empty()).unwrap_or_else(|| "Windows".into())
    } else {
        "macOS".to_string()
    };
    let ytdlp = ytdlp_version().unwrap_or_else(|| "нет".into());
    let deno = if tool("deno").exists() { "есть" } else { "нет" };
    format!("Scorpena {} (Windows-версия) · {} · {}\nyt-dlp {} · deno {}", env!("CARGO_PKG_VERSION"), os, std::env::consts::ARCH, ytdlp, deno)
}

/// Runs each bundled tool once. If one is missing or blocked, nothing can be downloaded — worth knowing about.
pub fn check_bundled_tools() -> Vec<String> {
    // an update that was interrupted in the middle of the swap: put the previous yt-dlp back
    let live = tool("yt-dlp");
    let old = live.with_extension("old");
    if !live.exists() && old.exists() { let _ = std::fs::rename(&old, &live); } else { let _ = std::fs::remove_file(&old); }
    let _ = std::fs::remove_file(live.with_extension(if cfg!(windows) { "new.exe" } else { "new" }));
    let mut problems = vec![];
    for (name, arg) in [("yt-dlp", "--version"), ("ffmpeg", "-version"), ("deno", "--version")] {
        let path = tool(name);
        if !path.exists() { problems.push(format!("{name}: файла нет")); continue; }
        let mut c = Command::new(&path);
        c.arg(arg).stdout(Stdio::null()).stderr(Stdio::null());
        no_window(&mut c);
        match c.status() {
            Err(_) => problems.push(format!("{name}: не удалось запустить")),
            Ok(s) if !s.success() => problems.push(format!("{name}: код выхода {}", s.code().unwrap_or(-1))),
            _ => {}
        }
    }
    problems
}


// ---------- H.264: MP4 and MOV have to play everywhere ----------

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct Phase {
    id: String,
    phase: String,
    percent: f64,
}

fn newest_video(dir: &Path) -> Option<PathBuf> {
    let mut best: Option<(std::time::SystemTime, PathBuf)> = None;
    for e in std::fs::read_dir(dir).ok()?.flatten() {
        let p = e.path();
        let name = p.file_name()?.to_string_lossy().to_lowercase();
        if name.starts_with('.') || name.ends_with(".part") || name.ends_with(".ytdl") || name.contains(".h264.") { continue; }
        let ext = p.extension().map(|x| x.to_string_lossy().to_lowercase()).unwrap_or_default();
        if !["mp4", "mkv", "webm", "mov", "m4v"].contains(&ext.as_str()) { continue; }
        let t = e.metadata().ok()?.modified().ok()?;
        if best.as_ref().map_or(true, |(b, _)| t > *b) { best = Some((t, p)); }
    }
    best.map(|(_, p)| p)
}

fn probe_codec(file: &Path) -> (Option<String>, Option<f64>) {
    let mut c = Command::new(tool("ffmpeg"));
    c.args(["-hide_banner", "-i"]).arg(file).stdout(Stdio::null()).stderr(Stdio::piped());
    no_window(&mut c);
    let Ok(out) = c.output() else { return (None, None) };
    let text = String::from_utf8_lossy(&out.stderr).to_string();
    let mut codec = None;
    let mut duration = None;
    for line in text.lines() {
        if codec.is_none() {
            if let Some(i) = line.find("Video: ") {
                codec = line[i + 7..].split(|ch: char| ch == ' ' || ch == ',' || ch == '(').next().map(|x| x.to_lowercase());
            }
        }
        if duration.is_none() {
            if let Some(i) = line.find("Duration: ") {
                let t = line[i + 10..].split(',').next().unwrap_or("").trim();
                let p: Vec<f64> = t.split(':').filter_map(|x| x.parse().ok()).collect();
                if p.len() == 3 { duration = Some(p[0] * 3600.0 + p[1] * 60.0 + p[2]); }
            }
        }
    }
    (codec, duration)
}

/// Checks the codec of the finished file and re-encodes it into H.264 when it is something else.
/// Returns "", "h264", "h264-failed" or "no-ffmpeg".
fn to_h264(app: &AppHandle, state: &Arc<Running>, id: &str, staging: &Path) -> String {
    let phase = |name: &str, percent: f64| { let _ = app.emit("job-phase", Phase { id: id.to_string(), phase: name.to_string(), percent }); };
    let Some(file) = newest_video(staging) else { return String::new() };
    if !tool("ffmpeg").exists() { return "no-ffmpeg".into(); }
    phase("check", 0.0);
    let (codec, duration) = probe_codec(&file);
    let codec = codec.unwrap_or_default();
    if codec.is_empty() || codec == "h264" || codec == "avc1" { return String::new(); }

    let ext = file.extension().map(|e| e.to_string_lossy().to_string()).unwrap_or_else(|| "mp4".into());
    let output = file.with_extension(format!("h264.{ext}"));
    let _ = std::fs::remove_file(&output);
    phase("transcode", 0.0);
    let mut cmd = Command::new(tool("ffmpeg"));
    cmd.args(["-y", "-hide_banner", "-loglevel", "error", "-nostats", "-progress", "pipe:1", "-i"]).arg(&file)
        .args(["-map", "0:v:0", "-map", "0:a:0?", "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
               "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]).arg(&output)
        .stdout(Stdio::piped()).stderr(Stdio::null());
    no_window(&mut cmd);
    let Ok(mut child) = cmd.spawn() else { return "h264-failed".into() };
    let stdout = child.stdout.take();
    let slot = Arc::new(Mutex::new(Some(child)));
    state.children.lock().unwrap().insert(id.to_string(), slot.clone());
    if let Some(out) = stdout {
        for line in BufReader::new(out).lines().map_while(Result::ok) {
            if let Some(us) = line.strip_prefix("out_time_us=").or_else(|| line.strip_prefix("out_time_ms=")) {
                if let (Ok(t), Some(total)) = (us.trim().parse::<f64>(), duration) {
                    if total > 0.0 { phase("transcode", (t / 1_000_000.0 / total).min(1.0)); }
                }
            }
        }
    }
    let ok = slot.lock().unwrap().as_mut().and_then(|c| c.wait().ok()).map(|s| s.success()).unwrap_or(false);
    state.children.lock().unwrap().remove(id);
    if state.stopped.lock().unwrap().contains(id) { let _ = std::fs::remove_file(&output); return String::new(); }
    if ok && output.exists() && std::fs::remove_file(&file).is_ok() && std::fs::rename(&output, &file).is_ok() { return "h264".into(); }
    let _ = std::fs::remove_file(&output);
    "h264-failed".into()
}

/// Stops every running download (when the program closes).
pub fn stop_all(state: &Arc<Running>) {
    let ids: Vec<String> = state.children.lock().unwrap().keys().cloned().collect();
    for id in ids { stop_job(state, &id); }
}

// ---------- first launch: which browsers are signed in (only cookie NAMES are read, nothing is decrypted) ----------

const LOGIN_COOKIES: [(&str, &[&str]); 3] = [
    ("youtube.com", &["SAPISID", "LOGIN_INFO", "__Secure-3PSID"]),
    ("instagram.com", &["sessionid"]),
    ("vimeo.com", &["vimeo"]),
];

fn profile_dbs(root: &Path, files: &[&str]) -> Vec<PathBuf> {
    let mut out = vec![];
    for e in std::fs::read_dir(root).into_iter().flatten().flatten() {
        for f in files {
            let p = e.path().join(f);
            if p.exists() { out.push(p); }
        }
    }
    out
}

/// Works on a copy, because the browser keeps its own file locked while it runs.
fn count_sites(db: &Path, table: &str, host_col: &str) -> usize {
    let tmp = std::env::temp_dir().join(format!("scorpena-cookies-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&tmp);
    let copy = tmp.join("db");
    let result = (|| -> Option<usize> {
        std::fs::copy(db, &copy).ok()?;
        let wal = PathBuf::from(format!("{}-wal", db.display()));
        if wal.exists() { let _ = std::fs::copy(&wal, tmp.join("db-wal")); }
        let conn = rusqlite::Connection::open_with_flags(&copy, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY).ok()?;
        let mut n = 0;
        for (host, names) in LOGIN_COOKIES {
            let list = names.iter().map(|x| format!("'{x}'")).collect::<Vec<_>>().join(",");
            let sql = format!("select count(*) from {table} where {host_col} like '%{host}' and name in ({list})");
            let c: i64 = conn.query_row(&sql, [], |r| r.get(0)).unwrap_or(0);
            if c > 0 { n += 1; }
        }
        Some(n)
    })();
    let _ = std::fs::remove_dir_all(&tmp);
    result.unwrap_or(0)
}

fn default_browser() -> Option<String> {
    if !cfg!(windows) { return None; }
    let mut c = Command::new("reg");
    c.args(["query", r"HKCU\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice", "/v", "ProgId"]).stdout(Stdio::piped()).stderr(Stdio::null());
    no_window(&mut c);
    let out = String::from_utf8_lossy(&c.output().ok()?.stdout).to_lowercase();
    for (needle, name) in [("chromehtml", "chrome"), ("msedgehtm", "edge"), ("firefox", "firefox"), ("bravehtml", "brave"), ("yandex", "yandex"), ("opera", "opera"), ("vivaldi", "vivaldi")] {
        if out.contains(needle) { return Some(name.into()); }
    }
    None
}

/// Installed browsers that already have a login, best first.
pub fn cookie_preflight() -> Vec<String> {
    let mut scored: Vec<(String, usize)> = vec![];
    let (local, roaming, home) = if cfg!(windows) {
        (std::env::var("LOCALAPPDATA").unwrap_or_default(), std::env::var("APPDATA").unwrap_or_default(), String::new())
    } else {
        (String::new(), String::new(), std::env::var("HOME").unwrap_or_default())
    };
    for b in installed_browsers() {
        let mut best = 0;
        let chromium: Option<PathBuf> = match (b.as_str(), cfg!(windows)) {
            ("chrome", true) => Some(PathBuf::from(&local).join("Google/Chrome/User Data")),
            ("edge", true) => Some(PathBuf::from(&local).join("Microsoft/Edge/User Data")),
            ("brave", true) => Some(PathBuf::from(&local).join("BraveSoftware/Brave-Browser/User Data")),
            ("vivaldi", true) => Some(PathBuf::from(&local).join("Vivaldi/User Data")),
            ("yandex", true) => Some(PathBuf::from(&local).join("Yandex/YandexBrowser/User Data")),
            ("chrome", false) => Some(PathBuf::from(&home).join("Library/Application Support/Google/Chrome")),
            _ => None,
        };
        if let Some(root) = chromium {
            for db in profile_dbs(&root, &["Network/Cookies", "Cookies"]) { best = best.max(count_sites(&db, "cookies", "host_key")); }
        } else if b == "firefox" {
            let root = if cfg!(windows) { PathBuf::from(&roaming).join("Mozilla/Firefox/Profiles") } else { PathBuf::from(&home).join("Library/Application Support/Firefox/Profiles") };
            for db in profile_dbs(&root, &["cookies.sqlite"]) { best = best.max(count_sites(&db, "moz_cookies", "host")); }
        } else if b == "opera" {
            let root = PathBuf::from(&roaming).join("Opera Software");
            for db in profile_dbs(&root, &["Network/Cookies", "Cookies"]) { best = best.max(count_sites(&db, "cookies", "host_key")); }
        }
        if best > 0 { scored.push((b, best)); }
    }
    let default = default_browser();
    scored.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| (Some(&b.0) == default.as_ref()).cmp(&(Some(&a.0) == default.as_ref()))));
    scored.into_iter().map(|(b, _)| b).collect()
}

// ---------- updating the program itself ----------

#[derive(Serialize, Clone)]
struct Fraction(f64);

/// Downloads the newest installer to a temporary folder and checks it against the checksum GitHub published.
pub fn download_update(app: &AppHandle) -> Result<String, String> {
    let rel: serde_json::Value = ureq::get("https://api.github.com/repos/erickkey/Scorpena/releases/latest")
        .set("User-Agent", "Scorpena-app").timeout(std::time::Duration::from_secs(15)).call().map_err(|e| e.to_string())?
        .into_json().map_err(|e| e.to_string())?;
    let asset = rel["assets"].as_array().and_then(|a| a.iter().find(|x| x["name"] == "Scorpena.exe")).ok_or("в релизе нет Scorpena.exe")?;
    let url = asset["browser_download_url"].as_str().ok_or("нет ссылки")?.to_string();
    let digest = asset["digest"].as_str().unwrap_or("").trim_start_matches("sha256:").to_lowercase();
    let size = asset["size"].as_u64().unwrap_or(0);
    let dir = std::env::temp_dir().join("scorpena-update");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let path = dir.join("Scorpena.exe");
    let resp = ureq::get(&url).set("User-Agent", "Scorpena-app").timeout(std::time::Duration::from_secs(600)).call().map_err(|e| e.to_string())?;
    let mut reader = resp.into_reader();
    let mut file = std::fs::File::create(&path).map_err(|e| e.to_string())?;
    use sha2::{Digest, Sha256};
    use std::io::{Read, Write};
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 256 * 1024];
    let mut got = 0u64;
    loop {
        let n = reader.read(&mut buf).map_err(|e| e.to_string())?;
        if n == 0 { break; }
        file.write_all(&buf[..n]).map_err(|e| e.to_string())?;
        hasher.update(&buf[..n]);
        got += n as u64;
        if size > 0 { let _ = app.emit("update-progress", Fraction((got as f64 / size as f64).min(1.0))); }
    }
    drop(file);
    let hash: String = hasher.finalize().iter().map(|b| format!("{b:02x}")).collect();
    if !digest.is_empty() && hash != digest { let _ = std::fs::remove_dir_all(&dir); return Err("контрольная сумма не сошлась".into()); }
    if size > 0 && got != size { let _ = std::fs::remove_dir_all(&dir); return Err("файл загрузился не полностью".into()); }
    Ok(path.to_string_lossy().into())
}

/// Starts the installer quietly after the program has closed, then opens the program again.
pub fn install_update(installer: &str) -> bool {
    let app = std::env::current_exe().unwrap_or_default();
    if !cfg!(windows) { return false; }
    let line = format!("timeout /t 3 /nobreak >nul & start /wait \"\" \"{installer}\" /S & start \"\" \"{}\"", app.display());
    let mut c = Command::new("cmd");
    c.args(["/C", &line]);
    no_window(&mut c);
    c.spawn().is_ok()
}

// ---------- crash reports: a panic leaves a short summary that is sent on the next start ----------

fn crash_file() -> PathBuf { data_dir().join("last-crash.txt") }

pub fn install_crash_hook() {
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let message = info.payload().downcast_ref::<&str>().map(|s| s.to_string())
            .or_else(|| info.payload().downcast_ref::<String>().cloned()).unwrap_or_default();
        let place = info.location().map(|l| format!("{}:{}", l.file().rsplit(['/', '\\']).next().unwrap_or(""), l.line())).unwrap_or_default();
        let trace = std::backtrace::Backtrace::force_capture().to_string();
        let frames: Vec<&str> = trace.lines().filter(|l| l.trim_start().starts_with(|c: char| c.is_ascii_digit())).take(10).collect();
        let text = format!("Сообщение: {}\nМесто: {}\n\nСтек:\n{}", message.chars().take(300).collect::<String>(), place, frames.join("\n"));
        let _ = std::fs::write(crash_file(), text);
        previous(info);
    }));
}

/// The summary of the previous crash, if there was one (it is deleted once taken).
pub fn take_crash_report() -> Option<String> {
    let text = std::fs::read_to_string(crash_file()).ok()?;
    let _ = std::fs::remove_file(crash_file());
    Some(text)
}
