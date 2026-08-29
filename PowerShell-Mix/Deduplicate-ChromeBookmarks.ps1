#requires -Version 5.1

<#
.SYNOPSIS
    Extracts and deduplicates domains from a Chrome bookmarks HTML export.

.DESCRIPTION
    This script opens a file-selection dialog and processes a bookmarks file
    exported from Google Chrome or another browser using the Netscape bookmark
    HTML format.

    It extracts HTTP and HTTPS addresses and cleans each address by:

    - Removing the protocol, such as https://
    - Removing paths, query parameters and fragments
    - Removing port numbers
    - Converting domains to lowercase
    - Removing the leading "www."
    - Converting international domain names to ASCII/Punycode
    - Removing duplicate domains while preserving their original order

    After selecting the bookmarks file, the script asks:

        "Do you want top domains only and remove any subdomains?"

    Selecting YES:
        Subdomains are converted to their registrable top domains.

        Examples:
            mail.google.com          -> google.com
            support.microsoft.com    -> microsoft.com
            shop.example.com.pl      -> example.com.pl

        The script uses the Public Suffix List to handle compound suffixes
        such as .com.pl and .co.uk correctly. The list is downloaded when
        necessary and cached for 30 days.

    Selecting NO:
        Subdomains remain separate, reproducing the original behaviour.

        Examples:
            mail.google.com          -> mail.google.com
            support.microsoft.com    -> support.microsoft.com

.OUTPUT
    The resulting text file is created in the same directory as the selected
    bookmarks file.

    Example:

        Input:
            D:\Desktop\bookmarks.html

        Output:
            D:\Desktop\deduplicated_bookmarks.txt

    The output contains one unique domain per line. If the destination file
    already exists, the script asks for confirmation before replacing it.

.HOW TO EXPORT CHROME BOOKMARKS
    1. Open Chrome.
    2. Press Ctrl+Shift+O to open Bookmark Manager.
    3. Open the three-dot menu in Bookmark Manager.
    4. Select "Export bookmarks".
    5. Save the resulting HTML file.

.HOW TO RUN
    Open PowerShell, navigate to the directory containing this script and run:

        Unblock-File -LiteralPath .\Deduplicate-ChromeBookmarks.ps1
        .\Deduplicate-ChromeBookmarks.ps1

    Unblock-File is normally required only once after downloading the script.

.REQUIREMENTS
    - Windows PowerShell 5.1 or newer
    - Internet access when top-domain mode first downloads or refreshes the
      Public Suffix List
#>

Add-Type -AssemblyName System.Windows.Forms

[System.Windows.Forms.Application]::EnableVisualStyles()

function ConvertTo-AsciiDomainRule {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Rule
    )

    $idn = [System.Globalization.IdnMapping]::new()
    $asciiLabels = [System.Collections.Generic.List[string]]::new()

    foreach ($label in $Rule.Split('.')) {
        if ([string]::IsNullOrWhiteSpace($label)) {
            return $null
        }

        try {
            [void]$asciiLabels.Add($idn.GetAscii($label).ToLowerInvariant())
        }
        catch {
            return $null
        }
    }

    return ($asciiLabels -join '.')
}

