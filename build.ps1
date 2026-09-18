<#
.SYNOPSIS
  Builds llama2.c for the Kindle directly on Windows, with no WSL/Linux.

.DESCRIPTION
  Uses Zig as the cross-compiler (zig cc -target arm-linux-musleabihf), which
  produces a static ARMv7 hard-float binary -- exactly what the Kindle runs.
  No toolchain, no Docker, no WSL.

.EXAMPLE
  .\build.ps1
  .\build.ps1 -Src runq.c
  .\build.ps1 -DownloadZig
  .\build.ps1 -Target host
#>
[CmdletBinding()]
param(
    [ValidateSet('zig-arm', 'host')]
    [string]$Target = 'zig-arm',

    [ValidateSet('run.c', 'runq.c')]
    [string]$Src = 'run.c',

    [switch]$DownloadZig
)

$ErrorActionPreference = 'Stop'

$Root   = $PSScriptRoot
$Vendor = Join-Path $Root 'vendor'
$Out    = Join-Path $Root 'out'

$ArchFlags = if ($env:ARCH_FLAGS) { $env:ARCH_FLAGS -split '\s+' } else { @('-O3', '-funroll-loops') }

$OutName = switch ($Src) {
    'run.c'  { 'llama' }
    'runq.c' { 'llama-q8' }
    default  { [IO.Path]::GetFileNameWithoutExtension($Src) }
}

function Find-Zig {
    if ($env:ZIG -and (Test-Path $env:ZIG)) { return $env:ZIG }

    $cmd = Get-Command zig -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $bases = @(
        (Join-Path $env:LOCALAPPDATA 'kindle-zig'),
        (Join-Path $env:TEMP 'opencode\zig')
    )
    foreach ($base in $bases) {
        if (-not (Test-Path $base)) { continue }
        $found = Get-ChildItem -Path $base -Recurse -Filter 'zig.exe' -ErrorAction SilentlyContinue |
                 Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

function Install-Zig {
    Write-Host 'zig not found; downloading the stable release...' -ForegroundColor Yellow
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $index = Invoke-RestMethod 'https://ziglang.org/download/index.json'
    $stable = ($index.PSObject.Properties.Name | Where-Object { $_ -ne 'master' } | Select-Object -First 1)
    $url = $index.$stable.'x86_64-windows'.tarball
    Write-Host "  version $stable"
    Write-Host "  $url"

    $dest = Join-Path $env:LOCALAPPDATA 'kindle-zig'
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $zip = Join-Path $dest 'zig.zip'

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $prev = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $url -OutFile $zip
    } finally {
        $ProgressPreference = $prev
    }
    $sw.Stop()
    Write-Host ("  downloaded ({0:N1} MB in {1:N0}s)" -f ((Get-Item $zip).Length / 1MB), $sw.Elapsed.TotalSeconds)

    Write-Host '  extracting...'
    Expand-Archive -Path $zip -DestinationPath $dest -Force
    Remove-Item $zip -Force

    $zig = Get-ChildItem -Path $dest -Recurse -Filter 'zig.exe' | Select-Object -First 1
    if (-not $zig) { throw 'zig extraction failed' }
    return $zig.FullName
}

# --- validation --------------------------------------------------------------

$srcFile = Join-Path $Vendor $Src
if (-not (Test-Path $srcFile)) {
    throw "$srcFile does not exist. Run: sh tools/fetch.sh"
}

if (-not (Test-Path $Out)) { New-Item -ItemType Directory -Force -Path $Out | Out-Null }
$outFile = Join-Path $Out $OutName

Write-Host ''
Write-Host '  target: ' -NoNewline; Write-Host $Target -ForegroundColor Cyan
Write-Host '  source: ' -NoNewline; Write-Host "vendor\$Src"
Write-Host '  output: ' -NoNewline; Write-Host "out\$OutName"
Write-Host ''

# --- build -------------------------------------------------------------------

if ($Target -eq 'host') {
    $cc = Get-Command gcc, cc -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cc) { throw 'no C compiler on PATH (install one, or use -Target zig-arm)' }
    Write-Host "  compiler: $($cc.Source)"
    & $cc.Source @ArchFlags '-include' 'stdint.h' '-o' $outFile $srcFile '-lm'
    if ($LASTEXITCODE -ne 0) { throw "build failed (exit $LASTEXITCODE)" }
}
else {
    $zig = Find-Zig
    if (-not $zig) {
        if ($DownloadZig) {
            $zig = Install-Zig
        }
        else {
            throw @'
zig not found.

  .\build.ps1 -DownloadZig          downloads it automatically (~90 MB)
  winget install zig.zig            installs via winget
  choco install zig                 or via chocolatey

Or point at it manually:  $env:ZIG = 'C:\path\to\zig.exe'
'@
        }
    }

    & $zig version | Out-Null
    Write-Host "  compiler: $zig (zig $(& $zig version))"
    Write-Host "  target  : arm-linux-musleabihf (ARMv7 hard-float, static)"
    Write-Host ''

    & $zig cc -target arm-linux-musleabihf @ArchFlags '-include' 'stdint.h' `
        '-static' '-o' $outFile $srcFile '-lm'
    if ($LASTEXITCODE -ne 0) { throw "build failed (exit $LASTEXITCODE)" }
}

# --- result ------------------------------------------------------------------

$bin = Get-Item $outFile
Write-Host ''
Write-Host ("  built: {0}  ({1:N1} KB)" -f $bin.Name, ($bin.Length / 1KB)) -ForegroundColor Green

$py = Get-Command python, python3 -ErrorAction SilentlyContinue | Select-Object -First 1
$insp = Join-Path $Root 'tools\inspect-elf.py'
if ($Target -ne 'host' -and $py -and (Test-Path $insp)) {
    Write-Host ''
    & $py.Source $insp $outFile
}
