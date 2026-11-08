# 生成正式版演示视频的旁白音频（System.Speech），并输出每句时长清单。
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Speech

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$outDir = Join-Path $repoRoot 'docs/demo/narration'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$lines = @(
  'mooniso，纯 MoonBit 的 ISO 9660 光盘映像读写库。',
  '先从一个目录生成可启动映像，同时写入 BIOS 和 UEFI 启动项。',
  '读取卷信息，正确识别出 El Torito 启动目录。',
  '列出根目录，长文件名、中文名、空文件都能正确显示。',
  '同一张光盘的 UDF 视图，也能直接读取。',
  '导出文件，与源文件逐字节比对，完全一致。',
  '生成的映像被 Windows 原生挂载，独立实现读回的内容一致。',
  '四十七个测试，双后端全绿，读取侧与写入侧都经过独立实现对拍。'
)

$synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
$synth.SelectVoice('Microsoft Huihui Desktop')
$synth.Rate = -1

$manifest = @()
for ($i = 0; $i -lt $lines.Count; $i++) {
  $wav = Join-Path $outDir ("line{0:D2}.wav" -f $i)
  $synth.SetOutputToWaveFile($wav)
  $synth.Speak($lines[$i])
  $synth.SetOutputToNull()
  $dur = [math]::Round((New-Object System.IO.FileInfo($wav)).Length / 32000.0, 3)
  $manifest += [pscustomobject]@{ index = $i; text = $lines[$i]; wav = $wav; duration = $dur }
}

$manifest | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $outDir 'manifest.json')
$manifest | ForEach-Object { "{0} {1}s {2}" -f $_.index, $_.duration, $_.text }