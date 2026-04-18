param(
    [Parameter(Position = 0)]
    [string]$Command,

    [Parameter(Position = 1, ValueFromRemainingArguments)]
    [string[]]$ExtraArgs
)

$ErrorActionPreference = "Stop"
Push-Location $PSScriptRoot

$tsCompose = @("-f", "docker-compose.yaml", "-f", "docker-compose.tailscale.yaml")

try {
    switch ($Command) {
        "auth" {
            Write-Host "Starting GitHub OAuth device flow..."
            docker compose run --rm -it copilot-proxy auth
        }
        "setup-claude-code" {
            Write-Host "Configuring Claude Code to use copilot-proxy..."
            $claudeDir = Join-Path $env:USERPROFILE ".claude"
            if (-not (Test-Path $claudeDir)) { New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null }
            $claudeJson = Join-Path $env:USERPROFILE ".claude.json"
            if (-not (Test-Path $claudeJson)) { Set-Content -Path $claudeJson -Value "{}" }
            docker compose run --rm -it `
                -v "${claudeDir}:/root/.claude" `
                -v "${claudeJson}:/root/.claude.json" `
                copilot-proxy setup-claude-code @ExtraArgs
        }
        "start" {
            docker compose up -d @ExtraArgs
            Write-Host "Copilot proxy running at http://localhost:4141"
        }
        "stop" {
            docker compose down
        }
        "logs" {
            docker compose logs -f @ExtraArgs
        }
        "restart" {
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
            Write-Host "Commands:"
            Write-Host "  auth              GitHub OAuth login (first-time setup)"
            Write-Host "  setup-claude-code Configure Claude Code to use this proxy"
            Write-Host "  start             Start the proxy locally (detached)"
            Write-Host "  stop              Stop the proxy"
            Write-Host "  restart           Restart the proxy"
            Write-Host "  logs              Tail container logs"
            Write-Host "  build             Rebuild the container"
            Write-Host ""
            Write-Host "Tailscale (optional - runs as sidecar container):"
            Write-Host "  tailscale-auth    Interactive Tailscale login"
            Write-Host "  tailscale-start   Start proxy + Tailscale sidecar"
            Write-Host "  tailscale-stop    Stop proxy + Tailscale sidecar"
            Write-Host "  tailscale-build   Rebuild both containers"
            Write-Host ""
            Write-Host "First-time setup:"
            Write-Host "  1. .\copilotproxy.ps1 auth"
            Write-Host "  2. .\copilotproxy.ps1 start"
            Write-Host "  3. .\copilotproxy.ps1 setup-claude-code"
            Write-Host ""
            Write-Host "Proxy will be available at http://localhost:4141"
            exit 1
        }
    }
} finally {
    Pop-Location
}
