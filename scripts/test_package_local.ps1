# Local test script for package_dist.ps1
# Usage: .\test_package_local.ps1

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$buildRoot = Join-Path $repoRoot "build"
$outputRoot = Join-Path $repoRoot "build/package_test"
$tag = "test-tag"
$commitSha = "local-test"

Write-Host "=== Package Dist Test ===" -ForegroundColor Cyan
Write-Host "Repo Root:   $repoRoot"
Write-Host "Build Root:  $buildRoot"
Write-Host "Output Root: $outputRoot"
Write-Host ""

# Check if build directory exists
if (-not (Test-Path $buildRoot)) {
    Write-Host "Build directory not found: $buildRoot" -ForegroundColor Red
    Write-Host "Please run CMake build first." -ForegroundColor Yellow
    exit 1
}

# Create output directory if not exists
if (-not (Test-Path $outputRoot)) {
    New-Item -ItemType Directory -Path $outputRoot | Out-Null
}

# Run the packaging script
Write-Host "Running package_dist.ps1..." -ForegroundColor Yellow
& "$PSScriptRoot\package_dist.ps1" -BuildRoot $buildRoot -OutputRoot $outputRoot -Tag $tag -CommitSha $commitSha

Write-Host ""
Write-Host "=== Package Contents ===" -ForegroundColor Cyan

$packageRoot = Join-Path $outputRoot "polyscope"

# List include directory
Write-Host "`ninclude/" -ForegroundColor Green
Get-ChildItem -Path (Join-Path $packageRoot "include") -Recurse | ForEach-Object {
    $indent = "  "
    if ($_.PSIsContainer) {
        Write-Host "$indent$($_.Name)/" -ForegroundColor Magenta
    } else {
        Write-Host "$indent$($_.Name)" -ForegroundColor White
    }
}

# List lib directories
Write-Host "`nlib/debug/" -ForegroundColor Green
Get-ChildItem -Path (Join-Path $packageRoot "lib\debug") -File | ForEach-Object {
    Write-Host "  $($_.Name)" -ForegroundColor White
}

Write-Host "`nlib/release/" -ForegroundColor Green
Get-ChildItem -Path (Join-Path $packageRoot "lib\release") -File | ForEach-Object {
    Write-Host "  $($_.Name)" -ForegroundColor White
}

# Show metadata
Write-Host "`nbuild-metadata.txt:" -ForegroundColor Green
Get-Content (Join-Path $packageRoot "build-metadata.txt") | ForEach-Object {
    Write-Host "  $_" -ForegroundColor Gray
}

Write-Host "`nDone! Package location: $packageRoot" -ForegroundColor Cyan
