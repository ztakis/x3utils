# acp_probe.ps1 - where and when the bundled Windows OpenOCD mishandles a path.
#
# No hardware. Nothing outside the work directory is touched. Re-runnable.
# Run it on any Windows box; the ACP it reports is what the results are about.
#
#   pwsh -File acp_probe.ps1 [-Oocd <path to native\windows\oocd>] [-Work <dir>]
#
# Outcomes, which are NOT equally bad:
#   OK       - OpenOCD used the path that was asked for
#   FAIL     - OpenOCD refused it, loudly, non-zero exit or an error line
#   WRONG    - OpenOCD silently used a DIFFERENT existing path (best-fit mapping)

param(
  [string]$Oocd = '',
  [string]$Work = (Join-Path $env:TEMP 'acp_probe_work')
)

$ErrorActionPreference = 'Stop'

# ── locate the bundled OpenOCD ────────────────────────────────────────────────
if (-not $Oocd) {
  $Oocd = @(
    "$env:LOCALAPPDATA\Programs\x3utils\native\windows\oocd",
    "C:\x3utils_app\native\windows\oocd",
    "$PSScriptRoot\..\native\windows\oocd",
    "$PSScriptRoot\native\windows\oocd"
  ) | Where-Object { Test-Path (Join-Path $_ 'bin\openocd.exe') } | Select-Object -First 1
}
if (-not $Oocd -or -not (Test-Path (Join-Path $Oocd 'bin\openocd.exe'))) {
  Write-Host "openocd not found - pass -Oocd <path to native\windows\oocd>"
  exit 1
}
$exe = (Resolve-Path (Join-Path $Oocd 'bin\openocd.exe')).Path

# ── environment, so any pasted result is self-describing ─────────────────────
$acp = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
$ver = (& $exe --version 2>&1 | Select-Object -First 1)
"== acp_probe =="
"USER   : $env:USERNAME"
"ACP    : $acp   (results below are about THIS codepage only)"
"OOCD   : $exe"
"VERSION: $ver"
"WORK   : $Work"
""

# ── the character classes ────────────────────────────────────────────────────
# Built from code points so this file's own encoding cannot corrupt them.
$N = [ordered]@{
  ascii  = 'AsciiCtl'
  greek  = "$([char]0x0386)$([char]0x03BA)$([char]0x03B7)$([char]0x03C2)"          # Άκης
  umlaut = "J$([char]0x00F6)rg"                                                    # Jörg
  plain  = 'Jorg'                                                                  # best-fit twin of Jörg
  cyr    = "$([char]0x0421)$([char]0x0430)$([char]0x0448)$([char]0x0430)"          # Саша
}

