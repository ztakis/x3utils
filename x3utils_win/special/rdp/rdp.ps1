<#
    rdp.ps1 - AT32F415 read-protection (FAP) toolkit for Windows.

    Windows-native rewrite of the Linux special/rdp/ tools (rdp_check.sh,
    fap_clear.sh, fap_enable.sh, rescue_unlock.sh), consolidated into one
    verb-dispatched PowerShell script. Written for Windows PowerShell 5.1+
    (no PS7-only syntax) so it runs on a stock Windows 10 machine.

    VERBS (choose one; -Check is the default):
      -Check    Read-only detector. Verdict + exit code:
                  0 = NOT read protected (readable)
                  2 = READ PROTECTED
                  3 = INCONCLUSIVE / could not determine
      -Clear    Restore pristine option bytes (FAP=0xA5, WRP/SSB/Data=0xFF).
                On a protected part this MASS-ERASES main flash on reload.
      -Rescue   Last-resort unlock via universal manual connect-under-reset
                (rescue.cfg guided_rescue). Same rewrite as -Clear.
      -Enable   TESTBED ONLY: turn read protection ON (FAP=0x00) to validate
                the -Check "READ PROTECTED" branch. DESTRUCTIVE.

    SWITCHES:
      -Yes        Skip the typed confirmation for destructive verbs.
      -Launcher   Honor the launcher-selected connect mode in config.cmd
                  ($TARGET) instead of the default guided rescue connect.

    WHY RAW REGISTER WRITES (not disable_access_protection):
      The bundled OpenOCD's `at32f4xx disable_access_protection 0` reads the
      USD, overrides only FAP, and writes the rest back. On a still-protected
      part the USD reads masked to 0x00000000, so it programs WRP/SSB to 0x00
      and leaves the part WRITE-protected. Reproduced deterministically on
      hardware (3/3 testbed runs, 2026-07-06): the protected part's USD reads
      back as `ff005aa5 ff00ff00 ff00ff00 ff00ff00` -- FAP unlocked (A5/5A) but
      SSB and WRP0..3 forced to 0x00, after which re-flashing FAILS on the
      erase of the now write-protected sectors. Every unlock path here instead
      erases the USD and programs ONLY the FAP half-word via raw flash-
      controller registers. NEVER call disable_access_protection to recover a
      read-protected board.

    CONTACT RETRY (design goal): the #1 real-world failure is losing hand-held
    SWD contact on the tiny nRST/C45 cap mid-connect. Every verb wraps its
    OpenOCD session in a re-seat-and-retry loop, so a fumbled contact never
    forces re-typing the command or re-confirming. The guided connect
    shutdown-errors BEFORE any write runs, so a failed attempt writes nothing.

    RUN (execution policy may block a bare double-click):
      powershell -NoProfile -ExecutionPolicy Bypass -File rdp.ps1 -Check
#>

