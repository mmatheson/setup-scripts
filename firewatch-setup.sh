#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="/workspaces"
CACHE="/cache"
ORG="trunk-io"
REPOS=(trunk trunk2 trunk-cloud analytics-cli)

# --- Create /cache and route heavy caches there ---
# $HOME is a 5G shared NFS mount across devboxes; the root partition is large
# and devbox-local, so rustup/cargo/nvm/pnpm-store/trunk all live under /cache.
sudo mkdir -p "$CACHE"
sudo chown "$USER:$USER" "$CACHE"
export XDG_CACHE_HOME="$CACHE"

# --- Install apt packages ---
APT_PACKAGES=(zsh vim less htop direnv libwebkit2gtk-4.1-dev libappindicator3-dev librsvg2-dev patchelf)
MISSING_APT=()
for pkg in "${APT_PACKAGES[@]}"; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    MISSING_APT+=("$pkg")
  fi
done
if [ ${#MISSING_APT[@]} -gt 0 ]; then
  echo "→ installing apt packages: ${MISSING_APT[*]}"
  sudo apt-get update
  sudo apt-get install -y "${MISSING_APT[@]}"
else
  echo "✓ apt packages already installed"
fi

# --- Set zsh as the default login shell ---
ZSH_PATH="$(command -v zsh)"
if [ "$SHELL" != "$ZSH_PATH" ]; then
  echo "→ setting zsh as default shell for $USER"
  sudo chsh -s "$ZSH_PATH" "$USER"
fi

# --- Configure git ---
if ! git config --global user.name >/dev/null 2>&1; then
  echo "→ setting git user.name"
  git config --global user.name "Matt Matheson"
fi
if ! git config --global user.email >/dev/null 2>&1; then
  echo "→ setting git user.email"
  git config --global user.email "matt@trunk.io"
fi

# --- Ensure ~/.local/bin exists and is on PATH for this run ---
# jj/claude/cursor-agent install here; without this, the `command -v`
# idempotency checks miss on re-runs from a fresh shell and reinstall.
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"

# --- Relocate hardcoded-$HOME dirs onto /cache (migrate + symlink) ---
# Many tools ignore XDG_CACHE_HOME and write straight into $HOME. For each:
# copy anything already there onto /cache (cp -an, no clobber), remove the
# original, and leave a symlink so every future write lands on /cache —
# including from non-interactive shells that never source .zshrc.
relocate_to_cache() {
  local link="$1" target="$2"
  mkdir -p "$target" "$(dirname "$link")"
  if [ -e "$link" ] && [ ! -L "$link" ]; then
    echo "→ migrating $link into $target"
    cp -an "$link/." "$target/" 2>/dev/null || true
    rm -rf "$link"
  fi
  if [ ! -L "$link" ] || [ "$(readlink "$link")" != "$target" ]; then
    echo "→ symlinking $link → $target"
    rm -rf "$link"
    ln -snf "$target" "$link"
  fi
}

# ~/.cache: XDG_CACHE_HOME points at /cache, but plenty of tools hardcode
# ~/.cache anyway (trunk, prisma engine downloads). Symlinking the whole dir
# catches them all.
relocate_to_cache "$HOME/.cache" "$CACHE"
# ~/.config/sst: SST hoards provider plugins plus bundled bun/pulumi binaries
# (1.4G+ observed) and has no env var to relocate them.
relocate_to_cache "$HOME/.config/sst" "$CACHE/sst"
# ~/.cursor-server: each remote-server build under cli/servers is ~370M and
# old ones linger after client updates.
relocate_to_cache "$HOME/.cursor-server" "$CACHE/cursor-server"
# Claude Code / cursor-agent native installers keep each downloaded version
# (~200M apiece) under ~/.local/share.
relocate_to_cache "$HOME/.local/share/claude" "$CACHE/local/share/claude"
relocate_to_cache "$HOME/.local/share/cursor-agent" "$CACHE/local/share/cursor-agent"

# --- Install zellij (prebuilt musl binary from GitHub releases) ---
if command -v zellij >/dev/null 2>&1; then
  echo "✓ zellij already installed ($(zellij --version))"
else
  echo "→ installing zellij"
  case "$(uname -m)" in
    x86_64)  ZJ_ARCH="x86_64-unknown-linux-musl" ;;
    aarch64|arm64) ZJ_ARCH="aarch64-unknown-linux-musl" ;;
    *) echo "Unsupported arch $(uname -m) for zellij" >&2; exit 1 ;;
  esac
  ZJ_URL="https://github.com/zellij-org/zellij/releases/latest/download/zellij-${ZJ_ARCH}.tar.gz"
  TMP="$(mktemp -d)"
  curl -fsSL "$ZJ_URL" -o "$TMP/zellij.tar.gz"
  tar -xzf "$TMP/zellij.tar.gz" -C "$TMP"
  sudo install -m 755 "$TMP/zellij" /usr/local/bin/zellij
  rm -rf "$TMP"
