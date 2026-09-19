#!/bin/bash
# Boots the chat server and one wrapper.py per agent listed in $AGENTS, all
# inside a single tmux session so they can be watched/driven together.
#
# AGENTS=claude,codex,gemini  (space or comma separated, default: claude)
set -euo pipefail

SESSION=agentchattr
AGENTS=${AGENTS:-claude}
AGENTS=${AGENTS//,/ }

# Bind all interfaces inside the container's own network namespace; the quadlet
# publishes only 127.0.0.1:8300 back to the host, so external reachability is
# unchanged from a bare loopback bind. --allow-network's YES prompt is piped
# here since there's no tty; harmless when AGENTCHATTR_HOST is loopback too.
export AGENTCHATTR_HOST=${AGENTCHATTR_HOST:-0.0.0.0}

tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -n server "printf 'YES\n' | python run.py --allow-network; exec bash"

# Give the server a moment to open its MCP ports before wrappers register.
sleep 2

for agent in $AGENTS; do
    tmux new-window -t "$SESSION" -n "$agent" "python wrapper.py $agent; exec bash"
done

echo "tmux session '$SESSION' running. Attach with:"
echo "  podman exec -it <container> tmux attach -t $SESSION"

trap 'exit 0' TERM INT
sleep infinity &
wait $!
