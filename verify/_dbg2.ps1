param(
  [int]$MG = 8, [int]$Rot = 0, [int]$Tilt = 0, [int]$Roll = 0, [int]$Pitch = 0,
  [int]$K1Q = -2248147, [int]$LATF = 29
)
$ErrorActionPreference = 'Continue'
$root = 'D:\AI\Project\Pango_Microsystems\frame_repair\distortion-correction\fix_16b'
Set-Location $root
$vs = 'D:/modelsim/modelsim_ase/win32aloem'
$env:HOME = Join-Path $root 'homeout'
$env:TEMP = $env:HOME
$env:TMP  = $env:HOME
$tag = "dbg2-r$Rot-t$Tilt-p$Pitch"
$log = Join-Path $root "bisect/$tag.log"
$rtl = "bisect/rtl_$tag.txt"
'' | Out-File -FilePath $log -Encoding utf8
Get-Process vsim,vsimk -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 6
if (Test-Path $rtl) { Remove-Item $rtl -Force }
$gen = ((& node tools/m3_model.mjs --rot $Rot --tilt $Tilt --roll $Roll --pitch $Pitch --emit4) | Out-String).Trim()
"GEN: $gen" | Out-File -FilePath $log -Append -Encoding utf8
$srcs = @('rtl/dm_mapper.v','rtl/ud_persp_front.v','rtl/ud_coord_gen_dm_norm.v','rtl/ud_win_tab.v','rtl/ud_tile_core_m4.v','rtl/ud_tile_sched.v','rtl/ud_ddr_row_rd.v','rtl/tb_ud_bil_m4_dump.v')
& "$vs/vlog.exe" -quiet +define+DBG2 +incdir=rtl -work work @srcs *>&1 | Out-File -FilePath $log -Append -Encoding utf8
if ($LASTEXITCODE -ne 0) { Write-Host 'VLOG FAILED (see log)'; exit 1 }
& node tools/m3_model.mjs --k1q $K1Q --rot $Rot --tilt $Tilt --roll $Roll --pitch $Pitch --emit-tab wintab *>&1 | Out-File -FilePath $log -Append -Encoding utf8
$vsimArgs = @('-c', "-gK1Q=$K1Q", '-gNT=8', "-gMG=$MG", "-gLATF=$LATF", "+DUMP=$rtl") + ($gen -split '\s+') + @('-do','run -all; quit -f','work.tb_ud_bil_m4_dump')
& "$vs/vsim.exe" @vsimArgs *>&1 | Out-File -FilePath $log -Append -Encoding utf8
Write-Host "=== $tag ==="
Select-String -Path $log -Pattern 'DUMPM4|Errors: ' | ForEach-Object { $_.Line }
(Select-String -Path $log -Pattern '^# RSUM' | Measure-Object).Count | ForEach-Object { "RSUM lines: $_" }