fi

# --- Install jj (prebuilt musl binary from GitHub releases) ---
if command -v jj >/dev/null 2>&1; then
  echo "✓ jj already installed ($(jj --version))"
else
  echo "→ installing jj"
  case "$(uname -m)" in
    x86_64) JJ_ARCH="x86_64-unknown-linux-musl" ;;
    aarch64|arm64) JJ_ARCH="aarch64-unknown-linux-musl" ;;
    *) echo "Unsupported arch $(uname -m) for jj" >&2; exit 1 ;;
  esac
  JJ_VERSION="v0.41.0"
  curl -fsSL "https://github.com/jj-vcs/jj/releases/download/${JJ_VERSION}/jj-${JJ_VERSION}-${JJ_ARCH}.tar.gz" \
    | tar -xz -C "$HOME/.local/bin" ./jj
  chmod +x "$HOME/.local/bin/jj"
fi

# --- Install rustup / cargo (caches live on $XDG_CACHE_HOME) ---
export RUSTUP_HOME="$XDG_CACHE_HOME/.rustup"
export CARGO_HOME="$XDG_CACHE_HOME/.cargo"
export PATH="$CARGO_HOME/bin:$PATH"
# Belt-and-suspenders: symlink ~/.rustup and ~/.cargo onto /cache. The env
# vars above route rustup/cargo correctly in this shell and any interactive
# zsh (via the managed .zshrc block), but non-interactive shells — one-shot
# ssh, IDE subprocesses, Make rules invoking /bin/sh, build agents — don't
# source .zshrc and fall back to $HOME. A single nightly toolchain is enough
# to blow the 5G $HOME quota (os error 122).
relocate_to_cache "$HOME/.rustup" "$RUSTUP_HOME"
relocate_to_cache "$HOME/.cargo" "$CARGO_HOME"
if ! command -v rustup >/dev/null 2>&1; then
  echo "→ installing rustup"
  # --no-modify-path: don't touch .zshenv/.profile; the managed block in .zshrc
  # owns PATH and sources $CARGO_HOME/env (which lives on /cache, not $HOME).
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --default-toolchain stable
fi
# Older runs (before --no-modify-path) left a `. "$HOME/.cargo/env"` line in
# .zshenv; that path doesn't exist when CARGO_HOME=/cache/.cargo, so new shells
# error on startup. Strip any cargo-env sourcing — the managed .zshrc block
# handles it.
if [ -f "$HOME/.zshenv" ] && grep -q '\.cargo/env' "$HOME/.zshenv"; then
  echo "→ removing stale cargo env sourcing from ~/.zshenv"
  sed -i.bak '/\.cargo\/env/d' "$HOME/.zshenv"
  [ -s "$HOME/.zshenv" ] || rm -f "$HOME/.zshenv"
fi
# Devboxes sometimes ship with rustup present but no toolchain (or the previous
# toolchain lived on a mount that got wiped).
if ! rustup default >/dev/null 2>&1; then
  echo "→ installing rust stable toolchain"
  rustup default stable
fi

# --- Route Go caches onto /cache ---
# Go's defaults all land on the 5G $HOME mount: GOPATH=~/go (which holds the
# module cache pkg/mod and `go install`ed binaries) and GOCACHE=~/.cache/go-build.
# A single big build is enough to blow the quota, so point them at /cache. Same
# belt-and-suspenders symlink as rustup/cargo: env vars cover this shell and the
# managed .zshrc block, the ~/go symlink covers non-interactive shells that
# don't source .zshrc (one-shot ssh, IDE subprocesses, /bin/sh make rules).
export GOPATH="$XDG_CACHE_HOME/go"
export GOCACHE="$XDG_CACHE_HOME/go-build"
export GOMODCACHE="$GOPATH/pkg/mod"
export PATH="$GOPATH/bin:$PATH"
mkdir -p "$GOCACHE"
relocate_to_cache "$HOME/go" "$GOPATH"

