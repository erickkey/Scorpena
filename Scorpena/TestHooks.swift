#if SCORPENA_TEST
import Foundation
import AppKit

/// Only in the test build (`SCORPENA_TEST_BUILD=1 sh Scripts/build-app.sh`): lets the end-to-end test
/// (Scripts/e2e.sh) start a download by itself and read what came of it. A normal build does not contain
/// any of this.
///
/// Environment: SCORPENA_E2E_LINK (the link), SCORPENA_E2E_DIR (where the file goes), SCORPENA_E2E_LOG
/// (a file the progress is written to), SCORPENA_E2E_AUDIO=1 (sound only), SCORPENA_E2E_CLIP="3-12" (a part).
enum TestHooks {
    static func run(queue: DownloadQueue, destination: URL) {
        let env = ProcessInfo.processInfo.environment
        guard let link = env["SCORPENA_E2E_LINK"], let logPath = env["SCORPENA_E2E_LOG"] else { return }
        let dest = URL(fileURLWithPath: env["SCORPENA_E2E_DIR"] ?? destination.path, isDirectory: true)
        var section: ClipSection?
        if let clip = env["SCORPENA_E2E_CLIP"] {
            let parts = clip.split(separator: "-").compactMap { Double($0) }
            if parts.count == 2 { section = ClipSection(start: parts[0], end: parts[1]) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            queue.submit(QueuedDownload(url: link, destination: dest, maxHeight: nil,
                                        audioOnly: env["SCORPENA_E2E_AUDIO"] == "1", stripAudio: false,
                                        videoFormat: .mp4, audioFormat: .mp3, section: section))
            var lines = ""
            let started = Date()
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
                let current = queue.managers.first { $0.isRunning || $0.isPaused } ?? queue.managers.first
                if let current { lines += String(format: "PROGRESS|%.3f|%@\n", current.progress, current.statusLine) }
                var result: String?
                if let done = queue.finished.first {
                    let path = done.fileURL?.path ?? ""
                    result = done.succeeded ? ("RESULT|ok|" + path) : ("RESULT|failed|" + done.note)
                } else if Date().timeIntervalSince(started) > 240 {
                    result = "RESULT|failed|timeout"
                }
                if let result { lines += result + "\n" }
                try? lines.write(toFile: logPath, atomically: true, encoding: .utf8)
                if result != nil {
                    timer.invalidate()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
                }
            }
        }
    }
}
#endif
