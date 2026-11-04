param(
  [int]$Rot = 0, [int]$Tilt = 0, [int]$Pitch = 0, [int]$Roll = 0,
  [int]$K1Q = -2248147, [int]$MG = 8, [int]$LATF = 29, [int]$DLY = 12,
  [double]$CLKP = 10.0, [double]$DDRP = 11.9045, [switch]$SkipVlog
)
# run_wrback.ps1 -- P2: M4 -> write master -> DDR model -> read back by address, compare to golden.
# Expect: WRBACK ... holes=0 drop=0 perr=0 pagebad=0 werr=0  and  unequal: 0 / 921600
$ErrorActionPreference = 'Continue'
$root = 'D:\AI\Project\Pango_Microsystems\frame_repair\distortion-correction\fix_16b'
Set-Location $root
$vs = 'D:/modelsim/modelsim_ase/win32aloem'
$env:HOME = Join-Path $root 'homeout'
if (-not (Test-Path $env:HOME)) { New-Item -ItemType Directory -Force -Path $env:HOME | Out-Null }
$env:TEMP = $env:HOME
$env:TMP  = $env:HOME
New-Item -ItemType Directory -Force -Path (Join-Path $root 'bisect') | Out-Null

$tag = "wrback-r$Rot-t$Tilt-p$Pitch"
$log = Join-Path $root "bisect/$tag.log"
$rtl = "bisect/rtl_$tag.txt"
$mdl = "bisect/model_$tag.txt"
"" | Out-File -FilePath $log -Encoding utf8

Get-Process vsim,vsimk -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
if (Test-Path $rtl) { Remove-Item $rtl -Force }
if (Test-Path $mdl) { Remove-Item $mdl -Force }

$gen = ((& node tools/m3_model.mjs --rot $Rot --tilt $Tilt --roll $Roll --pitch $Pitch --emit4) | Out-String).Trim()
"GEN: $gen" | Out-File -FilePath $log -Append -Encoding utf8

if (-not $SkipVlog) {
  & "$vs/vlog.exe" -quiet +incdir=rtl -work work rtl/dm_mapper.v rtl/ud_persp_front.v rtl/ud_coord_gen_dm_norm.v rtl/ud_win_tab.v rtl/ud_row_rd_cdc.v rtl/ud_tile_core_m4.v rtl/ud_tile_sched.v rtl/ud_ddr_row_rd.v ..\install\rtl_m4\ud_axi_wr_master.v rtl/tb_m4_wrback.v *>&1 | Out-File -FilePath $log -Append -Encoding utf8
  if ($LASTEXITCODE -ne 0) { Write-Host 'VLOG FAILED (see log)'; exit 1 }
}

& node tools/m3_model.mjs --k1q $K1Q --rot $Rot --tilt $Tilt --roll $Roll --pitch $Pitch --emit-tab wintab *>&1 | Out-File -FilePath $log -Append -Encoding utf8
if ($LASTEXITCODE -ne 0) { Write-Host 'TAB GEN FAILED'; exit 1 }

$vsimArgs = @('-c', "-gK1Q=$K1Q", '-gNT=8', "-gMG=$MG", "-gLATF=$LATF", "-gDLY=$DLY", "-gCLKP=$CLKP", "-gDDRP=$DDRP", "+DUMP=$rtl") + ($gen -split '\s+') + @('-do','run -all; quit -f','work.tb_m4_wrback')
& "$vs/vsim.exe" @vsimArgs *>&1 | Out-File -FilePath $log -Append -Encoding utf8

$env:MG = "$MG"; $env:MAR = "$MG"
& node tools/m3_model.mjs --k1q $K1Q --rot $Rot --tilt $Tilt --roll $Roll --pitch $Pitch --out $mdl *>&1 | Out-Null
& node tools/compare.mjs $rtl $mdl *>&1 | Out-File -FilePath $log -Append -Encoding utf8

Write-Host "=== $tag ==="
Get-Content $log | Select-String -Pattern 'WRBACK|WATCHDOG|unequal:|Error:' | ForEach-Object { '   ' + $_.Line.Trim() }
