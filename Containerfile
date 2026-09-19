FROM python:3.11-slim

ARG UID=1000
ARG GID=1000

# tmux drives keystroke injection into agent CLI panes (wrapper_unix.py).
# nodejs/npm are needed to install the agent CLIs themselves.
RUN apt-get update && apt-get install -y --no-install-recommends \
        tmux git curl ca-certificates \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Agent CLIs wrapper.py knows how to drive. Skip any that fail to install
# rather than aborting the whole build (e.g. a package gets renamed upstream).
RUN npm install -g \
        @anthropic-ai/claude-code \
        @openai/codex \
        @google/gemini-cli \
    || true

# Match the host UID/GID (UserNS=keep-id) so bind-mounted ~/.claude, data/,
# uploads/ keep sane ownership instead of everything landing as root.
RUN (getent group ${GID} || groupadd --gid ${GID} appgroup) && \
    useradd --uid ${UID} --gid ${GID} --create-home --shell /bin/bash skogix

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

RUN mkdir -p /app/data /app/uploads && chown -R skogix:${GID} /app

EXPOSE 8300 8200 8201

USER skogix

ENTRYPOINT ["/entrypoint.sh"]
