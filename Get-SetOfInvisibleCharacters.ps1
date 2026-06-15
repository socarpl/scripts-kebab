# Creates a UTF-8 text file where invisible characters are placed
# between visible markers, so you can select/copy them manually.

$codes = @(
    0x200B, # Zero Width Space
    0x200C, # Zero Width Non-Joiner
    0x200D, # Zero Width Joiner
    0x200E, # Left-to-Right Mark
    0x200F, # Right-to-Left Mark
    0x2060, # Word Joiner
    0xFEFF, # Zero Width No-Break Space / BOM
    0x034F, # Combining Grapheme Joiner
    0x061C, # Arabic Letter Mark
    0x2061, # Function Application
    0x2062, # Invisible Times
    0x2063, # Invisible Separator
    0x2064  # Invisible Plus
)

# Combine invisible characters
$invisibleText = -join ($codes | ForEach-Object { [char]$_ })

# Use script folder if available, otherwise current folder
if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $folder = Get-Location
}
else {
    $folder = $PSScriptRoot
}

$outputPath = Join-Path $folder "invisible-symbols-copyable.txt"

# Put invisible characters between visible markers
$fileContent = @"
COPY ONLY WHAT IS BETWEEN THE TWO MARKERS BELOW.

START>>>$invisibleText<<<END

The invisible characters are between START>>> and <<<END.
Do not copy START>>> or <<<END.
The characters should be already in your clipboard if not, follow this:
Put the blinking cursor of text editor on left side of < symbol
Using arrow keys go to right side of last > symbol
Press and hold SHIFT
Press several times left arrow key till first < symbol gets highligted
When first on the left symbol < gets highligted press left arrow once
Chain of invisible characters are now selected, so press CTRL+C to aquire them into clipboard
Character count between markers: $($invisibleText.Length)
"@

# Write as UTF-8 without BOM
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($outputPath, $fileContent, $utf8NoBom)

# Also copy the invisible characters directly to clipboard
Set-Clipboard -Value $invisibleText

Write-Host "Created file:"
Write-Host $outputPath
Write-Host ""
Write-Host "Invisible characters were also copied directly to clipboard."
Write-Host "Character count:" $invisibleText.Length
