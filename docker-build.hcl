# The build step. compose.yaml runs the shared services; the launchers run the rest.
#
#   docker buildx create --name multiarch --driver docker-container --bootstrap --use
#                                          # once; the default docker driver cannot attest
#   docker buildx bake -f docker-build.hcl --load          # dev: all, native arch
#   docker buildx bake -f docker-build.hcl harness-codex --load   # dev: one target
#   GIT_SHA=$(git rev-parse HEAD) SOURCE_DATE_EPOCH=$(git log -1 --pretty=%ct) \
#     docker buildx bake -f docker-build.hcl release       # ship: both arches, PUSHES
#
# Releases normally come from CI (.github/workflows/release.yml), which pushes
# every image to Docker Hub as willfarrell/<target> on each push to main.
#
# Always pass -f: bake otherwise also reads compose.yaml next to it and merges
# its service into the plan.
#
# If the container-driver builder is not the active one, release targets need
# `--builder <name>` or they fail with "Attestation is not supported for the
# docker driver". Dev targets work on the default driver either way.
#
# Why two tiers: attestations turn even a one-arch result into an image index,
# which the classic image store cannot --load, and the docker driver cannot
# produce them at all. Dev targets carry neither, release targets carry both.
# `docker info -f '{{.Driver}}'`: overlayfs = containerd store, --load works for
# everything; overlay2 = classic store, release builds must push.
#
# `release` pushes by itself: rewrite-timestamp is an exporter option and
# `--push` cannot carry options. Both arches without pushing:
#   docker buildx bake -f docker-build.hcl release --set '*.output=type=cacheonly'
#
# Lint, after a --load build: BuildKit's checks cannot follow a `target:`
# context, so this points the named contexts at the loaded images instead.
#   CONTEXTS=image docker buildx bake -f docker-build.hcl --call check

variable "TAG" {
  default = "latest"
}

# Docker Hub, the willfarrell namespace: willfarrell/harness-codex and so on.
variable "REGISTRY" {
  default = "docker.io/willfarrell"
}

variable "SOURCE_URL" {
  default = "https://github.com/willfarrell/local-agent-isolation"
}

# Provenance inputs, fed from the environment because bake cannot run git.
# Both are omitted from the build when empty rather than passed as "".
variable "GIT_SHA" {
  default = ""
}

variable "SOURCE_DATE_EPOCH" {
  default = ""
}

# Where the named contexts come from: "target" builds them in the same run,
# "image" reads the already-loaded agents/* images, which is what lets
# `--call check` lint the harnesses.
variable "CONTEXTS" {
  default = "target"
}

function "ctx" {
  params = [name]
  result = CONTEXTS == "image" ? "docker-image://willfarrell/${name}:${TAG}" : "target:${name}"
}

# Base images: full reference including digest, so overriding these actually
# works. A digest on the FROM line instead would win over the ARG and make the
# knob silently inert. A base bump changes libc, the CA bundle and every package
# version at once, so it is a deliberate edit, not a drift.
#
# It is also not a one-variable change: every Dockerfile pins its apk packages
# to revisions that exist only in this exact base (hadolint DL3018), and alpine
# keeps one revision per branch. A new digest invalidates every pin at once and
# the build fails with "package not found", never naming the digest as the
# cause. Re-read values with `apk policy <pkg>` in the new base, per image:
# local-system-2 pins ollama through OLLAMA_VERSION below, and herdr needs
# openssh-client-default, which `apk policy openssh-client` never reveals
# because that name is a virtual provider.
#
# `unable to select packages ... exit code: 4` is usually a transient index
# fetch, not a bad pin: retry once before re-reading versions. A preceding
# `DNS: transient error` or `fetching .../APKINDEX.tar.gz` warning is what
# distinguishes a network blip from a revision that genuinely vanished — the
# error itself names neither the package nor the cause.
variable "ALPINE_IMAGE" {
  default = "alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6"
}

variable "NODE_IMAGE" {
  default = "node:24-alpine@sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1"
}

# Installed versions. Pinned rather than `latest`: these images are the ones
# you debug six months from now, and a `latest` build is not reproducible.
variable "CLAUDE_CODE_VERSION" {
  default = "2.1.280"
}

variable "CODEX_VERSION" {
  default = "0.156.0"
}

variable "COPILOT_VERSION" {
  default = "1.0.88"
}

