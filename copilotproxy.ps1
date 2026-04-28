param(
    [Parameter(Position = 0)]
    [string]$Command,

    [Parameter(Position = 1, ValueFromRemainingArguments)]
    [string[]]$ExtraArgs
)

$ErrorActionPreference = "Stop"
Push-Location $PSScriptRoot

$tsCompose = @("-f", "docker-compose.yaml", "-f", "docker-compose.tailscale.yaml")
$envFile = Join-Path $PSScriptRoot ".env"

function Ensure-EnvFile {
    if (-not (Test-Path $envFile)) {
        Copy-Item (Join-Path $PSScriptRoot ".env.example") $envFile
    }
}

function Get-ProxyToken {
    Ensure-EnvFile
    $content = Get-Content $envFile -Raw
    if ($content -match 'PROXY_AUTH_TOKEN=(\S+)') {
        return $Matches[1]
    }
    return $null
}

function Assert-TokenExists {
    $token = Get-ProxyToken
    if (-not $token) {
        Write-Host "Error: PROXY_AUTH_TOKEN not set. Run '.\copilotproxy.ps1 token' first." -ForegroundColor Red
        exit 1
    }
}

function Get-RunningMode {
    $ts = docker ps --quiet --filter "name=copilot-proxy-tailscale" 2>$null
    $local = docker ps --quiet --filter "name=copilot-caddy" 2>$null
    if ($ts) { return "tailscale" }
    if ($local) { return "local" }
    return $null
}

