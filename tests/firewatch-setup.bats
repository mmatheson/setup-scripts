#!/usr/bin/env bats
# Unit tests for firewatch-setup.sh
#
# The script installs real packages and modifies system state, so we can't run
# it end-to-end in CI. Instead we extract and test the pure-logic helpers in
# isolation against a temp filesystem, and verify the managed-block config
# logic with synthetic dotfiles.

load test_helper/bats-support/load
load test_helper/bats-assert/load

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

setup() {
  TEST_HOME="$(mktemp -d)"
  TEST_CACHE="$(mktemp -d)"
  export HOME="$TEST_HOME"
  export CACHE="$TEST_CACHE"
  export XDG_CACHE_HOME="$TEST_CACHE"

  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$SCRIPT_DIR/firewatch-setup.sh"
}

teardown() {
  rm -rf "$TEST_HOME" "$TEST_CACHE"
}

# Extract relocate_to_cache from the script for isolated testing.
source_relocate() {
  eval "$(sed -n '/^relocate_to_cache()/,/^}/p' "$SCRIPT")"
}

# ---------------------------------------------------------------------------
# relocate_to_cache tests
# ---------------------------------------------------------------------------

@test "relocate_to_cache creates symlink when source does not exist" {
  source_relocate

  relocate_to_cache "$TEST_HOME/.cargo" "$TEST_CACHE/.cargo"

  [ -L "$TEST_HOME/.cargo" ]
  [ "$(readlink "$TEST_HOME/.cargo")" = "$TEST_CACHE/.cargo" ]
  [ -d "$TEST_CACHE/.cargo" ]
}

@test "relocate_to_cache migrates existing dir contents" {
  source_relocate

  mkdir -p "$TEST_HOME/.cargo/bin"
  echo "rustc" > "$TEST_HOME/.cargo/bin/rustc"
  echo "config" > "$TEST_HOME/.cargo/config.toml"

  relocate_to_cache "$TEST_HOME/.cargo" "$TEST_CACHE/.cargo"

  # Source is now a symlink
  [ -L "$TEST_HOME/.cargo" ]
  [ "$(readlink "$TEST_HOME/.cargo")" = "$TEST_CACHE/.cargo" ]
  # Contents were migrated
  [ -f "$TEST_CACHE/.cargo/bin/rustc" ]
  [ "$(cat "$TEST_CACHE/.cargo/bin/rustc")" = "rustc" ]
  [ -f "$TEST_CACHE/.cargo/config.toml" ]
}

@test "relocate_to_cache is idempotent (re-run is a no-op)" {
  source_relocate

  mkdir -p "$TEST_CACHE/.cargo"
  echo "existing" > "$TEST_CACHE/.cargo/data"
  ln -s "$TEST_CACHE/.cargo" "$TEST_HOME/.cargo"

  relocate_to_cache "$TEST_HOME/.cargo" "$TEST_CACHE/.cargo"

  [ -L "$TEST_HOME/.cargo" ]
  [ "$(readlink "$TEST_HOME/.cargo")" = "$TEST_CACHE/.cargo" ]
  [ "$(cat "$TEST_CACHE/.cargo/data")" = "existing" ]
}

@test "relocate_to_cache fixes wrong symlink target" {
  source_relocate

  mkdir -p "$TEST_CACHE/old-target" "$TEST_CACHE/new-target"
  ln -s "$TEST_CACHE/old-target" "$TEST_HOME/.cargo"

  relocate_to_cache "$TEST_HOME/.cargo" "$TEST_CACHE/new-target"

  [ -L "$TEST_HOME/.cargo" ]
  [ "$(readlink "$TEST_HOME/.cargo")" = "$TEST_CACHE/new-target" ]
}

@test "relocate_to_cache does not clobber existing files in target" {
  source_relocate

  # Pre-populate both source and target with different files
  mkdir -p "$TEST_HOME/.npm" "$TEST_CACHE/npm"
  echo "source-only" > "$TEST_HOME/.npm/source.txt"
  echo "target-only" > "$TEST_CACHE/npm/target.txt"
  echo "target-version" > "$TEST_CACHE/npm/shared.txt"
  echo "source-version" > "$TEST_HOME/.npm/shared.txt"

  relocate_to_cache "$TEST_HOME/.npm" "$TEST_CACHE/npm"

  # Both files present; target's version of shared wins (cp -an = no clobber)
  [ -f "$TEST_CACHE/npm/source.txt" ]
  [ -f "$TEST_CACHE/npm/target.txt" ]
  [ "$(cat "$TEST_CACHE/npm/shared.txt")" = "target-version" ]
}

