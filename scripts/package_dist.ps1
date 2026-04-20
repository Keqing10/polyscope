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

$HeaderExtensions = @(
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

function Test-IsWhitelistedHeaderFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $ext = [System.IO.Path]::GetExtension($Path)
  return $HeaderExtensions -contains $ext.ToLowerInvariant()
}

function Copy-HeadersDirectory {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Source,
    [Parameter(Mandatory = $true)]
    [string]$Destination,
    [Parameter()]
    [bool]$Recursive = $true
  )

  if (-not (Test-Path -LiteralPath $Source)) {
    throw "Missing header source directory: $Source"
  }

  $sourceRoot = (Resolve-Path -LiteralPath $Source).Path
  $copiedCount = 0

  if ($Recursive) {
    $files = Get-ChildItem -LiteralPath $sourceRoot -Recurse -File
  }
  else {
    $files = Get-ChildItem -LiteralPath $sourceRoot -File
  }

  $files | Where-Object {
    Test-IsWhitelistedHeaderFile -Path $_.FullName
  } | ForEach-Object {
    $relative = $_.FullName.Substring($sourceRoot.Length).TrimStart('\', '/')
    $destinationFile = Join-Path $Destination $relative
    $destinationDir = Split-Path -Path $destinationFile -Parent
    New-Item -ItemType Directory -Force -Path $destinationDir | Out-Null
    Copy-Item -LiteralPath $_.FullName -Destination $destinationFile -Force
    $copiedCount += 1
  }

  if ($copiedCount -eq 0) {
    throw "No whitelisted header files found in: $Source"
  }
}

function Copy-ModuleIncludeDirectory {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ModuleRoot,
    [Parameter(Mandatory = $true)]
    [string]$Destination
  )

  $includeDir = Join-Path $ModuleRoot "include"
  if (-not (Test-Path -LiteralPath $includeDir)) {
    throw "Missing module include directory: $includeDir"
  }

  Copy-HeadersDirectory -Source $includeDir -Destination $Destination -Recursive $true
}

function Copy-TopLevelHeaders {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Source,
    [Parameter(Mandatory = $true)]
    [string]$Destination
  )

  Copy-HeadersDirectory -Source $Source -Destination $Destination -Recursive $false
}

function Get-RelativePath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FromFile,
    [Parameter(Mandatory = $true)]
    [string]$ToFile
  )

  $fromDir = Split-Path -Path $FromFile -Parent
  $fromUri = [System.Uri]::new(($fromDir.TrimEnd([char]92, [char]'/') + [System.IO.Path]::DirectorySeparatorChar))
  $toUri = [System.Uri]::new($ToFile)
  $relativeUri = $fromUri.MakeRelativeUri($toUri)
  $relativePath = [System.Uri]::UnescapeDataString($relativeUri.ToString())
  return $relativePath.Replace('\\', '/')
}

