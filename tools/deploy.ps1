<#
.SYNOPSIS
  Copies E-INK HACK to the connected Kindle, verifying every file by hash.

.DESCRIPTION
  Finds the Kindle drive on its own (looking for one that has a "documents"
  folder), copies everything the app needs, and compares the MD5 of each file
  after copying.

  Copies both runner+model pairs:
    fp32  -> llama      + stories15M.bin     (the faster one on the KT4)
    Q8_0  -> llama-q8   + stories15M_q80.bin (smaller; force it via chat.conf)

  If one of them does not exist on the PC, it copies what it can and says so.

.EXAMPLE
  .\tools\deploy.ps1
  .\tools\deploy.ps1 -Eject
  .\tools\deploy.ps1 -Drive E:\
#>
[CmdletBinding()]
param(
    [string]$Drive,
    [switch]$Eject
)

$ErrorActionPreference = 'Stop'

$Root = Split-Path $PSScriptRoot -Parent

# --- find the Kindle ---------------------------------------------------------

function Find-Kindle {
    param([string]$Forced)
    if ($Forced) {
        if (-not (Test-Path (Join-Path $Forced 'documents'))) {
            throw "$Forced has no 'documents' folder - does not look like a Kindle"
        }
        return $Forced
    }
    $found = @()
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if (Test-Path (Join-Path $d.Root 'documents') -ErrorAction SilentlyContinue) {
            $found += $d.Root
        }
    }
    if ($found.Count -eq 0) { throw 'Kindle not found. Connect the cable and unlock the screen.' }
    if ($found.Count -gt 1)  { throw "more than one drive has 'documents': $($found -join ', '). Use -Drive." }
    return $found[0]
}

$K = Find-Kindle $Drive
Write-Host ''
Write-Host "  Kindle: " -NoNewline; Write-Host $K -ForegroundColor Cyan

$App = Join-Path $K 'extensions\kindlechat'
New-Item -ItemType Directory -Force -Path $App, (Join-Path $App 'model') | Out-Null

# --- what to copy ------------------------------------------------------------

$map = @(
    @{ From = 'chat.sh';                  To = (Join-Path $K 'documents\chat.sh');         Required = $true },
    @{ From = 'chat.conf';                To = (Join-Path $App 'chat.conf');               Required = $true },
    @{ From = 'out\llama';                To = (Join-Path $App 'llama');                   Required = $true },
    @{ From = 'vendor\tokenizer.bin';     To = (Join-Path $App 'model\tokenizer.bin');     Required = $true },
    @{ From = 'model\stories15M.bin';     To = (Join-Path $App 'model\stories15M.bin');     Required = $true },
    @{ From = 'out\llama-q8';             To = (Join-Path $App 'llama-q8');                 Required = $false },
    @{ From = 'model\stories15M_q80.bin'; To = (Join-Path $App 'model\stories15M_q80.bin'); Required = $false },
    # llama.cpp runtime, which is what turns this into a chat that answers
    @{ From = 'out\llama-completion';     To = (Join-Path $App 'llama-completion');         Required = $false }
)

# Any quantized instruct model. Not committed (too large); see tools/fetch.sh.
foreach ($g in (Get-ChildItem (Join-Path $Root 'model') -Filter '*.gguf' -ErrorAction SilentlyContinue)) {
    $map += @{ From = "model\$($g.Name)"; To = (Join-Path $App "model\$($g.Name)"); Required = $false }
}

Write-Host ''
$problems = 0
foreach ($m in $map) {
    $source = Join-Path $Root $m.From
    if (-not (Test-Path $source)) {
        if ($m.Required) {
            Write-Host ("  MISSING {0}  (required)" -f $m.From) -ForegroundColor Red
            $problems++
        } else {
            Write-Host ("  skipping {0}  (optional, not built)" -f $m.From) -ForegroundColor DarkGray
        }
        continue
    }

    $kb = [math]::Round((Get-Item $source).Length / 1KB)
    Write-Host ("  {0,-26} {1,9:N0} KB ... " -f $m.From, $kb) -NoNewline
    Copy-Item -LiteralPath $source -Destination $m.To -Force

    if ((Get-FileHash $source -Algorithm MD5).Hash -ne (Get-FileHash $m.To -Algorithm MD5).Hash) {
        Write-Host 'HASH MISMATCH' -ForegroundColor Red
        $problems++
    } else {
        Write-Host 'ok'
    }
}