# --- Install nvm + Node LTS ---
export NVM_DIR="$XDG_CACHE_HOME/.nvm"
if [ -s "$NVM_DIR/nvm.sh" ]; then
  echo "✓ nvm already installed"
else
  echo "→ installing nvm"
  mkdir -p "$NVM_DIR"
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash
fi
# shellcheck disable=SC1091
. "$NVM_DIR/nvm.sh"
nvm install --lts

# --- Enable pnpm via corepack and install global tools ---
# Corepack downloads pnpm on first use and prompts interactively unless this
# is set; we want unattended runs.
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
corepack enable
# Pin PNPM_HOME and add it to PATH BEFORE invoking pnpm, so pnpm's internal
# "is global-bin-dir on PATH" check sees a consistent env on every run.
export PNPM_HOME="$HOME/.local/share/pnpm"
mkdir -p "$PNPM_HOME"
case ":$PATH:" in
  *":$PNPM_HOME:"*) ;;
  *) export PATH="$PNPM_HOME:$PATH" ;;
esac
SHELL="$ZSH_PATH" pnpm setup --force >/dev/null || true
# Belt-and-suspenders: force pnpm's stored global-bin-dir to match PNPM_HOME,
# in case a prior run recorded a different path.
pnpm config set global-bin-dir "$PNPM_HOME" >/dev/null
# Big content-addressed store goes on /cache, not the 5G $HOME mount.
pnpm config set store-dir "$XDG_CACHE_HOME/pnpm/store" >/dev/null
pnpm i -g @openai/codex
# Codex refuses to start if CODEX_HOME is set to a missing dir.
mkdir -p "$XDG_CACHE_HOME/.codex"

# --- Route npm's cache onto /cache ---
# npm/npx download into ~/.npm/_cacache by default — easily 1G+ on the 5G $HOME
# mount. NPM_CONFIG_CACHE (mirrored in the managed .zshrc block) relocates it;
# migrate + symlink so non-interactive shells and one-shot npx follow too.
export NPM_CONFIG_CACHE="$XDG_CACHE_HOME/npm"
relocate_to_cache "$HOME/.npm" "$NPM_CONFIG_CACHE"

# --- Route Pulumi onto /cache ---
# ~/.pulumi/plugins holds downloaded provider plugins (hundreds of MB). PULUMI_HOME
# relocates the whole dir; migrate + symlink so the env var isn't strictly required.
export PULUMI_HOME="$XDG_CACHE_HOME/pulumi"
relocate_to_cache "$HOME/.pulumi" "$PULUMI_HOME"

# --- Install Claude Code (native installer, installs to ~/.local/bin) ---
# Versions land under ~/.local/share/claude, which is symlinked onto /cache
# above. The installer's checksum check is occasionally flaky, so retry once.
if command -v claude >/dev/null 2>&1; then
  echo "✓ claude already installed ($(claude --version 2>/dev/null | head -n1))"
