# VideoDownloader — project notes for Claude

macOS SwiftUI app (yt-dlp + ffmpeg wrapper) for downloading video/audio from
YouTube, VK, Instagram, TikTok, Vimeo, and ~1750 other sites. Built for the
user's friends — casual, non-technical audience, distributed as a DMG via
AirDrop/Telegram/GitHub Releases (never send via Telegram/WhatsApp directly,
it corrupts the file — that's why README warns about it).

## Current release status (check before assuming anything is live)

- The app was renamed **VideoDownloader → Scorpena ("Scorpena – video downloader")**;
  the GitHub repo is now `erickkey/Scorpena` (old URLs redirect).
- **Version 3.1 is the current one (2026-10-29):** parallel downloads with a queue
  (`DownloadQueue.swift`, saved in `queue.json`, pauses included), playlists (`Playlist.swift`),
  the merged «Загрузки» window (queue + history by day), cleanup reminder (`Cleanup.swift`),
  quit warning (`QuitWarning.swift`), first-launch browser-login preflight (`CookiePreflight.swift`),
  new logo and one shared look for all windows (`Style.swift`: pills, `DialogLayout`).
  3.0 was published 2026-10-28. Check what is live with `gh release list --repo erickkey/Scorpena`.
  New `.swift` files are NOT in `YouTubeDownloader.xcodeproj` (the build is `Scripts/build-app.sh`).
- Releases must always carry TWO DMGs: `Scorpena.dmg` and the legacy `VideoDownloader.dmg`
  (installed 2.0/2.1 apps fetch exactly that file name and look for `VideoDownloader.app`).
  `version.json` is bumped LAST.
- Texts in the app use the informal «ты» everywhere. The user wants short,
  non-technical UI wording and approves every changelog/About/Legal change.
- **Do not push, build a release DMG, or run `gh release create/upload` without the
  user explicitly saying so in that session** (one approval = one action).
- Never detach a mounted DMG by volume name (the user may have their own
  `VideoDownloader.dmg` mounted); use `hdiutil info` and detach only your own image.

## Standing workflow rule: changelog approval before publishing

Before *asking* whether to publish a new version, always:
1. Draft the "Список изменений" (changelog) text for the About→"Что нового"
   dialog (the `changelog` dict in `ContentView.swift`, keyed by version
   string, shown once per version via `WhatsNewPanel`).
2. Show that exact text to the user in chat and let them edit/approve it.
3. Only *after* they approve the text do you ask about actually publishing
   (bump `APP_VERSION`, build, package, git commit/push, `gh release`).

This is a two-step gate, not one — don't collapse it. The user writes the
final wording themselves as often as not; paste their edits back into the
`changelog` dict verbatim, don't paraphrase.

## Build & release workflow (no Xcode available — CLI tools only)

- Build: `sh Scripts/build-app.sh` — compiles arm64+x86_64 via raw `swiftc`,
  hand-assembles the .app bundle, downloads yt-dlp_macos + lipo's a
  universal ffmpeg, ad-hoc signs. Output: `~/Desktop/VideoDownloader.app`.
- Typecheck only (fast, no download): `swiftc -typecheck -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macosx13.0 YouTubeDownloader/*.swift`
- Package: `sh Scripts/package.sh ~/Desktop/VideoDownloader.app ~/Desktop` —
  produces styled `.dmg` (custom background, icon positions via
  `hdiutil`+AppleScript) and `.zip`.
- Release: `git add`/`commit`/`push`, then
  `gh release create vX.XX ~/Desktop/VideoDownloader.dmg --title "..." --notes "..."`.
  For a version bump only (no new content changes), re-upload with
  `gh release upload vX.XX <dmg> --clobber` instead of creating a new tag.
- `version.json` at repo root also needs bumping to match — the in-app
  `UpdateChecker` polls `raw.githubusercontent.com/.../main/version.json`
  and shows a red pulsing "Доступно обновление" note if it's ahead of the
  running build. That raw-content URL is CDN-cached for a few minutes
  independent of client cache headers — the checker already busts this with
  a timestamp query param, so don't re-add caching workarounds there.

## Telegram bot integration (error reports + feedback)

- `YouTubeDownloader/Secrets.swift` holds `Secrets.telegramBotToken` and
  `Secrets.telegramChatID` — **this file is gitignored and must never be
  committed** (a public repo leaking a bot token is trivially scraped).
  It only exists locally; if it's ever missing, the project won't compile —
  recreate it with the real token/chat id (ask the user, don't guess) as:
  ```swift
  enum Secrets {
      static let telegramBotToken = "..."
      static let telegramChatID = "..."
  }
  ```
- Bot: `@VideoDL_Lukyanov_bot`. Both "Сообщить об ошибке" (inline button
  under a failed download, `reportError` in `ContentView.swift`) and
  "Обратная связь" (dedicated `FeedbackView` window, message + optional
  name + optional contact) POST straight to
  `https://api.telegram.org/bot<TOKEN>/sendMessage` — no Telegram client
  needed on the sending user's machine at all.
- `reportError` includes a per-install incrementing "Обращение №N" ticket
  number (`errorReportCounter`, `@AppStorage`) and the tail of the internal
  log (kept even though the log UI itself is hidden from users — see
  below).
- `FeedbackView` has a 60-second cooldown between sends
  (`lastFeedbackSendTime`), persists "Имя" and "Как связаться" across opens
  (`@AppStorage`) but always resets the message field itself. The single
  "Отправить" button is disabled while the message is empty; on send it
  shows "Обращение отправлено" for 1.5s then auto-closes. It does **not**
  double as a close button — closing without sending uses the window's own
  traffic-light close, on purpose (don't re-add dual behavior, this was
  explicitly reverted once already).

## UI/UX decisions worth knowing before "fixing" them again

- **The technical log is intentionally hidden from users.** It used to be a
  visible "Журнал" panel under "Дополнительно"; it's gone from the UI now
  (only `manager.log` internally, used to build error reports). Don't add
  it back to the visible UI without being asked — this was a deliberate
  simplification, not an oversight.
- **No background "is this link even valid" network check exists anymore.**
  One was built (quick yt-dlp `--simulate` call, ~10s for YouTube, showed
  a green/red indicator under the URL field) and then explicitly removed
  because it was unreliable for sites like Vimeo (false negatives) and the
  green "success" state gave false confidence. All that remains is a
  zero-network, offline **format** check (`isPlausibleURL` /
  `isPlausibleURLString` static func) that just verifies the pasted text
  *looks* like a URL (has a scheme or bare domain, a real-looking TLD, not
  a bare filename) — this only produces the red "Кажется, это не ссылка"
  warning, never a green "it works" claim. Don't reintroduce the network
  check unless explicitly asked again.
- **Quality picker before any probe shows literally "Максимально
  доступное"** as a real Picker entry (not placeholder fallback heights
  like 1080p/720p/etc — that used to exist and was removed because it
  implied fake precision). Only after "Проверить качество" runs does the
  full per-resolution list (with per-item file sizes) appear. Downloading
  before probing always takes the true max, never a stale previously
  probed height (see `startDownload`'s `effectiveMaxHeight` logic).
- **There is ONE «Скачать» button.** What it saves depends on the format rows under the
  URL field: picking a format in the «Видео» or «Звук» row also switches `downloadMode`
  (video | audio). (2.0 had separate «Скачать видео»/«Скачать звук» buttons; 3.0 replaced
  them — don't describe them in texts.)
- **A single elapsed-time counter** (`runStartTime`, ticks via
  `TimelineView` under the status line) is the general "the app hasn't
  frozen" indicator for *any* long-running op (download, Homebrew
  install/update, transcode) — it's not per-feature, don't duplicate it.
- **"Дополнительно"'s expand/collapse resizes the actual NSWindow** by a
  hardcoded `advancedSectionHeight` constant (currently tuned for
  tools-block + notifications-block only, no log block). If content inside
  "Дополнительно" changes again, this constant needs re-tuning by hand —
  a fully automatic GeometryReader-based measurement was attempted and hit
  a real SwiftUI/macOS bug (DisclosureGroup does not reliably propagate
  PreferenceKey values out of its disclosed content on macOS); don't
  re-attempt that approach without expecting the same wall.
- **`resetWindowHeightIfStaleExpanded()`** works around a separate, real
  SwiftUI-on-macOS quirk: SwiftUI auto-persists each window's frame in
  UserDefaults per content-view-type key (independent of anything the app
  does), so quitting while "Дополнительно" is expanded reopens the window
  at that taller size with content starting collapsed, leaving a visible
  gap. This trims it back on launch. If window-sizing bugs resurface,
  check for this class of issue before assuming it's a fresh bug.

## Testing constraints in this environment

- No Xcode, no Accessibility permission granted to this automation session
  — cannot click buttons, type into fields, or drive the UI via
  AppleScript/System Events beyond basic `activate`/`frontmost`. Verified
  features by: (a) typecheck + build succeeding, (b) temporary debug hooks
  in `onAppear` (auto-trigger a download/probe/report, then remove before
  shipping) + screenshots, (c) direct `curl` tests against yt-dlp/Telegram
  APIs, (d) asking the user to click through it themselves.
- Full-screen screenshots on this machine reliably capture whatever the
  user is doing in *other* apps (their own Telegram, other Claude Code
  sessions, unrelated work) because window focus is unreliable via
  `osascript activate` alone — always re-query window bounds via
  `CGWindowListCopyWindowInfo` right before screenshotting, and never
  describe/forward unrelated content that ends up in a screenshot by
  accident.
- Rebuilding while an old instance is running can leave a stray mounted
  DMG volume from `Scripts/package.sh`'s temp image — `hdiutil detach` it
  before re-running package.sh if you see a "convert failed" error; check
  `hdiutil info` for the `image-path` to avoid detaching a DMG the *user*
  has open themselves (they do sometimes inspect the built DMG in Finder
  while you're mid-session).