[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$Clear,
    [switch]$Enable,
    [switch]$Rescue,
    [switch]$Yes,
    [switch]$Launcher
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

# --- Resolve the single verb ------------------------------------------------
$verbs = @()
if ($Check)  { $verbs += 'Check'  }
if ($Clear)  { $verbs += 'Clear'  }
if ($Enable) { $verbs += 'Enable' }
if ($Rescue) { $verbs += 'Rescue' }
if ($verbs.Count -gt 1) {
    Write-Host "Pick exactly one verb: -Check | -Clear | -Enable | -Rescue"
    exit 3
}
$Verb = if ($verbs.Count -eq 1) { $verbs[0] } else { 'Check' }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WinRoot   = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path

# ---------------------------------------------------------------------------
# Console colors (ANSI). Enable VT so the escapes render on legacy consoles.
# ---------------------------------------------------------------------------
function Enable-Vt {
    try {
        if (-not ([System.Management.Automation.PSTypeName]'Rdp.NativeVt').Type) {
            Add-Type -Namespace Rdp -Name NativeVt -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern System.IntPtr GetStdHandle(int nStdHandle);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool GetConsoleMode(System.IntPtr hConsoleHandle, out uint lpMode);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool SetConsoleMode(System.IntPtr hConsoleHandle, uint dwMode);
'@
        }
        $h = [Rdp.NativeVt]::GetStdHandle(-11)   # STD_OUTPUT_HANDLE
        $mode = 0
        if ([Rdp.NativeVt]::GetConsoleMode($h, [ref]$mode)) {
            [void][Rdp.NativeVt]::SetConsoleMode($h, $mode -bor 0x0004)  # ENABLE_VIRTUAL_TERMINAL_PROCESSING
        }
    } catch {
        # No console (or restricted) - colors may show as raw codes; harmless.
    }
}
Enable-Vt

$E     = [char]27
$CL_NC = "$E[0m"
$CL_R  = "$E[1;31m"
$CL_G  = "$E[1;32m"
$CL_Y  = "$E[1;33m"
$CL_C  = "$E[1;36m"
$D     = '============================================================'

function Say     { param([string]$m) Write-Host $m }
function SayOk   { param([string]$m) Write-Host "[ ${CL_G}OK${CL_NC} ] $m" }
function SayInfo { param([string]$m) Write-Host "[${CL_C}INFO${CL_NC}] $m" }
function SayWarn { param([string]$m) Write-Host "[${CL_Y}WARN${CL_NC}] $m" }
function SayFail { param([string]$m) Write-Host "[${CL_R}FAIL${CL_NC}] $m" }

# ---------------------------------------------------------------------------
# Configuration. Reuse the paths from config.cmd; read TARGET/CONNECT_TIMEOUT
# from it so -Launcher honors whatever launcher.bat last selected.
# ---------------------------------------------------------------------------
function Get-RdpConfig {
    $openocd = Join-Path $WinRoot 'oocd\bin\openocd.exe'
    $scripts = Join-Path $WinRoot 'oocd\scripts'
    $target  = 'target\at32f415xx_c45.cfg'
    $timeout = 3

    $cfgCmd = Join-Path $WinRoot 'config.cmd'
    if (Test-Path $cfgCmd) {
        foreach ($line in Get-Content $cfgCmd) {
            if ($line -match '^\s*set\s+"TARGET=([^"]+)"')          { $target  = $Matches[1].Trim() }
            elseif ($line -match '^\s*set\s+"CONNECT_TIMEOUT=([^"]+)"') { $timeout = $Matches[1].Trim() }
        }
    }

    if (-not (Test-Path $openocd)) { SayFail "OpenOCD binary not found: $openocd"; exit 3 }
    if (-not (Test-Path $scripts)) { SayFail "OpenOCD scripts dir not found: $scripts"; exit 3 }

    return @{
        OpenOcd   = $openocd
        Scripts   = $scripts
        Interface = 'interface\stlink.cfg'
        Target    = $target
        Timeout   = $timeout
    }
}

# Resolve the connect arguments for the chosen mode, mirroring rdp_lib.sh's
# resolve_connect. Returns Pre[] (-f args), Connect[] (-c args), and a label.
function Resolve-Connect {
    param($cfg, [switch]$UseLauncher)

    if ($UseLauncher) {
        switch -Wildcard ($cfg.Target) {
            '*_c45.cfg' {
                return @{
                    Pre     = @('-f', $cfg.Target)              # c45 bundles the interface
                    Connect = @('-c', "guided_connect {$($cfg.Timeout)}")
                    Mode    = 'launcher B - guided connect-under-reset (c45)'
                    Plain   = $false
                }
            }
            '*_nrst.cfg' {
                return @{
                    Pre     = @('-f', $cfg.Interface, '-f', $cfg.Target)
                    Connect = @('-c', 'init', '-c', 'reset halt')
                    Mode    = 'launcher C - ST-Link reset (connect-under-reset)'
                    Plain   = $false
                }
            }
            default {
                return @{
                    Pre     = @('-f', $cfg.Interface, '-f', $cfg.Target)
                    Connect = @('-c', 'init', '-c', 'reset halt')
                    Mode    = 'launcher A - plain (SWD already available)'
                    Plain   = $true
                }
            }
        }
    }

    $rescue = Join-Path $ScriptDir 'rescue.cfg'
    if (-not (Test-Path $rescue)) { SayFail "Missing rescue.cfg beside rdp.ps1"; exit 3 }
    # OpenOCD is happiest with forward slashes in -f paths.
    $rescueFwd = ($rescue -replace '\\', '/')
    return @{
        Pre     = @('-f', $rescueFwd)
        Connect = @('-c', "guided_rescue {$($cfg.Timeout)}")
        Mode    = 'default - guided connect-under-reset (rescue.cfg)'
        Plain   = $false
    }
}

# Deterministic option-area rewrite: erase USD, program ONLY FAP.
# 0x5AA5 => FAP=0xA5 (unlocked); 0xFF00 => FAP=0x00 (protected).
# Raw flash-controller writes, so they work after ANY connect method.
function Get-FapRewrite {
    param([ValidateSet('Unlock', 'Protect')]$Kind)
    $half = if ($Kind -eq 'Unlock') { '0x5AA5' } else { '0xFF00' }
    $desc = if ($Kind -eq 'Unlock') { 'FAP=0xA5 (unlocked)' } else { 'FAP=0x00 (protected)' }
    return @(
        '-c', "echo {--- erase USD, program $desc ---}",
        '-c', 'mww 0x40022004 0x45670123',
        '-c', 'mww 0x40022004 0xCDEF89AB',
        '-c', 'mww 0x40022008 0x45670123',
        '-c', 'mww 0x40022008 0xCDEF89AB',
        '-c', 'mww 0x40022010 0x220',
        '-c', 'mww 0x40022010 0x260',
        '-c', 'sleep 200',
        '-c', 'mww 0x40022010 0x210',
        '-c', "mwh 0x1FFFF800 $half",
        '-c', 'sleep 200',
        '-c', 'mww 0x40022010 0x80'
    )
}

# True when the output shows a connection/contact failure (adapter or guided
# connect could not reach/halt the target) rather than a protection state.
# This is the retry trigger for the contact re-seat loop.
function Test-ConnectFailed {
    param([string]$Text)
    return ($Text -match 'open failed|unable to open|no device found|init mode failed|Error connecting DP|Could not initialize the debug port|Could not re-examine target|Could not halt target|Adapter init failed|invalid mode value')
}

# Run one OpenOCD session, teeing combined output to the log AND the console
# (so the guided connect prompts stay live; stdin is not redirected so the
# proc's `gets stdin` still reads the keyboard). Returns @{ Code; Text }.
function Invoke-OpenOcd {
    param($cfg, [string[]]$OocdArgs, [string]$LogFile)

    $full = @('-s', $cfg.Scripts, '-d0') + $OocdArgs
    # OpenOCD writes ALL logging (banner + mdw results) to stderr. Merge it with
    # 2>&1, but drop ErrorActionPreference to Continue for the native call:
    # otherwise the harmless startup banner on stderr becomes a terminating
    # NativeCommandError under the script's global 'Stop' preference.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # Convert each merged line to clean text FIRST (an empty stderr line wraps
        # as an ErrorRecord whose "$_" is the useless type name), then tee the
        # clean text to the log and echo it live.
        $lines = & $cfg.OpenOcd @full 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                if ($_.Exception -and $_.Exception.Message) { $_.Exception.Message } else { '' }
            } else { "$_" }
        } | Tee-Object -FilePath $LogFile -Append | ForEach-Object {
            Write-Host $_
            $_
        }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    return @{ Code = $code; Text = ($lines -join "`n") }
}

