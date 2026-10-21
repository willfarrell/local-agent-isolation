# Harness containers, one per repo. Source from ~/.zshrc:
#
#   source ~/Development/willfarrell/local-agent-isolation/agents.zsh
#
# Then, from inside any repo:
#
#   claude              # runs the container against $PWD
#   claude --continue   # arguments go to the harness
#   codex ~/src/foo     # a leading directory is where to run instead
#   claude -0 [dir] [args...]   # the host binary, no container
#
# These SHADOW the natively installed claude/codex/copilot/gemini/hermes/kiro/opencode/pi/herdr. To reach
# the host binary instead: `claude -0` or `command claude` (`command kiro-cli`
# for kiro: `command kiro` is the Kiro IDE).

# The local-agent-isolation checkout: the images' Dockerfiles, docker-build.hcl
# and compose.yaml. ~/.agents is the config those images mount at /.agents.
# Defaults to the folder this file is in, read when it is sourced.
AGENTS_ISOLATION=${AGENTS_ISOLATION:-${${(%):-%x}:A:h}}

# Where container sessions live on the host: $AGENTS_SESSIONS/<harness>/<key>,
# one folder per harness and directory. Same filesystem as ~/.claude and
# ~/.codex, or the hard links into them fail.
AGENTS_SESSIONS=${AGENTS_SESSIONS:-$HOME/.local/share/agent-isolation/sessions}

# Every container the launchers start: never --privileged, --cap-add, --pid
# host, --network host, a docker.sock mount, or seccomp or apparmor
# unconfined (docker's default profiles stay). Every bind mount but the repo, session
# folders, memory and /azure is :ro. No --memory: Rust builds need the RAM.
# --pids-limit stops a fork bomb; AGENTS_PIDS_LIMIT, read when sourced, raises it.
# --add-host stays for Linux hosts, but Docker Desktop resolves
# host.docker.internal regardless, so host loopback services are reachable
# from any container; blocking that needs a network policy, out of scope here.
# Each harness run gets a network of its own (harness()).
AGENTS_HARDENING=(--user 1000:1000 --read-only --cap-drop ALL --security-opt no-new-privileges:true
  --pids-limit ${AGENTS_PIDS_LIMIT:-4096} --ipc private)

# The harness images agents-build smoke-tests; herdr last, it is built from the rest.
AGENTS_HARNESSES=(harness-claude-code harness-codex harness-copilot harness-gemini harness-hermes harness-kiro harness-opencode harness-pi-mono herdr)

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
    docker run --rm $AGENTS_HARDENING --network none \
      --tmpfs /tmp:exec,nosuid,nodev --tmpfs /home:uid=1000,gid=1000,nosuid,nodev \
      -v "$HOME/.agents:/.agents:ro" "$(_agents_image $image)" --version >/dev/null 2>&1 \
      || { print -u2 "agents-build: $(_agents_image $image) does not start"; failed=1 }
  done
  return $failed
}

# The image docker-build.hcl tags for $1: Kiro's is local/, as its license bars
# publishing it; the rest are willfarrell/.
_agents_image() {
  [[ $1 == harness-kiro ]] && print -r -- local/$1 || print -r -- willfarrell/$1
}

# Project config that host tools load and some run code from: Claude, MCP,
# OpenCode, Gemini, Codex and pi settings, VS Code tasks, direnv. The ones a
# repo has are mounted read-only, so an agent cannot change them for the host
# `-0` run or your IDE; the ones it lacks are not created (that would litter
# every repo), so `-0` asks before running when any appeared or changed.
AGENTS_PROJECT_CONFIG=(.claude .mcp.json opencode.json opencode.jsonc .opencode .gemini .codex .pi .vscode .envrc)

# sha256 of $1, in hex.
_agents_sha256() {
  print -rn -- $1 | if (( $+commands[sha256sum] )); then sha256sum; else shasum -a 256; fi
}

