# Scorpena – video downloader

[**English**](README.md) · [Русский](README.ru.md)

*Downloading video and audio on Mac*

Scorpena is a free program for macOS. Just paste a link to a video, and the program saves it to the Mac in the chosen format and quality. YouTube, VK, Instagram, TikTok, Vimeo and more than 1000 other sites are supported.

**[Download Scorpena.dmg](https://github.com/erickkey/Scorpena/releases/latest/download/Scorpena.dmg)**

## Features

**Downloading.** Video (MP4, MOV, WebM, MKV) and audio (MP3, WAV, M4A). Before downloading, the available qualities and the file size are shown. A copied link is pasted into the field automatically.

**Clip cutting.** Keyboard navigation is available. Video preview, start and end marks, downloading only the chosen part. The time can be entered by hand.

**Queue and playlists.** Up to three videos download at the same time, the others start automatically. The queue can be paused and is saved when the program closes. Playlists are downloaded into a separate folder.

**History.** A list of downloaded files with their length and download time. Any file opens in one click. If a file has already been downloaded, the program says so. Old history and unfinished files can be cleaned up on a reminder and by hand.

**Reliability.** Resuming after the program is closed or the connection is lost. A download speed limit. Updating the program with one button.

**Appearance.** Light and dark theme. Five interface languages: Russian, English, Chinese, Hindi, Spanish.

**Compatibility.** Any Mac (Intel and Apple Silicon), macOS 13 and newer.

**And much more.**

## Limitations

**Protected content.** Netflix, Disney+, Prime Video, Apple TV+, Kinopoisk, ivi, Okko and other DRM services cannot be downloaded: their video is encrypted against copying.

**Live streams.** Only finished broadcasts are recorded.

## Installation

1. Open the DMG and drag Scorpena to «Applications».
2. Launch the program. It is not signed by Apple, so macOS may show a warning on the first launch. Right-click the program → «Open» → «Open».
3. If that did not help: «System Settings» → «Privacy & Security» → «Open Anyway».
4. If the message «damaged» appears, run this command in Terminal: `xattr -cr /Applications/Scorpena.app`. It removes the «downloaded from the internet» mark, because of which macOS considers the program suspicious.

**Updates.** These steps are not needed for updates: the program downloads the new version itself, without the «downloaded from the internet» mark, and macOS shows no warning.

**Sending the file.** The DMG should be sent via AirDrop or as a link, not through Telegram or WhatsApp: they corrupt the file.

## Usage

1. Paste a link to a video.
2. Choose a format in the «Video» row (MP4, MOV, WebM, MKV) or the «Audio» row (MP3, WAV, M4A). If needed, choose the quality, the maximum is downloaded by default.
3. Click «Download».

**Videos that require signing in.** Some sites require signing in to an account. The program uses the cookies from the user's browser. For Safari, «Full Disk Access» is required: the program tells how to turn it on.

## Privacy

The program collects no personal data. Error reports and feedback are sent to the developer only when «Send» is clicked. Anonymous crash reports can be turned off in «Advanced».

## Supporting the project

The program is free. Its development can be [supported](https://tips.tips/000490838).

For developers: [DEVELOPMENT.md](DEVELOPMENT.md). Only download what you have the right to.
