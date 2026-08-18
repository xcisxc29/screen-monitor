# monitor-service.ps1 - Resident screen analysis service (P0)
# Fully autonomous: capture -> change detection -> local OCR -> understanding ->
# publish (floating window / Edge tab / result files). Runs independently of any
# agent session. Stop with stop-monitor.bat (or create stop.flag).
#
# config.json sits next to this script. ASCII-safe structure with UTF-8 output.

param([string]$ConfigPath = '', [switch]$SelfTest)

$ErrorActionPreference = 'Continue'

if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'config.json' }
$cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
# 自包含路径：优先脚本所在目录（无论解压到哪都能跑）；config 的 paths 仅在指向有效目录时覆盖
$dir = $PSScriptRoot
if (-not $dir) { $dir = 'C:\Users\XCISXC\Desktop\DH\workplace\screen-monitor' }
if ($cfg.paths.base -and (Test-Path $cfg.paths.base)) { $dir = $cfg.paths.base }
# 结果交付目录（result 文件夹）：结果/悬浮窗数据/历史/统计 → result；过程状态/触发文件留根目录
$resultDir = Join-Path $dir 'result'
if ($cfg.paths.result -and (Test-Path (Split-Path $cfg.paths.result -Parent))) { $resultDir = $cfg.paths.result }
if (-not (Test-Path $resultDir)) { New-Item -ItemType Directory -Path $resultDir -Force | Out-Null }

$statusPath  = Join-Path $dir 'status.json'
$hbPath      = Join-Path $dir 'heartbeat.txt'
$resultPath  = Join-Path $resultDir 'result.json'
$overlayTxt  = Join-Path $resultDir 'overlay.txt'
$overlayHtml = Join-Path $resultDir 'overlay.html'
$historyLog  = Join-Path $resultDir 'history.log'
$jsonlPath   = Join-Path $resultDir 'history.jsonl'
$statsPath   = Join-Path $resultDir 'stats.json'
$triggerPath = Join-Path $dir 'analyze-trigger.flag'
$pidFile     = Join-Path $dir 'service.pid'
$cachePath   = Join-Path $dir 'llm-cache.json'
$stopFlag    = Join-Path $dir 'stop.flag'
$firstRun    = Join-Path $dir 'firstrun.flag'

$utf8 = New-Object System.Text.UTF8Encoding($false)

# 防重复实例（原子化，避免双服务竞态）：CreateNew 只有一个进程能成功
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
      $oldProc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
      if ($oldProc) { Write-Host "another service instance running (pid $oldPid), exiting"; exit }
    } catch { }
    Start-Sleep -Milliseconds 500
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
  }
}
if (-not $pidOk) { Write-Host "cannot acquire pid file"; exit }

function Log($msg) {
  $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"
  try { [System.IO.File]::AppendAllText($historyLog, $line + "`r`n") } catch { }
}

Log "service start pid=$PID interval=$($cfg.intervalSec)"

# ---------------- WinRT OCR init ----------------
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics, ContentType = WindowsRuntime]
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.RandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
$null = [Windows.Globalization.Language, Windows.Globalization, ContentType = WindowsRuntime]

$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
})[0]

function Await($WinRtTask, $ResultType) {
  $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
  $netTask = $asTask.Invoke($null, @($WinRtTask))
  $netTask.Wait(-1) | Out-Null
  $netTask.Result
}

function Invoke-LocalOcr([string]$ImagePath) {
  try {
    $full = (Resolve-Path $ImagePath).Path
    $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($full)) ([Windows.Storage.StorageFile])
    $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $bitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage([Windows.Globalization.Language]::new($cfg.ocrLang))
    if (-not $engine) { $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages() }
    if (-not $engine) { throw 'no ocr engine' }
    $result = Await ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
    $stream.Dispose()
    $outLines = @()
    foreach ($line in $result.Lines) {
      $outLines += ((@($line.Words) | ForEach-Object { $_.Text }) -join ' ')
    }
    return ($outLines -join "`n")
  } catch {
    Log "OCR error: $($_.Exception.Message)"
    return $null
  }
}

function Get-CleanText([string]$t) {
  if (-not $t) { return '' }
  $t = $t -replace '([\u4e00-\u9fff])\s+(?=[\u4e00-\u9fff])', '$1'
  $t = $t -replace '([\u4e00-\u9fff])\s+(?=[，。、；：？！）】」》])', '$1'
  $t = $t -replace '([（【「《])\s+(?=[\u4e00-\u9fff])', '$1'
  $t = $t -replace '(\d)\s+([\.、．\)·，,])', '$1$2'
  $t = $t -replace '([\.、．\)·，,])\s+(?=[\u4e00-\u9fff])', '$1'
  $t = $t -replace '[\r]+', "`n"
  # 伪分行：把同一行内连续的选项字母/题号切成独立行，保证行首解析可用
  $t = $t -replace '(\s+)(?=[A-Ha-h][\.、．\)·，,])', "`n"
  $t = $t -replace '(\s+)(?=\d{1,3}[\.、．\)·，,])', "`n"
  return $t.Trim()
}

