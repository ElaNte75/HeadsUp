# HeadsUp ship script
# Builds Desktop\HeadsUp-<version>.zip with only the HeadsUp folder inside, ready for CurseForge.
#
# The version is the one written in HeadsUp.toc ("## Version: 1.0 beta"). It is changed by hand, when there is
# a new version to publish. It is not changed here (no week number).

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$AddonDir = Join-Path $RepoRoot "HeadsUp"
$TocPath = Join-Path $AddonDir "HeadsUp.toc"
if (-not (Test-Path -LiteralPath $TocPath)) {
    throw "Cannot find HeadsUp.toc under $AddonDir"
}

$DesktopDir = [Environment]::GetFolderPath("Desktop")
Write-Host "Addon: $AddonDir"

$lines = Get-Content -LiteralPath $TocPath
$versionLine = $lines | Where-Object { $_ -match '^##\s*Version\s*:' } | Select-Object -First 1
if (-not $versionLine) { throw "No ## Version line in HeadsUp.toc" }
$version = ($versionLine -split ":", 2)[1].Trim()
Write-Host "Version: $version"

# what goes into the zip: the HeadsUp folder, and nothing else
$staging = Join-Path $env:TEMP ("HeadsUp-ship-" + [guid]::NewGuid().ToString("N"))
$stageAddon = Join-Path $staging "HeadsUp"
New-Item -ItemType Directory -Force -Path $stageAddon | Out-Null
Copy-Item -Path (Join-Path $AddonDir "*") -Destination $stageAddon -Recurse -Force

# working leftovers never go to the zip
Get-ChildItem -Path $stageAddon -Recurse -Directory -Filter "__pycache__" -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force
Get-ChildItem -Path $stageAddon -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in ".bak", ".tmp", ".pyc", ".orig" } |
    Remove-Item -Force

$fileName = ("HeadsUp-" + $version + ".zip") -replace " ", "-"
$zipPath = Join-Path $DesktopDir $fileName
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

# the zip is written by hand so that every path inside has forward slashes (HeadsUp/Sounds/...)
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    $basePath = (Resolve-Path -LiteralPath $staging).Path.TrimEnd('\') + '\'
    foreach ($file in Get-ChildItem -Path $stageAddon -Recurse -File) {
        $relative = $file.FullName.Substring($basePath.Length).Replace('\', '/')
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $archive, $file.FullName, $relative, [System.IO.Compression.CompressionLevel]::Optimal)
    }
} finally {
    $archive.Dispose()
}
Remove-Item -LiteralPath $staging -Recurse -Force

Write-Host ""
Write-Host "DONE"
Write-Host "Zip ready on Desktop: $zipPath"
Write-Host "It holds only the HeadsUp folder. Upload it to CurseForge."