# ── build the tree ───────────────────────────────────────────────────────────
if (Test-Path $Work) { Remove-Item -LiteralPath $Work -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Work | Out-Null
foreach ($k in $N.Keys) {
  $d = Join-Path $Work $N[$k]
  New-Item -ItemType Directory -Force -Path (Join-Path $d 'scripts') | Out-Null
  # a cfg that names the directory it was loaded from
  Set-Content -LiteralPath (Join-Path $d 'scripts\probe.cfg') -Value "echo `"MARK:$k`"" -Encoding ascii
  # a firmware-shaped file that names the directory it was read from
  Set-Content -LiteralPath (Join-Path $d 'fw.bin') -Value "FW:$k" -Encoding ascii -NoNewline
}

function Fwd([string]$p) { $p.Replace([char]92, '/') }

$rows = @()
function Row($where, $class, $outcome, $detail) {
  $script:rows += [pscustomobject]@{ Where = $where; Class = $class; Outcome = $outcome; Detail = $detail }
}

# Classify by which MARK came back: the one asked for, another one, or none.
function Verdict($out, $code, $expect) {
  $m = [regex]::Match($out, 'MARK:(\w+)')
  if ($m.Success) {
    $got = [string]$m.Groups[1].Value
    if ($got -eq $expect) { return @('OK', "MARK:$expect") }
    return @('WRONG', "asked $expect, loaded MARK:$got")
  }
  $e = ($out -split "`n" | Where-Object { $_ -match "Can't find|Invalid argument|error|Error" } | Select-Object -First 1)
  return @('FAIL', ("exit=$code " + "$e".Trim()))
}

# ── 1. -s <dir> absolute  (OpenOcdRunner._base) ──────────────────────────────
foreach ($k in 'ascii','greek','umlaut','cyr') {
  $s = Join-Path (Join-Path $Work $N[$k]) 'scripts'
  $out = & $exe -s $s -d0 -f probe.cfg -c exit 2>&1 | Out-String
  $v = Verdict $out $LASTEXITCODE $k
  Row '-s <dir> absolute' $k $v[0] $v[1]
}

# ── 2. -f <cfg> absolute  (the rdp.ps1 rescue.cfg pattern) ───────────────────
foreach ($k in 'ascii','greek','umlaut','cyr') {
  $f = Join-Path (Join-Path $Work $N[$k]) 'scripts\probe.cfg'
  $out = & $exe -d0 -f $f -c exit 2>&1 | Out-String
  $v = Verdict $out $LASTEXITCODE $k
  Row '-f <cfg> absolute' $k $v[0] $v[1]
}

# ── 3. file READ by a command  (write_image / verify_image input) ────────────
foreach ($k in 'ascii','greek','umlaut','cyr') {
  $p = Fwd (Join-Path (Join-Path $Work $N[$k]) 'fw.bin')
  $tcl = 'set f [open {' + $p + '} rb]; puts "MARK:[read $f 32]"; close $f; exit'
  $out = & $exe -d0 -c $tcl 2>&1 | Out-String
  $m = [regex]::Match($out, 'MARK:FW:(\w+)')
  if ($m.Success) {
    if ($m.Groups[1].Value -eq $k) { Row 'file read (open rb)' $k 'OK' "FW:$k" }
    else { Row 'file read (open rb)' $k 'WRONG' ("asked $k, read FW:" + $m.Groups[1].Value) }
  } else {
    $e = ($out -split "`n" | Where-Object { $_ -match 'Invalid argument|No such file|error' } | Select-Object -First 1)
    Row 'file read (open rb)' $k 'FAIL' ("$e".Trim())
  }
}

# ── 4. file WRITE by a command  (dump_image output) ──────────────────────────
# The decisive dump-destination test: check on disk WHERE the bytes landed.
foreach ($k in 'umlaut','cyr','greek') {
  $target = Join-Path (Join-Path $Work $N[$k]) 'out.bin'
  $twin   = Join-Path (Join-Path $Work $N['plain']) 'out.bin'
  Remove-Item -LiteralPath $target,$twin -Force -ErrorAction SilentlyContinue
  $tcl = 'set f [open {' + (Fwd $target) + '} wb]; puts $f "WROTE"; close $f; exit'
  $out = & $exe -d0 -c $tcl 2>&1 | Out-String
  if (Test-Path -LiteralPath $target)   { Row 'file write (open wb)' $k 'OK'    'landed at the requested path' }
  elseif (Test-Path -LiteralPath $twin) { Row 'file write (open wb)' $k 'WRONG' ("landed in " + $N['plain'] + " instead") }
  else {
    $e = ($out -split "`n" | Where-Object { $_ -match 'Invalid argument|No such file|error' } | Select-Object -First 1)
    Row 'file write (open wb)' $k 'FAIL' ("$e".Trim())
  }
}

# ── 5. best-fit WITHOUT the ASCII twin present ───────────────────────────────
# Separates "fails" from "silently hits the wrong file". Same umlaut read,
# with the Jorg directory moved out of the way.
$plainDir = Join-Path $Work $N['plain']
$hidden   = Join-Path $Work '_hidden_twin'
Move-Item -LiteralPath $plainDir -Destination $hidden -Force
$p = Fwd (Join-Path (Join-Path $Work $N['umlaut']) 'fw.bin')
$tcl = 'set f [open {' + $p + '} rb]; puts "MARK:[read $f 32]"; close $f; exit'
$out = & $exe -d0 -c $tcl 2>&1 | Out-String
if ($out -match 'MARK:FW:umlaut') { Row 'file read, no ASCII twin' 'umlaut' 'OK' 'FW:umlaut' }
elseif ($out -match 'MARK:FW:')   { Row 'file read, no ASCII twin' 'umlaut' 'WRONG' 'read some other file' }
else {
  $e = ($out -split "`n" | Where-Object { $_ -match 'Invalid argument|No such file|error' } | Select-Object -First 1)
  Row 'file read, no ASCII twin' 'umlaut' 'FAIL' ("$e".Trim())
}
Move-Item -LiteralPath $hidden -Destination $plainDir -Force

# ── 6. exe + working directory inside a non-representable tree, relative -s ──
# Process.start passes the exe path and cwd wide; only argv is converted.
$appRoot = Join-Path $Work ($N['cyr'] + '_app')
New-Item -ItemType Directory -Force -Path (Join-Path $appRoot 'bin') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $appRoot 'scripts') | Out-Null
Copy-Item (Join-Path $Oocd 'bin\*') -Destination (Join-Path $appRoot 'bin') -Force
Set-Content -LiteralPath (Join-Path $appRoot 'scripts\probe.cfg') -Value 'echo "MARK:relative"' -Encoding ascii
Push-Location (Join-Path $appRoot 'bin')
$out = & .\openocd.exe -s ..\scripts -d0 -f probe.cfg -c exit 2>&1 | Out-String
$code = $LASTEXITCODE
Pop-Location
if ($out -match 'MARK:relative') { Row 'relative -s, exe in bad tree' 'cyr' 'OK' 'cfg resolved via ..\scripts' }
else {
  $e = ($out -split "`n" | Where-Object { $_ -match "Can't find|error" } | Select-Object -First 1)
  Row 'relative -s, exe in bad tree' 'cyr' 'FAIL' ("exit=$code " + "$e".Trim())
}

# ── report ───────────────────────────────────────────────────────────────────
""
$rows | Format-Table -AutoSize
""
"WRONG = OpenOCD silently used a different existing path. That is the failure"
"class a guard exists to prevent; FAIL is merely an unusable app."
