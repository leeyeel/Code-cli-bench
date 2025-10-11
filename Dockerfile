# syntax=docker/dockerfile:1.7
FROM node:20.19-bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Etc/UTC \
    LC_ALL=en_US.UTF-8 \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    UV_LINK_MODE=copy \
    UV_NO_SYNC_INSTALLS=1

ARG HOST_UID=1000
ARG HOST_GID=1000

RUN --mount=type=cache,target=/var/cache/apt \
    apt-get update && apt-get install -y --no-install-recommends \
    locales ca-certificates tzdata curl git vim python3 python3-pip tmux \
    && sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/g' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

RUN curl -LsSf https://astral.sh/uv/install.sh | sh

RUN groupmod -o -g "${HOST_GID}" node || true \
 && usermod  -o -u "${HOST_UID}" -g "${HOST_GID}" node || true

RUN mkdir -p /home/node/.local/bin \
 && cp /root/.local/bin/uv /home/node/.local/bin/uv \
 && chown -R node:node /home/node \
 && mkdir -p /workspace \
 && chown -R node:node /workspace

ENV PATH="/home/node/.local/bin:${PATH}"
RUN printf 'export PATH="/workspace/Pywen/.venv/bin:$PATH"\n' > /etc/profile.d/pywen.sh

RUN npm install -g @anthropic-ai/claude-code@1.0.81
COPY claude/cli.js /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js
RUN chmod 755 /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js

USER node
WORKDIR /workspace

COPY --chown=node:node . /workspace/Code-cli-bench/
RUN chmod +x /workspace/Code-cli-bench/*.sh

COPY --chown=node:node claude/claude.json /home/node/.claude.json
COPY --chown=node:node claude/setting/settings.json /home/node/.claude/settings.json
RUN chmod 755 -R /workspace/Code-cli-bench/claude/script/

RUN git clone https://github.com/leeyeel/Pywen.git \
 && cd Pywen \
 && git checkout feat/config \
 && uv venv \
 && uv sync --all-extras \
 && uv pip install -e .

COPY --chown=node:node pywen/pywen_hooks.json /home/node/.pywen/pywen_hooks.json
RUN chmod 755 -R /workspace/Code-cli-bench/pywen/script/

ENV PATH="/workspace/Pywen/.venv/bin:${PATH}"
