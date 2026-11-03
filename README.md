# Scorpena – video downloader

[**English**](README.md) · [Русский](README.ru.md)

A Mac program: paste a link to a video and it downloads it in one click. Works with YouTube, VK, Instagram, TikTok, Vimeo and more than 1000 other sites. Free.

**Download:** [Scorpena.dmg](https://github.com/erickkey/Scorpena/releases/latest/download/Scorpena.dmg)

## How to use

1. Open the DMG and drag Scorpena to «Applications».
2. Paste a link to a video.
3. Choose a format: video (MP4, MOV, WebM, MKV) or audio (MP3, WAV, M4A).
4. Click «Download».

## Features

- **Downloading:** video (MP4, MOV, WebM, MKV) and audio (MP3, WAV, M4A)
- **Quality and size:** before downloading you can see which qualities are available and how big the file will be
- **Clips:** downloading only the chosen part of a video instead of the whole one
- **Queue:** up to 3 videos download at the same time, the others start automatically as the previous ones finish
- **Playlists:** downloading playlists
- **History:** a list of downloaded files, each opens in one click
- **Resume:** if the program is closed or the internet drops, the download continues
- **Speed:** a limit for the download speed
- **Link:** a copied link is pasted into the field automatically
- **Appearance:** light and dark theme, five languages
- **Updates:** a new version installs with one button
- **Compatibility:** any Mac (Intel and Apple Silicon), macOS 13 and newer

## Limitations

- **Protected content:** Netflix, Disney+, Prime Video, Apple TV+, Kinopoisk, ivi, Okko and other DRM services cannot be downloaded: they encrypt the video against copying
- **Live streams:** only broadcasts that have already ended can be recorded

## First launch

The program is not signed by Apple, so on the first launch the Mac may complain:

- Right-click the program → «Open» → «Open».
- If it says «damaged», open Terminal and paste this command:

  ```
  xattr -cr /Applications/Scorpena.app
  ```

  (it removes the «downloaded from the internet» mark from the program, which makes the Mac think it is suspicious)

- If that did not help: «System Settings» → «Privacy & Security» → «Open Anyway».

This is not needed for later updates. Send the DMG via AirDrop or as a link, not through Telegram or WhatsApp: they corrupt the file.

## If a video asks to sign in

Some sites ask to sign in to an account. The program takes the cookies from your browser by itself. For Safari it needs «Full Disk Access», and it tells how to turn it on.

## Privacy

The program collects nothing personal. Error reports and feedback go to the developer only when you click «Send». Anonymous crash reports can be turned off in «Advanced».

## Support

If the program was useful, you can [support its development](https://tips.tips/000490838).

For developers: [DEVELOPMENT.md](DEVELOPMENT.md).

Download only what you have the right to.
