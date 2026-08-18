# ocr.ps1 - Local OCR via Windows.Media.Ocr (zero-install, offline).
# Usage: powershell -File ocr.ps1 -ImagePath <png> [-Lang zh-Hans-CN]
# Output: JSON with { text, lang, avgConf, minConf, lines:[{text,conf}] } to stdout (UTF-8).
param(
  [Parameter(Mandatory = $true)][string]$ImagePath,
  [string]$Lang = 'zh-Hans-CN'
)

$ErrorActionPreference = 'Stop'

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

try {
  $full = (Resolve-Path $ImagePath).Path
  $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($full)) ([Windows.Storage.StorageFile])
  $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
  $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
  $bitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])

  $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage([Windows.Globalization.Language]::new($Lang))
  if (-not $engine) { $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages() }
  if (-not $engine) { throw 'No OCR engine available' }

  $result = Await ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
  $stream.Dispose()

  $lines = @()
  $allWords = @()
  foreach ($line in $result.Lines) {
    $w = @($line.Words)
    $txt = ($w | ForEach-Object { $_.Text }) -join ' '
    $confs = @($w | ForEach-Object { [double]$_.Confidence })
    $conf = if ($confs.Count -gt 0) { [Math]::Round(($confs | Measure-Object -Average).Average, 3) } else { 0 }
    $lines += @{ text = $txt; conf = $conf }
    $allWords += $confs
  }
  $avg = if ($allWords.Count -gt 0) { [Math]::Round(($allWords | Measure-Object -Average).Average, 3) } else { 0 }
  $min = if ($allWords.Count -gt 0) { [Math]::Round(($allWords | Measure-Object -Minimum).Minimum, 3) } else { 0 }

  $out = @{
    ok       = $true
    lang     = $engine.RecognizerLanguage.LanguageTag
    text     = $result.Text
    avgConf  = $avg
    minConf  = $min
    lineCount = $result.Lines.Count
    lines    = $lines
  }
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  $out | ConvertTo-Json -Depth 4 -Compress
} catch {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  @{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
}
