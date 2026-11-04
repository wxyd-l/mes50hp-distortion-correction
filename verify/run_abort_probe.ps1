param(
  [int]$Rot = 15, [int]$Tilt = 20, [int]$Pitch = 20, [int]$Roll = 0,
  [int]$K1Q = -2248147, [int]$MG = 8, [int]$LATF = 29, [int]$CLKP = 5
)
$ErrorActionPreference = 'Continue'
$root = 'D:\AI\Project\Pango_Microsystems\frame_repair\distortion-correction\fix_16b'
Set-Location $root
$vs = 'D:/modelsim/modelsim_ase/win32aloem'
$env:HOME = Join-Path $root 'homeout'
if (-not (Test-Path $env:HOME)) { New-Item -ItemType Directory -Force -Path $env:HOME | Out-Null }
$env:TEMP = $env:HOME
$env:TMP  = $env:HOME

Get-Process vsim,vsimk -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 4

& node tools/m3_model.mjs --k1q $K1Q --rot $Rot --tilt $Tilt --roll $Roll --pitch $Pitch --emit-tab wintab *>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'TAB GEN FAILED'; exit 1 }

$gen = ((& node tools/m3_model.mjs --rot $Rot --tilt $Tilt --roll $Roll --pitch $Pitch --emit4) | Out-String).Trim()
Write-Host "GEN: $gen"

& "$vs/vlog.exe" -quiet +incdir=rtl -work work rtl/dm_mapper.v rtl/ud_persp_front.v rtl/ud_coord_gen_dm_norm.v rtl/ud_win_tab.v rtl/ud_tile_core_m4.v rtl/ud_tile_sched.v rtl/ud_ddr_row_rd.v rtl/tb_abort_probe.v *>&1 | Out-String | Write-Host
if ($LASTEXITCODE -ne 0) { Write-Host 'VLOG FAILED'; exit 1 }

$vsimArgs = @('-c', "-gK1Q=$K1Q", '-gNT=8', "-gMG=$MG", "-gLATF=$LATF", "-gCLKP=$CLKP") + ($gen -split '\s+') + @('-do', 'run -all; quit -f', 'work.tb_abort_probe')
& "$vs/vsim.exe" @vsimArgs *>&1 | Out-String | Write-Host
