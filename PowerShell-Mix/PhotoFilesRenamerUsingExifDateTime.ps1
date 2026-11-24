<#
PhotoFilesRenamerUsingExifDateTime.ps1

Copies JPG/JPEG files from $inputFolder to $outputFolder without scanning
subfolders or modifying originals. Names copies yyyyMMdd_HHmmss.jpg using
the first valid EXIF date: DateTimeOriginal, DateTimeDigitized, GPSDateStamp,
then DateTime. GPS dates use 000000 as the time.

Adds numbered suffixes to prevent overwrites. Uses prefixes noexif_ when
EXIF is absent, nodateinexif_ when no valid date exists, and readerror_
when metadata cannot be read.

Usage: Set $inputFolder and $outputFolder, then run on Windows:
.\PhotoFilesRenamerUsingExifDateTime.ps1
#>

# Windows PowerShell 5.1 or PowerShell 7 on Windows. No extra modules required.
# Edit these two variables before running:
$inputFolder  = 'c:\input_photos_folder'
$outputFolder = 'c:\output_folder'

# Only JPG/JPEG files directly inside inputFolder are processed.
# Originals are never renamed, modified, or deleted. Copies retain all metadata.
# GPSDateStamp has no time component: its filename uses 000000 for the time.
# Unreadable/corrupt metadata: copy with readerror_ and print a warning.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function Test-JpegExif {
    param([Parameter(Mandatory)][string]$Path)

    # Check for an actual EXIF APP1 segment. A nonempty PropertyItems array
    # alone is insufficient: JPEG/JFIF properties are not necessarily EXIF.
    $stream = [System.IO.File]::OpenRead($Path)
    $reader = [System.IO.BinaryReader]::new($stream)
    try {
        if ($reader.ReadByte() -ne 0xFF -or $reader.ReadByte() -ne 0xD8) {
            throw 'The file does not have a JPEG signature.'
        }
        while ($stream.Position -lt $stream.Length) {
            if ($reader.ReadByte() -ne 0xFF) { throw 'Invalid JPEG marker.' }
            do { $marker = $reader.ReadByte() } while ($marker -eq 0xFF)

            # Stop before compressed image data or at the end of the image.
            if ($marker -eq 0xDA -or $marker -eq 0xD9) { return $false }
            if ($marker -eq 0x00) { throw 'Invalid JPEG marker.' }
            if ($marker -eq 0x01 -or ($marker -ge 0xD0 -and $marker -le 0xD8)) {
                continue
            }

            $length = ([int]$reader.ReadByte() * 256) + [int]$reader.ReadByte()
            if ($length -lt 2) { throw 'Invalid JPEG segment length.' }
            $end = $stream.Position + $length - 2
            if ($end -gt $stream.Length) { throw 'Truncated JPEG segment.' }

            if ($marker -eq 0xE1 -and $length -ge 8) {
                $header = $reader.ReadBytes(6)
                if ($header[0] -eq 0x45 -and $header[1] -eq 0x78 -and
                    $header[2] -eq 0x69 -and $header[3] -eq 0x66 -and
                    $header[4] -eq 0 -and $header[5] -eq 0) {
                    return $true
                }
            }
            $stream.Position = $end
        }
        throw 'JPEG ended before an image-data or end marker.'
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Get-ExifDate {
    param([Parameter(Mandatory)][System.Drawing.Image]$Image)

    # Try each field in the requested order; invalid values fall through.
    $fields = @(
        @{ Id = 0x9003; Name = 'DateTimeOriginal';  Format = 'yyyy:MM:dd HH:mm:ss' }
        @{ Id = 0x9004; Name = 'DateTimeDigitized'; Format = 'yyyy:MM:dd HH:mm:ss' }
        @{ Id = 0x001D; Name = 'GPSDateStamp';     Format = 'yyyy:MM:dd' }
        @{ Id = 0x0132; Name = 'DateTime';         Format = 'yyyy:MM:dd HH:mm:ss' }
    )

    $ids = $Image.PropertyIdList
    foreach ($field in $fields) {
        if ($ids -notcontains $field.Id) { continue }
        try {
            $property = $Image.GetPropertyItem($field.Id)
            if ($property.Type -ne 2) { continue } # EXIF ASCII
            $value = [System.Text.Encoding]::ASCII.GetString($property.Value)
            $value = ($value -split "`0", 2)[0].Trim()
            $parsedDate = [datetime]::MinValue
            if ([datetime]::TryParseExact(
                $value, $field.Format,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::None,
                [ref]$parsedDate
            )) {
                return [PSCustomObject]@{ Date = $parsedDate; Field = $field.Name }
            }
        }
        catch {
            # A broken field must not prevent trying the remaining dates.
            continue
        }
    }
    return $null
}

function Copy-WithoutOverwrite {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$DestinationFolder,
        [Parameter(Mandatory)][string]$Name
    )

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    $extension = [System.IO.Path]::GetExtension($Name)
    [long]$suffix = 0
    while ($true) {
        $candidateName = if ($suffix -eq 0) { $Name } else {
            '{0}_{1}{2}' -f $baseName, $suffix, $extension
        }
        $destination = Join-Path $DestinationFolder $candidateName
        if (Test-Path -LiteralPath $destination) {
            $suffix++
            continue
        }
        try {
            # false also prevents overwrite if another process creates the
            # destination between our existence check and this copy.
            [System.IO.File]::Copy($Source, $destination, $false)
            return $destination
        }
        catch [System.IO.IOException] {
            $code = $_.Exception.HResult -band 0xFFFF
            if ($code -eq 80 -or $code -eq 183) {
                $suffix++
                continue
            }
            throw
        }
    }
}

