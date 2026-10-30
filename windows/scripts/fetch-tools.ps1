# Downloads the three tools the program needs next to itself: yt-dlp, ffmpeg and deno (Windows builds).
$ErrorActionPreference = "Stop"
$dest = Join-Path $PSScriptRoot "..\tools"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
$tmp = Join-Path $env:TEMP "scorpena-tools"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

Invoke-WebRequest "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe" -OutFile (Join-Path $dest "yt-dlp.exe")

Invoke-WebRequest "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip" -OutFile "$tmp\ffmpeg.zip"
Expand-Archive "$tmp\ffmpeg.zip" -DestinationPath "$tmp\ffmpeg" -Force
Copy-Item (Get-ChildItem "$tmp\ffmpeg" -Recurse -Filter ffmpeg.exe | Select-Object -First 1).FullName (Join-Path $dest "ffmpeg.exe")
Copy-Item (Get-ChildItem "$tmp\ffmpeg" -Recurse -Filter ffprobe.exe | Select-Object -First 1).FullName (Join-Path $dest "ffprobe.exe")

Invoke-WebRequest "https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip" -OutFile "$tmp\deno.zip"
Expand-Archive "$tmp\deno.zip" -DestinationPath $dest -Force

Get-ChildItem $dest | Format-Table Name, Length