# The _harness_* helpers below read and set harness()'s locals (args, dir,
# sessions, ...) directly: zsh scoping is dynamic, so a called function sees
# its caller's locals.
harness() {
  local name=${1:?usage: harness <image> [-0] [-gh] [-aws] [-az] [dir] [args...]}
  shift
  local args=("$@") native= share_gh= share_aws= share_az= help= dir=
  _harness_flags || return

  if [[ -n $native ]]; then
    _agents_host_check $dir || return
    ( cd $dir && command $native "${args[@]}" )
    return
  fi

  # Mount the whole repo even when started from a subdirectory, or the agent
  # sees no .git; then start in the subdirectory. Outside a repo, just the dir.
  local repo
  _agents_repo $dir || return

  # -t only with a terminal, so piping or scripting still works.
  local tty=()
  [[ -t 0 && -t 1 ]] && tty=(-t)

  # Credentials first: a failed check then leaves no session folder behind.
  # run and lockfd are set by _harness_fresh, net, joined and home below; always undoes them.
  local guards=() creds=() passed=() azdir= sessions=() links=() rc run= lockfd= net= joined=() home= s c
  local uuid=${(L)$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)} image=$(_agents_image $name)
  _harness_guards
  _harness_creds || return

  # The repo is mounted at its host path, not a fixed /repo: every harness keys
  # sessions, memory and project settings by path, and with one path for every
  # repo they all shared one project, so --continue resumed another repo.
  #
  # No --name: two repos sharing a basename would collide and fail the run.
  # The home is a volume of the run's own, home-<uuid>, which docker fills from
  # the image's /home and harness removes after; nothing an agent leaves in it
  # reaches another run. Logins outlive it in a store per image, ${name}-logins,
  # read-only here: home-init copies them in, _harness_save copies them back.
  # One .agents mount: every image links /home/.agents to it, so the settings
  # hook path ($HOME/.agents/hooks/...) resolves here and on the host.
  # TERM/COLORTERM: docker -t otherwise sets TERM=xterm, and the TUIs drop to 16 colours.
  # Credentials are exported in a subshell and named with -e, so no value lands in docker's argv.
  #
  # A network of the run's own, not one shared by every run: on a shared one each
  # harness container could reach the others, and through them other repos. The
  # local model daemons join it, when running, under their service names, so the
  # harness reaches them at http://local-system-2:11434/v1.
  # internet egress is unrestricted. Upgrade: an --internal network
  # plus an allowlisting proxy (model APIs, registries) as the only way out.
  {
    _harness_sessions || return
    _harness_logins
    docker network create agents-$uuid >/dev/null || return
    net=agents-$uuid
    for s in local-system-1 local-system-2; do
      for c in ${(f)"$(docker ps -q --filter label=com.docker.compose.project=local-agent-isolation --filter label=com.docker.compose.service=$s)"}; do
        docker network connect --alias $s $net $c &>/dev/null && joined+=($c)
      done
    done
    home=home-$uuid
    (
    (( $#creds )) && export $creds
    exec docker run --rm -i $tty \
      --label "repo=$repo" \
      --network $net \
      --add-host host.docker.internal:host-gateway \
      $AGENTS_HARDENING \
      --tmpfs /tmp:exec,nosuid,nodev \
      -e TERM -e COLORTERM \
      -e ANTHROPIC_API_KEY -e CLAUDE_CODE_OAUTH_TOKEN -e OPENAI_API_KEY \
      -e GEMINI_API_KEY -e GOOGLE_API_KEY -e KIRO_API_KEY \
      $passed \
      -v "$HOME/.agents:/.agents:ro" \
      -v "$repo:$repo" \
      -w "$dir" \
      -v "${home}:/home" \
      -v "${name}-logins:/logins:ro" \
      $guards \
      $sessions \
      $image "${args[@]}"
    )
    rc=$?
    return $rc
  } always {
    # Failed or interrupted runs too: a login made before Ctrl-C is kept, and
    # so is the session.
    if [[ -n $home ]]; then
      _harness_save $home || print -u2 "harness: not every login from this run was saved (above)"
      docker volume rm $home >/dev/null
    fi
    if [[ -n $run ]]; then
      _harness_collect $run
      [[ -n $lockfd ]] && zsystem flock -u $lockfd
      rm -f $run.lock
    fi
    _harness_link
    if [[ -n $net ]]; then
      for c in $joined; do docker network disconnect $net $c &>/dev/null; done
      docker network rm $net >/dev/null
    fi
    [[ -n $azdir ]] && rm -rf $azdir
    _agents_git_warn
  }
}

# Creates the login store, ${name}-logins, when there is none: from the logins
# in the shared home volume earlier versions used, ${name}-home, when there is
# one, which is left for the user to remove.
_harness_logins() {
  docker volume inspect ${name}-logins &>/dev/null && return
  if docker volume inspect ${name}-home &>/dev/null; then
    _harness_save ${name}-home
    print -u2 "harness: logins copied from the old ${name}-home volume; once they work, remove it: docker volume rm ${name}-home"
  else
    _harness_save
  fi
}

# Copies the logins out of home volume $1, read-only, into ${name}-logins with
# the image's agents-logins-save (regular files its logins.d declares, through
# its sanitizers). With no $1 it only creates the store, which docker fills from
# the image's 1000-owned /logins.
_harness_save() {
  local from=()
  [[ -n $1 ]] && from=(-v ${1}:/run:ro)
  docker run --rm $AGENTS_HARDENING --network none $from -v ${name}-logins:/logins \
    --entrypoint agents-logins-save $image /run /logins
}

# The launcher's own flags, taken out of args; sets native, share_*, help, dir.
_harness_flags() {
  # The wrapper that called harness (claude, codex, ...) and its host binary.
  local wrapper=${funcstack[3]} bin=${funcstack[3]}
  [[ $bin == kiro ]] && bin=kiro-cli   # the kiro wrapper; the host CLI is kiro-cli

  # -0, anywhere in the arguments (`claude --resume <id> -0`), runs the host
  # binary, still honouring a leading directory.
  if (( ${args[(Ie)-0]} )); then
    [[ -n $wrapper ]] || { print -u2 "harness: -0 needs a wrapper like claude"; return 1 }
    native=$bin
    args=("${(@)args:#-0}")
  fi

  # -gh, -aws and -az, also anywhere, share the host's GitHub, AWS and Azure
  # credentials; without them the container gets none of them.
  (( ${args[(Ie)-gh]} )) && share_gh=1 && args=("${(@)args:#-gh}")
  (( ${args[(Ie)-aws]} )) && share_aws=1 && args=("${(@)args:#-aws}")
  (( ${args[(Ie)-az]} )) && share_az=1 && args=("${(@)args:#-az}")

  # A leading argument that is an existing directory is where to run; anything
  # else, --continue or -p included, goes to the harness.
  dir=$PWD
  if [[ -n $args[1] && -d $args[1] ]]; then
    dir=$args[1]
    shift args
  fi
  dir=${dir:A}            # zsh: absolute, symlinks resolved, to match git's answer

  # --help or -h, after the directory too (`claude ~/repo --help`): the
  # launcher's own usage, then the harness's, from the host binary when one is
  # installed (no container start), else from the image.
  if [[ -z $native && $args[1] == (-h|--help) ]]; then
    help=1
    print "usage: ${wrapper:-harness} [-0] [-gh] [-aws] [-az] [dir] [args...]
  -0    run the host ${bin:-harness}, no container
  -gh   share the host's gh login (gh auth token)
  -aws  share the expiring keys of the host's AWS_PROFILE (SSO or assumed
        role; long-term access keys are refused)
  -az   share a copy of the host's az login, deleted when the run ends
  dir   run in this directory instead of \$PWD
  args  go to ${wrapper:-harness}; its own help follows
"
    (( $+commands[$bin] )) && native=$bin
  fi
  return 0
}

