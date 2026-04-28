# Devtunnel Watchdog
# Monitors devtunnel health and auto-restarts on failure.
# Launched by: copilotproxy.ps1 devtunnel-watchdog
#
# Detection modes:
#   1. Process death (PID gone) -> immediate restart
#   2. Auth errors (401/Unauthorized in logs) -> immediate restart
#   3. Persistent reconnect failures -> restart after grace period (2 checks)
#
# Gives up after 5 consecutive failures (likely needs `devtunnel-auth`).

param(
    [string]$Root = $PSScriptRoot
)

$ErrorActionPreference = 'Continue'

$envFile   = Join-Path $Root '.env'
$logFile   = Join-Path $Root 'devtunnel.log'
$errFile   = Join-Path $Root 'devtunnel-err.log'
$pidFile   = Join-Path $Root 'devtunnel.pid'
$wdLog     = Join-Path $Root 'devtunnel-watchdog.log'

$checkInterval   = 30
$maxRetries      = 5
$consecutiveFails = 0
$reconnectChecks = 0
$reconnectGrace  = 2

function Log($msg) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$ts [WATCHDOG] $msg" | Add-Content $wdLog
}

function Get-TunnelId {
    if (Test-Path $envFile) {
        $c = Get-Content $envFile -Raw
        if ($c -match 'DEVTUNNEL_ID=(\S+)') { return $Matches[1] }
    }
    return $null
}

function Get-TunnelPid {
    if (Test-Path $pidFile) {
        $p = [int](Get-Content $pidFile -Raw).Trim()
        $proc = Get-Process -Id $p -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -eq 'devtunnel') { return $p }
    }
    return $null
}

function Restart-Tunnel {
    param($reason)
    Log "Restarting: $reason"

    $ep = Get-Process -Name 'devtunnel' -ErrorAction SilentlyContinue
    if ($ep) { $ep | Stop-Process -Force; Start-Sleep 2 }

    $tid = Get-TunnelId
    if (-not $tid) { Log "DEVTUNNEL_ID not found. Stopping watchdog."; exit 1 }

    '' | Set-Content $errFile -ErrorAction SilentlyContinue

    devtunnel port create $tid -p 4141 2>$null
    $p = Start-Process -FilePath 'devtunnel' `
        -ArgumentList 'host', $tid `
        -NoNewWindow `
        -RedirectStandardOutput $logFile `
        -RedirectStandardError $errFile `
        -PassThru
    $p.Id | Set-Content $pidFile
    Log "Started devtunnel (PID: $($p.Id))"

    Start-Sleep 8

    $alive = Get-Process -Id $p.Id -ErrorAction SilentlyContinue
    if (-not $alive) {
        Log "Process died immediately after restart."
        return $false
    }
    if (Test-Path $errFile) {
        $errs = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
        if ($errs -match 'Unauthorized|401') {
            Log "Auth failure after restart. Run: .\copilotproxy.ps1 devtunnel-auth"
            return $false
        }
    }
    return $true
}

# --- Main loop ---

Log "Watchdog started. Checking every ${checkInterval}s. Max retries: $maxRetries."

while ($true) {
    Start-Sleep $checkInterval
    $needsRestart = $false
    $reason = ''
    $dtPid = Get-TunnelPid

    # Check 1: Process alive?
    if (-not $dtPid) {
        $fallback = Get-Process -Name 'devtunnel' -ErrorAction SilentlyContinue
        if (-not $fallback) {
            $needsRestart = $true
            $reason = 'Process exited'
            $reconnectChecks = 0
        }
    }

    # Check 2: Auth errors in either log (fatal - restart immediately)
    if (-not $needsRestart) {
        $authError = $false
        foreach ($f in @($errFile, $logFile)) {
            if (Test-Path $f) {
                $tail = Get-Content $f -Tail 10 -ErrorAction SilentlyContinue
                if ($tail -match 'Unauthorized|Not authorized') {
                    $authError = $true
                }
            }
        }
        if ($authError) {
            $needsRestart = $true
            $reason = 'Auth failure (401/Unauthorized)'
            $reconnectChecks = 0
        }
    }

    # Check 3: Persistent reconnect failures (grace period)
    if (-not $needsRestart -and $dtPid) {
        $reconnecting = $false
        foreach ($f in @($errFile, $logFile)) {
            if (Test-Path $f) {
                $tail = Get-Content $f -Tail 5 -ErrorAction SilentlyContinue
                if ($tail -match 'Connection.*lost.*Reconnecting|Disconnected') {
                    $reconnecting = $true
                }
            }
        }
        if ($reconnecting) {
            $reconnectChecks++
            if ($reconnectChecks -ge $reconnectGrace) {
                $needsRestart = $true
                $reason = "Persistent reconnect failure ($reconnectChecks checks)"
                $reconnectChecks = 0
            } else {
                Log "Reconnect detected (check $reconnectChecks/$reconnectGrace) - waiting..."
            }
        } else {
            $reconnectChecks = 0
        }
    }

    if ($needsRestart) {
        $consecutiveFails++
        if ($consecutiveFails -gt $maxRetries) {
            Log "Max retries ($maxRetries) exceeded. Run: .\copilotproxy.ps1 devtunnel-auth"
            Log "Watchdog stopping."
            exit 1
        }
        $ok = Restart-Tunnel $reason
        if ($ok) {
            Log "Restart succeeded (attempt $consecutiveFails/$maxRetries)."
        } else {
            Log "Restart failed (attempt $consecutiveFails/$maxRetries)."
        }
    } else {
        if ($consecutiveFails -gt 0) {
            Log "Tunnel healthy. Resetting failure counter."
            $consecutiveFails = 0
        }
    }
}