if ($problems -gt 0) {
    Write-Host ''
    throw "$problems problem(s) while copying - nothing was ejected"
}

# --- the KOReader plugin -----------------------------------------------------

$PluginSrc = Join-Path (Split-Path $Root -Parent) 'kindlechat.koplugin'
$PluginsDir = Join-Path $K 'koreader\plugins'
$PluginDst = Join-Path $PluginsDir 'kindlechat.koplugin'

if (Test-Path $PluginSrc) {
    Write-Host ''
    Write-Host '  --- KOReader plugin ---'

    if (-not (Test-Path $PluginsDir)) {
        Write-Host '  no koreader/plugins on the device - skipping the plugin' -ForegroundColor Yellow
    }
    else {
        # tests/ is development-only; keep the deployed plugin clean.
        $pluginFiles = Get-ChildItem $PluginSrc -Recurse -File |
            Where-Object { $_.FullName -notmatch '\\tests\\' }

        foreach ($f in $pluginFiles) {
            $rel = $f.FullName.Substring($PluginSrc.Length + 1)
            $dest = Join-Path $PluginDst $rel
            New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null

            Write-Host ("  {0,-26} ... " -f $rel) -NoNewline
            Copy-Item -LiteralPath $f.FullName -Destination $dest -Force

            if ((Get-FileHash $f.FullName -Algorithm MD5).Hash -ne (Get-FileHash $dest -Algorithm MD5).Hash) {
                Write-Host 'HASH MISMATCH' -ForegroundColor Red
                $problems++
            } else {
                Write-Host 'ok'
            }
        }
    }
}

# --- final state -------------------------------------------------------------

Write-Host ''
Write-Host '  --- on the Kindle ---'
Get-ChildItem $App -Recurse -File | Sort-Object FullName | ForEach-Object {
    Write-Host ("  {0,-46} {1,11:N0}" -f $_.FullName.Replace($K, ''), $_.Length)
}
Write-Host ("  {0,-46} {1,11:N0}" -f 'documents\chat.sh', (Get-Item (Join-Path $K 'documents\chat.sh')).Length)

$hasFp32 = (Test-Path (Join-Path $App 'llama')) -and (Test-Path (Join-Path $App 'model\stories15M.bin'))
$hasQ8   = (Test-Path (Join-Path $App 'llama-q8')) -and (Test-Path (Join-Path $App 'model\stories15M_q80.bin'))
$ggufs   = @(Get-ChildItem (Join-Path $App 'model') -Filter '*.gguf' -ErrorAction SilentlyContinue)
$hasChat = (Test-Path (Join-Path $App 'llama-completion')) -and $ggufs.Count -gt 0
$hasPlugin = Test-Path (Join-Path $PluginDst 'main.lua')
Write-Host ''
Write-Host ("  fp32 pair (story mode)      : {0}" -f $hasFp32)
Write-Host ("  Q8 pair   (optional)        : {0}" -f $hasQ8)
Write-Host ("  chat mode (llama-completion): {0}" -f $hasChat)
if ($hasChat) {
    Write-Host ("    model: {0} ({1:N0} MB)" -f $ggufs[0].Name, ($ggufs[0].Length / 1MB))
}
Write-Host ("  KOReader plugin             : {0}" -f $hasPlugin)
if ($hasPlugin) {
    Write-Host ''
    Write-Host '  Restart KOReader, then: Tools -> E-INK HACK' -ForegroundColor Cyan
}

# --- eject -------------------------------------------------------------------

if ($Eject) {
    Write-Host ''
    Write-Host '  ejecting...' -NoNewline
    try {
        $shell = New-Object -ComObject Shell.Application
        $item = $shell.Namespace(17).ParseName($K)
        if ($item) { $item.InvokeVerb('Eject') }
    } catch { }
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 1
        if (-not (Test-Path $K)) { break }
    }
    if (Test-Path $K) {
        Write-Host ' still mounted'
        Write-Host '  eject it manually from the Windows tray icon' -ForegroundColor Yellow
    } else {
        Write-Host " removed (${i}s)" -ForegroundColor Green
    }
} else {
    Write-Host ''
    Write-Host '  Eject before unplugging (or run again with -Eject).' -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'RESULT: copy verified' -ForegroundColor Green
