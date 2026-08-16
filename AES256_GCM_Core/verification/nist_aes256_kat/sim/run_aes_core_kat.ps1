# ---------------------------------------------------------------------------
# AES-256 ECB Known Answer Test (NIST AESAVS) - Vivado xsim launcher
#
#   .\run_aes_core_kat.ps1                    Run all 405 vectors
#   .\run_aes_core_kat.ps1 -DumpWave          Record WDB and open Vivado GUI
#   .\run_aes_core_kat.ps1 -DumpWave -MaxVectors 20
#   .\run_aes_core_kat.ps1 -VivadoBin "C:\Xilinx\Vivado\2020.2\bin"
#
# VCS and xsim share filelist.f.
# ---------------------------------------------------------------------------
param(
    [string]$VivadoBin,
    [switch]$DumpWave,
    [int]$MaxVectors = 0,     # 0 runs all 405 vectors
    [switch]$NoGui
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root      = Split-Path -Parent $scriptDir          # nist_aes256_kat/
$vectors   = Join-Path $root 'kat_vectors'

# Keep all xsim artifacts outside the source tree.
$work = Join-Path ([System.IO.Path]::GetTempPath()) 'aes256-gcm-parallel-core\aes-core-kat'
New-Item -ItemType Directory -Path $work -Force | Out-Null

# Prefer known Vivado 2025.2 installs, then fall back to PATH.
$vivado = $VivadoBin
if (-not $vivado) {
    $candidates = @(
        'E:\AMDDesignTools\2025.2\Vivado\bin',
        'D:\2025.2\Vivado\bin',
        'C:\Xilinx\Vivado\2025.2\bin'
    )
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c 'xvlog.bat')) { $vivado = $c; break }
    }
}
if (-not $vivado) {
    $xvlogCommand = Get-Command 'xvlog.bat', 'xvlog' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $xvlogCommand) {
        throw 'Vivado tools not found. Pass -VivadoBin <Vivado-bin-folder>.'
    }
    $vivado = Split-Path -Parent $xvlogCommand.Source
}

Push-Location $work
try {
    $verLine = (& (Join-Path $vivado 'xvlog.bat') --version 2>&1 |
        Select-Object -First 1)
} finally {
    Pop-Location
}
if ($verLine -notmatch '2025') {
    Write-Warning "Expected Vivado 2025.x: $verLine  ($vivado)"
}
Write-Host "simulator: $verLine  [$vivado]"

# Resolve filelist entries and ignore comment lines.
$filelist = Join-Path $root 'filelist.f'
$sources  = Get-Content $filelist |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -ne '' -and -not $_.StartsWith('//') -and -not $_.StartsWith('#') } |
    ForEach-Object { Join-Path $root ($_ -replace '^\./', '') }

# The TB opens vector filenames from its working directory.
Copy-Item (Join-Path $vectors '*.rsp') -Destination $work -Force

# Use an option file to avoid cmd wrapper parsing issues with NAME=value.
$xvlogOpts = @('-sv')
if ($DumpWave -and ($MaxVectors -ne 0)) {
    # Limit vectors only for short waveform runs.
    $xvlogOpts += "-d KAT_MAX_VECTORS=$MaxVectors"
}
$xvlogOpts += ($sources | ForEach-Object { $_ -replace '\\', '/' })
$xvlogOpts | Set-Content -Path (Join-Path $work 'xvlog_opts.f') -Encoding ascii

$xelabArgs = @('tb_aes256_core_kat', '-timescale', '1ns/1ps', '-s', 'aes_core_kat_sim')
if ($DumpWave) {
    # Enable signal probing for log_wave.
    $xelabArgs += @('-debug', 'typical')
}

Push-Location $work
try {
    & (Join-Path $vivado 'xvlog.bat') -f 'xvlog_opts.f'
    if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }

    & (Join-Path $vivado 'xelab.bat') @xelabArgs
    if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }

    if ($DumpWave) {
        # Start waveform logging before simulation.
        @(
            'log_wave -recursive *'
            'run all'
            'quit'
        ) | Set-Content -Path 'dump.tcl' -Encoding ascii

        & (Join-Path $vivado 'xsim.bat') aes_core_kat_sim `
            -tclbatch 'dump.tcl' -wdb 'aes_core_kat.wdb' 2>&1 |
            Tee-Object -FilePath 'sim.log'
    } else {
        & (Join-Path $vivado 'xsim.bat') aes_core_kat_sim -runall 2>&1 |
            Tee-Object -FilePath 'sim.log'
    }
    if ($LASTEXITCODE -ne 0) { throw 'xsim failed' }

    # Verify the verdict because some xsim versions return zero after $fatal.
    if (-not (Select-String -Path 'sim.log' -SimpleMatch 'RESULT     : PASS' -Quiet)) {
        throw "AES core KAT FAILED - see $work\sim.log"
    }
} finally {
    Pop-Location
}

$wdb = Join-Path $work 'aes_core_kat.wdb'
if ($DumpWave) {
    if ($MaxVectors -eq 0) {
        Write-Host "AES core KAT PASS - all 405 vectors" -ForegroundColor Green
    } else {
        Write-Host "AES core KAT PASS - limited to $MaxVectors vectors per file" -ForegroundColor Yellow
    }
    Write-Host "waveform : $wdb"
    if (-not $NoGui) {
        Write-Host "Opening the waveform in Vivado GUI..."
        Start-Process -FilePath (Join-Path $vivado 'xsim.bat') `
            -ArgumentList '--gui', $wdb -WorkingDirectory $work
    }
} else {
    Write-Host "AES core KAT PASS ($work\sim.log)" -ForegroundColor Green
}
