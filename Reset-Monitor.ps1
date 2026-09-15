#Requires -Version 5.1
<#
.SYNOPSIS
Lists connected monitors, or disconnects one for 10 seconds and extends it again.
.EXAMPLE
.\Reset-Monitor.ps1
.EXAMPLE
.\Reset-Monitor.ps1 2
.NOTES
Windows 10/11; run in your local interactive desktop session, not via RDP.
IDs belong to this script, not Windows Settings. Re-list after changing cables/docks.
The embedded C# uses QueryDisplayConfig / SetDisplayConfig. No external modules.
Already disconnected displays remain disconnected during the countdown, then extend.
A duplicated display is reconnected as an independent extended display.
Do not close/kill the PowerShell process during the countdown. A finally block
attempts reconnection on normal interruption, but cannot survive process termination.
Restoring a display layout does not restore application window positions.
Reference: https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-setdisplayconfig
#>
[CmdletBinding()]
param([Parameter(Position=0)][ValidateRange(1,2147483647)][int]$MonitorId)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'This script requires Windows.' }

if (-not ('MonitorCycleV1.Config' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace MonitorCycleV1 {
    [StructLayout(LayoutKind.Sequential)] public struct Luid { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] public struct Rational { public uint Numerator, Denominator; }
    [StructLayout(LayoutKind.Sequential)] public struct Source {
        public Luid Adapter; public uint Id, ModeIndex, Status;
    }
    [StructLayout(LayoutKind.Sequential)] public struct Target {
        public Luid Adapter; public uint Id, ModeIndex, Technology, Rotation, Scaling;
        public Rational Refresh; public uint Scanline; public int Available; public uint Status;
    }
    [StructLayout(LayoutKind.Sequential)] public struct Path {
        public Source Source; public Target Target; public uint Flags;
    }
    // The native union occupies 48 bytes. Preserve target signal data verbatim.
    [StructLayout(LayoutKind.Explicit, Size=64)] public struct Mode {
        [FieldOffset(0)] public uint Type;
        [FieldOffset(4)] public uint Id;
        [FieldOffset(8)] public Luid Adapter;
        [FieldOffset(16)] public ulong Data0;
        [FieldOffset(24)] public ulong Data1;
        [FieldOffset(32)] public ulong Data2;
        [FieldOffset(40)] public ulong Data3;
        [FieldOffset(48)] public ulong Data4;
        [FieldOffset(56)] public ulong Data5;
        [FieldOffset(16)] public uint Width;
        [FieldOffset(20)] public uint Height;
        [FieldOffset(24)] public uint PixelFormat;
        [FieldOffset(28)] public int X;
        [FieldOffset(32)] public int Y;
    }
    [StructLayout(LayoutKind.Sequential)] public struct Header {
        public uint Type, Size; public Luid Adapter; public uint Id;
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct TargetName {
        public Header Header; public uint Flags, Technology;
        public ushort Manufacturer, Product; public uint Connector;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=64)] public string Name;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DevicePath;
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct SourceName {
        public Header Header;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string Name;
    }
    public class Display {
        public int MonitorId { get; set; }
        public string Name { get; set; }
        public string WindowsDevice { get; set; }
        public bool Active { get; set; }
        public bool Primary { get; set; }
        public string Resolution { get; set; }
        public string Position { get; set; }
        internal string Key, SortKey;
    }
    public class Snapshot { public Path[] Paths; public Mode[] Modes; }
    public class Cycle { public Snapshot Before, Off, On; public string TargetKey; }
    public static class Config {
        const uint ACTIVE=1, USE=0x20, VALIDATE=0x40, APPLY=0x80, ALLOW=0x400;
        [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint paths, out uint modes);
        [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint paths,
            [Out] Path[] pathArray, ref uint modes, [Out] Mode[] modeArray, IntPtr topology);
        [DllImport("user32.dll")] static extern int SetDisplayConfig(uint paths, [In] Path[] pathArray,
            uint modes, [In] Mode[] modeArray, uint flags);
        [DllImport("user32.dll", EntryPoint="DisplayConfigGetDeviceInfo")] static extern int GetTargetName(ref TargetName name);
        [DllImport("user32.dll", EntryPoint="DisplayConfigGetDeviceInfo")] static extern int GetSourceName(ref SourceName name);
        static void Check(int code, string operation) {
            if(code!=0) throw new Win32Exception(code, operation+": "+new Win32Exception(code).Message+" ("+code+")");
        }
        static string Key(Luid a, uint id) { return a.High.ToString("X8")+a.Low.ToString("X8")+":"+id.ToString("D10"); }
        static string TK(Path p) { return Key(p.Target.Adapter,p.Target.Id); }
        static string SK(Path p) { return Key(p.Source.Adapter,p.Source.Id); }
        public static Snapshot Query() {
            if(Marshal.SizeOf(typeof(Path))!=72 || Marshal.SizeOf(typeof(Mode))!=64 ||
               Marshal.SizeOf(typeof(TargetName))!=420 || Marshal.SizeOf(typeof(SourceName))!=84)
                throw new InvalidOperationException("Unexpected native structure sizes.");
            // Legacy mode view: do not request packed virtual-mode indices.
            for(int attempt=0;attempt<8;attempt++) {
                uint np,nm; Check(GetDisplayConfigBufferSizes(1,out np,out nm),"GetDisplayConfigBufferSizes");
                Path[] p=new Path[np]; Mode[] m=new Mode[nm];
                int r=QueryDisplayConfig(1,ref np,p,ref nm,m,IntPtr.Zero);
                if(r==122) continue;
                Check(r,"QueryDisplayConfig"); Array.Resize(ref p,(int)np); Array.Resize(ref m,(int)nm);
                return new Snapshot { Paths=p, Modes=m };
            }
            throw new InvalidOperationException("Display configuration kept changing. Retry when stable.");
        }
        static Snapshot Active(Snapshot s) {
            List<Path> p=new List<Path>();
            foreach(Path x in s.Paths) if((x.Flags&ACTIVE)!=0) p.Add(x);
            return new Snapshot { Paths=p.ToArray(), Modes=(Mode[])s.Modes.Clone() };
        }
        public static Display[] List(Snapshot s) {
            Dictionary<string,Path> targets=new Dictionary<string,Path>();
            foreach(Path p in s.Paths) {
                if(p.Target.Available==0 && (p.Flags&ACTIVE)==0) continue;
                string k=TK(p);
                if(!targets.ContainsKey(k) || (p.Flags&ACTIVE)!=0) targets[k]=p;
            }
            List<Display> result=new List<Display>();
            foreach(KeyValuePair<string,Path> item in targets) {
                Path p=item.Value; bool active=(p.Flags&ACTIVE)!=0;
                TargetName n=new TargetName(); n.Header=new Header { Type=2, Size=420, Adapter=p.Target.Adapter, Id=p.Target.Id };
                int nr=GetTargetName(ref n);
                SourceName sn=new SourceName(); sn.Header=new Header { Type=1, Size=84, Adapter=p.Source.Adapter, Id=p.Source.Id };
                int sr=active?GetSourceName(ref sn):-1;
                Display d=new Display { Key=item.Key, SortKey=(nr==0?n.DevicePath:"")+item.Key,
                    Name=nr==0&&!String.IsNullOrEmpty(n.Name)?n.Name:"Unnamed monitor",
                    WindowsDevice=sr==0?sn.Name:"-", Active=active, Resolution="-", Position="-" };
                if(active && p.Source.ModeIndex<s.Modes.Length) {
                    Mode m=s.Modes[p.Source.ModeIndex];
                    if(m.Type==1) { d.Primary=m.X==0&&m.Y==0; d.Resolution=m.Width+" x "+m.Height; d.Position=m.X+", "+m.Y; }
                }
                result.Add(d);
            }
            result.Sort(delegate(Display a,Display b) { return StringComparer.OrdinalIgnoreCase.Compare(a.SortKey,b.SortKey); });
            for(int i=0;i<result.Count;i++) result[i].MonitorId=i+1;
            return result.ToArray();
        }
        static int Set(Snapshot s,uint flags) {
            return SetDisplayConfig((uint)s.Paths.Length,s.Paths,(uint)s.Modes.Length,s.Modes,USE|flags);
        }
        static void Validate(Snapshot s,string label) { Check(Set(s,VALIDATE|ALLOW),label); }
        public static Cycle Prepare(Snapshot all, int id) {
            Display[] displays=List(all);
            if(id<1 || id>displays.Length) throw new ArgumentOutOfRangeException("id","Monitor ID not found. Run without parameters first.");
            string key=displays[id-1].Key;
            Snapshot before=Active(all);
            List<Path> keep=new List<Path>(); Path selected=new Path(); bool wasActive=false;
            foreach(Path p in before.Paths) {
                if(TK(p)==key) { selected=p; wasActive=true; } else keep.Add(p);
            }
            if(keep.Count==0) throw new InvalidOperationException("Cannot disconnect the last active display.");
            Snapshot off=new Snapshot { Paths=keep.ToArray(), Modes=(Mode[])before.Modes.Clone() };
            // If removing the primary, translate remaining source positions so a screen is at (0,0).
            bool hasPrimary=false; int dx=0,dy=0; bool found=false;
            foreach(Path p in off.Paths) {
                if(p.Source.ModeIndex>=off.Modes.Length) continue;
                Mode m=off.Modes[p.Source.ModeIndex]; if(m.Type!=1) continue;
                if(!found) { dx=m.X;dy=m.Y;found=true; }
                if(m.X==0&&m.Y==0) hasPrimary=true;
            }
            if(!hasPrimary && found) {
                HashSet<uint> moved=new HashSet<uint>();
                foreach(Path p in off.Paths) {
                    uint ix=p.Source.ModeIndex;
                    if(ix<off.Modes.Length && moved.Add(ix) && off.Modes[ix].Type==1) {
                        off.Modes[ix].X-=dx; off.Modes[ix].Y-=dy;
                    }
                }
            }
            bool cloned=false;
            if(wasActive) foreach(Path p in keep) if(SK(p)==SK(selected)) cloned=true;
            Snapshot on=before;
            if(!wasActive || cloned) {
                // An independent source is required for Extend (sharing a source creates a clone).
                HashSet<string> used=new HashSet<string>(); foreach(Path p in keep) used.Add(SK(p));
                Snapshot candidate=null;
                foreach(Path p in all.Paths) {
                    if(TK(p)!=key || p.Target.Available==0 || used.Contains(SK(p))) continue;
                    Path extra=p; extra.Flags=ACTIVE;
                    extra.Source.ModeIndex=UInt32.MaxValue; extra.Target.ModeIndex=UInt32.MaxValue;
                    List<Path> paths=new List<Path>(keep); paths.Add(extra);
                    Snapshot test=new Snapshot { Paths=paths.ToArray(), Modes=(Mode[])before.Modes.Clone() };
                    if(Set(test,VALIDATE|ALLOW)==0) { candidate=test; break; }
                }
                if(candidate==null) throw new InvalidOperationException("The driver could not validate an independent extended path for this monitor. No settings were changed.");
                on=candidate;
            }
            Validate(off,"Validate disconnect"); Validate(on,"Validate reconnect");
            return new Cycle { Before=before, Off=off, On=on, TargetKey=key };
        }
        public static void Disconnect(Cycle c) {
            Check(Set(c.Off,APPLY|ALLOW),"Disconnect display");
            foreach(Path p in Active(Query()).Paths) if(TK(p)==c.TargetKey)
                throw new InvalidOperationException("Windows still reports the selected display as active.");
        }
        public static void Reconnect(Cycle c) {
            int r=Set(c.On,APPLY); // First try the saved modes without modification.
            if(r!=0) r=Set(c.On,APPLY|ALLOW);
            if(r!=0) {
                int rollback=Set(c.Before,APPLY|ALLOW);
                throw new Win32Exception(r,"Reconnect failed: "+new Win32Exception(r).Message+
                    ". Original-layout recovery result: "+rollback+" (0 means success).");
            }
            Snapshot current=Active(Query()); bool present=false;
            foreach(Path p in current.Paths) if(TK(p)==c.TargetKey) {
                present=true;
                foreach(Path other in current.Paths) if(TK(other)!=c.TargetKey && SK(other)==SK(p))
                    throw new InvalidOperationException("Display is active, but Windows returned a duplicated rather than extended path.");
            }
            if(!present) throw new InvalidOperationException("Reconnect returned success, but Windows does not report the display as active.");
        }
    }
}
'@
}

$snapshot = [MonitorCycleV1.Config]::Query()
$monitors = [MonitorCycleV1.Config]::List($snapshot)
if (-not $PSBoundParameters.ContainsKey('MonitorId')) {
    $monitors | Format-Table MonitorId, Name, WindowsDevice, Active, Primary, Resolution, Position -AutoSize
    Write-Host 'Use this script''s MonitorId, e.g.: .\Reset-Monitor.ps1 2'
    return
}

$cycle = [MonitorCycleV1.Config]::Prepare($snapshot, $MonitorId)
Write-Host "Disconnecting monitor $MonitorId ..."
try {
    [MonitorCycleV1.Config]::Disconnect($cycle)
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $last = -1
    while ($timer.Elapsed.TotalSeconds -lt 10) {
        $remaining = [int][Math]::Ceiling(10 - $timer.Elapsed.TotalSeconds)
        if ($remaining -ne $last) {
            Write-Host "`rReconnecting in $remaining seconds ...  " -NoNewline
            $last = $remaining
        }
        Start-Sleep -Milliseconds 100
    }
}
finally {
    Write-Host "`nReconnecting monitor $MonitorId ..."
    [MonitorCycleV1.Config]::Reconnect($cycle)
}
Write-Host 'Done. Display is extended.'
