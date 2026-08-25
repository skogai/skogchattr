# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**agentchattr** — a local chat server (Python 3.11+) that lets AI coding agents (Claude Code, Codex, Gemini CLI, etc.) and humans communicate in real-time via a browser-based chat UI. Agents join via MCP tools; humans join via the browser. When anyone @mentions an agent, the server auto-injects a prompt into that agent's terminal.

## Commands

```bash
# Install dependencies (first time)
pip install -r requirements.txt

# Start the full server (web UI + MCP)
python run.py

# Start with per-project isolation (all three flags must match across server + wrapper)
python run.py --port 8310 --mcp-http-port 8210 --mcp-sse-port 8211 --data-dir ./my-project/.agentchattr

# Start an agent wrapper (CLI agents: claude, codex, gemini, kimi, qwen, kilo, codebuddy, copilot)
python wrapper.py claude
python wrapper.py claude -- --dangerously-skip-permissions   # pass-through flags after --

# Start an API/local-model agent wrapper
python wrapper_api.py qwen   # requires [agents.qwen] type = "api" in config.local.toml

# Run all tests
python -m pytest tests/
python -m unittest discover tests

# Run a single test file
python -m pytest tests/test_router.py
python -m unittest tests.test_config_overrides
```

The launcher scripts in `macos-linux/` and `windows/` are thin wrappers around `run.py` + `wrapper.py` that also set up a venv and configure MCP on first run.

## Architecture

```
Browser (chat.js) ←─WebSocket─→ FastAPI/uvicorn (app.py) port 8300
                                        │
                       ┌────────────────┼────────────────┐
                   store.py          registry.py       router.py
                 (JSONL msgs)     (live agent state)  (@mention logic)
                       │
Agent CLI ←─stdin injection─ wrapper.py ←─polls─ data/<agent>_queue.jsonl
                                  │                       ↑
Agent CLI ←─MCP tools─→ mcp_proxy.py → mcp_bridge.py ──writes──┘
                      (per-instance,    (tool defs:
                       stamps identity)  chat_send etc.)
                            │
                     port 8200 (HTTP, Claude/Codex/Qwen)
                     port 8201 (SSE, Gemini)
```

### Key data flows

**Message → agent trigger:**
1. Browser posts a message with `@claude` → `app.py` saves to `store.py`
2. `store.py` fires observer callbacks → `router.py` determines targets
3. `agents.py` appends a JSON entry to `data/claude_queue.jsonl`
4. `wrapper.py` polls that file → injects the prompt via `wrapper_unix.py` (tmux `send-keys`) or `wrapper_windows.py` (Win32 `WriteConsoleInput`)

**Agent MCP tool call → broadcast:**
1. Agent calls `chat_send` → hits `mcp_proxy.py` on its auto-assigned port
2. Proxy stamps the correct `sender` identity and forwards to `mcp_bridge.py`
3. `mcp_bridge.py` writes to `store.py` → observer fires → WebSocket broadcast to all browsers

### Module responsibilities

| Module | Role |
|--------|------|
| `run.py` | Entry point — starts uvicorn + two MCP servers in background threads |
| `app.py` | FastAPI app: WebSocket hub, all REST endpoints, security middleware, per-session token |
| `store.py` | JSONL message persistence; observer callbacks drive WebSocket broadcasts and routing |
| `registry.py` | Live agent state: slot assignment, multi-instance numbering, rename tracking, bearer tokens |
| `router.py` | `@mention` regex, per-channel loop guard (pauses after `max_agent_hops` agent-to-agent messages) |
| `agents.py` | Writes trigger queue files; reads presence/activity from `mcp_bridge` |
| `mcp_bridge.py` | All 11 MCP tool definitions; presence heartbeat tracking; cursor persistence |
| `mcp_proxy.py` | Per-instance HTTP proxy — intercepts MCP calls, stamps `sender`/`name` from registered identity |
| `wrapper.py` | Registers instance, polls queue, injects keystrokes, monitors activity, sends heartbeats |
| `wrapper_unix.py` | tmux-based injection + `tmux capture-pane` for activity detection |
| `wrapper_windows.py` | Win32 `WriteConsoleInput` injection + `ReadConsoleOutputW` for activity detection |
| `wrapper_api.py` | API agent: polls queue, calls `/v1/chat/completions`, posts reply via REST |
| `config_loader.py` | Merges `config.toml` + `config.local.toml`; applies `AGENTCHATTR_*` env overrides |
| `session_engine.py` | Structured session orchestration — phase advancement, turn triggering |
| `session_store.py` | Session and custom template persistence |
| `archive.py` | Export (zip) and import (merge) of messages, jobs, rules, summaries |

### Data files (all under `data/`, gitignored)

- `messages.jsonl` — chat messages (append-only; deletions are rewritten)
- `jobs.json`, `rules.json`, `schedules.json`, `summaries.json` — feature stores
- `hats.json`, `roles.json`, `mcp_cursors.json` — agent metadata
- `<agent>_queue.jsonl` — trigger queue per agent instance (written by server, consumed by wrapper)
- `settings.json` — UI room settings (channels list, username, font, etc.)

## Configuration

`config.toml` is the primary config. `config.local.toml` (gitignored) adds local API agents without touching the committed file — only its `[agents]` section is merged, and local entries cannot override `config.toml` agents.

**Env var overrides** (useful for per-project isolation):
```
AGENTCHATTR_DATA_DIR        → server.data_dir
AGENTCHATTR_PORT            → server.port
AGENTCHATTR_MCP_HTTP_PORT   → mcp.http_port
AGENTCHATTR_MCP_SSE_PORT    → mcp.sse_port
AGENTCHATTR_UPLOAD_DIR      → images.upload_dir
```
Relative paths in env vars resolve against CWD, not the install directory. CLI flags (`--port`, `--data-dir`, etc.) are translated to the same env vars by `config_loader.apply_cli_overrides()` before `load_config()` runs — this is how `run.py`, `wrapper.py`, and `wrapper_api.py` share identical override logic.

## Multi-instance agents

Running a second `wrapper.py claude` auto-assigns it to slot 2 (`claude-2`). The registry tracks slots, identity IDs, and bearer tokens per instance. Each instance gets its own `mcp_proxy.py` on an auto-assigned port — so agents never need to know their own name; the proxy stamps it. The 30-second grace period (`RuntimeRegistry.GRACE_PERIOD`) reserves a name after deregistration to prevent slot collisions on quick restarts.

## MCP tool identity rules

Agents must use their base name (`claude`, `codex`, `gemini`, `qwen`, `kilo`) as sender — never the CLI tool name (e.g. `gemini-cli`). `chat_claim` is only for recovering a previous identity after `/resume`; fresh sessions should never call it. The proxy enforces this by overwriting the `sender` param before forwarding to the real MCP server.

## Security model

- A random 64-hex session token is generated at server startup, injected into `index.html` at request time, and required on all API/WebSocket calls.
- `POST /api/register`, `/api/heartbeat`, `/api/deregister` only accept connections from loopback — enforced in middleware before any handler runs.
- The server refuses to bind to non-loopback addresses unless `--allow-network` is passed and the user types `YES` at a prompt.
- SVG hats are sanitized (strip `<script>`, `on*` attributes, `javascript:` URLs) before storage.
