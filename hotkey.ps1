# hotkey.ps1 - 全局热键监听：Ctrl+Shift+S -> 写 analyze-trigger.flag
# 服务每 3s 检查该文件，存在则立即分析（跳过防抖）。Esc/关闭：由 stop-monitor.bat 杀进程。
$ErrorActionPreference = 'Continue'
$dir = $PSScriptRoot
if (-not $dir) { $dir = 'C:\Users\XCISXC\Desktop\DH\workplace\screen-monitor' }
$pidFile = Join-Path $dir 'hotkey.pid'
$logFile = Join-Path $dir 'hotkey.log'

function Log($m) { try { [System.IO.File]::AppendAllText($logFile, "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m`r`n") } catch { } }

# 防重复 + 原子 pid
$pidOk = $false
for ($try = 0; $try -lt 3; $try++) {
  try {
    $fs = [System.IO.File]::Open($pidFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $sw = New-Object System.IO.StreamWriter($fs)
    $sw.Write("$PID"); $sw.Close(); $fs.Close()
    $pidOk = $true
    break
  } catch {
    try {
      $oldPid = [int](Get-Content $pidFile -ErrorAction SilentlyContinue)
      $old = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
      if ($old) { exit }
    } catch { }
    Start-Sleep -Milliseconds 500
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
  }
}
if (-not $pidOk) { exit }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -ReferencedAssemblies @('System.Windows.Forms.dll') -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class HotkeyForm : Form {
  public string TriggerPath = "";
  public static string LogFile = "";
  [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
  [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
  protected override void OnHandleCreated(EventArgs e) {
    base.OnHandleCreated(e);
    // Ctrl+Shift+S : MOD_CONTROL(0x2) | MOD_SHIFT(0x4), VK=0x53
    // 注册占用检测：失败时记录 Win32 错误码（1409=已被其他程序占用）到 hotkey.log
    bool ok = RegisterHotKey(this.Handle, 1, 0x0002 | 0x0004, 0x53);
    try {
      if (ok) {
        System.IO.File.AppendAllText(LogFile, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " hotkey registered OK (Ctrl+Shift+S)\r\n");
      } else {
        int err = System.Runtime.InteropServices.Marshal.GetLastWin32Error();
        System.IO.File.AppendAllText(LogFile, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " HOTKEY REGISTER FAILED err=" + err + (err == 1409 ? " (already taken by another program)" : "") + "\r\n");
      }
    } catch { }
  }
  protected override void OnFormClosed(FormClosedEventArgs e) {
    UnregisterHotKey(this.Handle, 1);
    base.OnFormClosed(e);
  }
  protected override void WndProc(ref Message m) {
    if (m.Msg == 0x0312 && m.WParam.ToInt32() == 1) {
      try {
        System.IO.File.WriteAllText(TriggerPath, DateTime.Now.ToString("HH:mm:ss"));
        System.IO.File.AppendAllText(LogFile, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " hotkey triggered -> flag written\r\n");
      } catch { }
    }
    base.WndProc(ref m);
  }
}
"@

$f = New-Object HotkeyForm
$f.TriggerPath = Join-Path $dir 'analyze-trigger.flag'
[HotkeyForm]::LogFile = $logFile
$f.ShowInTaskbar = $false
$f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$f.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
$f.Opacity = 0
Log "hotkey listener started pid=$PID (Ctrl+Shift+S)"
[System.Windows.Forms.Application]::Run($f)
Log 'hotkey listener exited'
