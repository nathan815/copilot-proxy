# Stage 1: Build the copilot-api-js project
FROM oven/bun:1 AS builder

RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN git clone --depth 1 https://github.com/puxu-msft/copilot-api-js.git .
RUN bun install --frozen-lockfile
RUN bun run build

# Stage 2: Runtime with Tailscale
FROM oven/bun:1-debian

# Install Tailscale
RUN apt-get update && \
    apt-get install -y curl gnupg iptables iproute2 ca-certificates && \
    curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg | \
      gpg --dearmor -o /usr/share/keyrings/tailscale-archive-keyring.gpg && \
    curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list | \
      tee /etc/apt/sources.list.d/tailscale.list && \
    apt-get update && \
    apt-get install -y tailscale && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy built artifacts from builder
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/ui/history-v3/dist ./ui/history-v3/dist
COPY --from=builder /app/package.json ./
COPY --from=builder /app/node_modules ./node_modules

# Copy config
COPY config.yaml ./config.yaml

# Copy entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 4141

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD curl -f http://localhost:4141/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]
