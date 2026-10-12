Add-Type -AssemblyName Microsoft.VisualBasic

$Root = 'D:\'

function Remove-ThumbsDbToRecycleBin {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StartPath
    )

    $stack = New-Object System.Collections.Stack
    $stack.Push($StartPath)

    while ($stack.Count -gt 0) {
        $currentPath = $stack.Pop()

        # First, try to delete Thumbs.db in the current folder
        try {
            Get-ChildItem -LiteralPath $currentPath -Force -File -ErrorAction Stop |
                Where-Object { $_.Name -ieq 'Thumbs.db' } |
                ForEach-Object {
                    try {
                        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                            $_.FullName,
                            [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                            [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
                        )
                        Write-Host "[OK] $($_.FullName)"
                    }
                    catch {
                        Write-Host "[SKIP] $($_.FullName) -- $($_.Exception.Message)"
                    }
                }
        }
        catch {
            Write-Host "[SKIP] Cannot access files in $currentPath -- $($_.Exception.Message)"
        }

        # Then, recurse into subfolders
        try {
            Get-ChildItem -LiteralPath $currentPath -Force -Directory -ErrorAction Stop |
                ForEach-Object {
                    $stack.Push($_.FullName)
                }
        }
        catch {
            Write-Host "[SKIP] Cannot access folders in $currentPath -- $($_.Exception.Message)"
        }
    }
}

Remove-ThumbsDbToRecycleBin -StartPath $Root
