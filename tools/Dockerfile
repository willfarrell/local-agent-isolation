# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# check=error=true

# MCP servers every harness names in its settings.*; --ignore-scripts is safe because node:sqlite replaces better-sqlite3 (checked below).
# Installed under lib/ so the package keeps the global-install path settings.pi.json names.
FROM --platform=$BUILDPLATFORM node:26-alpine@sha256:ae8e1c19d56886270987e99b3cfcef13a919f0655b376ae322bc64ada76f88cd AS mcp
WORKDIR /opt/mcp/lib
COPY mcp/package.json mcp/package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts

# Azure CLI is not packaged for alpine. uv supplies a checksummed musl Python 3.13 and installs az/uv.lock,
# hash-checked, wheels only (--no-build). Never $BUILDPLATFORM: wheels are arch- and libc-specific.
FROM alpine:3.24@sha256:c6b073f8e9e58d881f6ffba6ebf3b9ebd60b9e7d6e8337018c0e68bb5c356873 AS az
RUN apk add --no-cache \
      uv=0.11.19-r0
ENV UV_PYTHON_INSTALL_DIR=/opt/az/python \
    UV_PROJECT_ENVIRONMENT=/opt/az/venv \
    UV_PYTHON_PREFERENCE=only-managed \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy
WORKDIR /src
COPY az/pyproject.toml az/uv.lock ./
RUN uv python install 3.13 \
 && uv sync --locked --no-build --no-dev --python 3.13 \
 && /opt/az/venv/bin/az version >/dev/null

# safe.directory '*': repos are host-owned bind mounts at arbitrary host paths. The home dirs are the parents of
# the launchers' session mounts: docker creates a missing parent root-owned, and the harness could not write its login there.
# /logins is 1000-owned so a new login store volume, populated from it, is writable by agents-logins-save.
FROM alpine:3.24@sha256:c6b073f8e9e58d881f6ffba6ebf3b9ebd60b9e7d6e8337018c0e68bb5c356873

RUN apk add --no-cache \
      aws-cli=2.34.63-r0 \
      bash=5.3.9-r1 \
      cargo=1.96.1-r0 \
      ca-certificates=20261020-r0 \
      fd=10.2.0-r3 \
      git=2.54.0-r0 \
      github-cli=2.97.0-r2 \
      jq=1.8.2-r0 \
      libgcc=15.2.0-r5 \
      libstdc++=15.2.0-r5 \
      nodejs-current=26.5.1-r0 \
      npm=11.12.1-r0 \
      ripgrep=15.1.0-r0 \
      rust=1.96.1-r0 \
      sqlite=3.53.4-r0 \
      tini=0.19.0-r3 \
 && addgroup -g 1000 agent \
 && adduser -D -u 1000 -G agent -h /home -s /bin/bash agent \
 && mkdir -p /home/.claude/projects /home/.codex /home/.copilot/session-state /home/.gemini/tmp /home/.pi/agent/sessions \
 && mkdir -m 0700 /logins \
 && chown -R agent:agent /home /logins \
 && mkdir -p /.agents \
 && git config --system --add safe.directory '*'

COPY --from=mcp --chown=root:root /opt/mcp /opt/mcp
COPY --from=az --chown=root:root /opt/az /opt/az
# context-mode needs FTS5 in node:sqlite, else it falls back to a better-sqlite3 shipped without its binding.
RUN ln -s /opt/az/venv/bin/az /usr/local/bin/az \
 && ln -s /opt/mcp/lib/node_modules/.bin/context-mode /usr/local/bin/context-mode \
 && node -e "new (require('node:sqlite').DatabaseSync)(':memory:').exec('create virtual table t using fts5(x)')"

# Each image adds its home links (src=dst, dst relative to $HOME) to links.d, its login paths to logins.d (globs
# relative to $HOME: files, or folders copied whole) and the home paths it keeps to keep.d: one case pattern per
# line. A trailing / in keep.d marks a session store: kept whole and re-created if missing, since the launchers
# mount over it (hiding what an old run left) and docker would make it root-owned.
COPY <<'EOF' /etc/agents/links.d/tools
/.agents=.agents
/.agents/settings.claude.json=.claude/settings.json
EOF

