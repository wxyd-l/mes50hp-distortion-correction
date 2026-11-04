param(
  [int]$MG  = 56,
  [int]$Rot = 0,
  [int]$K1Q = -2248147,
  [switch]$SkipVlog
)
$ErrorActionPreference = 'Continue'
$root = 'D:\AI\Project\Pango_Microsystems\frame_repair\distortion-correction\fix_16b'
Set-Location $root
$vs = 'D:/modelsim/modelsim_ase/win32aloem'
$env:HOME = Join-Path $root 'homeout'
if (-not (Test-Path $env:HOME)) { New-Item -ItemType Directory -Force -Path $env:HOME | Out-Null }
$env:TEMP = $env:HOME
$env:TMP  = $env:HOME
New-Item -ItemType Directory -Force -Path (Join-Path $root 'bisect') | Out-Null

$tag = "mg$MG-r$Rot"
$log = Join-Path $root "bisect/$tag.log"
$rtl = "bisect/rtl_$tag.txt"
$mdl = "bisect/model_$tag.txt"
"" | Out-File -FilePath $log -Encoding utf8

# 清掉上一轮遗留的 vsim（会继续写同一个 dump），等 license 释放
Get-Process vsim,vsimk -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 6
if (Test-Path $rtl) { Remove-Item $rtl -Force }
if (Test-Path $mdl) { Remove-Item $mdl -Force }

$gen = ((& node tools/m3_model.mjs --rot $Rot --emit) | Out-String).Trim()
"GEN: $gen" | Out-File -FilePath $log -Append -Encoding utf8

if (-not $SkipVlog) {
  & "$vs/vlog.exe" -quiet +incdir=rtl -work work rtl/ud_tile_core_m3.v rtl/tb_ud_bil_m3_dump.v *>&1 |
      Out-File -FilePath $log -Append -Encoding utf8
  if ($LASTEXITCODE -ne 0) { Write-Host "VLOG FAILED (see $log)"; exit 1 }
}

$vsimArgs = @('-c', "-gK1Q=$K1Q", '-gNT=8', "-gMG=$MG", "+DUMP=$rtl") + ($gen -split '\s+') + @('-do','run -all; quit -f','work.tb_ud_bil_m3_dump')
& "$vs/vsim.exe" @vsimArgs *>&1 | Out-File -FilePath $log -Append -Encoding utf8

$env:MG = "$MG"
$env:ROT = "$Rot"
& node tools/m3_model.mjs --k1q $K1Q --rot $Rot --out $mdl *>&1 | Out-Null
& node tools/compare.mjs $rtl $mdl *>&1 | Out-File -FilePath $log -Append -Encoding utf8

$dump = Select-String -Path $log -Pattern 'DUMPM3|DUMPFILE|Errors: |RTL X pixels' | ForEach-Object { $_.Line }
$c1   = Select-String -Path $log -Pattern 'unequal: ' | ForEach-Object { $_.Line }
$c1b  = Select-String -Path $log -Pattern 'max\|dR\|' | ForEach-Object { $_.Line }
$c2   = Select-String -Path $log -Pattern 'over_tol\(' | ForEach-Object { $_.Line }
Write-Host "=== $tag ==="
$dump; $c1; $c1b; $c2
