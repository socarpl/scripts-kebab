Add-Type @"
using System;
using System.Runtime.InteropServices;

public class MonitorControl
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct PHYSICAL_MONITOR
    {
        public IntPtr hPhysicalMonitor;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szPhysicalMonitorDescription;
    }

    [DllImport("user32.dll")]
    public static extern bool EnumDisplayMonitors(
        IntPtr hdc,
        IntPtr lprcClip,
        MonitorEnumProc lpfnEnum,
        IntPtr dwData
    );

    public delegate bool MonitorEnumProc(
        IntPtr hMonitor,
        IntPtr hdcMonitor,
        IntPtr lprcMonitor,
        IntPtr dwData
    );

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(
        IntPtr hMonitor,
        out uint numberOfPhysicalMonitors
    );

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetPhysicalMonitorsFromHMONITOR(
        IntPtr hMonitor,
        uint physicalMonitorArraySize,
        PHYSICAL_MONITOR[] physicalMonitorArray
    );
}
"@

$callback = [MonitorControl+MonitorEnumProc]{
    param($hMonitor, $hdcMonitor, $lprcMonitor, $dwData)

    $count = 0

    $ok = [MonitorControl]::GetNumberOfPhysicalMonitorsFromHMONITOR(
        $hMonitor,
        [ref]$count
    )

    Write-Host "GetNumberOfPhysicalMonitorsFromHMONITOR = $ok"

    if (-not $ok) {
        Write-Host "Win32 Error:" ([Runtime.InteropServices.Marshal]::GetLastWin32Error())
        return $true
    }

    Write-Host "Physical monitor count = $count"

    $physical = New-Object MonitorControl+PHYSICAL_MONITOR[] $count

    $ok2 = [MonitorControl]::GetPhysicalMonitorsFromHMONITOR(
        $hMonitor,
        $count,
        $physical
    )

    Write-Host "GetPhysicalMonitorsFromHMONITOR = $ok2"

    if (-not $ok2) {
        Write-Host "Win32 Error:" ([Runtime.InteropServices.Marshal]::GetLastWin32Error())
        return $true
    }

    foreach ($p in $physical) {
        Write-Host "Monitor:" $p.szPhysicalMonitorDescription
    }

    return $true
}

[MonitorControl]::EnumDisplayMonitors(
    [IntPtr]::Zero,
    [IntPtr]::Zero,
    $callback,
    [IntPtr]::Zero
)
