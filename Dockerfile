# Stage 1: Build the copilot-api-js project
FROM oven/bun:1 AS builder

RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN git clone --depth 1 https://github.com/puxu-msft/copilot-api-js.git .
RUN bun install --frozen-lockfile
RUN bun run build

# Stage 2: Runtime (no Tailscale — use sidecar for that)
FROM oven/bun:1-debian

RUN apt-get update && apt-get install -y curl ca-certificates && \
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
