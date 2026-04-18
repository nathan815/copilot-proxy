# Proposed Improvements to copilot-api-js

Upstream repo: https://github.com/puxu-msft/copilot-api-js

These are security and usability improvements we'd like to contribute upstream.

## 🔴 Critical: CORS Wildcard

**Problem:** `server.ts` uses `cors()` with no arguments, which sets `Access-Control-Allow-Origin: *`. This allows **any website** to make requests to the proxy from a user's browser — including reading responses. A malicious website can:
- Call `/api/tokens` to steal GitHub and Copilot API tokens
- Use the proxy's AI endpoints for free
- Read `/api/config` and modify settings via POST

**Why it exists:** Hono's `cors()` defaults to `*` and the proxy was designed as a localhost dev tool, so the risk wasn't considered. But browsers allow websites to fetch `localhost`, making this exploitable.

**Proposed fix:** Replace `cors()` with explicit origin allowlist:
```typescript
cors({
  origin: (origin) => {
    // Only allow same-origin requests (no Origin header = non-browser client)
    if (!origin) return '*'
    const url = new URL(origin)
    if (url.hostname === 'localhost' || url.hostname === '127.0.0.1') return origin
    return null
  }
})
```

Or better: remove CORS entirely. Non-browser clients (Claude Code, curl) don't need CORS headers. The UI is served from the same origin so it doesn't need them either.

## 🔴 Critical: API Authentication Token

**Problem:** All endpoints are completely unauthenticated. Any process on the machine (or network, if not bound to localhost) can use the proxy without authorization.

**Proposed feature:** Add an optional `--auth-token` CLI flag and `auth_token` config.yaml setting:
- When set, all API endpoints require `Authorization: Bearer <token>` header
- `/health` exempt (for container orchestration)
- `/ui` and management routes could use a separate mechanism (cookie/basic auth)
- `setup-claude-code` would automatically configure `ANTHROPIC_AUTH_TOKEN` with the token

**Config example:**
```yaml
# Optional API authentication. When set, all API endpoints require
# Authorization: Bearer <token> header.
auth_token: "your-secret-token-here"
```

**CLI:**
```bash
copilot-api start --auth-token "your-secret-token"
# or generate one automatically:
copilot-api start --auth-token auto
```

## 🟠 High: Authentication on Management Endpoints

**Problem:** `/api/tokens` exposes raw GitHub OAuth and Copilot API tokens with no auth. `/api/config` allows reading and **writing** proxy configuration. These are dangerous even on localhost.

**Proposed fix:** If the auth token feature above is implemented, these routes should require it. At minimum, `/api/tokens` should be opt-in (disabled by default) or require explicit confirmation.

## 🟠 High: Bind to Localhost by Default

**Problem:** The server binds to `0.0.0.0` by default, exposing the proxy to the entire LAN.

**Proposed fix:** Default `--host` to `127.0.0.1`. Users who want LAN/Tailscale access can explicitly pass `--host 0.0.0.0`.

## 🟡 Medium: UI Authentication

**Problem:** The `/ui` dashboard shows request history, tokens, and config. It's accessible without any authentication.

**Proposed options:**
1. Add basic auth support for `/ui` routes (configurable username/password)
2. Require the auth token as a query parameter or cookie for UI access
3. Add a simple login page that sets a session cookie

## 🟡 Medium: History Contains Sensitive Data

**Problem:** The history system stores full request/response bodies, which may contain secrets, PII, or sensitive code. While auth headers are sanitized in `fetch-utils.ts`, the actual conversation content is stored verbatim.

**Proposed improvements:**
- Add a config option to disable history entirely
- Add configurable content redaction patterns
- Set a maximum retention period with auto-cleanup

## Implementation Priority

1. **Remove wildcard CORS** — smallest change, biggest security win
2. **Auth token** — enables secure deployment beyond localhost
3. **Localhost default binding** — simple one-line default change
4. **Management endpoint auth** — builds on auth token feature
5. **UI auth** — nice-to-have once auth token exists
6. **History controls** — lower priority but good hygiene
