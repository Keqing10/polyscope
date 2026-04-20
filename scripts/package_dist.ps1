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

function Resolve-HeaderSourceRoot {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ModuleRoot
  )

  if (-not (Test-Path -LiteralPath $ModuleRoot)) {
    throw "Missing module directory: $ModuleRoot"
  }

  $includeRoot = Join-Path $ModuleRoot "include"
  if (Test-Path -LiteralPath $includeRoot) {
    return (Resolve-Path -LiteralPath $includeRoot).Path
  }

  return (Resolve-Path -LiteralPath $ModuleRoot).Path
}

function Normalize-IncludePath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$PathValue
  )

  return ($PathValue -replace "\\", "/")
}

function New-ProxyHeaderFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ProxyPath,
    [Parameter(Mandatory = $true)]
    [string]$IncludeTarget
  )

  if (Test-Path -LiteralPath $ProxyPath) {
    return $false
  }

  $proxyDir = Split-Path -Path $ProxyPath -Parent
  New-Item -ItemType Directory -Force -Path $proxyDir | Out-Null
  $normalizedTarget = Normalize-IncludePath -PathValue $IncludeTarget
  Set-Content -LiteralPath $ProxyPath -Encoding ascii -Value @"
#pragma once
#include "$normalizedTarget"
"@
  return $true
}

function Ensure-MissingIncludeProxies {
  param(
    [Parameter(Mandatory = $true)]
    [string]$IncludeRoot
  )

  $resolvedIncludeRoot = (Resolve-Path -LiteralPath $IncludeRoot).Path
  $headerFiles = @(Get-ChildItem -LiteralPath $resolvedIncludeRoot -Recurse -File)
  $created = @()
  $includeRegex = '^\s*#\s*include\s*"([^"]+)"'
  $processedSpecs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

  foreach ($headerFile in $headerFiles) {
    foreach ($line in Get-Content -LiteralPath $headerFile.FullName) {
      $match = [System.Text.RegularExpressions.Regex]::Match($line, $includeRegex)
      if (-not $match.Success) {
        continue
      }

      $includeSpec = $match.Groups[1].Value.Trim()
      if ([string]::IsNullOrWhiteSpace($includeSpec)) {
        continue
      }

      $localCandidate = [System.IO.Path]::GetFullPath((Join-Path $headerFile.DirectoryName $includeSpec))
      if (Test-Path -LiteralPath $localCandidate) {
        continue
      }

      $packageCandidate = [System.IO.Path]::GetFullPath((Join-Path $resolvedIncludeRoot $includeSpec))
      if (Test-Path -LiteralPath $packageCandidate) {
        continue
      }

      if (-not $processedSpecs.Add($includeSpec)) {
        continue
      }

      $includeLeaf = [System.IO.Path]::GetFileName($includeSpec)
      if ([string]::IsNullOrWhiteSpace($includeLeaf)) {
        continue
      }

      $matchingTargets = @(
        $headerFiles | Where-Object {
          $_.Name -ieq $includeLeaf -and $_.FullName -ne $packageCandidate
        }
      )
      if ($matchingTargets.Count -eq 0) {
        continue
      }

      $target = $matchingTargets | Select-Object *,
        @{ Name = "RelativeFromIncludeRoot"; Expression = {
          Normalize-IncludePath -PathValue $_.FullName.Substring($resolvedIncludeRoot.Length).TrimStart('\', '/')
        } } |
        Sort-Object { $_.RelativeFromIncludeRoot.Length }, { $_.RelativeFromIncludeRoot } |
        Select-Object -First 1

      $proxyDir = Split-Path -Path $packageCandidate -Parent
      New-Item -ItemType Directory -Force -Path $proxyDir | Out-Null
      $relativeTarget = [System.IO.Path]::GetRelativePath($proxyDir, $target.FullName)
      if ([System.IO.Path]::IsPathRooted($relativeTarget)) {
        $relativeTarget = $target.RelativeFromIncludeRoot
      }

      if (New-ProxyHeaderFile -ProxyPath $packageCandidate -IncludeTarget $relativeTarget) {
        $created += (Normalize-IncludePath -PathValue $packageCandidate.Substring($resolvedIncludeRoot.Length).TrimStart('\', '/'))
      }
    }
  }

  return @($created | Sort-Object -Unique)
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
Copy-HeadersDirectory -Source (Resolve-HeaderSourceRoot -ModuleRoot (Join-Path $repoRoot "deps/glad")) -Destination $includeRoot
Copy-HeadersDirectory -Source (Resolve-HeaderSourceRoot -ModuleRoot (Join-Path $repoRoot "deps/glm")) -Destination $includeRoot
Copy-HeadersDirectory -Source (Resolve-HeaderSourceRoot -ModuleRoot (Join-Path $repoRoot "deps/imgui/imgui")) -Destination (Join-Path $includeRoot "imgui")
Copy-HeadersDirectory -Source (Resolve-HeaderSourceRoot -ModuleRoot (Join-Path $repoRoot "deps/imgui/implot")) -Destination (Join-Path $includeRoot "implot")
Copy-HeadersDirectory -Source (Resolve-HeaderSourceRoot -ModuleRoot (Join-Path $repoRoot "deps/imgui/ImGuizmo")) -Destination (Join-Path $includeRoot "ImGuizmo")
Copy-HeadersDirectory -Source (Resolve-HeaderSourceRoot -ModuleRoot (Join-Path $repoRoot "deps/glfw")) -Destination $includeRoot

$explicitProxies = @(
  @{ Path = "imgui.h"; Target = "imgui/imgui.h" },
  @{ Path = "implot.h"; Target = "implot/implot.h" },
  @{ Path = "ImGuizmo.h"; Target = "ImGuizmo/ImGuizmo.h" }
)
foreach ($proxy in $explicitProxies) {
  New-ProxyHeaderFile -ProxyPath (Join-Path $includeRoot $proxy.Path) -IncludeTarget $proxy.Target | Out-Null
}

$autoGeneratedProxies = Ensure-MissingIncludeProxies -IncludeRoot $includeRoot

$debugLibs = Copy-LibsForConfig -BuildDir $resolvedBuildRoot -Config "Debug" -DestinationDir $libDebugRoot
$releaseLibs = Copy-LibsForConfig -BuildDir $resolvedBuildRoot -Config "Release" -DestinationDir $libReleaseRoot

$metadataPath = Join-Path $packageRoot "build-metadata.txt"
$metadata = @(
  "tag=$Tag",
  "commit=$CommitSha",
  "generated_utc=$(Get-Date -AsUTC -Format o)",
  "debug_libs=$($debugLibs -join ',')",
  "release_libs=$($releaseLibs -join ',')",
  "auto_proxies=$($autoGeneratedProxies -join ',')"
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
