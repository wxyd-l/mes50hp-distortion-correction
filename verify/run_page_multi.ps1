param([switch]$SkipVlog, [string]$Defs = '')
# run_page_multi.ps1 -- 验收 #7：多帧连续 + M4 落后一帧的页所有权检查
#   -Defs '+define+INJECT_TEAR'  → 负向自检（故意撞页，必须 FAIL）
$ErrorActionPreference = 'Continue'
$root = 'D:\AI\Project\Pango_Microsystems\frame_repair\distortion-correction\fix_16b'
Set-Location $root
$vs = 'D:/modelsim/modelsim_ase/win32aloem'
$env:HOME = Join-Path $root 'homeout'
if (-not (Test-Path $env:HOME)) { New-Item -ItemType Directory -Force -Path $env:HOME | Out-Null }
$env:TEMP = $env:HOME; $env:TMP = $env:HOME
$log = Join-Path $root 'bisect/page_multi.log'
'' | Out-File -FilePath $log -Encoding utf8
Get-Process vsim,vsimk -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
if (-not $SkipVlog) {
  & "$vs/vlog.exe" -quiet $Defs -work work ../install/rtl_m4/ud_page_sched.v rtl/tb_page_multi.v *>&1 | Out-File -FilePath $log -Append -Encoding utf8
  if ($LASTEXITCODE -ne 0) { Write-Host 'VLOG FAILED (see bisect/page_multi.log)'; exit 1 }
}
& "$vs/vsim.exe" -c -do 'run -all; quit -f' work.tb_page_multi *>&1 | Out-File -FilePath $log -Append -Encoding utf8
Write-Host "=== tb_page_multi  defs='$Defs' ==="
Select-String -Path $log -Pattern 'PAGEMULTI|cam_frames=|page_ok_violations|Error:|Fatal' | ForEach-Object { $_.Line.Trim() }
