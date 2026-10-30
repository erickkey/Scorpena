# Helpers for the Windows test: screenshots, window list, closing a window by title.
param([string]$Cmd, [string]$Arg1 = "", [string]$Arg2 = "")
Add-Type -AssemblyName System.Drawing, System.Windows.Forms, System.Security
Add-Type @"
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public class W {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  public static List<object[]> All(uint pid) {
    var res = new List<object[]>();
    EnumWindows((h, l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p == pid && IsWindowVisible(h)) {
        var sb = new StringBuilder(256); GetWindowText(h, sb, 256);
        RECT r; GetWindowRect(h, out r);
        if (sb.Length > 0) res.Add(new object[] { h.ToInt64(), sb.ToString(), r.R - r.L, r.B - r.T, r.L, r.T });
      }
      return true;
    }, IntPtr.Zero);
    return res;
  }
}
"@
[void][W]::SetProcessDPIAware()
switch ($Cmd) {
  "shot" {
    $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
    $bmp.Save($Arg1); $g.Dispose(); $bmp.Dispose()
  }
  "windows" {
    $pids = Get-Process -Name $Arg1 -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }
    $out = @()
    foreach ($id in $pids) { foreach ($w in [W]::All([uint32]$id)) { $out += [pscustomobject]@{ title = $w[1]; width = $w[2]; height = $w[3]; left = $w[4]; top = $w[5] } } }
    $out | ConvertTo-Json -Compress
  }
  "close" {
    $pids = Get-Process -Name $Arg1 -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }
    foreach ($id in $pids) { foreach ($w in [W]::All([uint32]$id)) { if ($w[1] -like "*$Arg2*") { [void][W]::PostMessage([IntPtr]$w[0], 0x0010, [IntPtr]::Zero, [IntPtr]::Zero); "closed $($w[1])" } } }
  }
  "procs" { (Get-Process -Name yt-dlp,ffmpeg -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name) -join "," }
  "decrypt" {
    $bytes = [System.IO.File]::ReadAllBytes($Arg1)
    $plain = [System.Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, 'CurrentUser')
    [System.Text.Encoding]::UTF8.GetString($plain)
  }
}
