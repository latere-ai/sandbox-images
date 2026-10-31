# Agent harness: the base image plus agent CLIs, for workloads that run
# coding agents inside the sandbox. Upgrade a CLI by bumping its ARG pin
# below and cutting a release tag; nothing else references the versions.
#
# CLIs are installed system-wide (root npm -g => /usr/bin), NOT into the
# agent user's home: a volume mounted over /home/agent must never mask
# them.
ARG BASE_IMAGE=sandbox-base:latest
FROM ${BASE_IMAGE}

ARG CLAUDE_CODE_VERSION=2.1.316
ARG CODEX_VERSION=0.166.0

USER root
# The base image points NPM_CONFIG_PREFIX at the agent user's home for
# interactive npm -g; override it here or these CLIs would land in
# /home/agent/.npm-global and be masked by a mounted home.
RUN NPM_CONFIG_PREFIX=/usr/local npm install -g \
    @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
    @openai/codex@${CODEX_VERSION} \
    && npm cache clean --force

# Pre-create the CLI state dirs so callers can bind-mount a single
# credential file (e.g. ~/.claude/.credentials.json or ~/.codex/auth.json)
# without the container runtime creating the parent dir as root.
RUN mkdir -p /home/agent/.claude /home/agent/.codex && \
    chmod 700 /home/agent/.claude /home/agent/.codex && \
    chown -R agent:agent /home/agent/.claude /home/agent/.codex

USER agent