try {
    switch ($Command) {
        "token" {
            Ensure-EnvFile
            $existing = Get-ProxyToken
            if ($existing) {
                Write-Host "Token already exists: $existing"
                Write-Host "To regenerate, delete PROXY_AUTH_TOKEN from .env and run again."
                return
            }
            $token = -join ((1..32) | ForEach-Object { '{0:x2}' -f (Get-Random -Maximum 256) })
            $content = (Get-Content $envFile -Raw) -replace 'PROXY_AUTH_TOKEN=.*', "PROXY_AUTH_TOKEN=$token"
            Set-Content -Path $envFile -Value $content.TrimEnd() -NoNewline
            Write-Host "Generated proxy auth token: $token"
            Write-Host "Saved to .env"
        }
        "ui-password" {
            Ensure-EnvFile
            $newPass = Read-Host "Enter new UI password (leave blank to generate)"
            if (-not $newPass) {
                $newPass = -join ((1..16) | ForEach-Object { '{0:x2}' -f (Get-Random -Maximum 256) })
            }
            $envContent = Get-Content $envFile -Raw
            if ($envContent -match 'UI_PASSWORD=') {
                $envContent = $envContent -replace 'UI_PASSWORD=.*', "UI_PASSWORD=$newPass"
            } else {
                $envContent = $envContent.TrimEnd() + "`nUI_PASSWORD=$newPass"
            }
            Set-Content -Path $envFile -Value $envContent.TrimEnd() -NoNewline
            Write-Host "UI password updated. Login: admin / $newPass"
            $restart = Read-Host "Restart Caddy now to apply? (Y/n)"
            if ($restart -ne 'n') {
                $mode = Get-RunningMode
                switch ($mode) {
                    "tailscale" { docker compose @tsCompose restart caddy }
                    default { docker compose restart caddy }
                }
            }
        }
        "login" {
            Write-Host "Starting GitHub OAuth device flow..."
            docker compose run --rm -it copilot-proxy auth
        }
        "init" {
            Write-Host "=== Step 1/4: Generating proxy auth token ===" -ForegroundColor Cyan
            & $PSCommandPath token

            Write-Host ""
            Write-Host "=== Step 2/4: Setting UI password ===" -ForegroundColor Cyan
            & $PSCommandPath ui-password

            Write-Host ""
            Write-Host "=== Step 3/4: GitHub OAuth login ===" -ForegroundColor Cyan
            & $PSCommandPath login

            Write-Host ""
            Write-Host "=== Step 4/4: Configuring Claude Code ===" -ForegroundColor Cyan
            & $PSCommandPath setup-claude
        }
        "setup-claude" {
            Write-Host "Configuring Claude Code to use copilot-proxy..."
            Assert-TokenExists
            $token = Get-ProxyToken
            $claudeDir = Join-Path $env:USERPROFILE ".claude"
            if (-not (Test-Path $claudeDir)) { New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null }
            $claudeJson = Join-Path $env:USERPROFILE ".claude.json"
            if (-not (Test-Path $claudeJson)) { Set-Content -Path $claudeJson -Value "{}" }
            docker compose run --rm -it `
                -v "${claudeDir}:/root/.claude" `
                -v "${claudeJson}:/root/.claude.json" `
                copilot-proxy setup-claude-code @ExtraArgs

            # Set ANTHROPIC_AUTH_TOKEN in Claude's settings so it sends the Bearer token
            $settingsFile = Join-Path $claudeDir "settings.json"
            if (Test-Path $settingsFile) {
                $settings = Get-Content $settingsFile -Raw | ConvertFrom-Json
            } else {
                $settings = @{} | ConvertTo-Json | ConvertFrom-Json
            }
            if (-not $settings.env) {
                $settings | Add-Member -NotePropertyName "env" -NotePropertyValue @{} -Force
            }
            $settings.env | Add-Member -NotePropertyName "ANTHROPIC_AUTH_TOKEN" -NotePropertyValue $token -Force
            $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsFile
            Write-Host "Set ANTHROPIC_AUTH_TOKEN in Claude settings."
        }
        "start" {
            Assert-TokenExists
            $mode = Get-RunningMode
            if ($mode -eq "tailscale") {
                $answer = Read-Host "Tailscale mode is running. Stop and switch to local? (y/N)"
                if ($answer -ne 'y') { return }
                docker compose @tsCompose down
            }
            docker compose up -d @ExtraArgs
            Write-Host "Copilot proxy running at http://localhost:4141"
        }
        "setup-claude-remote" {
            Assert-TokenExists
            $mode = Get-RunningMode
            if ($mode -eq "tailscale") {
                Write-Host "Starting remote setup server (via Tailscale)..." -ForegroundColor Cyan
                Write-Host ""
                docker compose @tsCompose --profile setup run --rm -it --use-aliases setup-server
            } else {
                Write-Host "Starting remote setup server..." -ForegroundColor Cyan
                Write-Host ""
                docker compose --profile setup run --rm -it --use-aliases setup-server
            }
        }
        "stop" {
            docker compose down
            # Also stop tailscale containers if running
            $tsRunning = docker compose @tsCompose ps --quiet 2>$null
            if ($tsRunning) {
                docker compose @tsCompose down
            }
        }
        "logs" {
            docker compose logs -f @ExtraArgs
        }
        "restart" {
            Assert-TokenExists
            docker compose restart
        }
        "build" {
            docker compose build
        }
        "tailscale-auth" {
            Write-Host "Starting Tailscale interactive login..."
            docker compose @tsCompose run --rm -it tailscale auth
        }
        "tailscale-start" {
            Assert-TokenExists
            $mode = Get-RunningMode
            if ($mode -eq "local") {
                $answer = Read-Host "Local mode is running. Stop and switch to Tailscale? (y/N)"
                if ($answer -ne 'y') { return }
                docker compose down
            }
            docker compose @tsCompose up -d @ExtraArgs
            Write-Host "Copilot proxy running at http://localhost:4141"
            $hostname = if ($env:TS_HOSTNAME) { $env:TS_HOSTNAME } else { "copilot-proxy" }
            Write-Host "Tailscale hostname: http://${hostname}:4141"
        }
        "tailscale-stop" {
            docker compose @tsCompose down
        }
        "tailscale-build" {
            docker compose @tsCompose build
        }
        "devtunnel-auth" {
            if (-not (Get-Command devtunnel -ErrorAction SilentlyContinue)) {
                Write-Host "devtunnel CLI not found. Install it:" -ForegroundColor Red
                Write-Host "  winget install Microsoft.devtunnel" -ForegroundColor Yellow
                Write-Host "  or: https://learn.microsoft.com/azure/developer/dev-tunnels/get-started" -ForegroundColor Yellow
                return
            }
            Write-Host "Starting Dev Tunnel login..."
            devtunnel login
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Login cancelled or failed." -ForegroundColor Yellow
                return
            }
            Write-Host ""
            Write-Host "Creating tunnel..." -ForegroundColor Cyan
            $output = devtunnel create -e 30d 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Host ($output | Out-String)
                Write-Host "Failed to create tunnel." -ForegroundColor Red
                return
            }
            Write-Host ($output | Out-String)
            $tunnelId = ($output | Select-String -Pattern 'Tunnel ID\s*:\s*(\S+)' | ForEach-Object { $_.Matches[0].Groups[1].Value })
            if ($tunnelId) {
                Ensure-EnvFile
                $envContent = Get-Content $envFile -Raw
                if ($envContent -match 'DEVTUNNEL_ID=') {
                    $envContent = $envContent -replace 'DEVTUNNEL_ID=.*', "DEVTUNNEL_ID=$tunnelId"
                } else {
                    $envContent = $envContent.TrimEnd() + "`nDEVTUNNEL_ID=$tunnelId"
                }
                Set-Content -Path $envFile -Value $envContent.TrimEnd() -NoNewline
                Write-Host ""
                Write-Host "Tunnel ID saved to .env: $tunnelId" -ForegroundColor Green
            } else {
                Write-Host "Could not parse tunnel ID. Check output above and add DEVTUNNEL_ID to .env manually." -ForegroundColor Yellow
            }
        }
        "devtunnel-start" {
            Assert-TokenExists
            if (-not (Get-Command devtunnel -ErrorAction SilentlyContinue)) {
                Write-Host "devtunnel CLI not found. Run 'devtunnel-auth' first." -ForegroundColor Red
                return
            }
            Ensure-EnvFile
            $envContent = Get-Content $envFile -Raw
            $tunnelId = if ($envContent -match 'DEVTUNNEL_ID=(\S+)') { $Matches[1] } else { $null }
            if (-not $tunnelId) {
                Write-Host "DEVTUNNEL_ID not set. Run '.\copilotproxy.ps1 devtunnel-auth' first." -ForegroundColor Red
                return
            }
            # Check if devtunnel is already running
            $existingProcs = Get-Process -Name "devtunnel" -ErrorAction SilentlyContinue
            if ($existingProcs) {
                Write-Host "devtunnel is already running (PID: $(($existingProcs | ForEach-Object { $_.Id }) -join ', '))." -ForegroundColor Yellow
                Write-Host "Run '.\copilotproxy.ps1 devtunnel-stop' first, or '.\copilotproxy.ps1 devtunnel-status' to check." -ForegroundColor Yellow
                return
            }
            # Ensure proxy is running locally first
            $mode = Get-RunningMode
            if (-not $mode) {
                Write-Host "Starting proxy..." -ForegroundColor Cyan
                docker compose up -d
            }
            # Register port on the tunnel (idempotent - ignores if already exists)
            Write-Host "Ensuring port 4141 is registered on tunnel..." -ForegroundColor Cyan
            devtunnel port create $tunnelId -p 4141 2>$null
            $logFile = Join-Path $PSScriptRoot "devtunnel.log"
            $errFile = Join-Path $PSScriptRoot "devtunnel-err.log"
            Write-Host "Hosting tunnel $tunnelId on port 4141 (background)..." -ForegroundColor Cyan
            $proc = Start-Process -FilePath "devtunnel" -ArgumentList "host", $tunnelId -NoNewWindow -RedirectStandardOutput $logFile -RedirectStandardError $errFile -PassThru
            $proc.Id | Set-Content (Join-Path $PSScriptRoot "devtunnel.pid")
            # Wait briefly for log to populate with tunnel URL
            Start-Sleep 3
            $tunnelUrl = ""
            if (Test-Path $logFile) {
                $tunnelUrl = (Select-String -Path $logFile -Pattern 'Connect via browser: (https://\S+)' | Select-Object -Last 1 | ForEach-Object { $_.Matches[0].Groups[1].Value })
            }
            if ($tunnelUrl) {
                # Save tunnel URL to .env for setup-server
                Ensure-EnvFile
                $envContent = Get-Content $envFile -Raw
                if ($envContent -match 'DEVTUNNEL_URL=') {
                    $envContent = $envContent -replace 'DEVTUNNEL_URL=.*', "DEVTUNNEL_URL=$tunnelUrl"
                } else {
                    $envContent = $envContent.TrimEnd() + "`nDEVTUNNEL_URL=$tunnelUrl"
                }
                Set-Content -Path $envFile -Value $envContent.TrimEnd() -NoNewline
            }
            Write-Host ""
            Write-Host "Tunnel running in background." -ForegroundColor Green
            Write-Host "  Logs:   $logFile" -ForegroundColor Yellow
            Write-Host "  Errors: $errFile" -ForegroundColor Yellow
            Write-Host "  Status: .\copilotproxy.ps1 devtunnel-status" -ForegroundColor Yellow
            Write-Host "  Stop:   .\copilotproxy.ps1 devtunnel-stop" -ForegroundColor Yellow
            Write-Host ""
            # Auto-start watchdog
            & $PSCommandPath devtunnel-watchdog
            Write-Host ""
            Write-Host "Next: Open the setup page on your remote device:" -ForegroundColor Cyan
            if ($tunnelUrl) {
                Write-Host "  $tunnelUrl/setup" -ForegroundColor Green
            } else {
                Write-Host "  (tunnel URL not yet available - check devtunnel-status)" -ForegroundColor Yellow
            }
            Write-Host ""
            Write-Host "Then run:" -ForegroundColor Cyan
            Write-Host "  .\copilotproxy.ps1 setup-claude-remote" -ForegroundColor Cyan
        }
        "devtunnel-stop" {
            # Stop watchdog first if running
            $wdPidFile = Join-Path $PSScriptRoot "devtunnel-watchdog.pid"
            if (Test-Path $wdPidFile) {
                $wdPid = [int](Get-Content $wdPidFile -Raw).Trim()
                $wdProc = Get-Process -Id $wdPid -ErrorAction SilentlyContinue
                if ($wdProc -and $wdProc.ProcessName -match 'powershell|pwsh') {
                    Stop-Process -Id $wdPid -Force
                    Write-Host "Watchdog stopped (PID $wdPid)." -ForegroundColor Green
                }
                Remove-Item $wdPidFile -Force -ErrorAction SilentlyContinue
            }
            # Stop devtunnel
            $pidFile = Join-Path $PSScriptRoot "devtunnel.pid"
            $stopped = $false
            if (Test-Path $pidFile) {
                $dtPid = [int](Get-Content $pidFile -Raw).Trim()
                $dtProc = Get-Process -Id $dtPid -ErrorAction SilentlyContinue
                if ($dtProc -and $dtProc.ProcessName -eq 'devtunnel') {
                    Stop-Process -Id $dtPid -Force
                    $stopped = $true
                }
                Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
            }
            # Fallback: kill any remaining devtunnel processes
            $procs = Get-Process -Name "devtunnel" -ErrorAction SilentlyContinue
            if ($procs) {
                $procs | Stop-Process -Force
                $stopped = $true
            }
            if ($stopped) {
                Write-Host "Dev Tunnel stopped." -ForegroundColor Green
            } else {
                Write-Host "No devtunnel process running." -ForegroundColor Yellow
            }
        }
        "devtunnel-status" {
            $logFile = Join-Path $PSScriptRoot "devtunnel.log"
            $errFile = Join-Path $PSScriptRoot "devtunnel-err.log"
            $pidFile = Join-Path $PSScriptRoot "devtunnel.pid"
            $wdPidFile = Join-Path $PSScriptRoot "devtunnel-watchdog.pid"
            $wdLogFile = Join-Path $PSScriptRoot "devtunnel-watchdog.log"

            # Tunnel status
            $procs = Get-Process -Name "devtunnel" -ErrorAction SilentlyContinue
            if ($procs) {
                Write-Host "Dev Tunnel is running (PID: $(@($procs) | ForEach-Object { $_.Id } | Join-String -Separator ', '))" -ForegroundColor Green
            } else {
                Write-Host "Dev Tunnel is not running." -ForegroundColor Yellow
            }

            # Watchdog status
            $wdRunning = $false
            if (Test-Path $wdPidFile) {
                $wdPid = [int](Get-Content $wdPidFile -Raw).Trim()
                $wdProc = Get-Process -Id $wdPid -ErrorAction SilentlyContinue
                if ($wdProc -and $wdProc.ProcessName -match 'powershell|pwsh') {
                    Write-Host "Watchdog is running (PID: $wdPid)" -ForegroundColor Green
                    $wdRunning = $true
                } else {
                    Write-Host "Watchdog is not running (stale PID file)." -ForegroundColor Yellow
                    Remove-Item $wdPidFile -Force -ErrorAction SilentlyContinue
                }
            } else {
                Write-Host "Watchdog is not running." -ForegroundColor Yellow
            }
            if (Test-Path $logFile) {
                Write-Host ""
                Write-Host "--- Last 20 lines of $logFile ---" -ForegroundColor Cyan
                Get-Content $logFile -Tail 20
            }
            if ((Test-Path $errFile) -and ((Get-Content $errFile -Raw -ErrorAction SilentlyContinue) ?? '').Trim()) {
                Write-Host ""
                Write-Host "--- Last 20 lines of $errFile ---" -ForegroundColor Red
                Get-Content $errFile -Tail 20
            }
            if (-not (Test-Path $logFile) -and -not (Test-Path $errFile)) {
                Write-Host "No log files found." -ForegroundColor Yellow
            }
            if ((Test-Path $wdLogFile) -and ((Get-Content $wdLogFile -Raw -ErrorAction SilentlyContinue) ?? '').Trim()) {
                Write-Host ""
                Write-Host "--- Last 10 lines of $wdLogFile ---" -ForegroundColor Magenta
                Get-Content $wdLogFile -Tail 10
            }
        }
        "devtunnel-watchdog" {
            Assert-TokenExists
            $wdPidFile = Join-Path $PSScriptRoot "devtunnel-watchdog.pid"

            # Check if watchdog is already running
            if (Test-Path $wdPidFile) {
                $existPid = [int](Get-Content $wdPidFile -Raw).Trim()
                $existProc = Get-Process -Id $existPid -ErrorAction SilentlyContinue
                if ($existProc -and $existProc.ProcessName -match 'powershell|pwsh') {
                    Write-Host "Watchdog is already running (PID: $existPid)." -ForegroundColor Yellow
                    Write-Host "Run '.\copilotproxy.ps1 devtunnel-watchdog-stop' first." -ForegroundColor Yellow
                    return
                }
                Remove-Item $wdPidFile -Force -ErrorAction SilentlyContinue
            }

            # Ensure devtunnel is running first
            $dtProcs = Get-Process -Name "devtunnel" -ErrorAction SilentlyContinue
            if (-not $dtProcs) {
                Write-Host "Devtunnel not running. Starting it first..." -ForegroundColor Cyan
                & $PSCommandPath devtunnel-start
            }

            $watchdogScript = Join-Path $PSScriptRoot "devtunnel-watchdog.ps1"
            $wdProc = Start-Process -FilePath "powershell.exe" `
                -ArgumentList "-NoProfile", "-WindowStyle", "Hidden", "-File", $watchdogScript, "-Root", $PSScriptRoot `
                -PassThru
            $wdProc.Id | Set-Content $wdPidFile
            Write-Host "Watchdog started (PID: $($wdProc.Id))." -ForegroundColor Green
            Write-Host "  Log:    $(Join-Path $PSScriptRoot 'devtunnel-watchdog.log')" -ForegroundColor Yellow
            Write-Host "  Stop:   .\copilotproxy.ps1 devtunnel-watchdog-stop" -ForegroundColor Yellow
            Write-Host "  Status: .\copilotproxy.ps1 devtunnel-status" -ForegroundColor Yellow
        }
        "devtunnel-watchdog-stop" {
            $wdPidFile = Join-Path $PSScriptRoot "devtunnel-watchdog.pid"
            if (Test-Path $wdPidFile) {
                $wdPid = [int](Get-Content $wdPidFile -Raw).Trim()
                $wdProc = Get-Process -Id $wdPid -ErrorAction SilentlyContinue
                if ($wdProc -and $wdProc.ProcessName -match 'powershell|pwsh') {
                    Stop-Process -Id $wdPid -Force
                    Write-Host "Watchdog stopped (PID: $wdPid)." -ForegroundColor Green
                } else {
                    Write-Host "Watchdog process not found (stale PID)." -ForegroundColor Yellow
                }
                Remove-Item $wdPidFile -Force -ErrorAction SilentlyContinue
            } else {
                Write-Host "No watchdog running." -ForegroundColor Yellow
            }
        }
        default {
            Write-Host ""
            Write-Host "Usage: .\copilotproxy.ps1 [command]"
            Write-Host ""
            Write-Host "Setup:"
            Write-Host "  init                 Full setup: token + ui-password + login + setup-claude"
            Write-Host "  login                GitHub OAuth login"
            Write-Host "  token                Generate proxy auth token (saved to .env)"
            Write-Host "  ui-password          Set or change the UI basic auth password"
            Write-Host "  setup-claude         Configure Claude Code to use this proxy"
            Write-Host "  setup-claude-remote  Start approval server for remote device setup"
            Write-Host ""
            Write-Host "Commands:"
            Write-Host "  start             Start the proxy locally (detached)"
            Write-Host "  stop              Stop all containers"
            Write-Host "  restart           Restart the proxy"
            Write-Host "  logs              Tail container logs"
            Write-Host "  build             Rebuild the container"
            Write-Host ""
            Write-Host "Dev Tunnel (optional - runs locally, tunnels to proxy):"
            Write-Host "  devtunnel-auth           Login + create tunnel (saved to .env)"
            Write-Host "  devtunnel-start          Host tunnel in background"
            Write-Host "  devtunnel-stop           Stop the tunnel (and watchdog)"
            Write-Host "  devtunnel-status         Show tunnel + watchdog status"
            Write-Host "  devtunnel-watchdog       Start auto-restart watchdog"
            Write-Host "  devtunnel-watchdog-stop  Stop the watchdog only"
            Write-Host ""
            Write-Host "Tailscale (optional - runs as sidecar container):"
            Write-Host "  tailscale-auth           Interactive Tailscale login"
            Write-Host "  tailscale-start          Start proxy + Tailscale sidecar"
            Write-Host "  tailscale-stop           Stop proxy + Tailscale sidecar"
            Write-Host "  tailscale-build          Rebuild both containers"
            Write-Host ""
            Write-Host "First-time setup:"
            Write-Host "  1. .\copilotproxy.ps1 init    (or run token, login, setup-claude separately)"
            Write-Host "  2. .\copilotproxy.ps1 start"
            Write-Host ""
            Write-Host "Proxy will be available at http://localhost:4141"
            exit 1
        }
    }
} finally {
    Pop-Location
}