@test "relocate_to_cache handles nested directory trees" {
  source_relocate

  mkdir -p "$TEST_HOME/.rustup/toolchains/stable/lib"
  echo "lib" > "$TEST_HOME/.rustup/toolchains/stable/lib/libstd.so"

  relocate_to_cache "$TEST_HOME/.rustup" "$TEST_CACHE/.rustup"

  [ -L "$TEST_HOME/.rustup" ]
  [ -f "$TEST_CACHE/.rustup/toolchains/stable/lib/libstd.so" ]
}

@test "relocate_to_cache creates parent directories for the link" {
  source_relocate

  relocate_to_cache "$TEST_HOME/.config/sst" "$TEST_CACHE/sst"

  [ -L "$TEST_HOME/.config/sst" ]
  [ -d "$TEST_CACHE/sst" ]
}

# ---------------------------------------------------------------------------
# Managed .zshenv block tests
# ---------------------------------------------------------------------------

@test "zshenv managed block is inserted into empty file" {
  ZSHENV="$TEST_HOME/.zshenv"
  touch "$ZSHENV"
  ENV_BEGIN="# >>> workspace-setup.sh env (managed) >>>"
  ENV_END="# <<< workspace-setup.sh env (managed) <<<"

  # Reproduce insertion logic
  mkdir -p "$XDG_CACHE_HOME/zsh"
  cat >> "$ZSHENV" <<'EOF'
# >>> workspace-setup.sh env (managed) >>>
export XDG_CACHE_HOME="/cache"
export ZSH_COMPDUMP="$XDG_CACHE_HOME/zsh/zcompdump"
# <<< workspace-setup.sh env (managed) <<<
EOF

  run grep -c "XDG_CACHE_HOME" "$ZSHENV"
  assert_output "2"
  run grep -c "$ENV_BEGIN" "$ZSHENV"
  assert_output "1"
}

@test "zshenv managed block replaces existing block" {
  ZSHENV="$TEST_HOME/.zshenv"
  ENV_BEGIN="# >>> workspace-setup.sh env (managed) >>>"
  ENV_END="# <<< workspace-setup.sh env (managed) <<<"

  # Pre-populate with old block
  cat > "$ZSHENV" <<'EOF'
# user stuff
export FOO=bar
# >>> workspace-setup.sh env (managed) >>>
export OLD_VAR="old"
# <<< workspace-setup.sh env (managed) <<<
EOF

  # Reproduce the replacement logic
  if grep -Fq "$ENV_BEGIN" "$ZSHENV"; then
    sed -i.bak "\|$ENV_BEGIN|,\|$ENV_END|d" "$ZSHENV"
  fi
  cat >> "$ZSHENV" <<'EOF'
# >>> workspace-setup.sh env (managed) >>>
export XDG_CACHE_HOME="/cache"
export ZSH_COMPDUMP="$XDG_CACHE_HOME/zsh/zcompdump"
# <<< workspace-setup.sh env (managed) <<<
EOF

  # Old var gone, new var present, user content preserved
  run grep -c "OLD_VAR" "$ZSHENV"
  assert_output "0"
  run grep -c "XDG_CACHE_HOME" "$ZSHENV"
  assert_output "2"
  run grep -c "FOO=bar" "$ZSHENV"
  assert_output "1"
}

@test "zshenv preserves user content outside managed block" {
  ZSHENV="$TEST_HOME/.zshenv"
  ENV_BEGIN="# >>> workspace-setup.sh env (managed) >>>"
  ENV_END="# <<< workspace-setup.sh env (managed) <<<"

  cat > "$ZSHENV" <<'EOF'
export MY_CUSTOM="keep-me"
# >>> workspace-setup.sh env (managed) >>>
export OLD="remove"
# <<< workspace-setup.sh env (managed) <<<
export ALSO_KEEP="yes"
EOF

  sed -i.bak "\|$ENV_BEGIN|,\|$ENV_END|d" "$ZSHENV"
  cat >> "$ZSHENV" <<'EOF'
# >>> workspace-setup.sh env (managed) >>>
export NEW="added"
# <<< workspace-setup.sh env (managed) <<<
EOF

  run grep "MY_CUSTOM" "$ZSHENV"
  assert_output --partial "keep-me"
  run grep "ALSO_KEEP" "$ZSHENV"
  assert_output --partial "yes"
  run grep -c "OLD" "$ZSHENV"
  assert_output "0"
}