# Sets repo: the first of $1 and its parents with a .git, or $1 outside any.
# Not `git rev-parse --show-toplevel`, which honours a core.worktree a run could
# plant, so the next run would mount wherever it points ($HOME, say) read-write.
# Then readies the guards harness mounts read-only over it: .git/hooks,
# .git/config, .git/modules and .claude are created, so none is missing for an
# agent to create. Returns 1, saying why, for what they cannot cover: a link
# among them (docker would mount its target), a .git that is a file (a worktree
# or submodule, whose real .git is elsewhere), or a .git that points host git
# outside itself (_agents_git_escape). Checked again after creating, as a
# container running in the repo now could swap one in.
_agents_repo() {
  local d=$1 g p why paths
  repo=$1
  while :; do
    [[ -e $d/.git || -L $d/.git ]] && { repo=$d; break }
    [[ $d == / ]] && break
    d=${d:h}
  done
  g=$repo/.git
  paths=($repo $repo/.claude)
  for p in $AGENTS_PROJECT_CONFIG; do [[ -e $repo/$p || -L $repo/$p ]] && paths+=($repo/$p); done
  [[ -e $g || -L $g ]] && paths+=($g $g/hooks $g/config $g/modules)
  for p in $paths; do
    [[ -L $p || ${p:A} != $p ]] && { print -u2 "harness: $p is a symlink, or under one; refusing to start"; return 1 }
  done
  if [[ -e $g ]]; then
    [[ -d $g ]] || { print -u2 "harness: $g is a file (a worktree or submodule), which the read-only guards cannot cover; run in the main checkout"; return 1 }
    why=$(_agents_git_escape $repo)
    [[ -z $why ]] || { print -u2 "harness: $why; refusing to start. Remove it, after checking what it points at"; return 1 }
    mkdir -p $g/hooks $g/modules || return 1
    [[ -e $g/config ]] || touch $g/config || return 1
  fi
  mkdir -p $repo/.claude || return 1
  for p in $paths; do
    [[ -L $p ]] && { print -u2 "harness: $p is a symlink; refusing to start"; return 1 }
  done
  return 0
}

