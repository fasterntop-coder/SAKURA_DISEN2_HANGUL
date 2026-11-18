# ReSONANCE 01.42 test PKG packager for GitHub Windows runner.
param([Parameter(Mandatory=$true)][string]$Eboot,
      [Parameter(Mandatory=$true)][string]$SdkRoot,
      [Parameter(Mandatory=$true)][string]$ResonanceSource,
      [string]$OutputDir='run13_pkg_output')
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$stage=Join-Path (Get-Location).Path 'run13_stage'
if (-not (Test-Path -LiteralPath $Eboot)) {throw 'Missing genuine PS4 eboot.bin'}
$tools=Join-Path $SdkRoot 'windows/openorbis/bin/windows'
$pkgTool=Join-Path $tools 'PkgTool.Core.exe'
$gp4Tool=Join-Path $tools 'create-gp4.exe'
$sample=Join-Path $SdkRoot 'windows/openorbis/samples/graphics'
foreach ($file in @($pkgTool,$gp4Tool,
 (Join-Path $sample 'sce_module/libc.prx'),
 (Join-Path $sample 'sce_module/libSceFios2.prx'),
 (Join-Path $ResonanceSource 'sce_sys/icon0.png'),
 (Join-Path $ResonanceSource 'sce_sys/pic1.png'),
 (Join-Path $ResonanceSource 'launcher-assets/launcher'))) {
 if (-not (Test-Path -LiteralPath $file)) {throw "Missing packaging dependency: $file"}
}
New-Item -ItemType Directory -Force $stage, (Join-Path $stage 'sce_sys'), (Join-Path $stage 'sce_module') | Out-Null
Copy-Item -LiteralPath $Eboot -Destination (Join-Path $stage 'eboot.bin')
Copy-Item -LiteralPath (Join-Path $ResonanceSource 'sce_sys/icon0.png') -Destination (Join-Path $stage 'sce_sys/icon0.png')
Copy-Item -LiteralPath (Join-Path $ResonanceSource 'sce_sys/pic1.png') -Destination (Join-Path $stage 'sce_sys/pic1.png')
Copy-Item -LiteralPath (Join-Path $sample 'sce_module/libc.prx') -Destination (Join-Path $stage 'sce_module/libc.prx')
Copy-Item -LiteralPath (Join-Path $sample 'sce_module/libSceFios2.prx') -Destination (Join-Path $stage 'sce_module/libSceFios2.prx')
Copy-Item -LiteralPath (Join-Path $ResonanceSource 'launcher-assets/launcher') -Destination $stage -Recurse
[IO.File]::WriteAllText((Join-Path $stage 'version.txt'), '01.42'+[Environment]::NewLine)
$cid='IV0000-DCST00001_00-DECASTS400000000'
Push-Location $stage
try {
 & $pkgTool sfo_new sce_sys/param.sfo
 if($LASTEXITCODE -ne 0) {throw "sfo_new failed ($LASTEXITCODE)"}
 $entries=@(
  @('APP_TYPE','Integer','4','1'), @('ATTRIBUTE','Integer','4','0x2'),
  @('CATEGORY','Utf8','4','gd'), @('SYSTEM_VER','Integer','4','0'),
  @('APP_VER','Utf8','8','01.42'), @('CONTENT_ID','Utf8','48',$cid),
  @('DOWNLOAD_DATA_SIZE','Integer','4','0'), @('TITLE','Utf8','128','Resonance'),
  @('TITLE_ID','Utf8','12','DCST00001'), @('VERSION','Utf8','8','01.42')
 )
 foreach($e in $entries) {
   & $pkgTool sfo_setentry sce_sys/param.sfo $e[0] --type $e[1] --maxsize $e[2] --value $e[3] | Out-Null
   if($LASTEXITCODE -ne 0) {throw "sfo_setentry failed ($($e[0]))"}
 }
 & $gp4Tool -out resonance-run13.gp4 "--content-id=$cid" --path .
 if($LASTEXITCODE -ne 0) {throw "create-gp4 failed ($LASTEXITCODE)"}
 & $pkgTool pkg_build resonance-run13.gp4 .
 if($LASTEXITCODE -ne 0) {throw "pkg_build failed ($LASTEXITCODE)"}
 $pkg=Join-Path $stage ($cid+'.pkg')
 if(-not (Test-Path -LiteralPath $pkg)) {throw "PKG not created at $pkg"}
 & $pkgTool pkg_validate $pkg
 if($LASTEXITCODE -ne 0) {throw "pkg_validate failed ($LASTEXITCODE)"}
} finally {Pop-Location}
New-Item -ItemType Directory -Force $OutputDir | Out-Null
$out=Join-Path $OutputDir 'Resonance-v01.42-OFFLINE-BIOS-TEST.pkg'
Copy-Item -LiteralPath $pkg -Destination $out
(Get-FileHash -Algorithm SHA256 $out).Hash | Out-File -FilePath (Join-Path $OutputDir 'SHA256.txt') -Encoding utf8
'PKG_CREATED_UNTESTED_PS4_HARDWARE (network shares, online cover/updates disabled)' | Set-Content -Path (Join-Path $OutputDir 'BUILD_STATUS.txt')
Write-Host "PKG_CREATED_UNTESTED: $out"
