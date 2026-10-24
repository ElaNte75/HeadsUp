# HeadsUp Auras: brings your auras, groups and counters from the old "HeadsUp" add-on into "HeadsUp Auras".
#
# Why: the add-on changed its name (the old name was too close to another add-on). The game keeps the settings of an
# add-on in a file named after the add-on, so the settings of the old folder must be copied to the new name.
#
# How to use it (once):
#   1. Close World of Warcraft.
#   2. Put the new HeadsUpAuras folder in World of Warcraft\_retail_\Interface\AddOns (and delete the old HeadsUp folder).
#   3. Right-click this file > Run with PowerShell. Choose your World of Warcraft folder (the one that has "_retail_" inside).
#
# It copies WTF\Account\<account>\SavedVariables\HeadsUp.lua to HeadsUpAuras.lua (the old file is not touched or deleted).
# If HeadsUpAuras.lua already exists, it is left alone.

Add-Type -AssemblyName System.Windows.Forms
$dialog = New-Object System.Windows.Forms.FolderBrowserDialog
$dialog.Description = "Choose your World of Warcraft folder (the one that contains _retail_)"
$dialog.SelectedPath = "C:\Program Files (x86)\World of Warcraft"
if ($dialog.ShowDialog() -ne "OK") { return }

$retail = Join-Path $dialog.SelectedPath "_retail_"
if (-not (Test-Path $retail)) { $retail = $dialog.SelectedPath }
$accounts = Join-Path $retail "WTF\Account"
if (-not (Test-Path $accounts)) {
    Write-Host "Cannot find WTF\Account under $retail"
    Read-Host "Press Enter to close"
    return
}

$done = 0
foreach ($account in Get-ChildItem $accounts -Directory) {
    $old = Join-Path $account.FullName "SavedVariables\HeadsUp.lua"
    $new = Join-Path $account.FullName "SavedVariables\HeadsUpAuras.lua"
    if (-not (Test-Path $old)) { continue }
    $text = [System.IO.File]::ReadAllText($old)
    # only the add-on of this project has the list "auras" in its settings; the other add-on called Heads Up does not
    if ($text -notmatch '\["auras"\]') {
        Write-Host ("Skipped (no HeadsUp auras in it): " + $old)
        continue
    }
    if (Test-Path $new) {
        Write-Host ("Already there, left alone: " + $new)
        continue
    }
    $text = $text -replace '^\s*HeadsUpDB = \{', 'HeadsUpAurasDB = {'
    [System.IO.File]::WriteAllText($new, $text)
    Write-Host ("Copied: " + $old + "  ->  " + $new)
    $done++
}
Write-Host ""
Write-Host ("Done. Accounts migrated: " + $done)
Read-Host "Press Enter to close"
