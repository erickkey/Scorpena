import AppKit
import SwiftUI

/// Two small tidy-ups after an install, each asked about once and never done without a yes:
///  · the disk image the app was installed from is still mounted (and its file still in Downloads):
///    offer to eject it and move the file to the Trash;
///  · an older copy of this app is still on the Mac (it can be the one that opens from the Dock or
///    Spotlight): offer to move it to the Trash.
enum InstallCleanup {
    private static let dismissedKey = "installCleanupDismissed"

    private struct InstallImage { let imagePath: String; let mountPoint: String }
    private struct OldCopy { let url: URL; let version: String }

    private static var dismissed: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: dismissedKey) }
    }

    /// Called a few seconds after launch. Does nothing while the app runs from a disk image or from a
    /// randomised «translocated» place: it has not been installed yet then.
    static func runAfterLaunch() {
        let path = AppInstaller.currentAppURL.path
        guard !path.hasPrefix("/Volumes/"), !path.contains("/AppTranslocation/"),
              ProcessInfo.processInfo.environment["SCORPENA_TEST"] == nil else { return }
        DispatchQueue.global(qos: .utility).async {
            let image = findInstallImage()
            DispatchQueue.main.async {
                if let image { askAboutImage(image) { askAboutOldCopy() } } else { askAboutOldCopy() }
            }
        }
    }

    // MARK: Disk image

    private static func findInstallImage() -> InstallImage? {
        guard let output = run("/usr/bin/hdiutil", ["info", "-plist"]).output,
              let plist = try? PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return nil }
        let ownID = Bundle.main.bundleIdentifier
        for image in images {
            guard let imagePath = image["image-path"] as? String, imagePath.lowercased().hasSuffix(".dmg"),
                  FileManager.default.fileExists(atPath: imagePath), !dismissed.contains(imagePath) else { continue }
            for entity in (image["system-entities"] as? [[String: Any]]) ?? [] {
                guard let mount = entity["mount-point"] as? String else { continue }
                for name in ["Scorpena.app", "VideoDownloader.app"] {
                    let info = NSDictionary(contentsOfFile: mount + "/" + name + "/Contents/Info.plist")
                    if let id = info?["CFBundleIdentifier"] as? String, id == ownID {
                        return InstallImage(imagePath: imagePath, mountPoint: mount)
                    }
                }
            }
        }
        return nil
    }

    private static func askAboutImage(_ image: InstallImage, then next: @escaping () -> Void) {
        let name = (image.imagePath as NSString).lastPathComponent
        CleanupDialog.shared.ask(
            title: tr("Образ установки больше не нужен"),
            message: trf("Программа установлена. Извлечь образ «%@» и убрать файл в Корзину?", name),
            keep: tr("Оставить"), accept: tr("Извлечь и убрать")
        ) { accepted in
            guard accepted else {
                dismissed.insert(image.imagePath)
                next()
                return
            }
            DispatchQueue.global(qos: .utility).async {
                // Only this image, by the place it is mounted at (never by a volume's name).
                let detached = run("/usr/bin/hdiutil", ["detach", image.mountPoint]).status == 0
                if detached {
                    try? FileManager.default.trashItem(at: URL(fileURLWithPath: image.imagePath), resultingItemURL: nil)
                }
                DispatchQueue.main.async { next() }
            }
        }
    }

    // MARK: Older copy

    private static func findOldCopy() -> OldCopy? {
        guard let id = Bundle.main.bundleIdentifier,
              let output = run("/usr/bin/mdfind", ["kMDItemCFBundleIdentifier == '\(id)'"]).output,
              let text = String(data: output, encoding: .utf8) else { return nil }
        let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
        let ownPath = AppInstaller.currentAppURL.standardizedFileURL.path
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })
        for line in text.split(separator: "\n").map(String.init) {
            let url = URL(fileURLWithPath: line).standardizedFileURL
            let path = url.path
            guard url.pathExtension == "app", path != ownPath, !running.contains(path),
                  !path.hasPrefix("/Volumes/"), !path.contains("/.Trash/"), !path.contains("/AppTranslocation/"),
                  !path.contains("/Application Support/VideoDownloader/"), !dismissed.contains(path),
                  let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
                  let version = info["CFBundleShortVersionString"] as? String,
                  UpdateChecker.isNewer(current, than: version) else { continue }
            return OldCopy(url: url, version: version)
        }
        return nil
    }

    private static func askAboutOldCopy() {
        DispatchQueue.global(qos: .utility).async {
            let copy = findOldCopy()
            DispatchQueue.main.async {
                guard let copy else { return }
                let folder = copy.url.deletingLastPathComponent().lastPathComponent
                CleanupDialog.shared.ask(
                    title: tr("Найдена старая копия программы"),
                    message: trf("На этом Mac осталась прежняя версия %@ в папке «%@». Из-за неё иногда открывается старая версия. Убрать её в Корзину?", copy.version, folder),
                    keep: tr("Оставить"), accept: tr("В Корзину")
                ) { accepted in
                    if accepted { try? FileManager.default.trashItem(at: copy.url, resultingItemURL: nil) }
                    else { dismissed.insert(copy.url.path) }
                }
            }
        }
    }

    // MARK: Running a tool

    private static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: Data?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (-1, nil) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}

/// One question with two buttons, in the look of the program's other small dialogs.
final class CleanupDialog {
    static let shared = CleanupDialog()
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var answered = false

    func ask(title: String, message: String, keep: String, accept: String, onAnswer: @escaping (Bool) -> Void) {
        window?.close()
        answered = false

        func finish(_ accepted: Bool) {
            guard !answered else { return }
            answered = true
            window?.close()
            onAnswer(accepted)
        }

        let win = makeDialogWindow(CleanupDialogView(title: title, message: message, keep: keep, accept: accept, onChoose: finish))
        win.makeKeyAndOrderFront(nil)
        window = win

        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: win, queue: .main
        ) { _ in finish(false) }
    }
}

private struct CleanupDialogView: View {
    let title: String
    let message: String
    let keep: String
    let accept: String
    let onChoose: (Bool) -> Void

    @ObservedObject private var languageSettings = LanguageSettings.shared

    var body: some View {
        DialogLayout(title: title, message: message) {
            DialogButton(title: keep) { onChoose(false) }
            DialogButton(title: accept, primary: true) { onChoose(true) }
        }
    }
}