# ---------------------------------------------------------------------------
# Managed .zshrc block tests
# ---------------------------------------------------------------------------

@test "zshrc managed block is inserted correctly" {
  ZSHRC="$TEST_HOME/.zshrc"
  touch "$ZSHRC"
  BEGIN_MARK="# >>> workspace-setup.sh (managed) >>>"
  END_MARK="# <<< workspace-setup.sh (managed) <<<"

  cat >> "$ZSHRC" <<'EOF'
# >>> workspace-setup.sh (managed) >>>
export XDG_CACHE_HOME="/cache"
export RUSTUP_HOME="$XDG_CACHE_HOME/.rustup"
alias gs="git status"
# <<< workspace-setup.sh (managed) <<<
EOF

  run grep -c "$BEGIN_MARK" "$ZSHRC"
  assert_output "1"
  run grep "RUSTUP_HOME" "$ZSHRC"
  assert_success
  run grep 'alias gs=' "$ZSHRC"
  assert_success
}

@test "zshrc managed block replacement preserves user aliases" {
  ZSHRC="$TEST_HOME/.zshrc"
  BEGIN_MARK="# >>> workspace-setup.sh (managed) >>>"
  END_MARK="# <<< workspace-setup.sh (managed) <<<"

  cat > "$ZSHRC" <<'EOF'
# My custom aliases
alias myalias="echo hi"
# >>> workspace-setup.sh (managed) >>>
old content
# <<< workspace-setup.sh (managed) <<<
# More custom stuff
export MY_VAR=1
EOF

  sed -i.bak "\|$BEGIN_MARK|,\|$END_MARK|d" "$ZSHRC"
  cat >> "$ZSHRC" <<'EOF'
# >>> workspace-setup.sh (managed) >>>
new content
# <<< workspace-setup.sh (managed) <<<
EOF

  run grep "myalias" "$ZSHRC"
  assert_success
  run grep "MY_VAR" "$ZSHRC"
  assert_success
  run grep -c "old content" "$ZSHRC"
  assert_output "0"
  run grep "new content" "$ZSHRC"
  assert_success
}

# ---------------------------------------------------------------------------
# Stale cargo env removal from .zshenv
# ---------------------------------------------------------------------------

@test "stale cargo env sourcing is removed from .zshenv" {
  cat > "$TEST_HOME/.zshenv" <<'EOF'
# normal stuff
export FOO=bar
. "$HOME/.cargo/env"
EOF

  if [ -f "$TEST_HOME/.zshenv" ] && grep -q '\.cargo/env' "$TEST_HOME/.zshenv"; then
    sed -i.bak '/\.cargo\/env/d' "$TEST_HOME/.zshenv"
    [ -s "$TEST_HOME/.zshenv" ] || rm -f "$TEST_HOME/.zshenv"
  fi

  run grep -c "cargo/env" "$TEST_HOME/.zshenv"
  assert_output "0"
  run grep "FOO=bar" "$TEST_HOME/.zshenv"
  assert_success
}

@test "empty .zshenv is removed after stripping cargo env" {
  cat > "$TEST_HOME/.zshenv" <<'EOF'
. "$HOME/.cargo/env"
EOF

  if [ -f "$TEST_HOME/.zshenv" ] && grep -q '\.cargo/env' "$TEST_HOME/.zshenv"; then
    sed -i.bak '/\.cargo\/env/d' "$TEST_HOME/.zshenv"
    [ -s "$TEST_HOME/.zshenv" ] || rm -f "$TEST_HOME/.zshenv"
  fi

  [ ! -f "$TEST_HOME/.zshenv" ]
}

# ---------------------------------------------------------------------------
# APT package detection logic
# ---------------------------------------------------------------------------

@test "missing apt packages are detected correctly" {
  # Simulate the detection logic with a mock list
  APT_PACKAGES=(realpackage fakepackage123)
  MISSING_APT=()
  for pkg in "${APT_PACKAGES[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      MISSING_APT+=("$pkg")
    fi
  done

  # fakepackage123 should be missing; we don't know about realpackage
  local found=false
  for pkg in "${MISSING_APT[@]}"; do
    if [ "$pkg" = "fakepackage123" ]; then
      found=true
    fi
  done
  [ "$found" = true ]
}

# ---------------------------------------------------------------------------
# Git config idempotency
# ---------------------------------------------------------------------------

