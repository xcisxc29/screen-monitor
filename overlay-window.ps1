# overlay-window.ps1 - 屏幕分析悬浮窗 (WinForms TopMost, RichTextBox)
# 特性：可拖拽（拖拽条，双保险方案）、半透明（PgUp/PgDn）、位置记忆、
#       答案高亮（`1. [B] 理由` → B 大号金色字母）、防抽搐（内容变化才重绘）、
#       心跳在拖拽条右侧独立显示、Esc 关闭、防重复实例。

# 项目目录（脚本所在目录）
$script:projDir = $PSScriptRoot
if (-not $script:projDir) { $script:projDir = 'C:\Users\XCISXC\Desktop\DH\workplace\screen-monitor' }
$script:opidFile = Join-Path $script:projDir 'overlay.pid'
if (Test-Path $script:opidFile) {
  try {
    $oldPid = [int](Get-Content $script:opidFile -ErrorAction SilentlyContinue)
    $oldProc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
    if ($oldProc) { exit }
  } catch { }
}
[System.IO.File]::WriteAllText($script:opidFile, "$PID")

$script:logFile = Join-Path $script:projDir 'overlay-window.log'
function Log($m) { try { Add-Content -Encoding UTF8 $script:logFile "$(Get-Date -Format 'HH:mm:ss') $m" } catch { } }
Log 'script start'
# DPI 感知必须最先（任何 WinForms/GDI 初始化之前），否则窗口被系统虚拟化缩放、坐标错乱
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class DPIW4 {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
try { [DPIW4]::SetProcessDPIAware() | Out-Null } catch { }
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class User32X {
  [DllImport("user32.dll")] public static extern bool ReleaseCapture();
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);
}
"@
Log 'assemblies loaded'

# 可拖拽窗体：顶部区域返回 HTCAPTION（方案一：WM_NCHITTEST 原生拖动）
Add-Type -ReferencedAssemblies @('System.Windows.Forms.dll', 'System.Drawing.dll') -TypeDefinition @"
using System;
using System.Drawing;
using System.Windows.Forms;
public class DraggableForm2 : Form {
  public int DragBarHeight = 30;
  protected override void WndProc(ref Message m) {
    if (m.Msg == 0x0084) { // WM_NCHITTEST
      int x = (short)((int)m.LParam & 0xFFFF);
      int y = (short)((int)m.LParam >> 16);
      Point p = this.PointToClient(new Point(x, y));
      if (p.Y >= 0 && p.Y < DragBarHeight) {
        m.Result = new IntPtr(2); return; // HTCAPTION
      }
    }
    base.WndProc(ref m);
  }
}
"@

$script:dataFile = Join-Path $script:projDir 'result\overlay.txt'
$script:hbFile = Join-Path $script:projDir 'heartbeat.txt'
$script:posFile = Join-Path $script:projDir 'overlay.pos'

# 颜色
$cHeart = [System.Drawing.Color]::FromArgb(255, 154, 163, 184)
$cTitle = [System.Drawing.Color]::FromArgb(255, 79, 140, 255)
$cLetter = [System.Drawing.Color]::FromArgb(255, 255, 209, 102)
$cReason = [System.Drawing.Color]::FromArgb(255, 201, 210, 232)
$cNormal = [System.Drawing.Color]::FromArgb(255, 232, 234, 242)
$cBg = [System.Drawing.Color]::FromArgb(255, 15, 17, 26)
$cBar = [System.Drawing.Color]::FromArgb(255, 30, 35, 52)

$form = New-Object DraggableForm2
$form.Text = '屏幕分析悬浮窗'
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$scr = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Width = 500
$form.Height = 430
if (Test-Path $script:posFile) {
  try {
    $pos = (Get-Content $script:posFile -Raw).Trim() -split ','
    $form.Left = [int]$pos[0]; $form.Top = [int]$pos[1]
  } catch { $form.Left = $scr.Right - $form.Width - 16; $form.Top = 16 }
} else {
  $form.Left = $scr.Right - $form.Width - 16
  $form.Top = 16
}
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.KeyPreview = $true
$form.BackColor = $cBg
$form.Opacity = 0.92

