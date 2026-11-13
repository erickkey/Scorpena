import Foundation

// The tests never touch the real queue, history and caches: Scripts/test.sh gives each its own folder.
if AppSupport.isReal { print("FAIL  run the tests with Scripts/test.sh (they need their own data folder)"); exit(1) }
// The texts are checked in Russian whatever the language of the computer that runs the tests.
LanguageSettings.shared.language = .ru
import SwiftUI

var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok   " : "FAIL ", what); if !ok { failures += 1 } }

// --- link hints (the same line under every link field)
check(ContentView.linkHint("") == nil, "empty link: no hint")
check(ContentView.linkHint("привет мир")?.text.contains("не ссылка") == true, "garbage: «не ссылка»")
check(ContentView.linkHint("https://youtube.com/")?.text.contains("главная страница") == true, "homepage hint")
check(ContentView.linkHint("https://www.youtube.com/watch?v=jNQXAC9IVRw")?.text.contains("списке") == true, "known site hint")
check(ContentView.linkHint("https://tips.tips/000490838")?.text.contains("Необычный") == true, "unknown site hint")
check(ContentView.isCheckable("https://www.youtube.com/watch?v=jNQXAC9IVRw"), "video link is checkable")
check(!ContentView.isCheckable("https://youtube.com/"), "homepage is not checkable")

// --- sizes
check(ContentView.formatBytesParts(0).number == "0", "0 bytes shows 0")
check(ContentView.formatBytes(674_000) == "674 КБ", "674 KB")
check(ContentView.progressAmounts(done: 10_000_000, total: 558_000_000) == "10 из 558 МБ", "10 из 558 МБ (unit once)")
check(!ContentView.progressAmounts(done: 10_000_000, total: 558_000_000).contains("≈"), "no ≈ in the progress line")

// --- clips
let clip = ClipSection(start: 3, end: 12)
check(clip.length == 9, "clip length")
check(clip.fileTag == "0.03-0.12", "clip file tag \(clip.fileTag)")

// --- queue: parts of one video are different downloads
func item(_ section: ClipSection?) -> QueuedDownload {
    QueuedDownload(url: "https://www.youtube.com/watch?v=aaa", destination: URL(fileURLWithPath: "/tmp"), maxHeight: nil,
                   audioOnly: false, stripAudio: false, videoFormat: .mp4, audioFormat: .mp3, section: section)
}
let queue = DownloadQueue.shared
queue.submit(item(ClipSection(start: 1, end: 5)))
check(queue.isActive(url: item(nil).url, audioOnly: false, section: ClipSection(start: 1, end: 5)), "same clip is active")
check(!queue.isActive(url: item(nil).url, audioOnly: false, section: ClipSection(start: 6, end: 9)), "another clip is NOT active")
check(!queue.isActive(url: item(nil).url, audioOnly: false), "whole video is NOT active while a clip waits")
queue.submit(item(ClipSection(start: 6, end: 9)))
queue.submit(item(ClipSection(start: 10, end: 12)))
let total = { queue.items.count + queue.running.count }
check(total() == 3, "three clips of one video are all taken (got \(total()))")
queue.submit(item(ClipSection(start: 6, end: 9)))
check(total() == 3, "the same clip twice is refused (got \(total()))")
check(queue.badgeLabel == "3", "the number on the Dock icon is the number of downloads going and waiting (got \(queue.badgeLabel ?? "nothing"))")
queue.cancelAll()
check(queue.badgeLabel == (queue.running.isEmpty ? nil : String(queue.running.count)), "once the waiting ones are cancelled only the running ones are counted")

