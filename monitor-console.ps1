# monitor-console.ps1 - 屏幕监测助手 · 控制面板
# 双击「启动屏幕监测助手.bat」打开本界面。
# 功能：首启填写 API Key；一键打开/关闭服务（含悬浮窗与热键）；结果交付到 result 文件夹。
# 本进程由用户双击启动（用户上下文）→ Start-Process 的子进程（服务/悬浮窗）可正常显示 GUI。

# ---- DPI 感知必须最先（150% 缩放下窗口才正常）----
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class CslDPI {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
try { [CslDPI]::SetProcessDPIAware() | Out-Null } catch { }
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$base = $PSScriptRoot
if (-not $base) { $base = 'C:\Users\XCISXC\Desktop\DH\workplace\screen-monitor' }
$cfgPath = Join-Path $base 'config.json'
$psExe = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"

function Read-Cfg {
  try { return (Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}
$script:cfg = Read-Cfg
if (-not $script:cfg) { [System.Windows.Forms.MessageBox]::Show("无法读取 config.json：$cfgPath", '屏幕监测助手', 'OK', 'Error') | Out-Null; exit }

$script:resultDir = Join-Path $base 'result'
if ($script:cfg.paths.result -and (Test-Path (Split-Path $script:cfg.paths.result -Parent))) { $script:resultDir = $script:cfg.paths.result }
if (-not (Test-Path $script:resultDir)) { New-Item -ItemType Directory -Path $script:resultDir -Force | Out-Null }

function Get-PidAlive([string]$f) {
  $p = Join-Path $base $f
  if (-not (Test-Path $p)) { return $false }
  try { $id = [int](Get-Content $p); return [bool](Get-Process -Id $id -ErrorAction SilentlyContinue) } catch { return $false }
}
function Get-PidNum([string]$f) {
  $p = Join-Path $base $f
  if (-not (Test-Path $p)) { return '' }
  try { return (Get-Content $p).Trim() } catch { return '' }
}

# ---------------- 界面 ----------------
$form = New-Object System.Windows.Forms.Form
$form.Text = '屏幕监测助手'
$form.Size = New-Object System.Drawing.Size -ArgumentList @(660, 560)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(255, 240, 242, 248)

$cAccent = [System.Drawing.Color]::FromArgb(255, 20, 65, 124)
$cOk = [System.Drawing.Color]::FromArgb(255, 30, 140, 70)
$cOff = [System.Drawing.Color]::FromArgb(255, 160, 40, 40)

# 标题
$title = New-Object System.Windows.Forms.Label
$title.Text = '🖥 屏幕监测助手'
$title.Font = New-Object System.Drawing.Font -ArgumentList @('Microsoft YaHei', 16, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = $cAccent
$title.Location = New-Object System.Drawing.Point(16, 12)
$title.AutoSize = $true
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = '实时屏幕分析 · 本地 OCR · LLM 答题 · 结果交付 result 文件夹'
$subtitle.Font = New-Object System.Drawing.Font -ArgumentList @('Microsoft YaHei', 9)
$subtitle.ForeColor = [System.Drawing.Color]::Gray
$subtitle.Location = New-Object System.Drawing.Point(18, 46)
$subtitle.AutoSize = $true
$form.Controls.Add($subtitle)

# 状态区
$script:statusLabel = New-Object System.Windows.Forms.Label
$script:statusLabel.Font = New-Object System.Drawing.Font -ArgumentList @('Microsoft YaHei', 11, [System.Drawing.FontStyle]::Bold)
$script:statusLabel.Location = New-Object System.Drawing.Point(18, 78)
$script:statusLabel.AutoSize = $true
$form.Controls.Add($script:statusLabel)

$script:hbLabel = New-Object System.Windows.Forms.Label
$script:hbLabel.Font = New-Object System.Drawing.Font -ArgumentList @('Microsoft YaHei', 9)
$script:hbLabel.ForeColor = [System.Drawing.Color]::Gray
$script:hbLabel.Location = New-Object System.Drawing.Point(18, 104)
$script:hbLabel.AutoSize = $true
$form.Controls.Add($script:hbLabel)

# API Key 区
$apiLabel = New-Object System.Windows.Forms.Label
$apiLabel.Text = 'DeepSeek API Key（首启必填，本地保存到 config.json）'
$apiLabel.Font = New-Object System.Drawing.Font -ArgumentList @('Microsoft YaHei', 9)
$apiLabel.Location = New-Object System.Drawing.Point(18, 136)
$apiLabel.AutoSize = $true
$form.Controls.Add($apiLabel)

$script:apiBox = New-Object System.Windows.Forms.TextBox
$script:apiBox.Location = New-Object System.Drawing.Point(18, 160)
$script:apiBox.Size = New-Object System.Drawing.Size -ArgumentList @(450, 26)
$script:apiBox.Font = New-Object System.Drawing.Font -ArgumentList @('Consolas', 10)
$script:apiBox.PasswordChar = '*'
$script:apiBox.Text = [string]$script:cfg.llm.apiKey
$form.Controls.Add($script:apiBox)

$btnSaveKey = New-Object System.Windows.Forms.Button
$btnSaveKey.Text = '保存 Key'
$btnSaveKey.Location = New-Object System.Drawing.Point(478, 158)
$btnSaveKey.Size = New-Object System.Drawing.Size -ArgumentList @(110, 30)
$btnSaveKey.BackColor = [System.Drawing.Color]::FromArgb(255, 225, 235, 250)
$form.Controls.Add($btnSaveKey)

# 控制按钮
$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = '▶ 打开服务'
$btnStart.Location = New-Object System.Drawing.Point(18, 205)
$btnStart.Size = New-Object System.Drawing.Size -ArgumentList @(150, 44)
$btnStart.BackColor = [System.Drawing.Color]::FromArgb(255, 210, 235, 215)
$btnStart.Font = New-Object System.Drawing.Font -ArgumentList @('Microsoft YaHei', 11, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnStart)

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = '■ 关闭服务'
$btnStop.Location = New-Object System.Drawing.Point(178, 205)
$btnStop.Size = New-Object System.Drawing.Size -ArgumentList @(150, 44)
$btnStop.BackColor = [System.Drawing.Color]::FromArgb(255, 240, 210, 210)
$btnStop.Font = New-Object System.Drawing.Font -ArgumentList @('Microsoft YaHei', 11, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnStop)

$btnOpenResult = New-Object System.Windows.Forms.Button
$btnOpenResult.Text = '📂 打开 result 文件夹'
$btnOpenResult.Location = New-Object System.Drawing.Point(338, 205)
$btnOpenResult.Size = New-Object System.Drawing.Size -ArgumentList @(180, 44)
$form.Controls.Add($btnOpenResult)

$resultLabel = New-Object System.Windows.Forms.Label
$resultLabel.Text = '结果目录: ' + $script:resultDir
$resultLabel.Font = New-Object System.Drawing.Font -ArgumentList @('Microsoft YaHei', 8.5)
$resultLabel.ForeColor = [System.Drawing.Color]::Gray
$resultLabel.Location = New-Object System.Drawing.Point(18, 258)
$resultLabel.AutoSize = $true
$form.Controls.Add($resultLabel)

# 日志区
$logLabel = New-Object System.Windows.Forms.Label
$logLabel.Text = '运行日志'
$logLabel.Font = New-Object System.Drawing.Font -ArgumentList @('Microsoft YaHei', 9)
$logLabel.Location = New-Object System.Drawing.Point(18, 286)
$logLabel.AutoSize = $true
$form.Controls.Add($logLabel)

$script:logBox = New-Object System.Windows.Forms.TextBox
$script:logBox.Multiline = $true
$script:logBox.ReadOnly = $true
$script:logBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$script:logBox.BackColor = [System.Drawing.Color]::FromArgb(255, 20, 22, 32)
$script:logBox.ForeColor = [System.Drawing.Color]::FromArgb(255, 200, 210, 230)
$script:logBox.Font = New-Object System.Drawing.Font -ArgumentList @('Consolas', 9)
$script:logBox.Location = New-Object System.Drawing.Point(18, 310)
$script:logBox.Size = New-Object System.Drawing.Size -ArgumentList @(600, 200)
$form.Controls.Add($script:logBox)

# ---------------- 逻辑 ----------------
function Add-Log($m) {
  $line = "$(Get-Date -Format 'HH:mm:ss')  $m"
  $script:logBox.AppendText($line + "`r`n")
  if ($script:logBox.TextLength -gt 8000) { $script:logBox.Clear() }
}

function Update-Status {
  try {
    $sv = Get-PidAlive 'service.pid'; $hk = Get-PidAlive 'hotkey.pid'; $ov = Get-PidAlive 'overlay.pid'
    $svn = Get-PidNum 'service.pid'
    $s = '● 服务: ' + $(if ($sv) { '运行中' } else { '已停止' }) + '   热键: ' + $(if ($hk) { '已注册' } else { '未启动' }) + '   悬浮窗: ' + $(if ($ov) { '已打开' } else { '未打开' })
    $script:statusLabel.Text = $s
    if ($sv) { $script:statusLabel.ForeColor = $cOk } else { $script:statusLabel.ForeColor = $cOff }
    # 心跳
    $hb = ''
    $stPath = Join-Path $base 'status.json'
    if (Test-Path $stPath) {
      try { $st = Get-Content $stPath -Raw -Encoding UTF8 | ConvertFrom-Json; $hb = "心跳 $($st.ts) · cycle $($st.cycle) · mode $($st.mode) · pid $($st.pid)" } catch { }
    }
    $script:hbLabel.Text = $hb
    # API 状态
    $cfg2 = Read-Cfg
    if ($cfg2 -and $cfg2.llm.apiKey) { $script:apiBox.Text = [string]$cfg2.llm.apiKey }
  } catch { }
}

function Save-Key {
  $newKey = $script:apiBox.Text.Trim()
  if (-not $newKey) {
    [System.Windows.Forms.MessageBox]::Show('API Key 不能为空！', '屏幕监测助手', 'OK', 'Warning') | Out-Null
    return $false
  }
  try {
    $raw = Get-Content $cfgPath -Raw -Encoding UTF8
    $new = $raw -replace '"apiKey":\s*"[^"]*"', ('"apiKey": "' + $newKey + '"')
    [System.IO.File]::WriteAllText($cfgPath, $new, (New-Object System.Text.UTF8Encoding($false)))
    Add-Log "API Key 已保存"
    $script:cfg = Read-Cfg
    return $true
  } catch {
    Add-Log "保存失败: $($_.Exception.Message)"
    return $false
  }
}

function Start-Monitor {
  $cfg2 = Read-Cfg
  if (-not $cfg2.llm.apiKey) {
    [System.Windows.Forms.MessageBox]::Show('请先填写并保存 API Key。', '屏幕监测助手', 'OK', 'Warning') | Out-Null
    return
  }
  # 确保 result 目录
  if (-not (Test-Path $script:resultDir)) { New-Item -ItemType Directory -Path $script:resultDir -Force | Out-Null }
  # 启动：服务（隐藏）+ 热键（隐藏）+ 悬浮窗（可见）
  try {
    Start-Process $psExe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',(Join-Path $base 'monitor-service.ps1')
    Start-Process $psExe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',(Join-Path $base 'hotkey.ps1')
    Start-Process $psExe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',(Join-Path $base 'overlay-window.ps1')
    Add-Log '服务已启动：监测服务 + 全局热键(Ctrl+Shift+S) + 悬浮窗'
    Add-Log '结果将写入: ' + $script:resultDir
    Start-Sleep -Seconds 2
  } catch { Add-Log "启动失败: $($_.Exception.Message)" }
}

function Stop-Monitor {
  try {
    # 服务优雅停止
    [System.IO.File]::WriteAllText((Join-Path $base 'stop.flag'), 'stop')
    Start-Sleep -Seconds 4
    $sv = Get-PidNum 'service.pid'
    if ($sv) { $p = Get-Process -Id $sv -ErrorAction SilentlyContinue; if ($p) { Stop-Process -Id $sv -Force; Add-Log "服务已停止 (PID $sv)" } else { Add-Log '服务已优雅退出' } }
    # 热键
    $hk = Get-PidNum 'hotkey.pid'
    if ($hk) { $p = Get-Process -Id $hk -ErrorAction SilentlyContinue; if ($p) { Stop-Process -Id $hk -Force; Add-Log "热键已停止 (PID $hk)" } }
    # 悬浮窗
    $ov = Get-PidNum 'overlay.pid'
    if ($ov) {
      $p = Get-Process -Id $ov -ErrorAction SilentlyContinue
      if ($p) { $p.CloseMainWindow() | Out-Null; Start-Sleep -Seconds 2; $p2 = Get-Process -Id $ov -ErrorAction SilentlyContinue; if ($p2) { Stop-Process -Id $ov -Force }; Add-Log "悬浮窗已关闭 (PID $ov)" }
    }
    Remove-Item (Join-Path $base 'service.pid'),(Join-Path $base 'hotkey.pid'),(Join-Path $base 'overlay.pid'),(Join-Path $base 'stop.flag') -Force -ErrorAction SilentlyContinue
    Add-Log '全部组件已关闭'
  } catch { Add-Log "关闭失败: $($_.Exception.Message)" }
}

# ---------------- 事件绑定 ----------------
$btnSaveKey.Add_Click({ Save-Key | Out-Null; Update-Status })
$btnStart.Add_Click({ Start-Monitor; Update-Status })
$btnStop.Add_Click({ Stop-Monitor; Update-Status })
$btnOpenResult.Add_Click({
  try { if (-not (Test-Path $script:resultDir)) { New-Item -ItemType Directory -Path $script:resultDir -Force | Out-Null }; Start-Process explorer.exe -ArgumentList $script:resultDir } catch { Add-Log "打开失败: $($_.Exception.Message)" }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({ Update-Status })
$timer.Start()

$form.Add_Shown({
  Update-Status
  Add-Log '控制面板已启动'
  $cfg2 = Read-Cfg
  if (-not $cfg2.llm.apiKey) { Add-Log '⚠ 首次使用：请在上方填写 DeepSeek API Key 并保存' } else { Add-Log "API Key 已配置（$([string]$cfg2.llm.apiKey.Substring(0,6))...）" }
})

[System.Windows.Forms.Application]::Run($form)