$inputItem = Get-Item -LiteralPath $inputFolder -Force
if (-not $inputItem.PSIsContainer -or $inputItem.PSProvider.Name -ne 'FileSystem') {
    throw 'inputFolder must be an existing filesystem directory.'
}
$inputFolder = $inputItem.FullName
$outputFolder = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($outputFolder)
$trimChars = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
if ([string]::Equals($inputFolder.TrimEnd($trimChars), $outputFolder.TrimEnd($trimChars),
        [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Choose a different outputFolder from inputFolder.'
}
[void][System.IO.Directory]::CreateDirectory($outputFolder)

# Take a snapshot; do not recurse into any subdirectories.
$files = @(Get-ChildItem -LiteralPath $inputFolder -File -Force |
    Where-Object { $_.Extension -in '.jpg', '.jpeg' } |
    Sort-Object Name)

$copied = 0
$failed = 0
$metadataErrors = 0
foreach ($file in $files) {
    $image = $null
    try {
        $newName = 'noexif_' + $file.Name
        $reason = 'No EXIF'
        if (Test-JpegExif -Path $file.FullName) {
            $image = [System.Drawing.Image]::FromFile($file.FullName)
            $dateInfo = Get-ExifDate -Image $image
            if ($null -ne $dateInfo) {
                $newName = $dateInfo.Date.ToString('yyyyMMdd_HHmmss',
                    [System.Globalization.CultureInfo]::InvariantCulture) + '.jpg'
                $reason = $dateInfo.Field
            }
            else {
                $newName = 'nodateinexif_' + $file.Name
                $reason = 'EXIF without a valid date'
            }
        }
    }
    catch {
        $newName = 'readerror_' + $file.Name
        $reason = 'Metadata read error'
        $metadataErrors++
        Write-Warning ('Cannot inspect {0}: {1}' -f $file.Name, $_.Exception.Message)
    }
    finally {
        if ($null -ne $image) { $image.Dispose() }
    }

    try {
        $destination = Copy-WithoutOverwrite -Source $file.FullName -DestinationFolder $outputFolder -Name $newName
        $copied++
        Write-Host ('{0} -> {1} [{2}]' -f $file.Name, [System.IO.Path]::GetFileName($destination), $reason)
    }
    catch {
        $failed++
        Write-Warning ('COPY FAILED for {0}: {1}' -f $file.Name, $_.Exception.Message)
    }
}

Write-Host ("`nFinished. Copied: {0}; copy failures: {1}; metadata read errors: {2}." -f $copied, $failed, $metadataErrors)
