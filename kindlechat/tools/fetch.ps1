<#
.SYNOPSIS
  Downloads the project dependencies on Windows (llama2.c + the TinyStories 15M model).

.DESCRIPTION
  Equivalent to tools/fetch.sh, but without needing sh/WSL/Git Bash.
  Skips files that already exist (use -Force to download again).

  -Chat also fetches SmolLM2-135M-Instruct Q4_K_M (~101 MB), which is what makes
  the app answer questions instead of only continuing stories. It is opt-in
  because of the size.

.EXAMPLE
  .\fetch.ps1
  .\fetch.ps1 -Chat
  .\fetch.ps1 -Chat -Force
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$Chat
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root   = Split-Path $PSScriptRoot -Parent
$Vendor = Join-Path $Root 'vendor'
$Model  = Join-Path $Root 'model'

New-Item -ItemType Directory -Force -Path $Vendor, $Model | Out-Null

$Llama2c    = 'https://raw.githubusercontent.com/karpathy/llama2.c/master'
$TinyLlamas = 'https://huggingface.co/karpathy/tinyllamas/resolve/main'

$deps = @(
    @{ Url = "$Llama2c/run.c";             Dest = (Join-Path $Vendor 'run.c') },
    @{ Url = "$Llama2c/runq.c";            Dest = (Join-Path $Vendor 'runq.c') },
    @{ Url = "$Llama2c/tokenizer.bin";     Dest = (Join-Path $Vendor 'tokenizer.bin') },
    @{ Url = "$TinyLlamas/stories15M.bin"; Dest = (Join-Path $Model 'stories15M.bin') }
)

if ($Chat) {
    $deps += @{
        Url  = 'https://huggingface.co/bartowski/SmolLM2-135M-Instruct-GGUF/resolve/main/SmolLM2-135M-Instruct-Q4_K_M.gguf'
        Dest = (Join-Path $Model 'SmolLM2-135M-Instruct-Q4_K_M.gguf')
    }
}

foreach ($d in $deps) {
    $dest = $d.Dest
    $rel  = $dest.Substring($Root.Length + 1)

    if ((Test-Path $dest) -and -not $Force) {
        $kb = [math]::Round((Get-Item $dest).Length / 1KB)
        Write-Host ("  exists    {0,-24} ({1:N0} KB)" -f $rel, $kb)
        continue
    }

    $part = "$dest.part"
    Write-Host ("  download  {0}" -f $rel) -ForegroundColor Cyan

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $prev = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $d.Url -OutFile $part -UseBasicParsing
    }
    finally {
        $ProgressPreference = $prev
    }
    $sw.Stop()

    if ((Get-Item $part).Length -eq 0) { throw "empty download: $($d.Url)" }
    Move-Item -Force $part $dest

    $kb = [math]::Round((Get-Item $dest).Length / 1KB)
    Write-Host ("            ok  {0,-24} ({1:N0} KB in {2:N0}s)" -f $rel, $kb, $sw.Elapsed.TotalSeconds) -ForegroundColor Green
}

Write-Host ''
Write-Host '  --- contents ---'
Get-ChildItem $Vendor, $Model -File | ForEach-Object {
    Write-Host ("  {0,-24} {1,10:N0} bytes" -f $_.Name, $_.Length)
}
