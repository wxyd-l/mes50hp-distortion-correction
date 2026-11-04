# run_bit_exact.ps1 -- 一键逐位对拍（RTL dump -> Node 黄金模型 -> 三方比较）
# 替代原 Python 链 (run_dump.ps1 + tile_bil_model.py + compare.py)，本机无 Python。
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File verify/run_bit_exact.ps1 [-K1Q -2248147] [-NT 8]
param(
    [int]$K1Q = -2248147,
    [int]$NT  = 8
)
$ErrorActionPreference = 'Continue'
$vs   = 'D:/modelsim/modelsim_ase/win32aloem'
$root = Split-Path -Parent $PSScriptRoot
$env:HOME = Join-Path $root 'homeout'
New-Item -ItemType Directory -Force $env:HOME | Out-Null
$env:TEMP = $env:HOME; $env:TMP = $env:HOME
Set-Location $root
if (-not (Test-Path (Join-Path $root 'work'))) { & "$vs/vlib.exe" work | Out-Null }

$files = @('rtl/dm_mapper.v','rtl/ud_coord_gen_dm.v','rtl/ud_tile_sched.v',
           'rtl/ud_ddr_row_rd.v','rtl/ud_tile_core_bil.v','rtl/tb_ud_bil_dump.v')
$clog = Join-Path $root 'vlog_dump.log'
& "$vs/vlog.exe" +incdir=rtl -work work $files 2>&1 | Out-File -Encoding ascii $clog
if ((Select-String -Path $clog -Pattern '^Errors: [1-9]').Count -gt 0) {
    Write-Host '*** VLOG FAILED ***'
    Select-String -Path $clog -Pattern 'Error' | Select-Object -First 10 | ForEach-Object { $_.Line }
    exit 1
}
Write-Host 'vlog ok'

$log = Join-Path $root 'sim_dump.log'
& "$vs/vsim.exe" -c "-gK1Q=$K1Q" "-gNT=$NT" -do 'run -all; quit -f' work.tb_ud_bil_dump 2>&1 | Out-File -Encoding ascii $log
Select-String -Path $log -Pattern 'DUMP' | ForEach-Object { $_.Line }

Write-Host '--- golden model (node) ---'
node tools/tile_bil_model.mjs --k1q $K1Q --out model_dump.txt

Write-Host '--- compare (node) ---'
node tools/compare.mjs rtl_dump.txt model_dump.txt
