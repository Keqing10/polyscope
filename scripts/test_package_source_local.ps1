# Local test script for source packaging
# Usage: .\scripts\test_package_source_local.ps1

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$outputRoot = Join-Path $repoRoot "build/package_test"
$tag = "test-tag"

Write-Host "=== Package Source with Deps Test ===" -ForegroundColor Cyan
Write-Host "Repo Root:   $repoRoot"
Write-Host "Output Root: $outputRoot"
Write-Host ""

if (-not (Test-Path $outputRoot)) {
    New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
}

$sourceDir = Join-Path $outputRoot "polyscope-$tag-source"
if (Test-Path $sourceDir) {
    Remove-Item -Recurse -Force $sourceDir
}
New-Item -ItemType Directory -Force -Path $sourceDir | Out-Null

Write-Host "Copying files to $sourceDir..." -ForegroundColor Yellow

# robocopy returns a code between 0 and 7 for success/partial success (1 means files were copied). => 8 is error.
robocopy "$repoRoot" "$sourceDir" /E /XD .git build dist .github examples example misc scripts test tests doc docs util bin images vcpkg-example
if ($LASTEXITCODE -ge 8) {
    throw "Robocopy failed with code $LASTEXITCODE"
}

$zipPath = Join-Path $outputRoot "polyscope-$tag-source-with-deps.zip"
if (Test-Path $zipPath) {
    Remove-Item -Force $zipPath
}

Write-Host "Compressing to $zipPath..." -ForegroundColor Yellow
Compress-Archive -Path "$sourceDir\*" -DestinationPath $zipPath -CompressionLevel Fastest

Write-Host "Done! Source zip location: $zipPath" -ForegroundColor Cyan
