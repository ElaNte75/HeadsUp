# HeadsUp ship script
# 1) Sets the last number of the version in HeadsUp.toc to the current week of the year (ISO week)
# 2) Builds Desktop\HeadsUp-<version>.zip with only the HeadsUp folder inside, ready for CurseForge
#
# Version numbers are major.minor.week (like FarmWise): major and minor are never changed here.
# The version may be followed by a word, for example "1.0.43 beta".

[CmdletBinding()]
param(
    [switch]$SkipBump
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$AddonDir = Join-Path $RepoRoot "HeadsUp"
$TocPath = Join-Path $AddonDir "HeadsUp.toc"
if (-not (Test-Path -LiteralPath $TocPath)) {
    throw "Cannot find HeadsUp.toc under $AddonDir"
}

$DesktopDir = [Environment]::GetFolderPath("Desktop")
Write-Host "Addon: $AddonDir"

# the ISO week of the year (Monday first, the week with the first Thursday is week 1)
function Get-IsoWeek([datetime]$date) {
    $day = [int]$date.DayOfWeek
    if ($day -eq 0) { $day = 7 }
    $thursday = $date.AddDays(4 - $day)
    $calendar = [System.Globalization.CultureInfo]::InvariantCulture.Calendar
    return $calendar.GetWeekOfYear($thursday, [System.Globalization.CalendarWeekRule]::FirstFourDayWeek, [DayOfWeek]::Monday)
}

$lines = Get-Content -LiteralPath $TocPath
$versionLine = $lines | Where-Object { $_ -match '^##\s*Version\s*:' } | Select-Object -First 1
if (-not $versionLine) { throw "No ## Version line in HeadsUp.toc" }
$current = ($versionLine -split ":", 2)[1].Trim()

if ($current -notmatch '^(\d+)\.(\d+)\.(\d+)(.*)$') {
    throw "The version '$current' is not major.minor.week (optionally followed by a word like beta)"
}
$major = $Matches[1]
$minor = $Matches[2]
$suffix = $Matches[4]          # for example " beta"

if ($SkipBump) {
    $version = $current
    Write-Host "Version left at $version"
} else {
    $week = Get-IsoWeek (Get-Date)
    $version = "$major.$minor.$week$suffix"
    $out = foreach ($line in $lines) {
        if ($line -match '^##\s*Version\s*:') { "## Version: $version" } else { $line }
    }
    # (the toc is written without a byte order mark, with the same line ends as before)
    [System.IO.File]::WriteAllText($TocPath, (($out -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Version: $current  ->  $version  (week $week)"
}

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