function Get-PublicSuffixRuleSets {
    $listUrl = 'https://publicsuffix.org/list/public_suffix_list.dat'
    $cacheDirectory = Join-Path `
        ([System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData)) `
        'BookmarkDomainDeduplicator'
    $cachePath = Join-Path $cacheDirectory 'public_suffix_list.dat'
    $cacheMaximumAge = [System.TimeSpan]::FromDays(30)
    $downloadRequired = -not (Test-Path -LiteralPath $cachePath)

    if (-not $downloadRequired) {
        $cacheAge = (Get-Date) - (Get-Item -LiteralPath $cachePath).LastWriteTime
        $downloadRequired = $cacheAge -gt $cacheMaximumAge
    }

    if ($downloadRequired) {
        try {
            [System.Net.ServicePointManager]::SecurityProtocol = `
                [System.Net.ServicePointManager]::SecurityProtocol -bor `
                [System.Net.SecurityProtocolType]::Tls12

            $response = Invoke-WebRequest `
                -Uri $listUrl `
                -UseBasicParsing `
                -TimeoutSec 30 `
                -ErrorAction Stop

            $listText = [string]$response.Content
            if ([string]::IsNullOrWhiteSpace($listText)) {
                throw 'The downloaded Public Suffix List was empty.'
            }

            [void][System.IO.Directory]::CreateDirectory($cacheDirectory)
            $utf8WithoutBom = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::WriteAllText($cachePath, $listText, $utf8WithoutBom)
        }
        catch {
            if (Test-Path -LiteralPath $cachePath) {
                $listText = [System.IO.File]::ReadAllText($cachePath)
            }
            else {
                throw "Top-domain mode needs the Public Suffix List, but it could not be downloaded. $($_.Exception.Message)"
            }
        }
    }
    else {
        $listText = [System.IO.File]::ReadAllText($cachePath)
    }

    $exactRules = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $wildcardRules = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $exceptionRules = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($line in ($listText -split "`r?`n")) {
        $rule = $line.Trim().TrimStart([char]0xFEFF)

        if ([string]::IsNullOrWhiteSpace($rule) -or $rule.StartsWith('//')) {
            continue
        }

        # Ignore any whitespace-delimited comment following a rule.
        $rule = ($rule -split '\s+', 2)[0]
        $targetSet = $exactRules

        if ($rule.StartsWith('!')) {
            $targetSet = $exceptionRules
            $rule = $rule.Substring(1)
        }
        elseif ($rule.StartsWith('*.')) {
            $targetSet = $wildcardRules
            $rule = $rule.Substring(2)
        }

        $asciiRule = ConvertTo-AsciiDomainRule -Rule $rule
        if ($null -ne $asciiRule) {
            [void]$targetSet.Add($asciiRule)
        }
    }

    return [PSCustomObject]@{
        Exact     = $exactRules
        Wildcard  = $wildcardRules
        Exception = $exceptionRules
    }
}

function Get-RegistrableDomain {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Domain,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Rules
    )

    $ipAddress = $null
    if ([System.Net.IPAddress]::TryParse($Domain, [ref]$ipAddress)) {
        return $Domain
    }

    $labels = @($Domain.Split('.') | Where-Object { $_.Length -gt 0 })
    if ($labels.Count -le 1) {
        return $Domain
    }

    # If nothing matches, the Public Suffix List's implicit rule is "*".
    $publicSuffixLabelCount = 1
    $exceptionLabelCount = $null

    for ($index = 0; $index -lt $labels.Count; $index++) {
        $candidate = $labels[$index..($labels.Count - 1)] -join '.'
        $candidateLabelCount = $labels.Count - $index

        if ($Rules.Exception.Contains($candidate)) {
            $exceptionLabelCount = $candidateLabelCount
            break
        }

        if ($Rules.Exact.Contains($candidate)) {
            $publicSuffixLabelCount = [Math]::Max(
                $publicSuffixLabelCount,
                $candidateLabelCount
            )
        }

        # A wildcard rule such as *.ck stores "ck" and consumes one
        # additional label from the domain.
        if ($index -gt 0 -and $Rules.Wildcard.Contains($candidate)) {
            $publicSuffixLabelCount = [Math]::Max(
                $publicSuffixLabelCount,
                $candidateLabelCount + 1
            )
        }
    }

    if ($null -ne $exceptionLabelCount) {
        # For an exception, eTLD+1 contains the same number of labels as the
        # exception rule (for example, !www.ck produces www.ck).
        $registrableLabelCount = $exceptionLabelCount
    }
    else {
        $registrableLabelCount = $publicSuffixLabelCount + 1
    }

    if ($labels.Count -le $publicSuffixLabelCount) {
        return $Domain
    }

    $firstLabel = $labels.Count - $registrableLabelCount
    return ($labels[$firstLabel..($labels.Count - 1)] -join '.')
}

