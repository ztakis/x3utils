param(
    [string]$ProcessName = 'x3utils'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ('X3Utils.WindowMetrics' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;

namespace X3Utils {
    public static class WindowMetrics {
        [StructLayout(LayoutKind.Sequential)]
        public struct RECT {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [DllImport("user32.dll")]
        public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);

        [DllImport("user32.dll")]
        public static extern bool GetClientRect(IntPtr hwnd, out RECT rect);
    }
}
'@
}

$process = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowHandle -ne 0 } |
    Select-Object -First 1

if ($null -eq $process) {
    throw "No visible '$ProcessName' window was found. Keep the app open and not minimized, then try again."
}

$outer = [X3Utils.WindowMetrics+RECT]::new()
$client = [X3Utils.WindowMetrics+RECT]::new()

if (-not [X3Utils.WindowMetrics]::GetWindowRect(
        $process.MainWindowHandle,
        [ref]$outer
    )) {
    throw "Could not read the outer window rectangle."
}

if (-not [X3Utils.WindowMetrics]::GetClientRect(
        $process.MainWindowHandle,
        [ref]$client
    )) {
    throw "Could not read the client window rectangle."
}

[pscustomobject]@{
    ProcessId  = $process.Id
    WindowTitle = $process.MainWindowTitle
    OuterSize  = '{0} x {1}' -f (
        $outer.Right - $outer.Left
    ), ($outer.Bottom - $outer.Top)
    ClientSize = '{0} x {1}' -f $client.Right, $client.Bottom
    Position   = '{0}, {1}' -f $outer.Left, $outer.Top
}
