<#
.SYNOPSIS
    Merges AVI files into one video, ordered by file size:
    largest first, smallest last.

.EXAMPLE
    1. Save this script as MergeAviFiles.ps1.

    2. Optionally populate the settings below:

       $source_folder = "D:\Printer\Timelapses"
       $target_file   = "D:\Printer\merged.avi"
       $ffmpeg        = "C:\c\ffmpeg\ffmpeg.exe"

       Populated settings are used directly.
       Empty or whitespace-only settings are requested in the terminal.
       If all three settings are populated, no prompts appear.

    3. Run the script from PowerShell:

       & "D:\Desktop\MergeAviFiles.ps1"

       Alternatively, open it in PowerShell ISE and press F5.

.DESCRIPTION
    - Reads AVI files directly inside the source folder.
      Subfolders are not included.

    - Sorts files by size in bytes, descending.
      Files with identical sizes are sorted by filename.

    - Uses FFmpeg's concat demuxer and stream copying.
      No re-encoding is performed, so there is no generation loss.

    - Requires compatible input streams: matching codecs, stream
      layouts, and video/audio parameters.

    - Creates the target folder if it does not exist.

    - Refuses to overwrite an existing target file.

    - Creates a temporary list of input paths and removes it afterward,
      including when merging fails.

    - Handles FFmpeg's stderr output so normal status messages do not
      stop the script in Windows PowerShell.

    - Checks FFmpeg's exit code to determine success or failure.

.NOTES
    Use an .avi target filename to produce an AVI output.

    Missing or damaged AVI indexes:
        FFmpeg can often read these recordings sequentially and write
        a new index in the output. This script does not perform a
        separate repair pass. Incorrect source durations or damaged
        frames may still cause problems.

    If merging fails:
        A partial target file may remain. Delete it or select another
        target filename before running the script again.

    Source files are not modified.
#>


# =====================================================================
# USER SETTINGS
# =====================================================================

# Populate these settings to use them without prompting.
# Leave any setting empty to enter it interactively when the script runs.
#
# Example:
# $source_folder = "D:\Printer\Timelapses"
# $target_file   = "D:\Printer\merged.avi"
# $ffmpeg        = "C:\c\ffmpeg\ffmpeg.exe"

$source_folder = ""
$target_file   = ""
$ffmpeg        = ""

# Treat PowerShell errors as terminating errors.
# This preference is temporarily relaxed while FFmpeg is running.
$ErrorActionPreference = 'Stop'


# =====================================================================
# PROMPT ONLY FOR MISSING SETTINGS
# =====================================================================

# Each loop runs only if its setting is empty or contains only whitespace.
# Keep prompting until a nonempty value is supplied.
#
# Strip surrounding whitespace and double quotes from entered paths,
# allowing paths pasted using Windows Explorer's "Copy as path".

while ([string]::IsNullOrWhiteSpace($source_folder)) {
    $source_folder = (
        Read-Host "Enter the folder containing AVI files"
    ).Trim().Trim('"')
}

while ([string]::IsNullOrWhiteSpace($target_file)) {
    $target_file = (
        Read-Host "Enter the full output path, including filename (e.g. D:\merged.avi)"
    ).Trim().Trim('"')
}

while ([string]::IsNullOrWhiteSpace($ffmpeg)) {
    $ffmpeg = (
        Read-Host "Enter the full path to ffmpeg.exe"
    ).Trim().Trim('"')
}


# =====================================================================
# VALIDATE SETTINGS AND PATHS
# =====================================================================

# Confirm that the FFmpeg executable exists.
# -LiteralPath treats characters such as [ and ] literally.
if (-not (Test-Path -LiteralPath $ffmpeg -PathType Leaf)) {
    throw "FFmpeg not found: $ffmpeg"
}

# Resolve the source folder and confirm that it is a directory.
# If the supplied path does not exist, Get-Item stops the script.
$folder = Get-Item -LiteralPath $source_folder

if (-not $folder.PSIsContainer) {
    throw "Source must be a folder: $source_folder"
}

# Convert the target path to an absolute path.
# Unlike Resolve-Path, this works when the target does not yet exist.
$output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
    $target_file
)