$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Title = 'Select a Chrome bookmarks export'
$dialog.Filter = 'HTML files (*.html)|*.html|All files (*.*)|*.*'
$dialog.FilterIndex = 1
$dialog.Multiselect = $false
$dialog.CheckFileExists = $true
$dialog.CheckPathExists = $true

if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
    return
}

$inputPath = $dialog.FileName
$topDomainChoice = [System.Windows.Forms.MessageBox]::Show(
    'Do you want top domains only and remove any subdomains?',
    'Domain deduplication mode',
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Question
)
$topDomainsOnly = $topDomainChoice -eq [System.Windows.Forms.DialogResult]::Yes

$inputDirectory = [System.IO.Path]::GetDirectoryName($inputPath)
$inputBaseName = [System.IO.Path]::GetFileNameWithoutExtension($inputPath)
$outputPath = Join-Path $inputDirectory ("deduplicated_{0}.txt" -f $inputBaseName)

try {
    $publicSuffixRules = $null
    if ($topDomainsOnly) {
        $publicSuffixRules = Get-PublicSuffixRuleSets
    }

    $html = [System.IO.File]::ReadAllText($inputPath)

    # Chrome exports bookmarks in Netscape Bookmark File Format. Extract every
    # HREF value while accepting double-quoted, single-quoted and unquoted URLs.
    $hrefPattern = "(?is)<a\b[^>]*\bhref\s*=\s*(?:""(?<href>[^""]*)""|'(?<href>[^']*)'|(?<href>[^\s>]+))"
    $matches = [System.Text.RegularExpressions.Regex]::Matches($html, $hrefPattern)

    $seen = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $domains = [System.Collections.Generic.List[string]]::new()

    foreach ($match in $matches) {
        $rawUrl = [System.Net.WebUtility]::HtmlDecode($match.Groups['href'].Value).Trim()
        $uri = $null

        if (-not [System.Uri]::TryCreate($rawUrl, [System.UriKind]::Absolute, [ref]$uri)) {
            continue
        }

        if ($uri.Scheme -notin @('http', 'https')) {
            continue
        }

        # IdnHost converts internationalized domain names to ASCII/Punycode,
        # which is convenient for later API lookups.
        $domain = $uri.IdnHost.ToLowerInvariant().TrimEnd('.')
        $domain = $domain -replace '^www\.', ''

        if ([string]::IsNullOrWhiteSpace($domain)) {
            continue
        }

        if ($topDomainsOnly) {
            $domain = Get-RegistrableDomain -Domain $domain -Rules $publicSuffixRules
        }

        if ($seen.Add($domain)) {
            [void]$domains.Add($domain)
        }
    }

    if (Test-Path -LiteralPath $outputPath) {
        $choice = [System.Windows.Forms.MessageBox]::Show(
            "The output file already exists:`r`n$outputPath`r`n`r`nReplace it?",
            'Replace existing file?',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) {
            return
        }
    }

    $utf8WithoutBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllLines($outputPath, $domains, $utf8WithoutBom)

    $domainCountLabel = if ($topDomainsOnly) {
        'Unique top domains written'
    }
    else {
        'Unique domains written'
    }

    [void][System.Windows.Forms.MessageBox]::Show(
        ("Finished.`r`n`r`nBookmark links found: {0}`r`n{1}: {2}`r`n`r`nOutput:`r`n{3}" -f `
            $matches.Count, $domainCountLabel, $domains.Count, $outputPath),
        'Bookmarks deduplicated',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
}
catch {
    [void][System.Windows.Forms.MessageBox]::Show(
        ("The bookmarks file could not be processed.`r`n`r`n{0}" -f $_.Exception.Message),
        'Error',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    )
}