else
  echo "→ installing claude code"
  curl --proto '=https' --tlsv1.2 -fsSL https://claude.ai/install.sh | bash \
    || { echo "→ claude install failed, retrying"; curl --proto '=https' --tlsv1.2 -fsSL https://claude.ai/install.sh | bash; }
fi

# --- Install cursor CLI (cursor-agent, installs to ~/.local/bin) ---
if command -v cursor-agent >/dev/null 2>&1; then
  echo "✓ cursor-agent already installed ($(cursor-agent --version 2>/dev/null | head -n1))"
else
  echo "→ installing cursor-agent"
  curl --proto '=https' --tlsv1.2 -fsSL https://cursor.com/install | bash
fi

# --- Install pi.dev ---
if command -v pi >/dev/null 2>&1; then
  echo "✓ pi already installed ($(pi --version 2>/dev/null | head -n1))"
else
  echo "→ installing pi"
  # The installer has no --yes flag; it goes interactive whenever it can open
  # /dev/tty (true even under `curl | sh`). Run it under setsid so it has no
  # controlling terminal — it then auto-installs without prompting, picking the
  # npm global prefix (or ~/.local) on its own.
  curl --proto '=https' --tlsv1.2 -fsSL https://pi.dev/install.sh | setsid sh
fi

# --- Install trunk ---
if command -v trunk >/dev/null 2>&1; then
  echo "✓ trunk already installed"
else
  echo "→ installing trunk"
  curl --proto '=https' --tlsv1.2 -fsSL https://get.trunk.io | bash -s -- -y
fi
trunk shellhooks install zsh

# --- Install tailscale ---
if command -v tailscale >/dev/null 2>&1; then
  echo "✓ tailscale already installed ($(tailscale version | head -n1))"
else
  echo "→ installing tailscale"
  curl --proto '=https' --tlsv1.2 -fsSL https://tailscale.com/install.sh | sh
fi
# On distros tailscale's installer doesn't recognize, it drops the static
# binaries (into /usr/local/sbin) but never installs a systemd unit — so
# `systemctl restart tailscaled` fails with "Unit tailscaled.service not found".
# Install the unit ourselves when it's missing, pointing at wherever tailscaled
# actually landed.
if ! systemctl list-unit-files tailscaled.service >/dev/null 2>&1 \
   || ! systemctl cat tailscaled.service >/dev/null 2>&1; then
  echo "→ installing tailscaled systemd unit"
  TAILSCALED_BIN="$(command -v tailscaled || echo /usr/local/sbin/tailscaled)"
  if [ ! -f /etc/default/tailscaled ]; then
    sudo tee /etc/default/tailscaled >/dev/null <<'EOF'
# Set the port to listen on for incoming VPN packets.
PORT="41641"
# Extra flags you might want to pass to tailscaled.
FLAGS=""
EOF
  fi
  sudo tee /etc/systemd/system/tailscaled.service >/dev/null <<EOF
[Unit]
Description=Tailscale node agent
Documentation=https://tailscale.com/kb/
Wants=network-pre.target
After=network-pre.target NetworkManager.service systemd-resolved.service

[Service]
EnvironmentFile=/etc/default/tailscaled
ExecStartPre=$TAILSCALED_BIN --cleanup
ExecStart=$TAILSCALED_BIN --state=/var/lib/tailscale/tailscaled.state --socket=/run/tailscale/tailscaled.sock --port=\${PORT} \$FLAGS
ExecStopPost=$TAILSCALED_BIN --cleanup

Restart=on-failure

RuntimeDirectory=tailscale
RuntimeDirectoryMode=0755
StateDirectory=tailscale
StateDirectoryMode=0700
CacheDirectory=tailscale
CacheDirectoryMode=0750
Type=notify

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable tailscaled
fi
sudo systemctl restart tailscaled
# `tailscale up` is skipped by default (the node is usually already authed).
# Set TAILSCALE_UP=1 to bring the node up as part of setup.
if [ -n "${TAILSCALE_UP:-}" ]; then
  sudo tailscale up
else
  echo "✓ skipping 'tailscale up' (set TAILSCALE_UP=1 to run it)"
fi

# --- Install nix (Determinate Systems installer, unattended) ---
# Multi-user daemon install; needs systemd, which devboxes have (see tailscale).
# The installer writes /etc/profile.d/nix*.sh and the daemon profile under
# /nix/var/nix/profiles/default — the managed .zshrc block sources the latter.
if command -v nix >/dev/null 2>&1 || [ -e /nix/var/nix/profiles/default/bin/nix ]; then
  echo "✓ nix already installed"
else
  echo "→ installing nix"
  curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix \
    | sh -s -- install --no-confirm
fi

# --- Configure ~/.zshenv: env that must be set BEFORE .zshrc (managed block) ---
# zsh sources .zshenv for every invocation (interactive or not) before .zshrc.
# ZSH_COMPDUMP must be pinned here: oh-my-zsh (sourced from .zshrc) otherwise
# derives the dump filename from $SHORT_HOST, which on these devboxes is a
# per-session randomized sandbox hostname — so every new shell drops a fresh
# ~/.zcompdump-<host>-<ver> (+ .zwc) pair and they pile up indefinitely. A
# fixed path on /cache means one reusable dump and nothing landing in $HOME.
ZSHENV="$HOME/.zshenv"
touch "$ZSHENV"
ENV_BEGIN="# >>> workspace-setup.sh env (managed) >>>"
ENV_END="# <<< workspace-setup.sh env (managed) <<<"
if grep -Fq "$ENV_BEGIN" "$ZSHENV"; then
  sed -i.bak "\|$ENV_BEGIN|,\|$ENV_END|d" "$ZSHENV"
fi
mkdir -p "$XDG_CACHE_HOME/zsh"
cat >> "$ZSHENV" <<'EOF'
# >>> workspace-setup.sh env (managed) >>>
export XDG_CACHE_HOME="/cache"
export ZSH_COMPDUMP="$XDG_CACHE_HOME/zsh/zcompdump"
# <<< workspace-setup.sh env (managed) <<<
EOF

# --- Configure zsh: env exports + direnv/trunk hooks (managed block) ---
ZSHRC="$HOME/.zshrc"
touch "$ZSHRC"
BEGIN_MARK="# >>> workspace-setup.sh (managed) >>>"
END_MARK="# <<< workspace-setup.sh (managed) <<<"
if grep -Fq "$BEGIN_MARK" "$ZSHRC"; then
  echo "→ refreshing managed block in $ZSHRC"
  sed -i.bak "\|$BEGIN_MARK|,\|$END_MARK|d" "$ZSHRC"
else
  echo "→ adding managed block to $ZSHRC"
fi
cat >> "$ZSHRC" <<'EOF'
# >>> workspace-setup.sh (managed) >>>
export XDG_CACHE_HOME="/cache"
export RUSTUP_HOME="$XDG_CACHE_HOME/.rustup"
export CARGO_HOME="$XDG_CACHE_HOME/.cargo"
export CODEX_HOME="$XDG_CACHE_HOME/.codex"
export NPM_CONFIG_CACHE="$XDG_CACHE_HOME/npm"
export PULUMI_HOME="$XDG_CACHE_HOME/pulumi"

export PATH="$HOME/.local/bin:$CARGO_HOME/bin:$PATH"
[ -s "$CARGO_HOME/env" ] && . "$CARGO_HOME/env"

export GOPATH="$XDG_CACHE_HOME/go"
export GOCACHE="$XDG_CACHE_HOME/go-build"
export GOMODCACHE="$GOPATH/pkg/mod"
export PATH="$GOPATH/bin:$PATH"

export NVM_DIR="$XDG_CACHE_HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"

export PNPM_HOME="$HOME/.local/share/pnpm"
case ":$PATH:" in
  *":$PNPM_HOME:"*) ;;
  *) export PATH="$PNPM_HOME:$PATH" ;;