# Copies the logins logins.d declares from FROM (a home or a login store) to TO: regular files only, never
# through a link, each at most 64 MiB (OpenCode, Hermes and Kiro keep logins and sessions in SQLite), each
# through its sanitizer, each written to a temp file (mktemp's 0600) and renamed. A sanitizer can skip a file,
# leaving what is at TO; exits 1 if any was refused.
# copies, never deletes, so a logout does not reach the store; docker volume rm <image>-logins does.
COPY --chmod=0755 <<'EOF' /usr/local/bin/agents-logins-save
#!/bin/sh
set -eu
from=${1:?usage: agents-logins-save FROM TO}
to=${2:?usage: agents-logins-save FROM TO}
max=65536
nl='
'
rc=0
logins=$(cat /etc/agents/logins.d/* 2>/dev/null || :)
IFS=$nl
set -f

# pi runs a value starting with ! as a shell command, so only the credential fields, strings or numbers, are kept.
pi_auth() {
  out=$(jq -ce '
    if type == "object" and all(.[]; type == "object") then . else error("not {provider: {...}}") end
    | map_values(with_entries(select((.key | IN("type", "key", "access", "refresh", "expires", "accountId", "enterpriseUrl"))
        and (.value | type | IN("string", "number")))))
    | if any(.. | strings; startswith("!")) then error("a value starts with !, which pi runs as a shell command") else . end' "$1") \
    && printf '%s\n' "$out" > "$1"
}
# Claude replaces its refresh token at each refresh, which voids the copy every other running container holds; that
# copy is blanked when its own refresh then fails. So a login with no refresh token, or one expiring no later than
# the one already at $2, is skipped rather than written over it. Anything else, unparsable included, is copied.
claude_credentials() {
  old=/dev/null
  [ -f "$2" ] && [ ! -L "$2" ] && old=$2
  verdict=$(jq -rn --slurpfile new "$1" --slurpfile old "$old" '
    def oauth: if type == "object" and (.claudeAiOauth | type) == "object" then .claudeAiOauth else null end;
    def live: . != null and ((.refreshToken // "") | type == "string" and . != "");
    def expiry: (.refreshTokenExpiresAt // .expiresAt) | if type == "number" then . else 0 end;
    ($new[0] | oauth) as $n | ($old[0] | oauth) as $o
    | if $n == null then "copy"
      elif ($n | live | not) then "blank"
      elif ($o | live) and ($o | expiry) >= ($n | expiry) then "older"
      else "copy" end' 2>/dev/null) || verdict=copy
  case $verdict in
    blank) echo "agents-logins-save: skipping ~/.claude/.credentials.json, its login has no refresh token" >&2; return 2 ;;
    older) return 2 ;;
  esac
}
# $1 is the copy, rewritten in place, $3 where it goes; 2 skips it, any other non-zero refuses it.
sanitize() {
  case $2 in
    .claude.json) node /opt/claude-code/seed-mcp.mjs "$1" || return 1 ;;
    .claude/.credentials.json) claude_credentials "$1" "$3" ;;
    .pi/agent/auth.json) pi_auth "$1" || return 1 ;;
  esac
}
copy() {
  r=${1#"$from"/} tmp=
  d=$to/$r
  if [ -n "$(find "$1" -prune -size +${max}k)" ]; then
    echo "agents-logins-save: skipping ~/$r, over $((max / 1024)) MiB" >&2
  elif ! { mkdir -p "${d%/*}" && [ "$(realpath "${d%/*}")" = "${d%/*}" ] && [ ! -d "$d" ] \
      && tmp=$(mktemp "${d%/*}/.agents-logins.XXXXXX") && cat "$1" > "$tmp"; }; then
    echo "agents-logins-save: cannot write $d" >&2
    rm -f "$tmp"
    rc=1
  else
    s=0
    sanitize "$tmp" "$r" "$d" || s=$?
    case $s in
      0) mv -f "$tmp" "$d" ;;
      2) rm -f "$tmp" ;;
      *) echo "agents-logins-save: refusing ~/$r" >&2; rm -f "$tmp"; rc=1 ;;
    esac
  fi
}

for pat in $logins; do
  set +f
  for src in "$from"/$pat; do
    [ -e "$src" ] && [ "$(realpath "$src")" = "$src" ] || continue
    if [ -d "$src" ]; then files=$(find "$src" -type f ! -name '.agents-logins.*'); else files=$src; fi
    for f in $files; do
      case $f in "$src"|"$src"/*) ;; *) continue ;; esac
      [ -f "$f" ] && [ ! -L "$f" ] && [ "$(realpath "$f")" = "$f" ] && copy "$f"
    done
  done
  set -f
done
exit $rc
EOF

# Rebuilds the home each start: a fresh volume for a harness run, the agent-writable one an orchestrator keeps.
# Deletes everything under $HOME except mount points and what keep.d lists, never following a symlink, copies in
# the logins from the read-only store at /logins, then relinks links.d. With no store mounted the logins are
# kept in the home instead, and sanitized in place.
COPY --chmod=0755 <<'EOF' /usr/local/bin/home-init
#!/bin/sh
set -eu
home=${HOME:?}
nl='
'
# Mount points below $HOME, relative to it; mountinfo octal-escapes space, tab, newline and backslash.
mounts=$(awk -v h="$home/" '
  function unescape(s,  o, i) {
    o = ""
    while ((i = index(s, "\\")) > 0) {
      o = o substr(s, 1, i - 1) sprintf("%c", substr(s, i + 1, 1) * 64 + substr(s, i + 2, 1) * 8 + substr(s, i + 3, 1))
      s = substr(s, i + 4)
    }
    return o s
  }
  { p = unescape($5) }
  index(p, h) == 1 {
    if (index(p, "\n")) { print "home-init: newline in mount point " p > "/dev/stderr"; exit 1 }
    print substr(p, length(h) + 1)
  }' /proc/self/mountinfo)
keep=$(cat /etc/agents/keep.d/* 2>/dev/null || :)
store=$(awk '$5 == "/logins"' /proc/self/mountinfo)
[ -n "$store" ] || keep=$keep$nl$(cat /etc/agents/logins.d/* 2>/dev/null || :)
links=$(cat /etc/agents/links.d/*)
uid=$(id -u)
IFS=$nl
set -f

mounted() { for m in $mounts; do [ "$1" = "$m" ] && return 0; done; return 1; }
kept() { for k in $keep; do case $1 in $k|${k%/}) return 0 ;; esac; done; return 1; }
# A directory on the way to a kept path or a mount point, or a kept "dir/": descend instead of deleting.
holds() { for p in $keep $mounts; do case $p in "$1"/*) return 0 ;; esac; done; return 1; }
# A directory the agent made unreadable or unwritable is opened first. What is still left is
# root-owned (docker's mount-point skeletons), which the agent cannot have filled.
remove() {
  rm -rf "$1" 2>/dev/null && return
  find "$1" -type d -user "$uid" ! -perm -u+rwx -exec chmod u+rwx {} \; 2>/dev/null || :
  rm -rf "$1" 2>/dev/null || :
  if [ -n "$(find "$1" -user "$uid" 2>/dev/null | head -n 1)" ]; then
    echo "home-init: cannot remove $1" >&2
    return 1
  fi
}

prune() (
  set +f
  set -- "$1"/* "$1"/.[!.]* "$1"/..?*
  set -f
  for f; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    r=${f#"$home"/}
    if mounted "$r"; then :
    elif [ -L "$f" ]; then remove "$f"
    elif kept "$r"; then :
    elif [ -d "$f" ] && holds "$r"; then prune "$f"
    else remove "$f"
    fi
  done
)
prune "$home"

# Kept "dir/" entries hold the launchers' session mounts: re-create any that are missing.
for k in $keep; do
  case $k in
    */) mkdir -p "$home/$k" 2>/dev/null || echo "home-init: cannot create ~/$k; docker created a parent root-owned, remove this home volume" >&2 ;;
  esac
done

if [ -n "$store" ]; then from=/logins; else from=$home; fi
agents-logins-save "$from" "$home" \
  || { echo "home-init: a stored login was refused (above); remove this harness's login store (docker volume rm <image>-logins) and log in again" >&2; exit 1; }

for pair in $links; do
  src=${pair%%=*}
  dst=$home/${pair#*=}
  mkdir -p "${dst%/*}"
  rm -rf "$dst"
  ln -s "$src" "$dst"
done
exec "$@"
EOF

ENV HOME=/home \
    SHELL=/bin/bash \
    AZURE_CORE_COLLECT_TELEMETRY=false

# Last root step: no setuid/setgid files, and nothing world-writable but /tmp (a tmpfs at runtime).
RUN { find / -xdev -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true; } \
 && { find / -xdev -perm -0002 ! -type l ! -path /tmp -exec chmod o-w {} + 2>/dev/null || true; }

USER 1000:1000
ENTRYPOINT ["/sbin/tini", "--", "home-init"]
CMD ["bash"]