function Add-ImguiForwardingHeaders {
  param(
    [Parameter(Mandatory = $true)]
    [string]$IncludeRoot
  )

  $imguiSubDir = Join-Path $IncludeRoot "imgui"
  if (-not (Test-Path -LiteralPath $imguiSubDir)) {
    return
  }

  $headers = Get-ChildItem -LiteralPath $imguiSubDir -Recurse -File | Where-Object {
    Test-IsWhitelistedHeaderFile -Path $_.FullName
  }

  foreach ($header in $headers) {
    $baseName = $header.Name
    $forwarderPath = Join-Path $IncludeRoot $baseName
    if (-not (Test-Path -LiteralPath $forwarderPath)) {
      $content = @(
        "// Auto-generated forwarding header.",
        "#pragma once",
        "#include `"imgui/$baseName`""
      )
      Set-Content -LiteralPath $forwarderPath -Encoding utf8 -Value $content
    }
  }
}

function Add-MissingIncludeForwarders {
  param(
    [Parameter(Mandatory = $true)]
    [string]$IncludeRoot
  )

  $resolvedIncludeRoot = (Resolve-Path -LiteralPath $IncludeRoot).Path
  $headers = Get-ChildItem -LiteralPath $resolvedIncludeRoot -Recurse -File | Where-Object {
    Test-IsWhitelistedHeaderFile -Path $_.FullName
  }

  $pathToFile = @{}
  $baseNameToPaths = @{}

  foreach ($header in $headers) {
    $relative = $header.FullName.Substring($resolvedIncludeRoot.Length).TrimStart([char]92, [char]'/')
    $relative = $relative.Replace('\\', '/')
    $pathToFile[$relative.ToLowerInvariant()] = $header.FullName

    $baseName = [System.IO.Path]::GetFileName($relative).ToLowerInvariant()
    if (-not $baseNameToPaths.ContainsKey($baseName)) {
      $baseNameToPaths[$baseName] = [System.Collections.Generic.List[string]]::new()
    }
    $baseNameToPaths[$baseName].Add($relative)
  }

  $createdForwarders = [System.Collections.Generic.List[string]]::new()

  foreach ($header in $headers) {
    $lines = Get-Content -LiteralPath $header.FullName
    foreach ($line in $lines) {
      if ($line -notmatch '^\s*#\s*include\s*[<\"]([^\">]+)[\">]') {
        continue
      }

      $includePath = $Matches[1].Trim()
      if ([string]::IsNullOrWhiteSpace($includePath)) {
        continue
      }

      $normalizedIncludePath = $includePath.Replace('\\', '/')
      if ($normalizedIncludePath.StartsWith('/') -or $normalizedIncludePath -match '^[A-Za-z]:') {
        continue
      }

      $includingDir = Split-Path -Path $header.FullName -Parent
      $includingDirCandidate = Join-Path $includingDir ($normalizedIncludePath -replace '/', '\\')
      if (Test-Path -LiteralPath $includingDirCandidate) {
        continue
      }

      if ($normalizedIncludePath -match '(^|/)\.\.?(/|$)') {
        continue
      }

      $includeExtension = [System.IO.Path]::GetExtension($normalizedIncludePath)
      if (-not ($HeaderExtensions -contains $includeExtension.ToLowerInvariant())) {
        continue
      }

      $lookupKey = $normalizedIncludePath.ToLowerInvariant()
      if ($pathToFile.ContainsKey($lookupKey)) {
        continue
      }

      $baseName = [System.IO.Path]::GetFileName($normalizedIncludePath).ToLowerInvariant()
      if (-not $baseNameToPaths.ContainsKey($baseName)) {
        continue
      }

      $candidates = @($baseNameToPaths[$baseName])
      if ($candidates.Count -ne 1) {
        continue
      }

      $destinationFile = Join-Path $resolvedIncludeRoot ($normalizedIncludePath -replace '/', '\\')
      if (Test-Path -LiteralPath $destinationFile) {
        $pathToFile[$lookupKey] = $destinationFile
        continue
      }

      $candidateRelativePath = $candidates[0]
      $candidateFile = Join-Path $resolvedIncludeRoot ($candidateRelativePath -replace '/', '\\')
      if (-not (Test-Path -LiteralPath $candidateFile)) {
        continue
      }

      $destinationDir = Split-Path -Path $destinationFile -Parent
      New-Item -ItemType Directory -Force -Path $destinationDir | Out-Null

      $forwardTarget = Get-RelativePath -FromFile $destinationFile -ToFile $candidateFile
      $forwarderContent = @(
        "// Auto-generated forwarding header for package include compatibility.",
        "#pragma once",
        "#include `"$forwardTarget`""
      )
      Set-Content -LiteralPath $destinationFile -Encoding utf8 -Value $forwarderContent

      $pathToFile[$lookupKey] = $destinationFile
      $createdForwarders.Add($normalizedIncludePath)
    }
  }

  return @($createdForwarders | Sort-Object -Unique)
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
Copy-ModuleIncludeDirectory -ModuleRoot (Join-Path $repoRoot "deps/glad") -Destination $includeRoot
Copy-ModuleIncludeDirectory -ModuleRoot (Join-Path $repoRoot "deps/glfw") -Destination $includeRoot

# These repos do not use a dedicated include/ subtree; copy only top-level headers into imgui/ subdirectory.
Copy-TopLevelHeaders -Source (Join-Path $repoRoot "deps/imgui/imgui") -Destination (Join-Path $includeRoot "imgui")
Copy-TopLevelHeaders -Source (Join-Path $repoRoot "deps/imgui/implot") -Destination (Join-Path $includeRoot "imgui")
Copy-TopLevelHeaders -Source (Join-Path $repoRoot "deps/imgui/ImGuizmo") -Destination (Join-Path $includeRoot "imgui")

Add-ImguiForwardingHeaders -IncludeRoot $includeRoot

$forwardHeaders = Add-MissingIncludeForwarders -IncludeRoot $includeRoot

$debugLibs = Copy-LibsForConfig -BuildDir $resolvedBuildRoot -Config "Debug" -DestinationDir $libDebugRoot
$releaseLibs = Copy-LibsForConfig -BuildDir $resolvedBuildRoot -Config "Release" -DestinationDir $libReleaseRoot

$metadataPath = Join-Path $packageRoot "build-metadata.txt"
$metadata = @(
  "tag=$Tag",
  "commit=$CommitSha",
  "generated_utc=$((Get-Date).ToUniversalTime().ToString('o'))",
  "forwarded_headers=$($forwardHeaders -join ',')",
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
