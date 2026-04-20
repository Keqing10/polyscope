param(
  [Parameter(Mandatory = $true)]
  [string]$BuildRoot,
  [Parameter(Mandatory = $true)]
  [string]$OutputRoot,
  [Parameter(Mandatory = $true)]
  [string]$Tag,
  [Parameter(Mandatory = $true)]
  [string]$CommitSha
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Copy-HeadersDirectory {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Source,
    [Parameter(Mandatory = $true)]
    [string]$Destination
  )

  if (-not (Test-Path -LiteralPath $Source)) {
    throw "Missing header source directory: $Source"
  }

  $extensions = @(
    ".h",
    ".hpp",
    ".hh",
    ".hxx",
    ".h++",
    ".ipp",
    ".inl",
    ".tpp",
    ".txx",
    ".inc",
    ".ixx",
    ".cppm",
    ".mpp"
  )
  $sourceRoot = (Resolve-Path -LiteralPath $Source).Path

  Get-ChildItem -LiteralPath $sourceRoot -Recurse -File | Where-Object {
    $extensions -contains $_.Extension.ToLowerInvariant()
  } | ForEach-Object {
    $relative = $_.FullName.Substring($sourceRoot.Length).TrimStart('\', '/')
    $destinationFile = Join-Path $Destination $relative
    $destinationDir = Split-Path -Path $destinationFile -Parent
    New-Item -ItemType Directory -Force -Path $destinationDir | Out-Null
    Copy-Item -LiteralPath $_.FullName -Destination $destinationFile -Force
  }
}

function Copy-HeaderFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SourceFile,
    [Parameter(Mandatory = $true)]
    [string]$DestinationFile
  )

  if (-not (Test-Path -LiteralPath $SourceFile)) {
    throw "Missing header source file: $SourceFile"
  }

  $destinationDir = Split-Path -Path $DestinationFile -Parent
  New-Item -ItemType Directory -Force -Path $destinationDir | Out-Null
  Copy-Item -LiteralPath $SourceFile -Destination $DestinationFile -Force
}

function Copy-LibsForConfig {
  param(
    [Parameter(Mandatory = $true)]
    [string]$BuildDir,
    [Parameter(Mandatory = $true)]
    [string]$Config,
    [Parameter(Mandatory = $true)]
    [string]$DestinationDir
  )

  $allowedLibNames = @(
    "polyscope",
    "imgui",
    "stb",
    "glm",
    "glad",
    "glfw",
    "glfw3",
    "glfw3_mt"
  )

  $configPathToken = [System.IO.Path]::DirectorySeparatorChar + $Config + [System.IO.Path]::DirectorySeparatorChar
  $copied = @{}
  Get-ChildItem -LiteralPath $BuildDir -Recurse -File -Filter "*.lib" | Where-Object {
    $_.FullName -like "*$configPathToken*"
  } | ForEach-Object {
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($_.Name).ToLowerInvariant()
    if ($allowedLibNames -contains $baseName -and -not $copied.ContainsKey($baseName)) {
      Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $DestinationDir $_.Name) -Force
      $copied[$baseName] = $_.Name
    }
  }

  if ($copied.Count -eq 0) {
    throw "No expected .lib files were found for config '$Config' in $BuildDir"
  }

  return @($copied.Values | Sort-Object)
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$resolvedBuildRoot = (Resolve-Path -LiteralPath $BuildRoot).Path
$resolvedOutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)

$packageRoot = Join-Path $resolvedOutputRoot "polyscope"
$includeRoot = Join-Path $packageRoot "include"
$libDebugRoot = Join-Path $packageRoot "lib/debug"
$libReleaseRoot = Join-Path $packageRoot "lib/release"

if (Test-Path -LiteralPath $packageRoot) {
  Remove-Item -LiteralPath $packageRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $includeRoot, $libDebugRoot, $libReleaseRoot | Out-Null

Copy-HeadersDirectory -Source (Join-Path $repoRoot "include/polyscope") -Destination (Join-Path $includeRoot "polyscope")
Copy-HeadersDirectory -Source (Join-Path $repoRoot "deps/glm/glm") -Destination (Join-Path $includeRoot "glm")
Copy-HeadersDirectory -Source (Join-Path $repoRoot "deps/glad/include/glad") -Destination (Join-Path $includeRoot "glad")
Copy-HeadersDirectory -Source (Join-Path $repoRoot "deps/glad/include/KHR") -Destination (Join-Path $includeRoot "KHR")
Copy-HeadersDirectory -Source (Join-Path $repoRoot "deps/glfw/include/GLFW") -Destination (Join-Path $includeRoot "GLFW")
Copy-HeaderFile -SourceFile (Join-Path $repoRoot "deps/imgui/imgui/imgui.h") -DestinationFile (Join-Path $includeRoot "imgui.h")
Copy-HeaderFile -SourceFile (Join-Path $repoRoot "deps/imgui/imgui/imconfig.h") -DestinationFile (Join-Path $includeRoot "imconfig.h")
Copy-HeaderFile -SourceFile (Join-Path $repoRoot "deps/imgui/implot/implot.h") -DestinationFile (Join-Path $includeRoot "implot.h")
Copy-HeaderFile -SourceFile (Join-Path $repoRoot "deps/imgui/ImGuizmo/ImGuizmo.h") -DestinationFile (Join-Path $includeRoot "ImGuizmo.h")

$debugLibs = Copy-LibsForConfig -BuildDir $resolvedBuildRoot -Config "Debug" -DestinationDir $libDebugRoot
$releaseLibs = Copy-LibsForConfig -BuildDir $resolvedBuildRoot -Config "Release" -DestinationDir $libReleaseRoot

$metadataPath = Join-Path $packageRoot "build-metadata.txt"
$metadata = @(
  "tag=$Tag",
  "commit=$CommitSha",
  "generated_utc=$(Get-Date -AsUTC -Format o)",
  "debug_libs=$($debugLibs -join ',')",
  "release_libs=$($releaseLibs -join ',')"
)
Set-Content -LiteralPath $metadataPath -Encoding utf8 -Value $metadata

$zipPath = Join-Path $resolvedOutputRoot "polyscope-$Tag-windows-lib.zip"
if (Test-Path -LiteralPath $zipPath) {
  Remove-Item -LiteralPath $zipPath -Force
}
Compress-Archive -Path $packageRoot -DestinationPath $zipPath -Force

$hashPath = "$zipPath.sha256"
if (Test-Path -LiteralPath $hashPath) {
  Remove-Item -LiteralPath $hashPath -Force
}
$hash = Get-FileHash -LiteralPath $zipPath -Algorithm SHA256
Set-Content -LiteralPath $hashPath -Encoding ascii -NoNewline -Value "$($hash.Hash.ToLowerInvariant())  $(Split-Path -Path $zipPath -Leaf)"

Write-Host "Created package: $zipPath"
Write-Host "Created checksum: $hashPath"