# ---- 顶部拖拽条：分两行（标题行 + 时间行），全部绝对定位（Panel 内 Anchor 不可靠）----
$dragBar = New-Object System.Windows.Forms.Panel
$dragBar.Location = New-Object System.Drawing.Point(0, 0)
$dragBar.Size = New-Object System.Drawing.Size -ArgumentList @($form.Width, 48)
$dragBar.BackColor = $cBar
$barTitle = New-Object System.Windows.Forms.Label
# 关闭 AutoSize：AutoSize 高度按字体 height 计算，YaHei CJK 会被垂直裁剪
$barTitle.AutoSize = $false
$barTitle.Location = New-Object System.Drawing.Point(10, 2)
$barTitle.Size = New-Object System.Drawing.Size -ArgumentList @(480, 22)
$barTitle.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$barTitle.Text = '🖥 屏幕分析 · 按住拖动 · PgUp/PgDn 透明 · Esc 关'
$barTitle.ForeColor = $cHeart
$barTitle.BackColor = [System.Drawing.Color]::Transparent
$barTitle.Font = New-Object System.Drawing.Font -ArgumentList @('Microsoft YaHei', 9)
$script:barHrt = New-Object System.Windows.Forms.Label
# 第二行：时间，右侧绝对定位（x = 宽-160），不用 Anchor
$script:barHrt.Location = New-Object System.Drawing.Point(($form.Width - 160), 25)
$script:barHrt.Size = New-Object System.Drawing.Size -ArgumentList @(150, 20)
$script:barHrt.Text = ''
$script:barHrt.ForeColor = $cHeart
$script:barHrt.BackColor = [System.Drawing.Color]::Transparent
$script:barHrt.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$script:barHrt.Font = New-Object System.Drawing.Font -ArgumentList @('Microsoft YaHei', 9)
$dragBar.Controls.Add($script:barHrt)
$dragBar.Controls.Add($barTitle)

# ---- 拖动：方案二（鼠标事件 → 原生拖动）绑定到拖拽条及全部子 Label ----
# 子 Label 会吞掉鼠标事件，所以对 dragBar/barTitle/barHrt 三处都绑定。
function Start-NativeDrag($e) {
  try {
    [User32X]::ReleaseCapture() | Out-Null
    # lParam 需为鼠标屏幕坐标
    $lparam = (($e.Y -shl 16) -band 0xFFFF0000) -bor ($e.X -band 0xFFFF)
    [User32X]::SendMessage($form.Handle, 0x00A1, [IntPtr]2, [IntPtr]$lparam) | Out-Null # WM_NCLBUTTONDOWN, HTCAPTION
  } catch { }
}
$dragBar.Add_MouseDown({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Start-NativeDrag $e } })
$barTitle.Add_MouseDown({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Start-NativeDrag $e } })
$script:barHrt.Add_MouseDown({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Start-NativeDrag $e } })

# ---- 内容区（可滚动，大字答案）：绝对定位 y 48 起（拖拽条 48px 高）----
$rtb = New-Object System.Windows.Forms.RichTextBox
$rtb.Location = New-Object System.Drawing.Point(0, 48)
$rtb.Size = New-Object System.Drawing.Size -ArgumentList @($form.Width, ($form.Height - 48))
$rtb.BackColor = $cBg
$rtb.ForeColor = $cNormal
$rtb.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$rtb.ReadOnly = $true
$rtb.DetectUrls = $false
$rtb.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Vertical
# 内容上边距：让第一行完整显示，不被顶边裁剪（"时间下面那行只显示上半"）
$rtb.Padding = New-Object System.Windows.Forms.Padding -ArgumentList @(2, 10, 2, 2)
$form.Controls.Add($rtb)
$form.Controls.Add($dragBar)

function Add-RtbText($rtb, $text, $size, $bold, $color) {
  if ($bold) { $fs = [System.Drawing.FontStyle]::Bold } else { $fs = [System.Drawing.FontStyle]::Regular }
  $rtb.SelectionStart = $rtb.TextLength
  $rtb.SelectionLength = 0
  $rtb.SelectionFont = New-Object System.Drawing.Font -ArgumentList @('Microsoft YaHei', $size, $fs)
  $rtb.SelectionColor = $color
  $rtb.AppendText($text)
}