// --- a normal download: lines in, status and bar out
let m = DownloadManager()
func feed(_ lines: [String]) { lines.forEach { m.handle(line: $0) } }
var last = 0.0
var monotonic = true
func step(_ line: String) { m.handle(line: line); if m.progress < last - 1e-9 { monotonic = false }; last = m.progress }
step("[info] x: Downloading 2 format(s): 137+140")
step("[download] Destination: v.f137.mp4")
for p in stride(from: 5.0, through: 100.0, by: 5.0) {
    step(String(format: "[download] %5.1f%% of  200.00MiB at  3.00MiB/s ETA 00:30", p))
    if p == 50 { check(!m.statusLine.contains("≈"), "status has no ≈: \(m.statusLine)") }
}
step("[download] Destination: a.f140.m4a")
for p in stride(from: 10.0, through: 100.0, by: 30.0) { step(String(format: "[download] %5.1f%% of  4.00MiB at  3.00MiB/s ETA 00:01", p)) }
step("[Merger] Merging formats into \"x.mp4\"")
check(m.statusLine == tr("Склеиваю видео и звук…"), "merge status: \(m.statusLine)")
check(monotonic, "bar never goes back (normal download)")
check(m.progress >= 0.8 && m.progress < 1, "bar is near the end before finishing: \(m.progress)")

// --- site that sends pieces and guesses the size: no total in the line
let f = DownloadManager()
f.handle(line: "[info] x: Downloading 1 format(s): hls-720")
f.handle(line: "[download] Destination: v.mp4")
f.handle(line: "[download]  10.0% of ~ 120.00MiB at  2.00MiB/s ETA 00:40 (frag 3/30)")
check(!f.statusLine.contains(" из "), "guessed size: no «из» in line: \(f.statusLine)")

// --- a clip: progress comes from ffmpeg time, no pause
let c = DownloadManager()
c.pendingSection = ClipSection(start: 3, end: 12)
var lastC = 0.0, monoC = true
for t in ["time=-577014:32:22.77", "time=00:00:02.75", "time=00:00:04.01", "time=00:00:05.35", "time=00:00:08.99"] {
    c.handle(line: "frame=  38 fps= 25 q=32.0 size= 1kB \(t) bitrate=1.7kbits/s speed=2.7x")
    if c.progress < lastC - 1e-9 { monoC = false }; lastC = c.progress
}
check(monoC, "clip bar never goes back")
check(c.progress > 0.8, "clip bar reaches the end of its range: \(c.progress)")
check(!c.canPause, "a clip cannot be paused")
check(!c.pausable, "a clip has no pause button")

// --- a link to an ordinary file (not a video)
let fileLinkLog = """
[generic] Extracting URL: https://example.com/Scorpena.dmg
WARNING: [generic] URL could be a direct video link, returning it as such.
[download] 0263df20 does not pass filter (ext != unknown_video), skipping ..
[info] Encountered a video that did not match filter, stopping due to --break-match-filter
"""
let fileLinkOldLog = """
[generic] Extracting URL: https://example.com/Scorpena.dmg
WARNING: [generic] URL could be a direct video link, returning it as such.
[download] 100% of  174.94MiB
ERROR: Postprocessing: file:/tmp/x.unknown_video: Invalid data found when processing input
"""
check(DownloadManager.friendlyDownloadError(in: fileLinkLog)?.contains("нет видео или аудио") == true, "a link to a file: «нет видео или аудио»")
check(DownloadManager.friendlyDownloadError(in: fileLinkOldLog)?.contains("нет видео или аудио") == true, "a link to a file (late failure): «нет видео или аудио»")
check(DownloadManager.friendlyDownloadError(in: "ERROR: Unsupported URL: https://example.com/") != nil
      && DownloadManager.friendlyDownloadError(in: "ERROR: Unsupported URL: https://example.com/")?.contains("нет видео или аудио") == false, "unsupported link keeps its own message")
let geoLog = "ERROR: [youtube] xnP7qKxwzjg: The uploader has not made this video available in your country. This video is available in this country list: Spain, France.\nYou might want to use a VPN or a proxy server (with --proxy) to workaround."
check(DownloadManager.friendlyDownloadError(in: geoLog)?.contains("недоступно в твоей стране") == true, "geo block: «недоступно в твоей стране»")
check(DownloadManager.friendlyDownloadError(in: "ERROR: Video unavailable")?.contains("недоступно в твоей стране") == false, "plain unavailable keeps its own message")
check(DownloadManager.friendlyDownloadError(in: "[generic] URL could be a direct video link\n[download] 100% of 5MiB") == nil, "a direct video link that downloaded fine is no error")

print(failures == 0 ? "ALL OK" : "FAILURES: \(failures)")
exit(failures == 0 ? 0 : 1)