# Protect existing files from accidental replacement.
if (Test-Path -LiteralPath $output) {
    throw "Target already exists. Delete it or choose another filename: $output"
}


# =====================================================================
# COLLECT AND SORT INPUT FILES
# =====================================================================

# -File selects files only.
# No -Recurse is used, so subfolders are excluded.
# -ieq matches the extension without regard to letter case.
#
# Primary sorting:   file size descending.
# Secondary sorting: filename ascending for equal-size files.
#
# @() ensures that $files is always an array, even for a single input.
$files = @(
    Get-ChildItem -LiteralPath $folder.FullName -File |
        Where-Object { $_.Extension -ieq '.avi' } |
        Sort-Object -Property @{
            Expression = 'Length'
            Descending = $true
        }, Name
)

if ($files.Count -eq 0) {
    throw "No AVI files found in: $source_folder"
}

# Create the target directory, including missing parent directories.
# If it already exists, CreateDirectory leaves it in place.
$outputDirectory = Split-Path -Parent $output
[System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null

# Display the actual merge order.
# PowerShell's 1MB constant equals 1,048,576 bytes (one MiB).
# Displayed sizes are rounded; sorting uses the exact byte counts.
Write-Host "`nMerge order:"

$files | Select-Object Name, @{
    Name = 'SizeMiB'
    Expression = { [math]::Round($_.Length / 1MB, 2) }
} | Format-Table -AutoSize


# =====================================================================
# CREATE THE CONCAT LIST AND RUN FFMPEG
# =====================================================================

# Create a uniquely named temporary file for FFmpeg's input list.
$listFile = [System.IO.Path]::GetTempFileName()

try {
    # FFmpeg expects one entry per line:
    #
    # file 'D:/Printer/Timelapses/recording.avi'
    #
    # Forward slashes avoid backslash-escaping issues.
    # Apostrophes inside filenames require concat-list escaping.
    $lines = foreach ($file in $files) {
        $escapedPath = $file.FullName.Replace('\', '/').Replace("'", "'\''")
        "file '$escapedPath'"
    }

    # Explicitly use UTF-8 without a byte-order mark.
    # This avoids differences between default text encodings in
    # Windows PowerShell 5.1 and newer PowerShell versions.
    $encoding = New-Object System.Text.UTF8Encoding($false)

    [System.IO.File]::WriteAllLines(
        $listFile,
        [string[]]$lines,
        $encoding
    )

    Write-Host "Merging $($files.Count) files...`n"

    # FFmpeg sends normal progress and status information to stderr.
    # Windows PowerShell can interpret that as PowerShell error records.
    # Temporarily use Continue so these messages do not abort the script.
    $previousPreference = $ErrorActionPreference

    try {
        $ErrorActionPreference = 'Continue'

        # FFmpeg arguments:
        #
        # -hide_banner  Hide the introductory build/configuration banner.
        # -nostdin      Disable interactive input.
        # -n            Never overwrite an existing output file.
        # -f concat     Read the input as a concat file list.
        # -safe 0       Permit absolute paths in that list.
        # -i            Specify the concat list as the input.
        # -map 0        Include all streams exposed by the concat input.
        # -c copy       Copy compressed streams without re-encoding.
        #
        # 2>&1 combines stderr and stdout for display.
        # Write-Host displays each message as text.
        & $ffmpeg -hide_banner -nostdin -n `
            -f concat -safe 0 -i $listFile `
            -map 0 -c copy $output 2>&1 |
            ForEach-Object { Write-Host $_.ToString() }

        # Capture the native program's exit code immediately.
        # Zero means success; a nonzero value means failure.
        $ffmpegExitCode = $LASTEXITCODE
    }
    finally {
        # Restore normal PowerShell error handling even if execution fails.
        $ErrorActionPreference = $previousPreference
    }

    # Determine success from FFmpeg's exit code, not its stderr messages.
    if ($ffmpegExitCode -ne 0) {
        throw "FFmpeg failed with exit code $ffmpegExitCode. A partial target file may remain."
    }

    Write-Host "`nCreated: $output" -ForegroundColor Green
}
finally {
    # Always attempt to remove the temporary concat list.
    # Suppress cleanup errors so they do not mask a merging error.
    Remove-Item -LiteralPath $listFile -Force -ErrorAction SilentlyContinue
}