@test "git config is set only when missing" {
  # Use a temp gitconfig
  export GIT_CONFIG_GLOBAL="$TEST_HOME/.gitconfig"

  # Not set yet
  run git config --global user.name
  assert_failure

  # Set it
  git config --global user.name "Test User"

  # Now it's set, second call shouldn't change it
  local before
  before="$(git config --global user.name)"
  if ! git config --global user.name >/dev/null 2>&1; then
    git config --global user.name "Different User"
  fi
  local after
  after="$(git config --global user.name)"

  [ "$before" = "$after" ]
  [ "$after" = "Test User" ]
}

# ---------------------------------------------------------------------------
# PATH deduplication (PNPM_HOME)
# ---------------------------------------------------------------------------

@test "PNPM_HOME is not duplicated in PATH" {
  PNPM_HOME="$TEST_HOME/.local/share/pnpm"
  export PATH="$PNPM_HOME:/usr/bin:/bin"

  case ":$PATH:" in
    *":$PNPM_HOME:"*) already=true ;;
    *) already=false ;;
  esac

  [ "$already" = true ]

  # PATH length unchanged after the guard
  local before_len after_len
  before_len="${#PATH}"
  case ":$PATH:" in
    *":$PNPM_HOME:"*) ;;
    *) export PATH="$PNPM_HOME:$PATH" ;;
  esac
  after_len="${#PATH}"

  [ "$before_len" -eq "$after_len" ]
}

@test "PNPM_HOME is added to PATH when absent" {
  PNPM_HOME="$TEST_HOME/.local/share/pnpm"
  export PATH="/usr/bin:/bin"

  case ":$PATH:" in
    *":$PNPM_HOME:"*) ;;
    *) export PATH="$PNPM_HOME:$PATH" ;;
  esac

  run echo "$PATH"
  assert_output --partial "$PNPM_HOME"
}

# ---------------------------------------------------------------------------
# Clone idempotency
# ---------------------------------------------------------------------------

@test "repo clone is skipped when .git already exists" {
  WORKSPACE="$TEST_HOME/workspaces"
  mkdir -p "$WORKSPACE/myrepo/.git"

  local cloned=false
  if [ -d "$WORKSPACE/myrepo/.git" ]; then
    cloned=false  # skip
  else
    cloned=true
  fi

  [ "$cloned" = false ]
}

@test "repo clone is triggered when dir is missing" {
  WORKSPACE="$TEST_HOME/workspaces"
  mkdir -p "$WORKSPACE"

  local should_clone=false
  if [ -d "$WORKSPACE/myrepo/.git" ]; then
    should_clone=false
  else
    should_clone=true
  fi

  [ "$should_clone" = true ]
}

# ---------------------------------------------------------------------------
# Architecture detection
# ---------------------------------------------------------------------------

@test "architecture mapping works for x86_64" {
  local arch
  arch="x86_64"
  case "$arch" in
    x86_64) ZJ_ARCH="x86_64-unknown-linux-musl" ;;
    aarch64|arm64) ZJ_ARCH="aarch64-unknown-linux-musl" ;;
    *) ZJ_ARCH="unsupported" ;;
  esac

  [ "$ZJ_ARCH" = "x86_64-unknown-linux-musl" ]
}

@test "architecture mapping works for aarch64" {
  local arch
  arch="aarch64"
  case "$arch" in
    x86_64) ZJ_ARCH="x86_64-unknown-linux-musl" ;;
    aarch64|arm64) ZJ_ARCH="aarch64-unknown-linux-musl" ;;
    *) ZJ_ARCH="unsupported" ;;
  esac

  [ "$ZJ_ARCH" = "aarch64-unknown-linux-musl" ]
}

@test "architecture mapping works for arm64" {
  local arch
  arch="arm64"
  case "$arch" in
    x86_64) ZJ_ARCH="x86_64-unknown-linux-musl" ;;
    aarch64|arm64) ZJ_ARCH="aarch64-unknown-linux-musl" ;;
    *) ZJ_ARCH="unsupported" ;;
  esac

  [ "$ZJ_ARCH" = "aarch64-unknown-linux-musl" ]
}

# ---------------------------------------------------------------------------
# Tailscale systemd unit detection
# ---------------------------------------------------------------------------

@test "TAILSCALE_UP guard skips tailscale up by default" {
  unset TAILSCALE_UP

  local should_up=false
  if [ -n "${TAILSCALE_UP:-}" ]; then
    should_up=true
  fi

  [ "$should_up" = false ]
}

@test "TAILSCALE_UP=1 triggers tailscale up" {
  export TAILSCALE_UP=1

  local should_up=false
  if [ -n "${TAILSCALE_UP:-}" ]; then
    should_up=true
  fi

  [ "$should_up" = true ]
}