# Before -0 runs a host binary in $1: the host binary runs git and loads project
# config there, so refuse what points host git outside the repo (as harness
# does), then ask when project config a container could have written is new or
# changed. Your own worktrees are allowed: there .git is a file and its
# commondir is real, and the launcher never runs a container in one.
_agents_host_check() {
  local d=$1 repo= changed=() p a
  while :; do
    [[ -e $d/.git || -L $d/.git ]] && { repo=$d; break }
    [[ $d == / ]] && break
    d=${d:h}
  done
  [[ -n $repo ]] || repo=$1
  if [[ -d $repo/.git && ! -L $repo/.git ]]; then
    local why=$(_agents_git_escape $repo)
    [[ -z $why ]] || { print -u2 "harness: $why; not running the host binary there. Remove it, after checking what it points at"; return 1 }
  fi
  if [[ -e $repo/.git ]]; then
    changed=(${(f)"$(git -C $repo status --porcelain --untracked-files=all -- $AGENTS_PROJECT_CONFIG 2>/dev/null)"})
  else
    # Not a folder the launcher left empty (it makes .claude in every run's dir).
    for p in $AGENTS_PROJECT_CONFIG; do
      a=($repo/$p(N^/) $repo/$p(N/F))
      (( $#a )) && changed+=("?? $p")
    done
  fi
  (( $#changed )) || return 0
  print -u2 "harness: project config the host binary may load is new or changed (a container could have written it):"
  print -u2 -l -- "  "$^changed
  [[ -t 0 ]] || { print -u2 "harness: review it, then run again from a terminal to confirm"; return 1 }
  read -q "a?Run the host binary anyway? [y/N] " || { print -u2; return 1 }
  print -u2
}

# Prints what in $1/.git points the host's git outside it, if anything:
# commondir (git then takes that folder's config and hooks) or core.worktree.
# -C /: not discovering the repo the caller is in.
_agents_git_escape() {
  local g=$1/.git
  if [[ -e $g/commondir || -L $g/commondir ]]; then
    print -r -- "$g/commondir points host git at another folder's config and hooks"
  elif git -C / config --file $g/config --includes --get core.worktree &>/dev/null; then
    print -r -- "$g/config sets core.worktree"
  fi
}

# After a run: the same check, for what the container set during it. Not
# deleted: whoever removes it should see what it pointed at first.
_agents_git_warn() {
  local why
  [[ -d $repo/.git ]] && why=$(_agents_git_escape $repo)
  [[ -z $why ]] || print -u2 "
harness: WARNING: $why, set during this run.
harness: WARNING: do not run git on the host in $repo until it is removed.
"
}

# Read-only over the rw repo mount, for every image: what the host runs from
# the repo, all created by _agents_repo. Fills guards.
_harness_guards() {
  # The host's git runs whatever lands in .git/hooks, and .git/config can point
  # it at a command too (core.fsmonitor, core.hooksPath), as can a submodule's
  # own hooks and config under .git/modules, which an agent could otherwise
  # create. So agents cannot `git remote add` or `branch -u` either.
  if [[ -d $repo/.git ]]; then
    guards=(-v "$repo/.git/hooks:$repo/.git/hooks:ro"
      -v "$repo/.git/config:$repo/.git/config:ro"
      -v "$repo/.git/modules:$repo/.git/modules:ro")
  fi
  # The host `claude -0` loads hooks and settings from .claude, so an agent
  # that could plant them there runs code outside the container. herdr runs
  # claude too, so every image gets it.
  guards+=(-v "$repo/.claude:$repo/.claude:ro")
  local p
  for p in ${AGENTS_PROJECT_CONFIG:#.claude}; do
    [[ -e $repo/$p ]] && guards+=(-v "$repo/$p:$repo/$p:ro")
  done
}

# Credentials only on request, as env vars (creds, NAME=value) and docker flags
# (passed); without them the container gets none. A failed check returns 1.
_harness_creds() {
  local e
  # Just the gh login's token, no GH_TOKEN or GITHUB_TOKEN from the host's env;
  # what it may do is limited by the rules in ~/.agents.
  if [[ -n $share_gh ]]; then
    local token=$(gh auth token 2>/dev/null)
    [[ -n $token ]] || { print -u2 "harness: -gh: no token from gh auth token (gh auth login?)"; return 1 }
    creds+=(GH_TOKEN=$token GITHUB_TOKEN=$token)
  fi
  # What `aws configure export-credentials` resolves: keys for one profile, not
  # ~/.aws with every profile in it. Only keys that expire, which come with a
  # session token: an SSO or role session's, never a user's long-term keys.
  if [[ -n $share_aws ]]; then
    local aws=(${(f)"$(aws configure export-credentials --format env-no-export 2>/dev/null)"})
    (( $#aws )) || { print -u2 "harness: -aws: no credentials from aws configure export-credentials (aws sso login?)"; return 1 }
    (( ${aws[(I)AWS_SESSION_TOKEN=*]} )) || { print -u2 "harness: -aws: ${AWS_PROFILE:-the default profile} has long-term access keys, which do not expire; use an SSO or assumed-role profile"; return 1 }
    local region=${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null)}}
    creds+=($aws ${region:+AWS_REGION=$region})
  fi
  for e in $creds; do passed+=(-e ${e%%=*}); done

  # az has no env-var login, so -az copies just the login files to a temp dir
  # the container uses as AZURE_CONFIG_DIR (token refreshes land there), and
  # harness deletes it after the run. Not ~/.azure itself: logs, extensions and
  # config stay on the host. These carry az's refresh token, longer-lived than -aws keys.
  if [[ -n $share_az ]]; then
    local azsrc=${AZURE_CONFIG_DIR:-$HOME/.azure}
    [[ -f $azsrc/msal_token_cache.json ]] || { print -u2 "harness: -az: no az login in $azsrc (an encrypted Windows token cache cannot be shared)"; return 1 }
    azdir=$(mktemp -d) || return 1
    cp $azsrc/(azureProfile.json|msal_token_cache.json|clouds.config|service_principal_entries.json)(N.) $azdir/
    passed+=(-v "$azdir:/azure" -e AZURE_CONFIG_DIR=/azure)
  fi
  return 0
}

# Each harness's container sessions for this directory live in one host folder,
# $AGENTS_SESSIONS/<harness>/<key>, mounted where the harness keeps them, so a
# run never sees a host session, nor another directory's. Where the launcher can
# know the run's session before it starts (Claude, Copilot, pi), the folder is
# read-only and only that session is writable over it: a run reads every
# session for the directory and writes its own. The others get the folder
# writable. Fills sessions, links and args; a refusal returns 1.
# The key is the path with every non-alphanumeric as -, as the harnesses key it
# in the container and on the host; Claude truncates and hashes keys over 200
# characters, which is not mirrored, so those skip this. The host folders add
# a hash of the path (skey), as /a/b-c and /a/b/c share a key.
_harness_sessions() {
  local key=${dir//[^a-zA-Z0-9]/-} h=${${name#harness-}%-*} in base id a f i found=() resume= sum skey
  [[ -n $help || $args[1] == (-h|--help|-v|--version) ]] && return
  if (( ${#key} > 200 )); then
    print -u2 "harness: path over 200 characters; this run's sessions are not kept"
    return
  fi
  sum=$(_agents_sha256 $dir)
  skey=$key-${sum[1,8]}
  # A bare -r or --resume opens the harness's picker, which offers sessions this
  # run could not write, so each harness that has one refuses it.
  case $h in
    (claude)
      [[ $args[1] == (mcp|auth|config|doctor|install|update|upgrade|plugin|plugins|setup-token|migrate-installer) ]] && return
      _harness_store claude claude || return
      # -c becomes --resume <newest>, rather than trusting Claude to pick the
      # same one: the run can only write the session named here. Newest by
      # transcript, which every append touches.
      local fork= named=
      for (( i = 1; i <= $#args; i++ )); do
        a=$args[i]
        case $a in
          (-r|--resume) resume=1; [[ $args[i+1] == -* ]] || id=$args[i+1] ;;
          (--resume=*) resume=1 id=${a#*=} ;;
          (-c|--continue)
            found=($base/*.jsonl(N.om[1]))
            (( $#found )) || { print -u2 "harness: no container session to continue here"; return 1 }
            id=${found[1]:t:r} resume=1
            args[i,i]=(--resume $id); (( i++ )) ;;
          (--session-id|--session-id=*) named=1 ;;
          (--fork-session) fork=1 ;;
        esac
      done
      if [[ -n $resume && -z $id ]]; then
        print -u2 "harness: claude -r needs a session id (the picker offers sessions this run cannot write); -c resumes the newest. This directory's are the <id>.jsonl in $base"
        return 1
      elif [[ -n $id && ! $id =~ '^[0-9a-f-]+$' ]]; then
        print -u2 "harness: not a session id: $id"; return 1
      elif [[ -n $id && ! -f $base/$id.jsonl ]]; then
        print -u2 "harness: no container session $id here; host sessions are not mounted in"; return 1
      fi
      # A new session, or a fork, gets a folder of its own (_harness_fresh):
      # its transcript would have to exist to be mounted on its own, and Claude
      # (2.1.302) refuses a --session-id whose <id>.jsonl exists: "Session ID
      # ... is already in use". A fork reads its source read-only there.
      # the /resume picker inside such a run lists none of the
      # directory's other sessions.
      # A resume's own session is <id>.jsonl, <id>/ (subagents, tool results)
      # and memory/, shared by the directory's runs; a /clear inside one starts
      # a transcript in the read-only folder, which fails.
      if [[ -n $fork || -z $id ]]; then
        [[ -n $named ]] || args=(--session-id $uuid "${args[@]}")
        local from=()
        [[ -n $id ]] && from=($id.jsonl:ro) && [[ -d $base/$id && ! -L $base/$id ]] && from+=(${id}:ro)
        _harness_fresh memory $from || return
      else
        _harness_mount $id.jsonl $id memory || return
      fi
      # Every transcript is hard-linked into ~/.claude/projects, so the host
      # `claude -0 --resume <id>` finds it and both sides append to one file.
      # subagent and tool-result folders are not linked to the host.
      links+=($base $HOME/.claude/projects/$key '*.jsonl')
      ;;
    (copilot)
      # A first argument that is not a flag is a subcommand.
      [[ -n $args[1] && $args[1] != -* ]] && return
      _harness_store copilot copilot || return
      # Copilot keeps a session as a folder, <id>/. --session-id=<id> resumes it,
      # or starts it under that id when there is none, so a new run gets one
      # the launcher names; --continue becomes --resume=<newest>.
      local id_new=
      for (( i = 1; i <= $#args; i++ )); do
        a=$args[i]
        case $a in
          (-r|--resume) resume=1; [[ $args[i+1] == -* ]] || id=$args[i+1] ;;
          (--resume=*) resume=1 id=${a#*=} ;;
          (--session-id) id_new=1 id=$args[i+1] ;;
          (--session-id=*) id_new=1 id=${a#*=} ;;
          (--continue)
            found=($base/*/events.jsonl(N.om[1]))
            (( $#found )) || { print -u2 "harness: no container session to continue here"; return 1 }
            id=${found[1]:h:t} resume=1
            args[i]=--resume=$id ;;
        esac
      done
      if [[ -n $resume && -z $id ]]; then
        print -u2 "harness: copilot --resume needs a session id (the picker offers sessions this run cannot write); --continue resumes the newest. This directory's are the folders in $base"
        return 1
      elif [[ -n $id && ! $id =~ '^[0-9a-f-]+$' ]]; then
        print -u2 "harness: not a session id: $id"; return 1
      elif [[ -n $id && -z $id_new && ! -d $base/$id ]]; then
        print -u2 "harness: no container session $id here; host sessions are not mounted in"; return 1
      fi
      [[ -n $id ]] || { id=$uuid; args=(--session-id=$id "${args[@]}") }
      # a new session's <id>/ is created empty for the mount;
      # unverified that Copilot starts a session in an empty folder rather
      # than failing to load one. Drop to a writable folder if it does not.
      _harness_mount $id || return
      ;;
    (pi)
      [[ $args[1] == (install|remove|uninstall|update|list|config) ]] && return
      _harness_store pi pi || return
      # pi opens the file --session names and starts a session in it when it
      # is missing or empty, so a new run gets one the launcher names
      # (<timestamp>_<uuid>.jsonl, pi's own pattern), created empty for the
      # mount. --session <id> matches the id in a file's first line, the
      # session header; -c becomes --session <newest>.
      local file= fork=
      for (( i = 1; i <= $#args; i++ )); do
        a=$args[i]
        case $a in
          (-r|--resume)
            print -u2 "harness: pi -r is a picker, which offers sessions this run cannot write; use pi --session <id>, or -c for the newest. This directory's are in $base"
            return 1 ;;
          (-c|--continue)
            found=($base/*.jsonl(N.om[1]))
            (( $#found )) || { print -u2 "harness: no container session to continue here"; return 1 }
            file=${found[1]:t}
            args[i,i]=(--session $in/$file); (( i++ )) ;;
          (--session)
            a=$args[i+1]
            if [[ $a == */* || $a == *.jsonl ]]; then
              file=${a:t}
            else
              for f in $base/*.jsonl(N.om); do
                read -r id < $f
                [[ $id == *\"id\":\"$a* ]] && { file=${f:t}; break }
              done
            fi
            [[ -n $file && -f $base/$file ]] || { print -u2 "harness: no container session $a here; host sessions are not mounted in"; return 1 }
            args[i+1]=$in/$file; (( i++ )) ;;
          (--fork) fork=1 ;;
        esac
      done
      # A fork's file is named by pi, so a fork gets a folder of its own
      # (_harness_fresh), its source read-only in it. Inside any other run,
      # /new or /fork starts a file in the read-only folder, which fails.
      if [[ -n $fork ]]; then
        _harness_fresh ${file:+${file}:ro} || return
      else
        if [[ -z $file ]]; then
          file=$(date -u +%Y-%m-%dT%H-%M-%S-000Z)_$uuid.jsonl
          touch $base/$file
          args=(--session $in/$file "${args[@]}")
        fi
        _harness_mount $file || return
      fi
      ;;
    (codex)
      # Codex picks its own ids and files (sessions/YYYY/MM/DD/rollout-*.jsonl),
      # so the folder is writable: this directory's container sessions only.
      # Each is hard-linked into ~/.codex/sessions, so the host `codex -0
      # resume <id>` finds it.
      _harness_store codex codex || return
      _harness_mount
      links+=($base $HOME/.codex/sessions '*/*/*/*.jsonl')
      ;;
    (gemini|opencode)
      # Gemini names its file with a timestamp it picks, and OpenCode keeps one
      # SQLite database, so the folder is writable.
      _harness_store $h $h || return
      _harness_mount
      ;;
    (herdr)
      # herdr's panes start sessions with ids the launcher cannot know, so each
      # harness it runs gets a writable folder of herdr's own, apart from the
      # standalone runs' read-only ones. Claude's memory/ is the directory's
      # shared one.
      local memory
      _harness_store claude claude || return
      memory=$base/memory
      [[ -L $memory ]] && { print -u2 "harness: $memory is a symlink"; return 1 }
      mkdir -p $memory
      for a in claude codex copilot gemini opencode pi; do
        _harness_store $a herdr/$a && _harness_mount
      done
      sessions+=(-v "$memory:/home/.claude/projects/$key/memory")
      links+=($AGENTS_SESSIONS/herdr/claude/$skey $HOME/.claude/projects/$key '*.jsonl'
              $AGENTS_SESSIONS/herdr/codex/$skey $HOME/.codex/sessions '*/*/*/*.jsonl')
      ;;
  esac
  _harness_link
  return 0
}

# Sets base, the host folder for harness $1's sessions under $AGENTS_SESSIONS/$2,
# and in, where that harness keeps this directory's sessions in the container.
# Any number of runs share it. First moves in what runs killed before they
# could (_harness_fresh) left in folders of their own: those whose lock is free.
_harness_store() {
  local old fd
  base=$AGENTS_SESSIONS/$2/$skey
  mkdir -p ${base:h} || return 1
  zmodload zsh/system || return 1
  for old in $base.run-*(N/); do
    zsystem flock -t 0 -f fd $old.lock 2>/dev/null || continue
    _harness_collect $old
    zsystem flock -u $fd
    rm -f $old.lock
  done
  case $1 in
    (claude)   in=/home/.claude/projects/$key ;;
    (codex)    in=/home/.codex/sessions ;;
    (copilot)  in=/home/.copilot/session-state ;;
    # pi: the cwd with its leading / dropped and every / and : as -, in --...--.
    (pi)       in=/home/.pi/agent/sessions/--${${${dir#/}//\//-}//:/-}-- ;;
    # Gemini: the cwd's name, lowercased, every run of other than [a-z0-9] as one
    # -, trimmed, or `project`. Gemini adds -1, -2 ... (in ~/.gemini/projects.json)
    # when another path took the name first, but each run's home starts with
    # none registered, so its slug is this one.
    # The whole project folder, not just its chats/: docker would make that
    # folder root-owned, and Gemini writes its logs and checkpoints there too.
    (gemini)
      local slug=${(L)dir:t}
      slug=${slug//[^a-z0-9]/-}
      while [[ $slug == *--* ]]; do slug=${slug//--/-}; done
      slug=${${slug#-}%-}
      in=/home/.gemini/tmp/${slug:-project} ;;
    # OpenCode: OPENCODE_DB moves only the database, so the login in it is per directory too.
    (opencode) in=/sessions-opencode; sessions+=(-e OPENCODE_DB=$in/opencode.db) ;;
  esac
  mkdir -p $base
}

# Mounts base at in: read-only with each named entry (a transcript file or a
# folder) writable over it, or with none named, writable. A named folder is
# created; a named file must exist. Docker mounts a symlink's target, so one is
# refused. No container swaps one in between this check and docker's mount: a
# base with entries named from it (Claude's, Copilot's, pi's) is only ever
# mounted read-only, new sessions going to a folder of their own
# (_harness_fresh); one mounted writable (Codex's, Gemini's, OpenCode's,
# herdr's) never has entries named.
_harness_mount() {
  local a
  if (( ! $# )); then
    sessions+=(-v "$base:$in")
    return
  fi
  sessions+=(-v "$base:$in:ro")
  for a; do
    [[ -L $base/$a ]] && { print -u2 "harness: $base/$a is a symlink"; return 1 }
    [[ -e $base/$a ]] || mkdir -p $base/$a
    sessions+=(-v "$base/$a:$in/$a")
  done
}

# Mounts a folder of this run's own, run ($base.run-<uuid>), writable at in, for
# a session whose transcript the harness names itself, so the launcher cannot
# mount it alone over a read-only base. Each named entry of base goes over it,
# writable, or read-only as <name>:ro (a fork's source); a missing one is
# created as a folder. When the run ends, _harness_collect moves its sessions
# into base. Locked for the run (lockfd, run.lock beside it), so _harness_store
# can tell the folder of a run killed before that.
_harness_fresh() {
  local a e
  run=$base.run-$uuid
  touch $run.lock && zsystem flock -t 0 -f lockfd $run.lock && mkdir $run || return 1
  sessions+=(-v "$run:$in")
  for a; do
    e=${a%:ro}
    [[ -L $base/$e ]] && { print -u2 "harness: $base/$e is a symlink"; return 1 }
    [[ -e $base/$e ]] || mkdir -p $base/$e
    # The mount point, made here: docker would make it root-owned.
    if [[ -d $base/$e ]]; then mkdir $run/$e; else touch $run/$e; fi
    sessions+=(-v "$base/$e:$in/$a")
  done
}

# Moves the sessions in run folder $1 (_harness_fresh) into its store: each
# transcript, a regular *.jsonl, with the <id>/ beside it (Claude's subagents
# and tool results), unless the store has that name (an entry mounted over the
# folder). Then removes the folder. Its container has exited, and mv and rm
# move or remove a symlink it left, never its target; _harness_mount and
# _harness_link refuse one in the store.
_harness_collect() {
  local base=${1%.run-*} f
  for f in $1/*.jsonl(N.); do
    [[ -e $base/${f:t} || -L $base/${f:t} ]] && continue
    mv $f $base/
    [[ -d ${f:r} && ! -L ${f:r} && ! -e $base/${f:r:t} ]] && mv ${f:r} $base/
  done
  rm -rf $1
}

# Hard-links each container transcript into the host harness's own folder, at
# the same relative path, once; a name already there (a host session, or linked
# before) is left alone. links holds (container folder, host folder, glob) triplets.
_harness_link() {
  local src dst glob f to tmp ok=
  (( $#links )) || return
  # -P links a symlink itself, never its target; macOS and GNU ln have it, busybox's
  # does not, and a plain ln could follow one a container swapped in, so skip there.
  # Probed by what it does: macOS and GNU word a failed link differently.
  tmp=$(mktemp -d) || return
  ln -s x $tmp/s && ln -P $tmp/s $tmp/h 2>/dev/null && [[ -L $tmp/h ]] && ok=1
  rm -rf $tmp
  if [[ -z $ok ]]; then
    print -u2 "harness: this ln has no -P, so container sessions are not linked to the host"
    return
  fi
  for src dst glob in $links; do
    # (.) regular files only: the container controls these folders, and a
    # symlink or FIFO named *.jsonl would hand the host CLI a file of its choice.
    # Nor through a symlinked folder (codex's YYYY/MM/DD). A running container
    # can still swap one in between the glob and ln, so recheck the link.
    for f in $src/${~glob}(N.); do
      [[ ${f:h:A} == ${src:A}${${f:h}#$src} ]] || continue
      to=$dst/${f#$src/}
      [[ -e $to || -L $to ]] && continue
      mkdir -p ${to:h}
      ln -P $f $to && [[ -L $to || ! -f $to ]] && rm -f $to
    done
  done
}

claude()   { harness harness-claude-code "$@" }
codex()    { harness harness-codex "$@" }
copilot()  { harness harness-copilot "$@" }
gemini()   { harness harness-gemini "$@" }
hermes()   { harness harness-hermes "$@" }
kiro()     { harness harness-kiro "$@" }
opencode() { harness harness-opencode "$@" }
pi()       { harness harness-pi-mono "$@" }

# herdr ships every harness but Kiro, whose license bars redistribution.
herdr()    { harness herdr "$@" }

# docker compose on compose.yaml, with AGENTS_WORKSPACE set to the repo $PWD is
# in (found and readied by _agents_repo, as for harness(), or $PWD outside one):
# the one directory paperclip and t3code see, at AGENTS_WORKSPACE_IN (the same
# path here; agents.ps1's is the /c/... form). AGENTS_WORKSPACE_KEY, 12 hex of
# its sha256, names their home volumes, one per workspace. Set on every call, since compose
# interpolates the whole file even for ollama or exec, so a refusal stops those
# too. compose.yaml mounts .git/hooks and .git/config read-only; .git/modules
# and .claude are created too, but compose does not mount them.
# Bringing paperclip or t3code up from another repo recreates that container,
# stopping whatever it was doing in the previous one.
_compose() {
  local repo rc
  _agents_repo ${PWD:A} || return
  [[ $1 == up ]] && print -u2 "workspace: $repo"
  local sum=$(_agents_sha256 $repo)
  AGENTS_WORKSPACE=$repo AGENTS_WORKSPACE_IN=$repo AGENTS_WORKSPACE_KEY=${sum[1,12]} \
    docker compose -f $AGENTS_ISOLATION/compose.yaml "$@"
  rc=$?
  _agents_git_warn
  return $rc
}

# Not a harness: one shared daemon, not one container per repo. Bare call
# starts it, args go to the ollama CLI inside it. The daemon's models are
# read-only, so `ollama pull hf.co/...` and the other commands that write
# them run in compose's one-off writer, local-system-2-pull; both need blobs/
# and manifests/ to exist.
ollama() {
  local m=$HOME/.agents/models
  mkdir -p $m/blobs $m/manifests || return
  if [[ $1 == (pull|rm|cp|create|push) ]]; then
    _compose run --rm local-system-2-pull "$@"
  elif (( $# )); then
    _compose exec local-system-2 ollama "$@"
  else
    _compose up -d local-system-2
  fi
}

# Also a shared service, with its database. Bare call starts both and prints
# where to go; args go to the paperclipai CLI inside: `paperclip doctor`.
paperclip() {
  if (( $# )); then
    _compose exec paperclip paperclipai "$@"
  else
    _compose up -d paperclip || return
    print "http://localhost:${PAPERCLIP_PORT:-3100}"
  fi
}

# Logs paperclip's claude agents in; kept in its home volume, one per workspace.
paperclip-claude-auth() {
  _compose exec paperclip claude auth login
}

# T3 Code, a shared service too. Bare call starts it and prints a one-time
# pairing link for the browser; args go to the t3 CLI inside: `t3 auth --help`.
t3() {
  if (( $# )); then
    _compose exec t3code t3 "$@"
  else
    _compose up -d --wait t3code || return
    _compose exec t3code t3 auth pairing create --base-url "http://localhost:${T3CODE_PORT:-3773}"
  fi
}