# ---------------- capture + change detection ----------------
# DPI 感知：系统 150% 缩放时，未感知进程只截物理屏幕左上角（虚拟分辨率），
# 导致屏幕右侧/底部内容永远读不到。必须在读取屏幕前启用。
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class DPIAware {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
try { [DPIAware]::SetProcessDPIAware() | Out-Null } catch { }
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$cur = Join-Path $dir 'screen-latest.png'
$prev = Join-Path $dir 'screen-prev.png'
$useRegion = ($cfg.analyzeRegion.enabled -and [int]$cfg.analyzeRegion.w -gt 0 -and [int]$cfg.analyzeRegion.h -gt 0)

# 排除区矩形（防自反馈：悬浮窗所在区域不参与变化检测，且 OCR 前涂黑避免内容污染）。
# 支持两种格式：新格式 {minX,minY,maxX,maxY} 矩形；旧格式 {minX,maxY}（右上角区域）向后兼容。
$script:excludeRect = @{ minX = 0; minY = 0; maxX = $bounds.Width; maxY = 0 }
if ($cfg.excludeRegion) {
  $er = $cfg.excludeRegion
  $script:excludeRect.minX = [int]$er.minX
  $script:excludeRect.maxY = [int]$er.maxY
  if ($er.PSObject.Properties['minY']) { $script:excludeRect.minY = [int]$er.minY }
  if ($er.PSObject.Properties['maxX']) { $script:excludeRect.maxX = [int]$er.maxX }
}

function Capture-And-Diff {
  $bmp = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
  $g.Dispose()
  # 选区裁剪：只保留指定区域（隐私/精准分析），裁剪后 excludeRegion 不生效
  if ($script:useRegion) {
    $rw = [int]$cfg.analyzeRegion.w; $rh = [int]$cfg.analyzeRegion.h
    $rx = [int]$cfg.analyzeRegion.x; $ry = [int]$cfg.analyzeRegion.y
    $crop = New-Object System.Drawing.Bitmap $rw, $rh
    $cg = [System.Drawing.Graphics]::FromImage($crop)
    $cg.DrawImage($bmp, (New-Object System.Drawing.Rectangle(0, 0, $rw, $rh)), (New-Object System.Drawing.Rectangle($rx, $ry, $rw, $rh)), [System.Drawing.GraphicsUnit]::Pixel)
    $cg.Dispose()
    $bmp.Dispose()
    $bmp = $crop
  }
  $w = $bmp.Width; $h = $bmp.Height
  $ratio = -1.0
  $hadPrev = Test-Path $prev
  if ($hadPrev) {
    $old = New-Object System.Drawing.Bitmap $prev
    # 防御：prev 与当前帧尺寸不一致（选区配置变更/分辨率变化）→ 丢弃重来
    if ($old.Width -ne $w -or $old.Height -ne $h) {
      $old.Dispose()
      Remove-Item $prev -Force -ErrorAction SilentlyContinue
      $hadPrev = $false
    }
  }
  if ($hadPrev) {
    $n = 0; $diff = 0
    $sx = [Math]::Max(1, [int]($w / 64))
    $sy = [Math]::Max(1, [int]($h / 36))
    for ($x = 0; $x -lt $w; $x += $sx) {
      for ($y = 0; $y -lt $h; $y += $sy) {
        if (-not $script:useRegion -and $x -ge $script:excludeRect.minX -and $x -le $script:excludeRect.maxX -and $y -ge $script:excludeRect.minY -and $y -le $script:excludeRect.maxY) { continue }
        $c1 = $bmp.GetPixel($x, $y); $c2 = $old.GetPixel($x, $y)
        $n++
        if ([Math]::Abs($c1.R - $c2.R) -gt 12 -or [Math]::Abs($c1.G - $c2.G) -gt 12 -or [Math]::Abs($c1.B - $c2.B) -gt 12) { $diff++ }
      }
    }
    $old.Dispose()
    $ratio = [Math]::Round($diff / [Math]::Max(1, $n), 4)
  }
  if ($hadPrev) { Remove-Item $prev -Force -ErrorAction SilentlyContinue }
  Move-Item $cur $prev -Force -ErrorAction SilentlyContinue
  # 防自反馈：OCR 前把排除区（悬浮窗所在区域）涂黑，悬浮窗文字不再进入分析。
  # 变化检测已在上面按矩形跳过该区域，涂黑不影响 ratio。
  if (-not $script:useRegion) {
    $ex = $script:excludeRect
    if ($ex.maxX -gt $ex.minX -and $ex.maxY -gt $ex.minY) {
      $g2 = [System.Drawing.Graphics]::FromImage($bmp)
      $g2.FillRectangle([System.Drawing.Brushes]::Black, $ex.minX, $ex.minY, ($ex.maxX - $ex.minX), ($ex.maxY - $ex.minY))
      $g2.Dispose()
    }
  }
  $bmp.Save($cur, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  return $ratio
}

# ---------------- understanding ----------------
function Get-ValidLen([string]$s) {
  $cjk = [regex]::Matches($s, '[\u4e00-\u9fff]').Count
  $alnum = [regex]::Matches($s, '[A-Za-z0-9]').Count
  return ($cjk + $alnum)
}

function Get-TextHash([string]$s) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($s)
  $hash = $sha.ComputeHash($bytes)
  return ([System.BitConverter]::ToString($hash)).Substring(0, 32)
}

# ---------------- LLM 答案缓存（持久化 + OCR 微抖动容错）----------------
# llm-cache.json：{hash, text, verdict, answers, ts} 数组，LRU 淘汰。
# 重启后仍去重（历史问题 8：缓存只在进程内）；OCR 微抖动导致哈希变化时，
# 用字符集 Jaccard 相似度 >= cacheSimilarity 的旧条目兜底，不再重复调 LLM。
$script:llmCache = @()
$script:cacheMax = 60
if ($cfg.llm.PSObject.Properties['cacheMax']) { $script:cacheMax = [int]$cfg.llm.cacheMax }

function Load-LlmCache {
  $script:llmCache = @()
  if (-not (Test-Path $cachePath)) { return }
  try {
    $arr = Get-Content $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($e in @($arr)) {
      if ($e -and $e.hash -and $e.verdict) {
        $script:llmCache += @{ hash = [string]$e.hash; text = [string]$e.text; verdict = [string]$e.verdict; answers = @($e.answers); ts = [string]$e.ts }
      }
    }
    if ($script:llmCache.Count -gt $script:cacheMax) { $script:llmCache = @($script:llmCache | Select-Object -Last $script:cacheMax) }
  } catch { Log "cache load error: $($_.Exception.Message)" }
}

function Save-LlmCache {
  try {
    if ($script:llmCache.Count -gt $script:cacheMax) { $script:llmCache = @($script:llmCache | Select-Object -Last $script:cacheMax) }
    [System.IO.File]::WriteAllText($cachePath, ($script:llmCache | ConvertTo-Json -Compress -Depth 6), $utf8)
  } catch { Log "cache save error: $($_.Exception.Message)" }
}

function Get-TextSimilarity([string]$a, [string]$b) {
  if ([string]::IsNullOrEmpty($a) -or [string]::IsNullOrEmpty($b)) { return 0.0 }
  # 字符集合 Jaccard：个别字 OCR 错/多/少不影响命中，不同页面差异大不会误命中
  $setA = @{}
  foreach ($ch in $a.ToCharArray()) { $setA[$ch] = $true }
  $inter = 0
  foreach ($k in $setA.Keys) { if ($b.IndexOf($k) -ge 0) { $inter++ } }
  $union = $setA.Count
  foreach ($ch in $b.ToCharArray()) { if (-not $setA.ContainsKey($ch)) { $union++ } }
  if ($union -eq 0) { return 0.0 }
  return ([double]$inter / $union)
}

function Find-CachedAnswer([string]$text, [string]$hash, [double]$threshold) {
  foreach ($e in $script:llmCache) {
    if ($e.hash -eq $hash) { return @{ entry = $e; fuzzy = $false } }
  }
  if ($threshold -le 0) { return $null }   # 0/负值 = 关闭模糊匹配（仅精确哈希）
  $best = $null; $bestScore = $threshold
  foreach ($e in $script:llmCache) {
    if (-not $e.text) { continue }
    $score = Get-TextSimilarity $text $e.text
    if ($score -ge $bestScore) { $bestScore = $score; $best = $e }
  }
  if ($best) { return @{ entry = $best; fuzzy = $true; score = $bestScore } }
  return $null
}

# 自检（-SelfTest）：验证缓存读写/相似度/查找逻辑，不碰屏幕不碰网络。
# 使用临时缓存文件，不动真实 llm-cache.json；结果写 selftest.txt 后退出。
if ($SelfTest) {
  $realCachePath = $cachePath
  $cachePath = Join-Path $env:TEMP ('llm-cache-selftest-' + $PID + '.json')
  $t1 = @('1. 下列哪项属于光的反射？ A. 小孔成像 B. 水中倒影 C. 日食 D. 月食', '2. 声音在下列哪种介质中传播速度最快？ A. 空气 B. 水 C. 钢铁 D. 真空', '3. 光的折射现象是？ A. 海市蜃楼 B. 平面镜成像 C. 小孔成像 D. 影子形成', '4. 下列属于可再生能源的是？ A. 煤炭 B. 石油 C. 太阳能 D. 天然气') -join "`n"
  $t2 = ($t1 -replace '倒影', '例影' -replace '太阳能', '太阳熊')   # 2 处 OCR 微抖动（模拟真实屏幕）
  $t3 = '完全不同的另一道题：计算机网络中最基本的拓扑结构是？ A 星型 B 总线 C 环形 D 网状'
  $s12 = Get-TextSimilarity $t1 $t2
  $s13 = Get-TextSimilarity $t1 $t3
  $h = Get-TextHash $t1
  $script:llmCache = @(
    @{ hash = $h; text = $t1; verdict = '【LLM 答案】' + "`n" + '第 1 题: B — 水中倒影是镜面反射'; answers = @(@{no = 1; answer = 'B'; reason = '镜面反射'}); ts = '00:00:00' }
  )
  Save-LlmCache
  $script:llmCache = @()
  Load-LlmCache
  $hit1 = Find-CachedAnswer $t1 $h 0.94
  $hit2 = Find-CachedAnswer $t2 (Get-TextHash $t2) 0.94
  $hit3 = Find-CachedAnswer $t3 (Get-TextHash $t3) 0.94
  $exact = ($hit1 -and -not $hit1.fuzzy)
  $fuzzy = ($hit2 -and $hit2.fuzzy)
  $miss  = (-not $hit3)
  $reload = ($script:llmCache.Count -eq 1 -and $script:llmCache[0].hash -eq $h -and $script:llmCache[0].answers.Count -eq 1)
  $msg = "sim12=$s12 sim13=$s13 exact=$exact fuzzy=$fuzzy miss=$miss reload=$reload"
  [System.IO.File]::WriteAllText((Join-Path $dir 'selftest.txt'), $msg + "`r`n", $utf8)
  Remove-Item $cachePath -Force -ErrorAction SilentlyContinue
  $cachePath = $realCachePath
  Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
  exit 0
}

function Get-HeuristicAnalysis([string]$text) {
  $lines = $text -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
  $q = @(); $o = @()
  $curQ = -1
  foreach ($ln in $lines) {
    # 选项：字母+分隔符+内容，内容须含 >=2 个有效字符（过滤 "G)"、"×" 等标签栏噪音）
    if ($ln -match '^([A-Ha-h])[\.、．\)·，,]\s*(.+)$') {
      $content = $matches[2].Trim() -replace '^[×xX*·\s]+', ''
      if ((Get-ValidLen $content) -ge 2) { $o += @{ letter = $matches[1].ToUpper(); text = $content; qIdx = $curQ } }
      continue
    }
    # 题目：题号从 1 起（排除 0，避免把 "0 25℃" 这类标签栏文字当题号），内容 >=2 有效字符
    if ($ln -match '^([1-9]\d{0,2})[\.、．\)·，,]\s*(.+)$') {
      $content = $matches[2].Trim()
      if ((Get-ValidLen $content) -ge 2) { $q += $ln; $curQ = $q.Count - 1 }
      continue
    }
    if ($ln -match '？|\?') { $q += $ln; if ($curQ -lt 0) { $curQ = $q.Count - 1 } }
  }
  # 答题场景置信度：题目>=1 且 选项>=2 才算答题界面，否则是一般界面摘要
  if ($q.Count -ge 1 -and $o.Count -ge 2) {
    # 按题统计选项数，定位不完整的题
    $perQ = @{}
    foreach ($opt in $o) { if ($opt.qIdx -ge 0) { $perQ[$opt.qIdx] = [int]$perQ[$opt.qIdx] + 1 } }
    $incomplete = @()
    for ($i = 0; $i -lt $q.Count; $i++) {
      $cnt = if ($perQ.ContainsKey($i)) { $perQ[$i] } else { 0 }
      if ($cnt -lt 2) {
        $qno = $i + 1
        if ($q[$i] -match '^(\d{1,3})') { $qno = [int]$matches[1] }
        $incomplete += $qno
      }
    }
    $optTexts = @($o | ForEach-Object { $_.letter + '. ' + $_.text })
    $verdict = '题目 ' + $q.Count + ' 条 / 选项 ' + $o.Count + ' 条'
    $verdict += "`n选项: " + (($optTexts | Select-Object -First 12) -join ' | ')
    $hint = ''
    if ($incomplete.Count -gt 0) { $hint = '提示: 第 ' + ($incomplete -join '、') + ' 题选项可能不完整（部分在屏幕外），滚动后自动补全' }
    if ($hint) { $verdict += "`n" + $hint }
    # coreText：纯题目+选项（无标签栏噪音），用于缓存比较（精确哈希 + 模糊匹配）
    $coreText = ((@($q) + @($o | ForEach-Object { $_.letter + ' ' + $_.text })) -join "`n")
    return @{ mode = 'quiz'; verdict = $verdict; hint = $hint; coreText = $coreText }
  }
  $sample = @($lines | Where-Object { (Get-ValidLen $_) -ge 2 } | Select-Object -First 4) -join ' / '
  if ($sample.Length -gt 160) { $sample = $sample.Substring(0, 160) + '…' }
  $verdict = '题目 ' + $q.Count + ' 条 / 选项 ' + $o.Count + ' 条（答题置信度不足）'
  $hint = ''
  if ($q.Count -ge 1 -and $o.Count -lt 2) { $hint = '提示: 疑似题目但选项不足（可能被屏幕截断），滚动后自动补全' }
  if ($hint) { $verdict += "`n" + $hint }
  if ($sample) { $verdict += "`n内容: " + $sample }
  return @{ mode = 'summary'; verdict = $verdict; hint = $hint; coreText = '' }
}

function Invoke-LlmUnderstanding([string]$text) {
  try {
    $sys = '你是屏幕答题助手。下面是从屏幕 OCR 提取的文本，可能包含多道题。请逐题作答。只输出 JSON（不要任何其他文字、不要 markdown 代码块），格式：{"answers":[{"no":1,"answer":"B","reason":"不超过20字"},{"no":2,"answer":"A","reason":"不超过20字"}]}'
    $body = @{
      model = $cfg.llm.model
      messages = @(
        @{ role = 'system'; content = $sys },
        @{ role = 'user'; content = $text }
      )
      temperature = 0.2
      max_tokens = 1200
    } | ConvertTo-Json -Depth 6

    # 用 HttpWebRequest 手动按 UTF-8 解码（PS5.1 的 Invoke-RestMethod 对无 charset 的响应会按 ISO-8859-1 解码导致中文乱码）
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $req = [System.Net.HttpWebRequest]::Create($cfg.llm.endpoint)
    $req.Method = 'POST'
    $req.ContentType = 'application/json; charset=utf-8'
    $req.Accept = 'application/json'
    $req.Headers['Authorization'] = 'Bearer ' + $cfg.llm.apiKey
    $req.Timeout = 40000
    $reqBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $reqStream = $req.GetRequestStream()
    $reqStream.Write($reqBytes, 0, $reqBytes.Length)
    $reqStream.Close()
    $resp = $req.GetResponse()
    $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
    $rawJson = $reader.ReadToEnd()
    $reader.Close(); $resp.Close()

    $obj = $rawJson | ConvertFrom-Json
    $content = $obj.choices[0].message.content
    $json = ($content -replace '```json|```', '').Trim()
    $answerObj = $json | ConvertFrom-Json
    $answers = @()
    foreach ($a in @($answerObj.answers)) {
      $answers += @{ no = $a.no; answer = $a.answer; reason = $a.reason }
    }
    $usage = $null
    if ($obj.usage) {
      $usage = @{ prompt = [int]$obj.usage.prompt_tokens; completion = [int]$obj.usage.completion_tokens }
    }
    $lines = @('【LLM 答案】')
    foreach ($a in $answers) { $lines += ('第 ' + $a.no + ' 题: ' + $a.answer + ' — ' + $a.reason) }
    return @{ mode = 'llm'; verdict = ($lines -join "`n"); answers = $answers; usage = $usage }
  } catch {
    Log "LLM error: $($_.Exception.Message)"
    return $null
  }
}

# ---------------- publish ----------------
$HTML_TEMPLATE = @'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta http-equiv="refresh" content="2">
<title>屏幕分析</title>
<style>
  :root { --bg: rgba(15, 17, 26, 0.92); --fg: #e8eaf2; --acc: #4f8cff; }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { background: var(--bg); color: var(--fg); font-family: "Segoe UI","Microsoft YaHei",system-ui,sans-serif;
         font-size: 14px; line-height: 1.6; padding: 18px 22px; max-height: 100vh; overflow: auto; }
  .banner { display: flex; align-items: center; gap: 10px; background: linear-gradient(90deg,#123,#1d4ed8);
            border: 1px solid #3b82f6; border-radius: 10px; padding: 10px 14px; margin-bottom: 14px;
            font-weight: 700; font-size: 16px; }
  .live { width: 12px; height: 12px; border-radius: 50%; background: #ff4d4f; box-shadow: 0 0 10px #ff4d4f; animation: blink 1s infinite; }
  @keyframes blink { 50% { opacity: 0.2; } }
  h2 { font-size: 13px; color: var(--acc); margin: 12px 0 5px; }
  .txt { background: rgba(255,255,255,0.06); border-radius: 8px; padding: 10px 12px; white-space: pre-wrap; word-break: break-word; }
  .anslist { display: flex; flex-direction: column; gap: 8px; }
  .note { font-size: 12px; color: #9aa3b8; margin-bottom: 8px; }
  .ansrow { display: flex; align-items: center; gap: 12px; padding: 7px 10px; background: rgba(255,255,255,0.06); border-radius: 8px; }
  .letter { font-size: 30px; font-weight: 800; color: #ffd166; min-width: 46px; text-align: center; background: rgba(255,209,102,0.14); border-radius: 8px; padding: 2px 0; }
  .reason { font-size: 13px; color: #c9d2e8; }
  footer { margin-top: 14px; color: #7c85a0; font-size: 12px; }
</style>
</head>
<body>
  <div class="banner"><span class="live"></span>__BANNER__</div>
  <h2>💬 结论</h2>
  <div class="txt" id="v">__VERDICT__</div>
  <h2>📄 屏幕内容</h2>
  <div class="txt" id="o">__OCR__</div>
  <footer>__FOOTER__</footer>
</body>
</html>
'@

function Publish-Analysis($state) {
  # 悬浮窗文本：只保留必要信息（模式/时间/结论），去掉技术噪音
  $modeLabel = switch ($state.mode) { 'quiz' { '答题场景' } 'llm' { 'LLM 答案' } 'summary' { '一般界面' } default { $state.mode } }
  $head = $modeLabel + ' · ' + $state.ts

  # ---- 成本统计（stats.json）：提前加载/更新，供悬浮窗与 Edge 页 footer 展示 ----
  $stats = $null
  if (Test-Path $statsPath) { try { $stats = Get-Content $statsPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }
  if (-not $stats) { $stats = @{ totalLlmCalls = 0; cachedHits = 0; fuzzyHits = 0; promptTokens = 0; completionTokens = 0; estCostUsd = 0.0; firstTs = $state.ts; lastTs = $state.ts } }
  # 旧版 stats.json 无 fuzzyHits 字段 → 补默认 0（避免升级后首次写文件丢失该字段）
  if ($stats -and -not $stats.PSObject.Properties['fuzzyHits']) { $stats | Add-Member -NotePropertyName fuzzyHits -NotePropertyValue 0 -Force }
  if ($state.usage) {
    $stats.totalLlmCalls = [int]$stats.totalLlmCalls + 1
    $stats.promptTokens = [int]$stats.promptTokens + [int]$state.usage.prompt
    $stats.completionTokens = [int]$stats.completionTokens + [int]$state.usage.completion
    $ppM = [double]$cfg.llmCost.promptPerM; $cpM = [double]$cfg.llmCost.completionPerM
    $stats.estCostUsd = [Math]::Round(([int]$stats.promptTokens / 1000000.0 * $ppM) + ([int]$stats.completionTokens / 1000000.0 * $cpM), 4)
    $stats.lastTs = $state.ts
  }
  if ($state.cached) {
    $stats.cachedHits = [int]$stats.cachedHits + 1
    if ($state.cacheFuzzy) { $stats.fuzzyHits = [int]$stats.fuzzyHits + 1 }
    $stats.lastTs = $state.ts
  }
  [System.IO.File]::WriteAllText($statsPath, ($stats | ConvertTo-Json), $utf8)
  $statsLine = 'LLM ' + [int]$stats.totalLlmCalls + ' 次 · 缓存命中 ' + [int]$stats.cachedHits + ' · Token ' + [int]$stats.promptTokens + '/' + [int]$stats.completionTokens + ' · 成本 ≈$' + [double]$stats.estCostUsd

  # LLM 答案用 [字母] 标记格式（WinForms RichTextBox 渲染大字母），其余纯文本
  # 答题结果保真：quiz/llm 结果保存，后续 summary 分析不覆盖悬浮窗上的答案
  if ($state.mode -eq 'llm' -and $state.answers) {
    $lines = @($head)
    foreach ($a in $state.answers) { $lines += ('{0}. [{1}] {2}' -f $a.no, $a.answer, $a.reason) }
    $txt = $lines -join "`r`n"
    $script:lastQuizVerdict = $state.verdict
    $script:lastQuizTs = $state.ts
    $script:lastQuizAnswers = $state.answers
  } elseif ($state.mode -eq 'quiz') {
    $txt = $head + "`r`n" + '━━━━━━━━━━━━━━━━' + "`r`n" + $state.verdict
    $script:lastQuizVerdict = $state.verdict
    $script:lastQuizTs = $state.ts
  } else {
    if ($script:lastQuizAnswers) {
      $lines = @($head, '━━━━━━━━━━━━━━━━', ('最近答题 · ' + $script:lastQuizTs + ':'), '')
      foreach ($a in $script:lastQuizAnswers) { $lines += ('{0}. [{1}] {2}' -f $a.no, $a.answer, $a.reason) }
      $txt = $lines -join "`r`n"
    } else {
      $txt = $head + "`r`n" + '━━━━━━━━━━━━━━━━' + "`r`n" + $state.verdict
    }
  }
  $txt += "`r`n" + '━━━━━━━━━━━━━━━━' + "`r`n" + '📊 ' + $statsLine
  [System.IO.File]::WriteAllText($overlayTxt, $txt, $utf8)

  # 屏幕内容摘录：只取前 6 行有效文本，控制长度
  $short = @($state.ocrText -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -First 6) -join "`n"
  if ($short.Length -gt 500) { $short = $short.Substring(0, 500) + '…' }

  $html = $HTML_TEMPLATE.Replace('__BANNER__', ('● LIVE · ' + $state.ts + ' · ' + $modeLabel))
  # LLM 答案：大字字母 + 理由（答案一眼可见）；summary 时保留最近答题
  $verdictHtml = ''
  if ($state.mode -eq 'llm' -and $state.answers) {
    $verdictHtml = '<div class="anslist">'
    foreach ($a in $state.answers) {
      $verdictHtml += '<div class="ansrow"><span class="letter">' + [System.Net.WebUtility]::HtmlEncode($a.answer) + '</span><span class="reason">' + ('第 {0} 题 · {1}' -f $a.no, [System.Net.WebUtility]::HtmlEncode($a.reason)) + '</span></div>'
    }
    $verdictHtml += '</div>'
    $script:lastQuizVerdict = $state.verdict
    $script:lastQuizTs = $state.ts
    $script:lastQuizAnswers = $state.answers
  } elseif ($state.mode -eq 'summary' -and $script:lastQuizAnswers) {
    $verdictHtml = '<div class="note">当前: 一般界面 · 保留最近答题</div><div class="anslist">'
    foreach ($a in $script:lastQuizAnswers) {
      $verdictHtml += '<div class="ansrow"><span class="letter">' + [System.Net.WebUtility]::HtmlEncode($a.answer) + '</span><span class="reason">' + ('第 {0} 题 · {1}' -f $a.no, [System.Net.WebUtility]::HtmlEncode($a.reason)) + '</span></div>'
    }
    $verdictHtml += '</div>'
  } else {
    $verdictHtml = [System.Net.WebUtility]::HtmlEncode($state.verdict)
  }
  $html = $html.Replace('__VERDICT__', $verdictHtml)
  $html = $html.Replace('__OCR__', [System.Net.WebUtility]::HtmlEncode($short))
  $html = $html.Replace('__FOOTER__', ('本地 OCR · 常驻服务 · 自动刷新 · ' + $statsLine))
  [System.IO.File]::WriteAllText($overlayHtml, $html, $utf8)

  $res = @{
    ts = $state.ts; cycle = $state.cycle; changed = $state.changed; ratio = $state.ratio
    mode = $state.mode; ocrLength = $state.ocrLen; verdict = $state.verdict; ocrText = $state.ocrText
  }
  if ($state.answers) { $res.answers = $state.answers }
  if ($state.cached) { $res.cached = $true }
  if ($state.cacheFuzzy) { $res.cacheFuzzy = $true }
  [System.IO.File]::WriteAllText($resultPath, ($res | ConvertTo-Json -Depth 5), $utf8)
  Log "analysis cycle=$($state.cycle) ratio=$($state.ratio) mode=$($state.mode) ocrLen=$($state.ocrLen)$(if ($state.cached) { ' cached' } else { '' })$(if ($state.cacheFuzzy) { ' fuzzy' } else { '' })"

  # ---- 结构化历史（JSONL）----
  $rec = @{
    ts = $state.ts; cycle = $state.cycle; mode = $state.mode; ratio = $state.ratio
    ocrLen = $state.ocrLen; cached = [bool]$state.cached; verdict = $state.verdict
  }
  if ($state.answers) { $rec.answers = $state.answers }
  if ($state.cacheFuzzy) { $rec.fuzzy = $true }
  if ($state.usage) { $rec.promptTokens = $state.usage.prompt; $rec.completionTokens = $state.usage.completion }
  [System.IO.File]::AppendAllText($jsonlPath, ($rec | ConvertTo-Json -Compress -Depth 5) + "`r`n")
}

# ---------------- optional one-time Edge tab ----------------
if ($cfg.openEdgeTab -and -not (Test-Path $firstRun)) {
  try {
    Start-Process 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe' -ArgumentList $overlayHtml
    [System.IO.File]::WriteAllText($firstRun, '1')
  } catch { Log "edge tab open failed: $($_.Exception.Message)" }
}

# ---------------- main loop ----------------
Log 'main loop start'
Load-LlmCache
Log "llm cache loaded: $($script:llmCache.Count) entries (max $script:cacheMax)"
$cycle = 0
$forceCounter = 0
$pendingChange = $false
$pendingSinceTicks = 0
$lastQuizVerdict = ''
$lastQuizTs = ''
$lastQuizAnswers = $null

while ($true) {
  if (Test-Path $stopFlag) { Log 'stop.flag found, exiting'; break }
  $cycle++
  $ts = Get-Date -Format 'HH:mm:ss'
  try {
    $ratio = Capture-And-Diff
    $changed = ($ratio -lt 0 -or $ratio -ge [double]$cfg.changeThreshold)
    $nowTicks = [DateTime]::UtcNow.Ticks

    # 防抖：变化发生后，等画面稳定 debounceSec 秒再分析（分析用户停留的最终帧）
    # 若画面持续变化（如活动标签自动刷新），最多 maxWaitSec 秒强制分析一次
    if ($changed) {
      $pendingChange = $true
      $pendingSinceTicks = $nowTicks
    }
    $elapsed = $nowTicks - $pendingSinceTicks
    $doOcr = $false
    if ($pendingChange) {
      $stableEnough = (-not $changed) -and ($elapsed -ge ([int]$cfg.debounceSec * 10000000))
      $tooLong = $elapsed -ge ([int]$cfg.maxWaitSec * 10000000)
      if ($stableEnough -or $tooLong) { $doOcr = $true; $pendingChange = $false }
    }
    $forceCounter++
    if ($forceCounter -ge [int]$cfg.forceAnalysisEvery) { $doOcr = $true; $forceCounter = 0; $pendingChange = $false }
    # 全局快捷键触发：存在 trigger 文件则立即分析（跳过防抖等待）
    if (Test-Path $triggerPath) {
      $doOcr = $true
      $pendingChange = $false
      try { Remove-Item $triggerPath -Force -ErrorAction SilentlyContinue } catch { }
    }

    $mode = 'idle'
    if ($doOcr) {
      $ocrText = Invoke-LocalOcr $cur
      if ($ocrText) {
        $clean = Get-CleanText $ocrText
        $analysis = Get-HeuristicAnalysis $clean
        # 仅答题场景才调 LLM；先查持久化缓存（精确哈希 + OCR 微抖动模糊匹配），命中不重复调用（省额度）
        if ($analysis.mode -eq 'quiz' -and $cfg.llm.enabled -and $cfg.llm.apiKey) {
          # 缓存键用 coreText（纯题目+选项），标签栏噪音不参与哈希/相似度，命中率更高
          $core = $analysis.coreText
          if (-not $core) { $core = $clean }
          $hash = Get-TextHash $core
          $cacheSim = [double]0.94
          if ($cfg.llm.PSObject.Properties['cacheSimilarity']) { $cacheSim = [double]$cfg.llm.cacheSimilarity }
          $hit = Find-CachedAnswer $core $hash $cacheSim
          if ($hit) {
            # 缓存存纯答案（不带滚动提示）；命中时按当前画面重新附加提示，保证题号提示最新
            $v = [string]$hit.entry.verdict
            if ($analysis.hint) { $v = $v + "`n" + $analysis.hint }
            $analysis = @{ mode = 'llm'; verdict = $v; answers = @($hit.entry.answers); cached = $true; hint = $analysis.hint; cacheFuzzy = $hit.fuzzy }
            # LRU：命中项移到队尾（精确命中不重写文件，模糊命中也不需要——内容未变）
            $script:llmCache = @(@($script:llmCache | Where-Object { $_ -ne $hit.entry }) + @($hit.entry))
          } else {
            $llm = Invoke-LlmUnderstanding $clean
            if ($llm) {
              # 保留滚动提示（LLM 答案后附加）；缓存只存纯答案
              $storeVerdict = $llm.verdict
              if ($analysis.hint) { $llm.verdict = $storeVerdict + "`n" + $analysis.hint }
              $analysis = $llm
              $script:llmCache += @{ hash = $hash; text = $core; verdict = $storeVerdict; answers = @($llm.answers); ts = $ts }
              Save-LlmCache
            }
          }
        }
        $state = @{
          ts = $ts; cycle = $cycle; changed = $changed; ratio = $ratio
          ocrText = $clean; ocrLen = $clean.Length; mode = $analysis.mode; verdict = $analysis.verdict
          answers = $analysis.answers; cached = $analysis.cached; usage = $analysis.usage
        }
        Publish-Analysis $state
        $mode = $analysis.mode
      } else {
        Log "ocr returned null cycle=$cycle"
      }
    }

    $status = @{ ts = $ts; cycle = $cycle; changed = $changed; ratio = $ratio; mode = $mode; pid = $PID } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($statusPath, $status, $utf8)
    [System.IO.File]::WriteAllText($hbPath, ('HEARTBEAT ' + $ts + ' | cycle ' + $cycle + ' | changed=' + $changed + ' | mode=' + $mode))
  } catch {
    Log ("loop error: " + $_.Exception.Message + " @line " + $_.InvocationInfo.ScriptLineNumber)
    try { [System.IO.File]::WriteAllText($hbPath, ('SERVICE ERROR: ' + $_.Exception.Message)) } catch { }
  }
  Start-Sleep -Seconds ([int]$cfg.intervalSec)
}
Log 'service exit'