variable "GEMINI_VERSION" {
  default = "0.60.0"
}

variable "OPENCODE_VERSION" {
  default = "1.18.32"
}

variable "PI_VERSION" {
  default = "0.73.1"
}

# npm installs only versions published before this, which freezes the
# dependencies under each pinned package too (npm has no lockfile for a global
# install). Must be later than the newest pinned version's publish time, so a
# version bump usually bumps this as well: `npm view <pkg> time --json`.
variable "NPM_BEFORE" {
  default = "2026-09-22T21:00:00Z"
}

# MCP server every harness names in its settings.*; built into tools.
variable "CONTEXT_MODE_VERSION" {
  default = "1.0.169"
}

# Hermes is built from its Git tag (upstream left PyPI); the commit is checked
# as well, since a tag can move. Bump both together:
#   git ls-remote https://github.com/NousResearch/hermes-agent.git 'refs/tags/<tag>^{}'
variable "HERMES_VERSION" {
  default = "v2026.9.21"
}

variable "HERMES_COMMIT" {
  default = "d337b736aa1e8ebecfab043842d13e4a2d2f48a3"
}

variable "PAPERCLIP_VERSION" {
  default = "2026.916.1"
}

variable "HERDR_VERSION" {
  default = "0.9.1"
}

# Alpine community package revision, so it moves with ALPINE_IMAGE.
variable "OLLAMA_VERSION" {
  default = "0.17.7-r1"
}

group "default" {
  targets = ["tools", "harness-claude-code", "harness-codex", "harness-copilot", "harness-gemini", "harness-hermes", "harness-opencode", "harness-pi-mono", "herdr", "paperclip", "local-system-2"]
}

target "_common" {
  labels = merge(
    { "org.opencontainers.image.source" = SOURCE_URL },
    GIT_SHA != "" ? { "org.opencontainers.image.revision" = GIT_SHA } : {}
  )
  args = SOURCE_DATE_EPOCH != "" ? { SOURCE_DATE_EPOCH = SOURCE_DATE_EPOCH } : {}
}

# Only the images that still name alpine directly take ALPINE_IMAGE: tools, the
# herdr download stage, and local-system-2. Harness runtimes start FROM tools instead, so
# passing it to them would warn about an unconsumed build arg.
target "_alpine" {
  args = {
    ALPINE_IMAGE = ALPINE_IMAGE
  }
}

# Only the images with a node build stage take NODE_IMAGE (tools, for the MCP
# servers, and the npm-installed harnesses); passing it to the others would
# warn about an unconsumed build arg.
target "_node" {
  args = {
    NODE_IMAGE = NODE_IMAGE
    NPM_BEFORE = NPM_BEFORE
  }
}

# Every harness runtime starts FROM this, so the shared packages and setup live
# in one file. Also what makes `FROM scratch AS tools` in each Dockerfile resolve.
target "_tools" {
  contexts = {
    tools = ctx("tools")
  }
}

# Release tier: both arches, SBOM and provenance as the audit trail, timestamps
# rewritten for reproducibility, pushed. Use `attest`, not the sbom/provenance
# shorthand: buildx parses the shorthand but silently drops it from the plan.
target "_release" {
  platforms = ["linux/amd64", "linux/arm64"]
  attest = [
    "type=sbom",
    "type=provenance,mode=max",
  ]
  output = ["type=registry,rewrite-timestamp=true"]
}

target "harness-claude-code" {
  inherits = ["_common", "_node", "_tools"]
  context  = "harness-claude-code"
  tags     = ["willfarrell/harness-claude-code:${TAG}"]
  args = {
    CLAUDE_CODE_VERSION = CLAUDE_CODE_VERSION
  }
}

target "harness-codex" {
  inherits = ["_common", "_node", "_tools"]
  context  = "harness-codex"
  tags     = ["willfarrell/harness-codex:${TAG}"]
  args = {
    CODEX_VERSION = CODEX_VERSION
  }
}

target "harness-copilot" {
  inherits = ["_common", "_node", "_tools"]
  context  = "harness-copilot"
  tags     = ["willfarrell/harness-copilot:${TAG}"]
  args = {
    COPILOT_VERSION = COPILOT_VERSION
  }
}

