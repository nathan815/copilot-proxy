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
        "auth" {
            Write-Host "Starting GitHub OAuth device flow..."
            docker compose run --rm -it copilot-proxy auth
        }
        "init" {
            Write-Host "=== Step 1/3: Generating proxy auth token ===" -ForegroundColor Cyan
            & $PSCommandPath token

            Write-Host ""
            Write-Host "=== Step 2/3: GitHub OAuth login ===" -ForegroundColor Cyan
            & $PSCommandPath auth

            Write-Host ""
            Write-Host "=== Step 3/3: Configuring Claude Code ===" -ForegroundColor Cyan
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
            $tsContainer = docker ps --quiet --filter "name=copilot-proxy-tailscale" 2>$null
            if ($tsContainer) {
                $answer = Read-Host "Tailscale mode is running. Stop and switch to local? (y/N)"
                if ($answer -ne 'y') { return }
                docker compose @tsCompose down
            }
            docker compose up -d @ExtraArgs
            Write-Host "Copilot proxy running at http://localhost:4141"
        }
        "setup-claude-remote" {
            Assert-TokenExists
            # Detect if tailscale stack is running
            $tsRunning = docker compose @tsCompose ps --quiet 2>$null
            if ($tsRunning) {
                Write-Host "Starting remote setup server (via Tailscale)..." -ForegroundColor Cyan
                Write-Host ""
                docker compose @tsCompose --profile setup run --rm -it setup-server
            } else {
                Write-Host "Starting remote setup server..." -ForegroundColor Cyan
                Write-Host ""
                docker compose --profile setup run --rm -it -p 4143:4143 setup-server
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
            $localCaddy = docker ps --quiet --filter "name=copilot-caddy" 2>$null
            $tsContainer = docker ps --quiet --filter "name=copilot-proxy-tailscale" 2>$null
            if ($localCaddy -and -not $tsContainer) {
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
        default {
            Write-Host "copilotproxy - GitHub Copilot API proxy"
            Write-Host ""
            Write-Host "Usage: .\copilotproxy.ps1 <command>"
            Write-Host ""
            Write-Host "Setup:"
            Write-Host "  init              Full setup: token + auth + setup-claude"
            Write-Host "  token             Generate proxy auth token (saved to .env)"
            Write-Host "  auth              GitHub OAuth login (first-time setup)"
            Write-Host "  setup-claude      Configure Claude Code to use this proxy"
            Write-Host "  setup-claude-remote  Start approval server for remote device setup"
            Write-Host ""
            Write-Host "Commands:"
            Write-Host "  start             Start the proxy locally (detached)"
            Write-Host "  stop              Stop all containers (proxy + tailscale)"
            Write-Host "  restart           Restart the proxy"
            Write-Host "  logs              Tail container logs"
            Write-Host "  build             Rebuild the container"
            Write-Host ""
            Write-Host "Tailscale (optional - runs as sidecar container):"
            Write-Host "  tailscale-auth           Interactive Tailscale login"
            Write-Host "  tailscale-start          Start proxy + Tailscale sidecar"
            Write-Host "  tailscale-stop           Stop proxy + Tailscale sidecar"
            Write-Host "  tailscale-build          Rebuild both containers"
            Write-Host ""
            Write-Host "First-time setup:"
            Write-Host "  1. .\copilotproxy.ps1 init    (or run token, auth, setup-claude separately)"
            Write-Host "  2. .\copilotproxy.ps1 start"
            Write-Host ""
            Write-Host "Proxy will be available at http://localhost:4141"
            exit 1
        }
    }
} finally {
    Pop-Location
}