esac

# nix daemon profile (multi-user install) — puts nix on PATH for interactive zsh
[ -s "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh" ] && . "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"

command -v direnv >/dev/null 2>&1 && eval "$(direnv hook zsh)"

alias ls="ls -lFa --color"
alias bb="bazel build"
alias br="bazel run"
alias bt="bazel test"
alias gs="git status"
alias k="kubectl"
alias zj='zellij'
alias za='zellij attach'
alias zs='zellij session'
alias zl='zellij list-sessions'
alias zk='zellij kill-session'
alias zr='zellij rename-session'
alias zd='zellij detach'
alias zq='zellij quit'
alias zc='zellij connect'
alias zx='zellij execute'
# <<< workspace-setup.sh (managed) <<<
EOF

# --- Create /workspaces and hand it to the current (non-root) user ---
sudo mkdir -p "$WORKSPACE"
sudo chown "$USER:$USER" "$WORKSPACE"

cd "$WORKSPACE"

# --- Clone repos (idempotent) ---
for repo in "${REPOS[@]}"; do
  if [ -d "$repo/.git" ]; then
    echo "✓ $repo already cloned"
  else
    echo "→ cloning $repo (shallow, last month of history)"
    git clone --recurse-submodules --shallow-submodules --shallow-since="1 month ago" "git@github.com:$ORG/$repo.git"
  fi
  # Always sync submodules — picks up new ones for repos cloned pre-flag.
  git -C "$repo" submodule update --init --recursive
done

echo "Done. Repos are in $WORKSPACE. Restart your shell (or log out/in) for zsh and PATH changes to take effect."
