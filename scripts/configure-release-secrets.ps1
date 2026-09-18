param([string]$Repository = 'OptimemEnding/MirrorBridge')
$ErrorActionPreference = 'Stop'
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'Install GitHub CLI and run gh auth login first.'
}
$project = Split-Path -Parent $PSScriptRoot
$propertiesFile = Join-Path $project 'android/key.properties'
if (-not (Test-Path -LiteralPath $propertiesFile)) {
    throw 'Missing android/key.properties. Configure the permanent release keystore first.'
}
# This helper accepts plain key=value properties, with forward slashes in paths.
$properties = @{}
foreach ($line in Get-Content -LiteralPath $propertiesFile) {
    if ($line -match '^\s*(storeFile|storePassword|keyAlias|keyPassword)\s*=(.*)$') {
        $properties[$Matches[1]] = $Matches[2].Trim()
    }
}
foreach ($name in @('storeFile','storePassword','keyAlias','keyPassword')) {
    if (-not $properties[$name]) { throw "Missing signing property: $name" }
}
$keystore = $properties.storeFile
if (-not [IO.Path]::IsPathRooted($keystore)) {
    $keystore = Join-Path (Join-Path $project 'android') $keystore
}
$values = [ordered]@{
    ANDROID_KEYSTORE_BASE64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($keystore))
    ANDROID_KEYSTORE_PASSWORD = $properties.storePassword
    ANDROID_KEY_ALIAS = $properties.keyAlias
    ANDROID_KEY_PASSWORD = $properties.keyPassword
}
foreach ($entry in $values.GetEnumerator()) {
    # stdin avoids putting secret values in command arguments or console output.
    $entry.Value | & gh secret set $entry.Key --repo $Repository
    if ($LASTEXITCODE -ne 0) { throw "Failed to configure $($entry.Key)" }
    Write-Output "Configured $($entry.Key)"
}