target "harness-gemini" {
  inherits = ["_common", "_node", "_tools"]
  context  = "harness-gemini"
  tags     = ["willfarrell/harness-gemini:${TAG}"]
  args = {
    GEMINI_VERSION = GEMINI_VERSION
  }
}

# Python, not npm, so no _node: its build stage starts from tools.
target "harness-hermes" {
  inherits = ["_common", "_tools"]
  context  = "harness-hermes"
  tags     = ["willfarrell/harness-hermes:${TAG}"]
  args = {
    HERMES_VERSION = HERMES_VERSION
    HERMES_COMMIT  = HERMES_COMMIT
  }
}

target "harness-opencode" {
  inherits = ["_common", "_node", "_tools"]
  context  = "harness-opencode"
  tags     = ["willfarrell/harness-opencode:${TAG}"]
  args = {
    OPENCODE_VERSION = OPENCODE_VERSION
  }
}

target "harness-pi-mono" {
  inherits = ["_common", "_node", "_tools"]
  context  = "harness-pi-mono"
  tags     = ["willfarrell/harness-pi-mono:${TAG}"]
  args = {
    PI_VERSION = PI_VERSION
  }
}

# herdr hosts the harnesses in its panes, so it ships them: the artifacts come
# from the sibling targets rather than reinstalling, so versions and pins stay
# in one place. Costs size: this image is the sum of all seven plus herdr.
target "herdr" {
  inherits = ["_common", "_alpine"]
  context  = "herdr"
  tags     = ["willfarrell/herdr:${TAG}"]
  # Override the Dockerfile's `FROM scratch AS <name>` placeholders. They exist
  # so hadolint DL3022 passes without an ignore, NOT to make a bare
  # `docker build` work; that still fails, at the COPY, which is what stops a
  # harness-less herdr being built by accident. Spelled out rather than
  # inherited from _tools: one contexts map per target, a second would replace
  # this one rather than merge into it.
  contexts = {
    harness-claude-code = ctx("harness-claude-code")
    harness-codex       = ctx("harness-codex")
    harness-copilot     = ctx("harness-copilot")
    harness-gemini      = ctx("harness-gemini")
    harness-hermes      = ctx("harness-hermes")
    harness-opencode    = ctx("harness-opencode")
    harness-pi-mono     = ctx("harness-pi-mono")
    tools               = ctx("tools")
  }
  args = {
    HERDR_VERSION = HERDR_VERSION
  }
}

# paperclip orchestrates the harnesses as agents, so it is built on herdr,
# which already carries all seven. A shared service in compose.yaml, not a
# per-repo harness.
target "paperclip" {
  inherits = ["_common", "_node"]
  context  = "paperclip"
  tags     = ["willfarrell/paperclip:${TAG}"]
  contexts = {
    herdr = ctx("herdr")
  }
  args = {
    PAPERCLIP_VERSION = PAPERCLIP_VERSION
  }
}

# The base every harness runtime is built on; see tools/Dockerfile.
target "tools" {
  inherits = ["_common", "_alpine", "_node"]
  context  = "tools"
  tags     = ["willfarrell/tools:${TAG}"]
  args = {
    CONTEXT_MODE_VERSION = CONTEXT_MODE_VERSION
  }
}

target "local-system-2" {
  inherits = ["_common", "_alpine"]
  context  = "local-system-2"
  tags     = ["willfarrell/local-system-2:${TAG}"]
  args = {
    OLLAMA_VERSION = OLLAMA_VERSION
  }
}

# Release tier of every target: `bake release` builds all of them, each tagged
# for the registry as TAG and, when GIT_SHA is set, as the short commit too, so
# a moving `latest` always has an immutable tag beside it to pin or roll back to.
#
# Another image: add its version variable and target block, then its name to
# this list and the default group (and, for a harness, AGENTS_HARNESSES in both
# launchers).
target "release" {
  name     = "${tgt}-release"
  matrix   = { tgt = ["tools", "harness-claude-code", "harness-codex", "harness-copilot", "harness-gemini", "harness-hermes", "harness-opencode", "harness-pi-mono", "herdr", "paperclip", "local-system-2"] }
  inherits = [tgt, "_release"]
  tags = concat(
    ["${REGISTRY}/${tgt}:${TAG}"],
    GIT_SHA != "" ? ["${REGISTRY}/${tgt}:${substr(GIT_SHA, 0, 7)}"] : []
  )
}
