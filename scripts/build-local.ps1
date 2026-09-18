param(
  [ValidateSet('all','normal','demo','arm64','check','native','doctor')][string]$Target='arm64',
  [string]$FlutterBin=$env:FLUTTER_BIN,
  [string]$AndroidSdk=$env:ANDROID_HOME,
  [string]$JavaHome=$env:JAVA_HOME
)
$ErrorActionPreference='Stop'
# Native stderr includes ordinary Java/Gradle diagnostics on Windows PowerShell.
$PSNativeCommandUseErrorActionPreference=$false
$project=Split-Path -Parent $PSScriptRoot
$workspace=$project
if (-not $FlutterBin -and $env:FLUTTER_ROOT) {$FlutterBin=Join-Path $env:FLUTTER_ROOT 'bin/flutter.bat'}
if (-not $FlutterBin) {
  $command=Get-Command flutter.bat -ErrorAction SilentlyContinue
  if ($command) {$FlutterBin=$command.Source}
}
while (-not $FlutterBin) {
  $candidate=Join-Path $workspace 'tools/flutter/bin/flutter.bat'
  if (Test-Path -LiteralPath $candidate -PathType Leaf) {$FlutterBin=$candidate;break}
  $parent=Split-Path -Parent $workspace
  if (-not $parent -or $parent -eq $workspace) {throw 'Set FLUTTER_BIN or -FlutterBin to Flutter bin/flutter.bat, or add Flutter to PATH.'}
  $workspace=$parent
}
if (-not (Test-Path -LiteralPath $FlutterBin -PathType Leaf)) {throw "Flutter not found: $FlutterBin"}
$flutter=(Resolve-Path -LiteralPath $FlutterBin).Path
$python=$null
foreach ($pythonName in @('python','python3')) {
  $pythonCommand=Get-Command $pythonName -ErrorAction SilentlyContinue
  if (-not $pythonCommand) {continue}
  & $pythonCommand.Source -c 'import sys; sys.exit(0 if sys.version_info.major == 3 else 1)' *> $null
  if ($LASTEXITCODE -eq 0) {$python=$pythonCommand.Source;break}
}
if (-not $python) {throw 'A working Python 3 interpreter is required for source and APK verification.'}
if (-not $AndroidSdk) {$AndroidSdk=$env:ANDROID_SDK_ROOT}
if (-not $AndroidSdk) {
  $toolRoot=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $flutter))
  foreach ($candidate in @((Join-Path $toolRoot 'android-sdk'),(Join-Path $env:LOCALAPPDATA 'Android/Sdk'))) {
    if (Test-Path -LiteralPath $candidate -PathType Container) {$AndroidSdk=$candidate;break}
  }
}
if (-not $JavaHome) {
  $command=Get-Command java.exe -ErrorAction SilentlyContinue
  if ($command) {$JavaHome=Split-Path -Parent (Split-Path -Parent $command.Source)}
}
if ($Target -notin @('check','doctor')) {
  if (-not $AndroidSdk -or -not (Test-Path (Join-Path $AndroidSdk 'platforms/android-36'))) {throw 'Set ANDROID_HOME or -AndroidSdk to an SDK containing platforms;android-36.'}
  if (-not $JavaHome -or -not (Test-Path (Join-Path $JavaHome 'bin/jlink.exe'))) {throw 'Set JAVA_HOME or -JavaHome to a full JDK (recommended: JDK 21).'}
}
if ($AndroidSdk) {$env:ANDROID_HOME=(Resolve-Path -LiteralPath $AndroidSdk).Path;$env:ANDROID_SDK_ROOT=$env:ANDROID_HOME}
if ($JavaHome) {$env:JAVA_HOME=(Resolve-Path -LiteralPath $JavaHome).Path;$env:Path="$env:JAVA_HOME/bin;$env:Path"}
# Some Windows JDKs fail to open AF_UNIX loopback pipes. A nonexistent socket
# directory makes the JDK fall back to TCP. Keep any caller-provided JVM options.
if ($env:JAVA_TOOL_OPTIONS -notmatch '-Djdk\.net\.unixdomain\.tmpdir=') {
  $socketFallback=Join-Path ([IO.Path]::GetTempPath()) ('mirrorbridge-socket-'+[guid]::NewGuid().ToString('N'))
  $env:JAVA_TOOL_OPTIONS=($env:JAVA_TOOL_OPTIONS+' -Djdk.net.unixdomain.tmpdir="'+$socketFallback+'"').Trim()
}
$out=Join-Path $project 'dist'
New-Item -ItemType Directory -Path $out -Force | Out-Null
Push-Location $project
try {
  if ($Target -eq 'doctor') {& $flutter doctor -v;exit $LASTEXITCODE}
  if ($Target -eq 'check') {
    & $flutter pub get
    if ($LASTEXITCODE -ne 0) {exit $LASTEXITCODE}
    & $python 'scripts/check_naming.py'
    if ($LASTEXITCODE -ne 0) {exit $LASTEXITCODE}
    & $python 'scripts/verify_sources.py'
    if ($LASTEXITCODE -ne 0) {exit $LASTEXITCODE}
    & $flutter analyze --no-pub
    if ($LASTEXITCODE -ne 0) {exit $LASTEXITCODE}
    & $flutter test --no-pub --reporter expanded --concurrency=1
    exit $LASTEXITCODE
  }
  if ($Target -eq 'native') {
    & $flutter pub get
    if ($LASTEXITCODE -ne 0) {exit $LASTEXITCODE}
    Push-Location (Join-Path $project 'android')
    try { & './gradlew.bat' ':app:testDebugUnitTest' '--console=plain'; $nativeExit=$LASTEXITCODE }
    finally { Pop-Location }
    exit $nativeExit
  }
  foreach($variant in @('normal','demo','arm64')) {
    if($Target -ne 'all' -and $Target -ne $variant){continue}
    $buildArgs=@('build','apk')
    if($variant -eq 'arm64'){$buildArgs+=@('--release','--target-platform','android-arm64')}else{$buildArgs+=@('--debug','--target-platform','android-x64')}
    if($variant -eq 'demo'){$buildArgs+='--dart-define=DEMO_MODE=true'}
    $log=Join-Path $out "final-$variant-build.log"
    & $flutter @buildArgs *> $log
    $code=$LASTEXITCODE
    Add-Content -LiteralPath $log -Value "`nEXIT_CODE=$code"
    if($code -ne 0){Get-Content $log -Tail 30;throw "$variant build failed: $code"}
    $artifact=if($variant -eq 'arm64'){'build/app/outputs/flutter-apk/app-release.apk'}else{'build/app/outputs/flutter-apk/app-debug.apk'}
    & $python 'scripts/inspect_apk.py' $artifact
    if ($LASTEXITCODE -ne 0) {throw "$variant APK inspection failed: $LASTEXITCODE"}
    $name=switch($variant){'normal'{'MirrorBridge-emulator.apk'}'demo'{'MirrorBridge-demo.apk'}'arm64'{'MirrorBridge-arm64.apk'}}
    Copy-Item -LiteralPath $artifact -Destination (Join-Path $out $name)
    Write-Output "$variant APK built: $name"
  }
} finally {Pop-Location}
