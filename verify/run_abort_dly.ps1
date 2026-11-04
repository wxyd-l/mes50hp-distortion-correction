param([string]$Angle = '15/20/20', [int]$DLY = 300)
$ErrorActionPreference = 'Continue'
$root = 'D:\AI\Project\Pango_Microsystems\frame_repair\distortion-correction\fix_16b'
Set-Location $root
$vs = 'D:/modelsim/modelsim_ase/win32aloem'
$env:HOME = Join-Path $root 'homeout'
if (-not (Test-Path $env:HOME)) { New-Item -ItemType Directory -Force -Path $env:HOME | Out-Null }
$env:TEMP = $env:HOME
$env:TMP  = $env:HOME
$K1Q = -2248147; $MG = 8; $LATF = 29; $CLKP = 5
$p = $Angle -split '/'
$Rot = [int]$p[0]; $Tilt = [int]$p[1]; $Pitch = [int]$p[2]

Get-Process vsim,vsimk -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 4

& node tools/m3_model.mjs --k1q $K1Q --rot $Rot --tilt $Tilt --roll 0 --pitch $Pitch --emit-tab wintab *>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'TAB GEN FAILED'; exit 1 }

& "$vs/vlog.exe" -quiet +incdir=rtl -work work rtl/dm_mapper.v rtl/ud_persp_front.v rtl/ud_coord_gen_dm_norm.v rtl/ud_win_tab.v rtl/ud_tile_core_m4.v rtl/ud_tile_sched.v rtl/ud_ddr_row_rd.v rtl/tb_abort_probe.v *>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'VLOG FAILED'; exit 1 }

$gen = ((& node tools/m3_model.mjs --rot $Rot --tilt $Tilt --roll 0 --pitch $Pitch --emit4) | Out-String).Trim()
$vsimArgs = @('-c', "-gK1Q=$K1Q", '-gNT=8', "-gMG=$MG", "-gLATF=$LATF", "-gCLKP=$CLKP", "-gDLY=$DLY") + ($gen -split '\s+') + @('-do', 'run -all; quit -f', 'work.tb_abort_probe')
Write-Host "=== ANGLE $Angle  DLY=$DLY ==="
(& "$vs/vsim.exe" @vsimArgs *>&1) | Select-String -Pattern 'PROBE|ABORT-BUSY|STALE|Fatal|Error' | ForEach-Object { $_.Line }
