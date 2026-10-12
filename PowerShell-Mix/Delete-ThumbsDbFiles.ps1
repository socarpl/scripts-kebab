# Relaunch as admin if not already
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "Not running as admin. Restarting as administrator..."
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# Load InputBox
Add-Type -AssemblyName Microsoft.VisualBasic
$folder = [Microsoft.VisualBasic.Interaction]::InputBox("Enter directory path:", "Directory Selection", "")

# If folder is valid, delete Thumbs.db
if (Test-Path $folder) {
    $files = Get-ChildItem -Path $folder -Recurse -Filter "Thumbs.db" -Force -ErrorAction SilentlyContinue
    $count = $files.Count

    if ($count -gt 0) {
        $files | Remove-Item -Force -ErrorAction SilentlyContinue
        Write-Host "$count Thumbs.db file(s) deleted from $folder"
    } else {
        Write-Host "No Thumbs.db files found in $folder"
    }
} else {
    Write-Host "Invalid path: $folder"
}
