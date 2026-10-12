Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class NativeMethods {
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint esFlags);
}
'@

# Prevent the system from sleeping
$result = [NativeMethods]::SetThreadExecutionState(2147483650)

function Show-BouncingAnimation {
    param(
        [int]$barWidth = 20,        # Width of the progress bar
        [int]$delay = 100           # Delay between frame updates (in milliseconds)
    )

    $position = 0
    $direction = 1

    while ($true) {
        # Build the progress bar with a bouncing star
        $bar = for ($i = 0; $i -lt $barWidth; $i++) {
            if ($i -eq $position) { "*" } else { " " }
        }
        $barString = "[" + ($bar -join '') + "] Still running..."
        
        # Write the progress bar on the same line
        Write-Host -NoNewline "`r$barString"
        Start-Sleep -Milliseconds $delay

        # Update the star's position
        $position += $direction
        if ($position -ge ($barWidth - 1)) {
            $direction = -1
        } elseif ($position -le 0) {
            $direction = 1
        }
    }
}

# Start the animation loop
Show-BouncingAnimation
