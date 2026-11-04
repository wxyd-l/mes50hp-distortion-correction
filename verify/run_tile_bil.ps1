# run_tile_bil.ps1 -- one-click sim for the 16-bit bilinear tile core
# Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File verify/run_tile_bil.ps1
# Edit the two variables below to change test / generics.
$Tb    = 'tb_ud_bil'
$Vargs = '-gNT=8'          # use '-gK1Q=-2248147 -gNT=8' for the k1=-0.134 run

$ErrorActionPreference = 'Continue'
$vs   = 'D:/modelsim/modelsim_ase/win32aloem'
$root = Split-Path -Parent $PSScriptRoot
$env:HOME = Join-Path $root 'homeout'
New-Item -ItemType Directory -Force $env:HOME | Out-Null
$env:TEMP = $env:HOME; $env:TMP = $env:HOME
Set-Location $root
if (-not (Test-Path (Join-Path $root 'work'))) { & "$vs/vlib.exe" work | Out-Null }

$files = @('rtl/dm_mapper.v','rtl/ud_coord_gen_dm.v','rtl/ud_tile_sched.v',
           'rtl/ud_ddr_row_rd.v','rtl/ud_tile_core_bil.v', ('rtl/' + $Tb + '.v'))
$clog = Join-Path $root 'vlog_out.log'
& "$vs/vlog.exe" +incdir=rtl -work work $files 2>&1 | Out-File -Encoding ascii $clog
if ((Select-String -Path $clog -Pattern '^Errors: [1-9]').Count -gt 0) {
    Write-Host '*** VLOG FAILED ***'
    Select-String -Path $clog -Pattern 'Error' | Select-Object -First 10 | ForEach-Object { $_.Line }
    exit 1
}
Write-Host 'vlog ok'
$log = Join-Path $root 'sim_last.log'
& "$vs/vsim.exe" -c $Vargs.Split(' ') -do 'run -all; quit -f' "work.$Tb" 2>&1 | Out-File -Encoding ascii $log
Select-String -Path $log -Pattern 'BIL|PASS|FAIL|vs ideal|TOL' | ForEach-Object { $_.Line }