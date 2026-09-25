# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
# check=error=true

ARG NODE_IMAGE=node:24-alpine@sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1
ARG CLAUDE_CODE_VERSION=2.1.280
ARG NPM_BEFORE=2026-09-22T21:00:00Z

# Never $BUILDPLATFORM: npm resolves an arch- and libc-specific native binary here.
FROM ${NODE_IMAGE} AS build
ARG CLAUDE_CODE_VERSION
ARG NPM_BEFORE
# pipefail: a failing `od` in `od | tr` is otherwise masked by tr's exit status.
SHELL ["/bin/ash", "-eu", "-o", "pipefail", "-c"]
# Postinstall places the native binary; assert the ELF because npm silently ignores unknown flags.
RUN bin=/opt/claude-code/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe \
 && npm install -g --allow-scripts=@anthropic-ai/claude-code --before="${NPM_BEFORE}" \
      --prefix /opt/claude-code \
      @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
 && { [ "$(od -An -tx1 -N4 "$bin" | tr -d ' ')" = "7f454c46" ] \
      || { echo "FATAL: $bin is not ELF; the postinstall did not place the native binary" >&2; exit 1; }; }

# Placeholder for docker-build.hcl's named context (tools/Dockerfile); a bare `docker build` fails here by design.
FROM scratch AS tools

FROM tools AS runtime
USER root

COPY --from=build --chown=root:root /opt/claude-code /opt/claude-code

# Seeds MCP servers from settings.mcp.json into ~/.claude.json at start; --mcp-config is variadic and eats the prompt.
COPY --chmod=0755 <<'EOF' /usr/local/lib/seed-mcp.mjs
import { readFileSync, writeFileSync, existsSync } from 'node:fs'
const target = `${process.env.HOME}/.claude.json`
const source = '/.agents/settings.mcp.json'
// No source still resets: skipping would keep whatever a session added to the shared home volume.
const repo = existsSync(source) ? JSON.parse(readFileSync(source, 'utf8')).mcpServers ?? {} : {}
const current = existsSync(target) ? JSON.parse(readFileSync(target, 'utf8')) : {}
// Clear per-project servers too: the shared home volume would otherwise persist a session-added one.
const projects = Object.fromEntries(Object.entries(current.projects ?? {})
  .map(([path, p]) => [path, { ...p, mcpServers: {} }]))
const next = { ...current, mcpServers: repo, projects }
if (JSON.stringify(current) !== JSON.stringify(next)) {
  writeFileSync(target, JSON.stringify(next, null, 2))
}
EOF

COPY --chmod=0755 <<'EOF' /usr/local/bin/claude
#!/bin/sh
node /usr/local/lib/seed-mcp.mjs || echo "claude: MCP reset failed; ~/.claude.json may keep session-added servers" >&2
exec /opt/claude-code/bin/claude "$@"
EOF

RUN { find / -xdev -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true; }

# /usr/local/bin first so the wrapper wins; bundled rg is glibc; SANDBOXED skips the trust dialog, not permissions.
ENV PATH=/usr/local/bin:/opt/claude-code/bin:$PATH \
    USE_BUILTIN_RIPGREP=0 \
    CLAUDE_CODE_SANDBOXED=1 \
    AGENTS_LINKS="${AGENTS_LINKS} /.agents/INSTRUCTIONS.md=.claude/CLAUDE.md /.agents/agents=.claude/agents /.agents/skills=.claude/skills /.agents/commands=.claude/commands"

USER 1000:1000
ENTRYPOINT ["/sbin/tini", "--", "home-init", "claude"]
