param(
    [Parameter(Position = 0)]
    [string]$Command,

    [Parameter(Position = 1, ValueFromRemainingArguments)]
    [string[]]$ExtraArgs
)

$ErrorActionPreference = "Stop"
Push-Location $PSScriptRoot

try {
    switch ($Command) {
        "auth" {
            Write-Host "Starting GitHub OAuth device flow..."
            docker compose run --rm copilot-proxy auth
        }
        "start" {
            docker compose up -d @ExtraArgs
            Write-Host "Copilot proxy running at http://localhost:4141"
            $hostname = if ($env:TS_HOSTNAME) { $env:TS_HOSTNAME } else { "copilot-proxy" }
            Write-Host "Tailscale hostname: $hostname"
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
        default {
            Write-Host "Usage: .\copilotproxy.ps1 {auth|start|stop|restart|logs|build}"
            Write-Host ""
            Write-Host "  auth     Run GitHub OAuth device flow (first-time setup)"
            Write-Host "  start    Start the proxy (detached)"
            Write-Host "  stop     Stop the proxy"
            Write-Host "  restart  Restart the proxy"
            Write-Host "  logs     Tail container logs"
            Write-Host "  build    Rebuild the container"
            exit 1
        }
    }
} finally {
    Pop-Location
}