# 内容重绘：只在文本真正变化时执行（防抽搐）
$script:lastContent = ''
function Update-Content {
  try {
    $sb = New-Object System.Text.StringBuilder
    if (Test-Path $script:dataFile) {
      $lines = @(Get-Content $script:dataFile -Encoding UTF8)
      foreach ($ln in $lines) { [void]$sb.AppendLine($ln) }
    }
    $newText = $sb.ToString()
    if ($newText -eq $script:lastContent) { return }
    $script:lastContent = $newText

    # 注意：不能用 WM_SETREDRAW off/on 包裹（实测会破坏 RichTextBox 文本渲染），
    # 防抽搐由"内容变化才重绘"保证，这里直接重建后 Refresh() 同步重绘
    $rtb.Clear()
    foreach ($ln in @($newText -split "`r?`n")) {
      if ($ln -match '^(\d+)\.\s*\[([A-Ha-h])\]\s*(.*)$') {
        Add-RtbText $rtb ($matches[1] + '.  ') 13 $false $cNormal
        Add-RtbText $rtb ($matches[2].ToUpper() + '  ') 27 $true $cLetter
        Add-RtbText $rtb ($matches[3] + "`r`n") 12 $false $cReason
      } elseif ($ln -match '^📊') {
        # 成本统计行：小字灰显（须在 '·' 规则之前，避免被放大成标题）
        Add-RtbText $rtb ($ln + "`r`n") 12 $false $cHeart
      } elseif ($ln -match '·') {
        Add-RtbText $rtb ($ln + "`r`n") 14 $true $cTitle
      } elseif ($ln -match '^━') {
        Add-RtbText $rtb ($ln + "`r`n") 9 $false $cHeart
      } elseif ($ln.Trim()) {
        Add-RtbText $rtb ($ln + "`r`n") 13 $false $cNormal
      }
    }
    $rtb.Refresh()
    Log ("content rendered, len=" + $newText.Length + " rtb=" + $rtb.Width + "x" + $rtb.Height + "@(" + $rtb.Left + "," + $rtb.Top + ")")
  } catch {
    Log ("Update-Content ERROR: " + $_.Exception.Message + " @line " + $_.InvocationInfo.ScriptLineNumber)
  }
}

# 心跳：只显示时间（拖拽条右侧，短文本防遮挡）
function Update-Heartbeat {
  try {
    if (Test-Path $script:hbFile) {
      $h = (Get-Content -Raw $script:hbFile).Trim()
      if ($h -match 'HEARTBEAT\s+(\S+)') { $script:barHrt.Text = '⏱ ' + $matches[1] } else { $script:barHrt.Text = '' }
    }
  } catch { }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({
  Update-Heartbeat
  Update-Content
})
$timer.Start()

$form.Add_Shown({
  Update-Heartbeat
  Update-Content
})
$form.Add_KeyDown({
  param($s, $e)
  if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $form.Close() }
  elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::PageUp) { $form.Opacity = [Math]::Min(1.0, [Math]::Round($form.Opacity + 0.1, 2)); Log "opacity=$($form.Opacity)" }
  elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::PageDown) { $form.Opacity = [Math]::Max(0.3, [Math]::Round($form.Opacity - 0.1, 2)); Log "opacity=$($form.Opacity)" }
})
$form.Add_FormClosing({
  try { [System.IO.File]::WriteAllText($script:posFile, "$($form.Left),$($form.Top)") } catch { }
  # 联动：把悬浮窗当前位置矩形写回 config.json 的 excludeRegion（服务下次启动自动防自反馈，
  # 拖完悬浮窗无需再手动改坐标）。config.json 无 BOM UTF-8，与读取方式一致。
  try {
    $cfgPath = Join-Path $script:projDir 'config.json'
    $cfgObj = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $cfgObj.excludeRegion = @{ minX = $form.Left; minY = $form.Top; maxX = ($form.Left + $form.Width); maxY = ($form.Top + $form.Height) }
    [System.IO.File]::WriteAllText($cfgPath, ($cfgObj | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    Log "excludeRegion synced to config: $($form.Left),$($form.Top),$($form.Left+$form.Width),$($form.Top+$form.Height)"
  } catch { Log ("excludeRegion sync FAILED: " + $_.Exception.Message) }
})

Log ("form bounds L={0} T={1} W={2} H={3} opacity={4}" -f $form.Left, $form.Top, $form.Width, $form.Height, $form.Opacity)
try {
  [System.Windows.Forms.Application]::Run($form)
  Log 'Run returned (form closed)'
} catch {
  Log ("Run ERROR: {0}" -f $_.Exception.Message)
  throw
}