# Wrap an OpenOCD session in the contact re-seat retry loop. $ShouldRetry is a
# predicate over the result hashtable deciding if this was a retryable connect
# failure. Returns the final result.
function Invoke-WithRetry {
    param($cfg, [string[]]$OocdArgs, [string]$LogFile, [scriptblock]$ShouldRetry)

    while ($true) {
        $result = Invoke-OpenOcd -cfg $cfg -OocdArgs $OocdArgs -LogFile $LogFile
        if (-not (& $ShouldRetry $result)) { return $result }

        Write-Host ''
        SayWarn 'Connection/contact failed - nothing was written.'
        Say  "       Re-seat the SWD probe and the nRST/C45 contact (touch the"
        Say  "       contact point, not on top of the cap), keep it steady, then:"
        $ans = Read-Host "       ${CL_C}Press ENTER to retry, or type Q to quit${CL_NC}"
        if ($ans -match '^(q|quit)$') { return $result }
        Write-Host ''
    }
}

function New-LogPath {
    param([string]$Prefix)
    $backup = Join-Path $WinRoot 'backup'
    if (-not (Test-Path $backup)) { New-Item -ItemType Directory -Path $backup -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    return (Join-Path $backup ("{0}_{1}.log" -f $Prefix, $stamp))
}

# ===========================================================================
# VERB: Check  (read-only detector; exit 0 / 2 / 3)
# ===========================================================================
$FAP_UNLOCKED = 0xA5

function Invoke-Check {
    param($cfg, $conn)

    $log = New-LogPath 'rdp_check'

    Write-Host ''
    Say $D
    Say '          AT32F415 read-protection (FAP) check'
    Say $D
    Write-Host ''
    Say "Connect mode:   $($conn.Mode)"
    Say "Log file:       $log"
    Write-Host ''
    Say "[${CL_C}....${CL_NC}] Connecting and reading FAP/USD @ 0x1FFFF800 and flash @ 0x08000000 ..."

    $ops = @('-c', 'flash probe 0', '-c', 'mdw 0x1FFFF800 1', '-c', 'mdw 0x08000000 4', '-c', 'shutdown')
    $oocdArgs = $conn.Pre + $conn.Connect + $ops

    $result = Invoke-WithRetry -cfg $cfg -OocdArgs $oocdArgs -LogFile $log -ShouldRetry {
        param($r) Test-ConnectFailed $r.Text
    }
    $scan = $result.Text
    $adapterFailed = Test-ConnectFailed $scan

    # --- Parse FAP / USD word ------------------------------------------------
    $fapRead = $false
    $fap = 0; $fapComp = 0; $ssb = 0; $ssbComp = 0; $usdWord = ''
    $usdMatches = [regex]::Matches($scan, '(?im)^0x1ffff800:\s+([0-9a-fA-F]{8})')
    if ($usdMatches.Count -gt 0) {
        $usdWord = $usdMatches[$usdMatches.Count - 1].Groups[1].Value
        $w = [Convert]::ToUInt32($usdWord, 16)
        $fap     = [int]($w -band 0xff)
        $fapComp = [int](($w -shr 8)  -band 0xff)
        $ssb     = [int](($w -shr 16) -band 0xff)
        $ssbComp = [int](($w -shr 24) -band 0xff)
        $fapRead = $true
    }
    $fapUnlocked = ($fapRead -and $fap -eq $FAP_UNLOCKED)
    $fapCompOk   = ($fapRead -and (($fap -bxor $fapComp) -eq 0xff))

    # --- Classify main-flash readability -------------------------------------
    #   MSP in SRAM (0x2xxxxxxx) -> firmware present, readable -> NOT protected
    #   all 0xFFFFFFFF          -> blank/erased but READABLE   -> NOT protected
    #   all 0x00000000          -> access protection masking   -> protected
    #   bus error               -> read refused                -> protected/fault
    $flashState = 'unknown'
    $msp = ''; $resetVec = ''
    if ($scan -match 'Error:.*(read|access|memory)|access denied|Failed to read') {
        $flashState = 'error'
        $flashErr = ($Matches[0])
    } else {
        $vecMatches = [regex]::Matches($scan, '(?im)^0x08000000:\s+(.*)$')
        if ($vecMatches.Count -gt 0) {
            $vecBody = $vecMatches[$vecMatches.Count - 1].Groups[1].Value.Trim()
            $words = @($vecBody -split '\s+')
            $msp = $words[0]
            if ($words.Count -gt 1) { $resetVec = $words[1] }
            if ($msp -match '^2[0-9a-fA-F]{7}$') {
                $flashState = 'firmware'
            } elseif (@($words | Where-Object { $_ -notmatch '^(?i)ffffffff$' }).Count -eq 0) {
                $flashState = 'blank'
            } elseif (@($words | Where-Object { $_ -notmatch '^(?i)00000000$' }).Count -eq 0) {
                $flashState = 'masked'
            }
        }
    }
    $flashAccessible = ($flashState -eq 'firmware' -or $flashState -eq 'blank')
    $flashBlocked    = ($flashState -eq 'masked'   -or $flashState -eq 'error')

    # --- Report evidence -----------------------------------------------------
    Write-Host ''
    Say $D
    Say 'Evidence'
    Say $D
    if ($adapterFailed) {
        SayWarn 'Adapter/target could not be opened at the SWD/USB level.'
        Say  '       Check ST-Link, cable, target power, and USB permissions.'
    }
    if ($fapRead) {
        SayOk ("USD @ 0x1FFFF800 = {0}" -f $usdWord)
        Say ("       FAP=0x{0:X2} FAP_COMP=0x{1:X2} SSB=0x{2:X2} SSB_COMP=0x{3:X2}" -f $fap, $fapComp, $ssb, $ssbComp)
        if ((($fap -bxor $fapComp)) -eq 0xff) {
            Say '       FAP complement byte is consistent.'
        } else {
            Say '       FAP complement byte is inconsistent (option area may be unusual).'
        }
    } else {
        SayWarn 'Could not read a valid FAP/USD word.'
    }
    switch ($flashState) {
        'firmware' { SayOk ("Main flash readable - firmware present (MSP=0x{0} RESET=0x{1})." -f $msp, $resetVec) }
        'blank'    { SayOk 'Main flash readable but blank/erased (all 0xFF) - ready to program.' }
        'masked'   { SayWarn 'Main-flash reads return all 0x00 - the access-protection masking pattern.' }
        'error'    { SayWarn ("Main-flash read was refused: {0}" -f $flashErr) }
        default    { SayWarn 'Main-flash read was inconclusive.' }
    }

    # --- Verdict -------------------------------------------------------------
    Write-Host ''
    Say $D
    Say 'Verdict'
    Say $D

    $rc = 3
    if ($adapterFailed) {
        Say "[${CL_Y}????${CL_NC}] INCONCLUSIVE: could not reach the chip; fix the connection and retry."
        $rc = 3
    } elseif ($flashAccessible -and $fapRead -and -not $fapUnlocked) {
        # Contradiction guard: the FAP byte read back non-0xA5 (looks protected) but main
        # flash returned real data (firmware or blank 0xFF). A truly read-protected AT32F415
        # masks the bus to 0x00 and can NEVER return readable flash, so it is the option-area
        # read that glitched here, not the chip. Readable flash is physically decisive.
        SayOk 'NOT PROTECTED: main flash reads back normally.'
        Say ("       (Note: FAP byte read as 0x{0:X2}, not 0x{1:X2} - but a protected part cannot" -f $fap, $FAP_UNLOCKED)
        Say '       return readable flash, so that was a glitched option read; re-run to confirm.)'
        $rc = 0
    } elseif ($fapRead -and -not $fapUnlocked) {
        # FAP byte is authoritative when flash does not contradict it: a non-0xA5 value here
        # means protected (flash is masked/blocked or unclassifiable - NOT provably readable,
        # or the contradiction guard above would have caught it).
        Say ("[${CL_R}PROT${CL_NC}] READ PROTECTED: FAP=0x{0:X2} (not the unlocked value 0x{1:X2})." -f $fap, $FAP_UNLOCKED)
        $rc = 2
    } elseif ($fapRead -and $fapUnlocked -and $fapCompOk) {
        if ($flashState -eq 'blank') {
            SayOk 'NOT PROTECTED: FAP is unlocked (0xA5); main flash is blank/erased (ready to program).'
        } else {
            SayOk 'NOT PROTECTED: FAP is unlocked (0xA5) and flash reads back normally.'
        }
        $rc = 0
    } elseif ($fapRead -and $fapUnlocked) {
        if ($flashBlocked) {
            Say "[${CL_R}PROT${CL_NC}] READ PROTECTED (likely): FAP low byte is 0xA5 but its complement is"
            Say '       invalid and flash reads are masked - a protected part hiding the option area.'
            $rc = 2
        } else {
            Say "[${CL_Y}????${CL_NC}] INCONCLUSIVE: FAP byte 0xA5 but complement inconsistent; re-seat and retry."
            $rc = 3
        }
    } else {
        if ($flashAccessible) {
            SayOk 'NOT PROTECTED: flash reads back normally (FAP word not parsed).'
            $rc = 0
        } elseif ($flashBlocked) {
            Say "[${CL_R}PROT${CL_NC}] READ PROTECTED (likely): chip connects at SWD but returns masked/no"
            Say '       option or flash data - the classic locked-chip fingerprint.'
            $rc = 2
        } else {
            Say "[${CL_Y}????${CL_NC}] INCONCLUSIVE: could not read option area or classify flash; retry."
            $rc = 3
        }
    }

    Write-Host ''
    Say "Full log: $log"
    Write-Host ''
    return $rc
}

# ===========================================================================
# VERB: Clear / Rescue / Enable  (option-area rewrite; destructive)
# ===========================================================================
function Invoke-Rewrite {
    param($cfg, $conn, [ValidateSet('Clear', 'Rescue', 'Enable')]$Mode)

    switch ($Mode) {
        'Enable' {
            $title  = "   ${CL_R}TESTBED ONLY${CL_NC} - enable AT32F415 read protection (FAP)"
            $rewrite = Get-FapRewrite -Kind Protect
            $confirm = 'ENABLE-FAP'
            $prefix  = 'fap_enable'
            $warn    = 'This ERASES the option bytes and turns read protection ON.'
        }
        default {
            $title  = '   Clear AT32F415 read/write protection - restore pristine option bytes'
            if ($Mode -eq 'Rescue') { $title = "   ${CL_R}LAST-RESORT UNLOCK${CL_NC} - AT32F415 read/write protection rescue" }
            $rewrite = Get-FapRewrite -Kind Unlock
            $confirm = if ($Mode -eq 'Rescue') { 'UNLOCK' } else { 'CLEAR-FAP' }
            $prefix  = if ($Mode -eq 'Rescue') { 'rescue_unlock' } else { 'fap_clear' }
            $warn    = 'On a read-protected part this triggers a hardware MASS-ERASE of main flash on reload.'
        }
    }

    Write-Host ''
    Say $D
    Say $title
    Say $D
    Write-Host ''
    SayInfo "Connect: $($conn.Mode)"
    if ($Mode -eq 'Rescue' -and $Launcher -and $conn.Plain) {
        SayWarn 'Launcher mode is A (plain). A locked/corrupted board usually will NOT'
        Say  '       answer plain connect - drop -Launcher to use guided rescue, or set B/C.'
    }
    SayWarn $warn
    Write-Host ''

    if (-not $Yes) {
        $reply = Read-Host "Type $confirm to proceed"
        if ($reply -cne $confirm) {
            SayWarn 'Aborted - nothing was written.'
            return 1
        }
    }

    $log = New-LogPath $prefix
    $ops = $rewrite + @(
        '-c', 'echo {--- option area after rewrite (masked 0x00 until reload if still protected) ---}',
        '-c', 'mdw 0x1FFFF800 8',
        '-c', 'shutdown'
    )
    $oocdArgs = $conn.Pre + $conn.Connect + $ops

    Write-Host ''
    Say "[${CL_C}....${CL_NC}] Connecting and rewriting option area ..."
    # Retry only on a connect/contact failure: the guided connect shutdown-errors
    # BEFORE any write, so a failed attempt (nonzero exit + connect-fail text)
    # wrote nothing and is safe to re-run.
    $result = Invoke-WithRetry -cfg $cfg -OocdArgs $oocdArgs -LogFile $log -ShouldRetry {
        param($r) ($r.Code -ne 0) -and (Test-ConnectFailed $r.Text)
    }

    Write-Host ''
    if ($result.Code -ne 0) {
        SayFail ("Session exited with code {0} - see output above and the log." -f $result.Code)
        Say "Full log: $log"
        return $result.Code
    }

    SayOk 'Rewrite sent.'
    if ($Mode -eq 'Enable') {
        Say "[${CL_Y}NEXT${CL_NC}] POWER-CYCLE the board, then run .\rdp.ps1 -Check - it should"
        Say '       report READ PROTECTED. To recover: .\rdp.ps1 -Clear'
    } else {
        Say "[${CL_Y}NEXT${CL_NC}] POWER-CYCLE the board, then run .\rdp.ps1 -Check to confirm NOT PROTECTED."
    }
    Say "Full log: $log"
    Write-Host ''
    return 0
}

# ===========================================================================
# Dispatch
# ===========================================================================
$cfg  = Get-RdpConfig
$conn = Resolve-Connect -cfg $cfg -UseLauncher:$Launcher

switch ($Verb) {
    'Check'  { $code = Invoke-Check   -cfg $cfg -conn $conn }
    'Clear'  { $code = Invoke-Rewrite -cfg $cfg -conn $conn -Mode Clear }
    'Rescue' { $code = Invoke-Rewrite -cfg $cfg -conn $conn -Mode Rescue }
    'Enable' { $code = Invoke-Rewrite -cfg $cfg -conn $conn -Mode Enable }
}
exit $code
