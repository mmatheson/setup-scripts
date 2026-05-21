#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="/workspaces"
ORG="trunk-io"
REPOS=(trunk trunk2 trunk-cloud analytics-cli)

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

# --- Ensure ~/.local/bin exists ---
mkdir -p "$HOME/.local/bin"

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

# --- Install rustup / cargo ---
# Pin CARGO_HOME / RUSTUP_HOME to user-local paths so a devbox-provided
# CARGO_HOME (e.g. /cache/.cargo) can't redirect rustup to an ephemeral mount.
export RUSTUP_HOME="$HOME/.rustup"
export CARGO_HOME="$HOME/.cargo"
export PATH="$CARGO_HOME/bin:$PATH"
if ! command -v rustup >/dev/null 2>&1; then
  echo "→ installing rustup"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
fi
# Devboxes sometimes ship with rustup present but no toolchain (or the
# previous toolchain lived on an ephemeral mount that got wiped).
if ! rustup default >/dev/null 2>&1; then
  echo "→ installing rust stable toolchain"
  rustup default stable
fi
# Strip stale shell-rc lines that source an ephemeral cargo env path.
for rc in "$HOME/.zshenv" "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
  if [ -f "$rc" ] && grep -q '/cache/\.cargo/env' "$rc"; then
    echo "→ removing stale /cache/.cargo/env source line from $rc"
    sed -i.bak '\|/cache/\.cargo/env|d' "$rc"
  fi
done

# --- Configure direnv zsh hook ---
ZSHRC="$HOME/.zshrc"
DIRENV_HOOK_LINE='eval "$(direnv hook zsh)"'
touch "$ZSHRC"
if ! grep -Fq 'direnv hook zsh' "$ZSHRC"; then
  echo "→ adding direnv hook to $ZSHRC"
  printf '\n# direnv\n%s\n' "$DIRENV_HOOK_LINE" >> "$ZSHRC"
else
  echo "✓ direnv hook already in $ZSHRC"
fi

# --- Install nvm + Node LTS ---
export NVM_DIR="$HOME/.nvm"
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
corepack enable
# Pin PNPM_HOME and add it to PATH BEFORE invoking pnpm, so pnpm's internal
# "is global-bin-dir on PATH" check sees a consistent env on every run.
export PNPM_HOME="$HOME/.local/share/pnpm"
mkdir -p "$PNPM_HOME"
case ":$PATH:" in
  *":$PNPM_HOME:"*) ;;
  *) export PATH="$PNPM_HOME:$PATH" ;;
esac
# Write zsh integration so future interactive shells inherit PNPM_HOME.
SHELL="$ZSH_PATH" pnpm setup --force >/dev/null || true
# Belt-and-suspenders: force pnpm's stored global-bin-dir to match PNPM_HOME,
# in case a prior run recorded a different path.
pnpm config set global-bin-dir "$PNPM_HOME" >/dev/null
pnpm i -g @openai/codex

# --- Install trunk ---
if command -v trunk >/dev/null 2>&1; then
  echo "✓ trunk already installed"
else
  echo "→ installing trunk"
  curl -fsSL https://get.trunk.io | bash -s -- -y
fi

# --- Create /workspaces and hand it to the current (non-root) user ---
sudo mkdir -p "$WORKSPACE"
sudo chown "$USER:$USER" "$WORKSPACE"

cd "$WORKSPACE"

# --- Clone repos (idempotent) ---
for repo in "${REPOS[@]}"; do
  if [ -d "$repo/.git" ]; then
    echo "✓ $repo already cloned, skipping"
  else
    echo "→ cloning $repo"
    git clone "git@github.com:$ORG/$repo.git"
  fi
done

echo "Done. Repos are in $WORKSPACE. Restart your shell (or log out/in) for zsh and PATH changes to take effect."
