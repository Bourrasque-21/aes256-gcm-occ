param(
    [string]$VivadoBin
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$coreRoot = Split-Path -Parent $scriptDir
$work = Join-Path ([System.IO.Path]::GetTempPath()) `
    'aes256-gcm-parallel-core\gcm-engine-test'
New-Item -ItemType Directory -Path $work -Force | Out-Null

if (-not $VivadoBin) {
    $candidates = @(
        'E:\AMDDesignTools\2025.2\Vivado\bin',
        'D:\2025.2\Vivado\bin',
        'C:\Xilinx\Vivado\2025.2\bin'
    )
    foreach ($candidate in $candidates) {
        if (Test-Path (Join-Path $candidate 'xvlog.bat')) {
            $VivadoBin = $candidate
            break
        }
    }
}

if (-not $VivadoBin) {
    throw 'Vivado tools not found. Pass -VivadoBin <Vivado-bin-folder>.'
}

$rtl = Join-Path $coreRoot 'rtl'
$sources = @(
    'aes_pkg.sv',
    'gcm_packet_pkg.sv',
    'aes_sbox.sv',
    'aes_subbytes.sv',
    'aes_shiftrows.sv',
    'aes_mixcolumns.sv',
    'aes_addroundkey.sv',
    'aes_round.sv',
    'aes256_core.sv',
    'gf128_mult_8bit_seq.sv',
    'ghash_engine_seq.sv',
    'gcm_tx_engine.sv',
    'gcm_rx_engine.sv',
    'authenticated_packet_buffer.sv'
) | ForEach-Object { (Join-Path $rtl $_) -replace '\\', '/' }
$sources += (Join-Path $coreRoot 'tb\tb_gcm_engines.sv') -replace '\\', '/'

Push-Location $work
try {
    & (Join-Path $VivadoBin 'xvlog.bat') -sv @sources
    if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }

    & (Join-Path $VivadoBin 'xelab.bat') tb_gcm_engines `
        -timescale 1ns/1ps -s gcm_engine_sim
    if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }

    & (Join-Path $VivadoBin 'xsim.bat') gcm_engine_sim -runall 2>&1 |
        Tee-Object -FilePath 'sim.log'
    if ($LASTEXITCODE -ne 0) { throw 'xsim failed' }
    if (-not (Select-String -Path 'sim.log' `
        -SimpleMatch '[TB][PASS] GCM TX/RX core engine test' -Quiet)) {
        throw "GCM engine test failed - see $work\sim.log"
    }
} finally {
    Pop-Location
}

Write-Host "GCM engine test PASS ($work\sim.log)" -ForegroundColor Green
