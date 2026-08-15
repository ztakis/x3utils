#!/usr/bin/env bash
set -euo pipefail

PROCESS_NAME="${1:-x3utils}"

usage() {
  cat <<'USAGE'
Usage: window_size_macos.sh [process-name]

Reports the outer and content sizes, in screen points, of the first visible
matching macOS application window. The process name defaults to "x3utils".
USAGE
}

fail() {
  echo "window_size_macos.sh: $*" >&2
  exit 1
}

if [[ "$PROCESS_NAME" == "-h" || "$PROCESS_NAME" == "--help" ]]; then
  usage
  exit 0
fi

[[ $# -le 1 ]] || {
  usage >&2
  exit 2
}

[[ "$(uname -s)" == "Darwin" ]] ||
  fail "This helper only runs on macOS."

command -v xcrun >/dev/null 2>&1 ||
  fail "Required command not found: xcrun"
xcrun --find swift >/dev/null 2>&1 ||
  fail "The Swift toolchain was not found. Install the Xcode command-line tools."

xcrun swift - "$PROCESS_NAME" <<'SWIFT'
import AppKit
import CoreGraphics
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(
        Data("window_size_macos.sh: \(message)\n".utf8)
    )
    exit(1)
}

func rounded(_ value: CGFloat) -> String {
    String(Int(value.rounded()))
}

func bounds(of window: [String: Any]) -> CGRect? {
    guard
        let dictionary = window[kCGWindowBounds as String] as? [String: Any]
    else {
        return nil
    }
    return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
}

let requestedName = CommandLine.arguments[1]
let windows = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements],
    kCGNullWindowID
) as? [[String: Any]] ?? []

let match = windows.first { window in
    guard
        let layer = window[kCGWindowLayer as String] as? Int,
        layer == 0,
        let processIdValue = window[kCGWindowOwnerPID as String] as? NSNumber,
        let bounds = bounds(of: window),
        bounds.width > 0,
        bounds.height > 0
    else {
        return false
    }

    let processId = pid_t(processIdValue.int32Value)
    let application = NSRunningApplication(processIdentifier: processId)
    let names = [
        window[kCGWindowOwnerName as String] as? String,
        application?.localizedName,
        application?.executableURL?.lastPathComponent,
    ].compactMap { $0 }

    return names.contains {
        $0.compare(requestedName, options: .caseInsensitive) == .orderedSame
    }
}

guard
    let window = match,
    let processIdValue = window[kCGWindowOwnerPID as String] as? NSNumber,
    let outer = bounds(of: window)
else {
    fail("No visible '\(requestedName)' window was found. Keep the app open and not minimized, then try again.")
}

let styleMask: NSWindow.StyleMask = [
    .titled,
    .closable,
    .miniaturizable,
    .resizable,
]
let content = NSWindow.contentRect(forFrameRect: outer, styleMask: styleMask)
let processId = pid_t(processIdValue.int32Value)
let application = NSRunningApplication(processIdentifier: processId)
let title = window[kCGWindowName as String] as? String
    ?? application?.localizedName
    ?? requestedName

print("ProcessId   : \(processId)")
print("WindowTitle : \(title)")
print("OuterSize   : \(rounded(outer.width)) x \(rounded(outer.height))")
print("ClientSize  : \(rounded(content.width)) x \(rounded(content.height))")
print("Position    : \(rounded(outer.minX)), \(rounded(outer.minY))")
SWIFT
