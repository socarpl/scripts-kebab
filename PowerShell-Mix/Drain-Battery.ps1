<#
.SYNOPSIS
Loads all logical CPU processors to drain a laptop battery quickly.

.DESCRIPTION
Starts one CPU-bound PowerShell job per logical processor by default. Press
Ctrl+C to stop. The script also stops all worker jobs when the duration expires.

This will make the machine hot, loud, and less responsive. Keep the laptop on a
hard surface with working ventilation.

.PARAMETER Threads
Number of CPU workers to start. Defaults to the number of logical processors.

.PARAMETER DurationMinutes
Optional runtime in minutes. Use 0 to run until Ctrl+C. Defaults to 0.

.PARAMETER Priority
Worker process priority. Defaults to Normal. High will make the system less
responsive and is usually unnecessary.

.EXAMPLE
.\Drain-Battery.ps1

.EXAMPLE
.\Drain-Battery.ps1 -DurationMinutes 30

.EXAMPLE
.\Drain-Battery.ps1 -Threads 16 -Priority AboveNormal
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 1024)]
    [int]$Threads = [Environment]::ProcessorCount,

    [ValidateRange(0, 10080)]
    [int]$DurationMinutes = 0,

    [ValidateSet('Idle', 'BelowNormal', 'Normal', 'AboveNormal', 'High')]
    [string]$Priority = 'Normal'
)

$ErrorActionPreference = 'Stop'

$worker = {
    param(
        [string]$Priority
    )

    [System.Diagnostics.Process]::GetCurrentProcess().PriorityClass = $Priority

    $x = 0.000001
    while ($true) {
        # Floating-point work keeps the interpreter busy without allocating memory.
        $x = [Math]::Sqrt($x + 1.000001)
        if ($x -gt 1000000) {
            $x = 0.000001
        }
    }
}

$jobs = @()

try {
    Write-Host "Logical processors detected: $([Environment]::ProcessorCount)"
    Write-Host "Starting $Threads CPU worker(s) at $Priority priority."
    Write-Host "Press Ctrl+C to stop."

    for ($i = 1; $i -le $Threads; $i++) {
        $jobs += Start-Job -Name "CpuDrain-$i" -ScriptBlock $worker -ArgumentList $Priority
    }

    if ($DurationMinutes -gt 0) {
        $endTime = (Get-Date).AddMinutes($DurationMinutes)
        while ((Get-Date) -lt $endTime) {
            $remaining = [Math]::Ceiling(($endTime - (Get-Date)).TotalSeconds)
            Write-Progress -Activity 'Draining battery with CPU load' -Status "$remaining second(s) remaining" -PercentComplete ((1 - ($remaining / ($DurationMinutes * 60))) * 100)
            Start-Sleep -Seconds 1
        }
    }
    else {
        while ($true) {
            $running = ($jobs | Where-Object State -eq 'Running').Count
            Write-Progress -Activity 'Draining battery with CPU load' -Status "$running worker(s) running. Press Ctrl+C to stop."
            Start-Sleep -Seconds 2
        }
    }
}
finally {
    Write-Progress -Activity 'Draining battery with CPU load' -Completed

    if ($jobs.Count -gt 0) {
        Write-Host 'Stopping CPU workers...'
        $jobs | Stop-Job -ErrorAction SilentlyContinue
        $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
    }

    Write-Host 'Stopped.'
}
