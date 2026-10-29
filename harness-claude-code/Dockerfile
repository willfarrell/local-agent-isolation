# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# check=error=true

# Never $BUILDPLATFORM: npm resolves an arch- and libc-specific native binary here.
FROM node:26-alpine@sha256:ae8e1c19d56886270987e99b3cfcef13a919f0655b376ae322bc64ada76f88cd AS build
# pipefail: a failing `od` in `od | tr` is otherwise masked by tr's exit status.
SHELL ["/bin/ash", "-eu", "-o", "pipefail", "-c"]
WORKDIR /opt/claude-code
COPY package.json package-lock.json ./
# No lifecycle scripts but the one that places the native binary, run by path: npm has no portable
# per-package allow (older npm ignores --allow-scripts, newer rejects it in project installs).
# Assert the ELF, so a skipped or changed postinstall fails the build.
RUN npm ci --omit=dev --ignore-scripts
WORKDIR /opt/claude-code/node_modules/@anthropic-ai/claude-code
RUN node install.cjs \
 && { [ "$(od -An -tx1 -N4 bin/claude.exe | tr -d ' ')" = "7f454c46" ] \
      || { echo "FATAL: bin/claude.exe is not ELF; the postinstall did not place the native binary" >&2; exit 1; }; }
WORKDIR /opt/claude-code

# Placeholder for docker-build.hcl's named context (tools/Dockerfile); a bare `docker build` fails here by design.
FROM scratch AS tools

FROM tools AS runtime
USER 0:0

COPY --from=build --chown=root:root /opt/claude-code /opt/claude-code

# Rebuilds ~/.claude.json (or the file named) from its login keys and settings.mcp.json's servers, at start and
# by agents-logins-save; --mcp-config is variadic and eats the prompt. The rest goes: a top-level env is applied
# to process.env at launch, and projects holds per-repo approvals (hasClaudeMdExternalIncludesApproved).
# Key names checked against the 2.1.302 binary.
COPY --chmod=0755 <<'EOF' /opt/claude-code/seed-mcp.mjs
import { existsSync, lstatSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
const target = process.argv[2] ?? `${process.env.HOME}/.claude.json`
const source = '/.agents/settings.mcp.json'
const login = ['oauthAccount', 'userID', 'primaryApiKey', 'customApiKeyResponses', 'hasCompletedOnboarding',
  'lastOnboardingVersion', 'firstStartTime', 'installMethod']
const object = (v) => v !== null && typeof v === 'object' && !Array.isArray(v)
const stat = lstatSync(target, { throwIfNoEntry: false })
let current = {}
if (stat) {
  if (!stat.isFile()) throw new Error(`${target} is not a regular file`)
  current = JSON.parse(readFileSync(target, 'utf8'))
  if (!object(current)) throw new Error(`${target} is not a JSON object`)
}
const next = Object.fromEntries(login.filter((k) => Object.hasOwn(current, k)).map((k) => [k, current[k]]))
next.mcpServers = existsSync(source) ? JSON.parse(readFileSync(source, 'utf8')).mcpServers ?? {} : {}
writeFileSync(`${target}.seed-${process.pid}`, JSON.stringify(next, null, 2), { mode: 0o600 })
renameSync(`${target}.seed-${process.pid}`, target)
EOF

COPY --chmod=0755 <<'EOF' /usr/local/bin/claude
#!/bin/sh
node /opt/claude-code/seed-mcp.mjs || { echo "claude: could not rebuild ~/.claude.json from its login keys; refusing to start" >&2; exit 1; }
exec /opt/claude-code/node_modules/.bin/claude "$@"
EOF

COPY <<'EOF' /etc/agents/links.d/harness-claude-code
/.agents/INSTRUCTIONS.md=.claude/CLAUDE.md
/.agents/agents=.claude/agents
/.agents/skills=.claude/skills
/.agents/commands=.claude/commands
EOF

COPY <<'EOF' /etc/agents/logins.d/harness-claude-code
.claude.json
.claude/.credentials.json
EOF

# The folder the launchers mount each session into (kept, emptied).
COPY <<'EOF' /etc/agents/keep.d/harness-claude-code
.claude/projects/
EOF

# Bundled rg is glibc; SANDBOXED skips the trust dialog, not permissions. The pinned install
# is read-only and bumped by rebuilding, so the self-updater can only fail.
ENV USE_BUILTIN_RIPGREP=0 \
    CLAUDE_CODE_SANDBOXED=1 \
    DISABLE_AUTOUPDATER=1

# --- Token optimizations ---

# agent_summary: every ~30 s per running subagent, the whole transcript is re-sent to the agent's own model for a
# 3-5 word panel status, measured at 15-26% of a session's spend. No setting turns it off
# (https://github.com/anthropics/claude-code/issues/86879). CLAUDE_CODE_FORK_SUBAGENT=0 does, but drops fork
# subagents with it. This Bun preload swaps the summary timer for an inert one; the binary is unmodified.
# Fail-open: it matches the timer by source text, so a rename in an update silently brings summaries back. After
# a Claude Code bump, check `CC_AGENT_SUMMARY_LOG=/tmp/nas.log claude --version && cat /tmp/nas.log` reports
# `preload active mode=off`. Pinned to a gist revision by checksum because it runs inside every claude process;
# review the diff before bumping it. MIT, Flamerix AI: https://gist.github.com/flamerix-ai/c3905705cc4205e5de3011fa2e74efce
ADD --chmod=0644 --checksum=sha256:dc6699da069646365492261d8ade189cd19af352ebfdc5926e6aae0a2e8d59f7 \
    https://gist.githubusercontent.com/flamerix-ai/c3905705cc4205e5de3011fa2e74efce/raw/2fe224167473e3185c104a5dbff7a788ab025b3b/no-agent-summary.js \
    /opt/claude-code/no-agent-summary.js
ENV BUN_OPTIONS="--preload /opt/claude-code/no-agent-summary.js"

# Last root step: no setuid/setgid files, and nothing world-writable but /tmp (a tmpfs at runtime).
RUN { find / -xdev -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true; } \
 && { find / -xdev -perm -0002 ! -type l ! -path /tmp -exec chmod o-w {} + 2>/dev/null || true; }

USER 1000:1000
ENTRYPOINT ["/sbin/tini", "--", "home-init", "claude"]
