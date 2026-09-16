#!/usr/bin/env bash
# Starts the agentchattr server, registers a "claude" agent instance,
# keeps its presence alive with a heartbeat loop, and (re)points this
# machine's `claude mcp` config at it with a fresh auth token.
#
# Everything runs in this process's job tree; Ctrl+C tears it all down
# (server, heartbeat loop, and deregisters the agent).
set -u
cd "$(dirname "$0")"

# Local secrets (Cloudflare Access service token, public URL) — optional.
[ -f .env ] && set -a && source ./.env && set +a

PORT="${AGENTCHATTR_PORT:-3001}"
MCP_HTTP_PORT="${AGENTCHATTR_MCP_HTTP_PORT:-3000}"
AGENT_BASE="${AGENTCHATTR_AGENT_BASE:-claude}"
LOCAL_URL="http://127.0.0.1:${PORT}"

SERVER_PID=""
HEARTBEAT_PID=""
AGENT_NAME=""
AGENT_TOKEN=""

log() { printf '%s\n' "$*"; }

cleanup() {
    log ""
    log "Shutting down..."
    [ -n "$HEARTBEAT_PID" ] && kill "$HEARTBEAT_PID" 2>/dev/null
    if [ -n "$AGENT_NAME" ] && [ -n "$AGENT_TOKEN" ]; then
        curl -s -X POST "${LOCAL_URL}/api/deregister/${AGENT_NAME}" \
            -H "Authorization: Bearer ${AGENT_TOKEN}" >/dev/null 2>&1
    fi
    if [ -n "$SERVER_PID" ] && [ "$STARTED_SERVER" = "1" ]; then
        kill "$SERVER_PID" 2>/dev/null
    fi
    wait 2>/dev/null
    exit 0
}
trap cleanup INT TERM

# --- 1. Start the server if nothing is listening on its port yet ---
STARTED_SERVER=0
if curl -s -o /dev/null "${LOCAL_URL}/api/roles" 2>/dev/null; then
    log "Server already running on ${LOCAL_URL}."
else
    log "Starting agentchattr server..."
    mkdir -p data
    yes YES | .venv/bin/python run.py --allow-network > data/server.log 2>&1 &
    SERVER_PID=$!
    STARTED_SERVER=1
    for _ in $(seq 1 30); do
        curl -s -o /dev/null "${LOCAL_URL}/api/roles" 2>/dev/null && break
        sleep 0.5
    done
    if ! curl -s -o /dev/null "${LOCAL_URL}/api/roles" 2>/dev/null; then
        log "Server did not come up — check data/server.log"
        exit 1
    fi
    log "Server up (pid ${SERVER_PID}). Log: data/server.log"
fi

# --- 2. Register this agent instance ---
log "Registering agent '${AGENT_BASE}'..."
REG=$(curl -s -X POST "${LOCAL_URL}/api/register" \
    -H 'Content-Type: application/json' -d "{\"base\":\"${AGENT_BASE}\"}")
AGENT_NAME=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['name'])" "$REG" 2>/dev/null)
AGENT_TOKEN=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['token'])" "$REG" 2>/dev/null)
if [ -z "$AGENT_TOKEN" ]; then
    log "Registration failed: $REG"
    exit 1
fi
log "Registered as '${AGENT_NAME}'."

# --- 3. Heartbeat loop keeps the registration from expiring (60s timeout) ---
(
    while true; do
        curl -s -X POST "${LOCAL_URL}/api/heartbeat/${AGENT_NAME}" \
            -H "Authorization: Bearer ${AGENT_TOKEN}" \
            -H 'Content-Type: application/json' -d '{}' >/dev/null 2>&1
        sleep 5
    done
) &
HEARTBEAT_PID=$!

# --- 4. Point this machine's `claude mcp` config at the fresh token ---
if command -v claude >/dev/null 2>&1; then
    claude mcp remove agentchattr -s local >/dev/null 2>&1
    if [ -n "${AGENTCHATTR_PUBLIC_MCP_URL:-}" ] && [ -n "${CF_ACCESS_CLIENT_ID:-}" ] && [ -n "${CF_ACCESS_CLIENT_SECRET:-}" ]; then
        claude mcp add agentchattr --transport http "${AGENTCHATTR_PUBLIC_MCP_URL}" \
            --header "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" \
            --header "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}" \
            --header "Authorization: Bearer ${AGENT_TOKEN}" >/dev/null 2>&1
        log "claude mcp: registered at ${AGENTCHATTR_PUBLIC_MCP_URL}"
    else
        claude mcp add agentchattr --transport http "http://127.0.0.1:${MCP_HTTP_PORT}/mcp" \
            --header "Authorization: Bearer ${AGENT_TOKEN}" >/dev/null 2>&1
        log "claude mcp: registered at http://127.0.0.1:${MCP_HTTP_PORT}/mcp"
    fi
    log "Run '/mcp' in any open Claude Code session to pick up the new token."
else
    log "claude CLI not found — skipping MCP registration."
fi

log ""
log "agentchattr is running. Ctrl+C to stop (deregisters agent, stops heartbeat, stops server if we started it)."

if [ "$STARTED_SERVER" = "1" ]; then
    wait "$SERVER_PID"
else
    wait "$HEARTBEAT_PID"
fi
