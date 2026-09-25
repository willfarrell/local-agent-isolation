# Harness containers, one per repo. Source from ~/.zshrc:
#
#   source ~/Development/willfarrell/local-agent-isolation/agents.zsh
#
# Then, from inside any repo:
#
#   claude              # runs the container against $PWD
#   claude --continue   # arguments go to the harness
#   codex ~/src/foo     # a leading directory is where to run instead
#
# These SHADOW the natively installed claude/codex/copilot/gemini/hermes/opencode/pi/herdr. To reach
# the host binary instead: `command claude`.

# The local-agent-isolation checkout: the images' Dockerfiles, docker-build.hcl
# and compose.yaml. ~/.agents is the config those images mount at /.agents.
AGENTS_ISOLATION=${AGENTS_ISOLATION:-$HOME/Development/willfarrell/local-agent-isolation}

# The harness images agents-build smoke-tests; herdr last, it is built from the rest.
AGENTS_HARNESSES=(harness-claude-code harness-codex harness-copilot harness-gemini harness-hermes harness-opencode harness-pi-mono herdr)

# Builds every image, the local systems included, so it is not harness-specific either.
# Subshell cd, not just -f: bake resolves each target's relative `context` against
# the current directory, so from anywhere else it fails with `path "local-system-2" not found`.
#
# Then starts each harness image once under the launcher's flags, so a build
# that produces an image which cannot start fails here rather than in a repo.
# /home is a tmpfs so the check leaves no volume behind.
agents-build() {
  ( cd $AGENTS_ISOLATION && docker buildx bake -f docker-build.hcl "$@" --load ) || return
  local image failed=0
  for image in $AGENTS_HARNESSES; do
    docker run --rm --read-only --tmpfs /tmp:exec --tmpfs /home:uid=1000,gid=1000 \
      --cap-drop ALL --security-opt no-new-privileges:true \
      -v "$HOME/.agents:/.agents:ro" "willfarrell/$image" --version >/dev/null 2>&1 \
      || { print -u2 "agents-build: willfarrell/$image does not start"; failed=1 }
  done
  return $failed
}

harness() {
  local name=${1:?usage: harness <image> [dir] [args...]}
  shift

  # A leading argument that is an existing directory is where to run; anything
  # else, --continue or -p included, goes to the harness.
  local dir=$PWD
  if [[ -n $1 && -d $1 ]]; then
    dir=$1
    shift
  fi
  dir=${dir:A}            # zsh: absolute, symlinks resolved, to match git's answer

  # Mount the whole repo even when started from a subdirectory, or the agent
  # sees no .git; then start in the subdirectory. Outside a repo, just the dir.
  local repo
  repo=$(git -C $dir rev-parse --show-toplevel 2>/dev/null) || repo=$dir

  # -t only with a terminal, so piping or scripting still works.
  local tty=()
  [[ -t 0 && -t 1 ]] && tty=(-t)

  # Shared with the local model daemons so the harness reaches them at http://local-system-2:11434/v1.
  docker network inspect local-agent-isolation &>/dev/null \
    || docker network create local-agent-isolation >/dev/null

  # The host's git runs whatever lands in .git/hooks, so an agent that can
  # write there can run code outside the container. Read-only over the rw repo
  # mount; created first so there is always something to mount over.
  # ponytail: .git/config stays writable (core.fsmonitor, core.hooksPath can
  # still point host git at a command); lock it too if agents never need
  # `git remote` or `branch -u`. A worktree's .git is a file, so it is skipped.
  local guards=()
  if [[ -d $repo/.git ]]; then
    mkdir -p $repo/.git/hooks
    guards=(-v "$repo/.git/hooks:$repo/.git/hooks:ro")
  fi

  # The repo is mounted at its host path, not a fixed /repo: every harness keys
  # sessions, memory and project settings by path, and with one path for every
  # repo they all shared one project, so --continue resumed another repo.
  #
  # No --name: two repos sharing a basename would collide and fail the run.
  # The home volume is per harness, not per repo, so logins outlive a repo
  # switch; home-init in the image resets what a session could plant there.
  # One .agents mount: every image links /home/.agents to it, so the settings
  # hook path ($HOME/.agents/hooks/...) resolves here and on the host.
  # TERM/COLORTERM: docker -t otherwise sets TERM=xterm, and the TUIs drop to 16 colours.
  docker run --rm -i $tty \
    --label "repo=$repo" \
    --network local-agent-isolation \
    --add-host host.docker.internal:host-gateway \
    --read-only --tmpfs /tmp:exec \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    -e TERM -e COLORTERM \
    -e ANTHROPIC_API_KEY -e OPENAI_API_KEY -e GITHUB_TOKEN \
    -e GEMINI_API_KEY -e GOOGLE_API_KEY \
    -v "$HOME/.agents:/.agents:ro" \
    -v "$repo:$repo" \
    -w "$dir" \
    -v "${name}-home:/home" \
    $guards \
    "willfarrell/${name}" "$@"
}

claude()   { harness harness-claude-code "$@" }
codex()    { harness harness-codex "$@" }
copilot()  { harness harness-copilot "$@" }
gemini()   { harness harness-gemini "$@" }
hermes()   { harness harness-hermes "$@" }
opencode() { harness harness-opencode "$@" }
pi()       { harness harness-pi-mono "$@" }

# herdr ships all seven harnesses, so its panes can run any of them.
herdr()    { harness herdr "$@" }

# Not a harness: one shared daemon, not one container per repo. Bare call
# starts it, args go to the ollama CLI inside it: `ollama pull hf.co/...`.
ollama() {
  local compose=(docker compose -f $AGENTS_ISOLATION/compose.yaml)
  if (( $# )); then
    $compose exec local-system-2 ollama "$@"
  else
    $compose up -d local-system-2
  fi
}

# Also a shared service, with its database. Bare call starts both and prints
# where to go; args go to the paperclipai CLI inside: `paperclip doctor`.
paperclip() {
  local compose=(docker compose -f $AGENTS_ISOLATION/compose.yaml)
  if (( $# )); then
    $compose exec paperclip paperclipai "$@"
  else
    $compose up -d paperclip || return
    print "http://localhost:${PAPERCLIP_PORT:-3100}"
  fi
}

# Logs paperclip's claude agents in; kept in its home volume.
paperclip-claude-auth() {
  docker compose -f $AGENTS_ISOLATION/compose.yaml exec paperclip claude auth login
}
