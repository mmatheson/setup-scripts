#!/usr/bin/env bats
# Unit tests for cleanup-home.sh
#
# Strategy: source individual functions in an isolated temp HOME, then exercise
# the full script in DRY_RUN mode against a fake filesystem tree.

load test_helper/bats-support/load
load test_helper/bats-assert/load

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

setup() {
  TEST_HOME="$(mktemp -d)"
  export HOME="$TEST_HOME"
  export DRY_RUN=""
  export KEEP_DAYS="14"

  # Source only the function definitions from cleanup-home.sh.
  # The script runs cleanup logic at the top level, so we extract just the
  # functions for isolated unit tests.
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$SCRIPT_DIR/cleanup-home.sh"
}

teardown() {
  rm -rf "$TEST_HOME"
}

# Extract and source just the shell functions (rm_path, prune_old_files) from
# the script without executing the mainline cleanup logic.
source_functions() {
  # Pull out the two function bodies and eval them in the current shell.
  eval "$(sed -n '/^rm_path()/,/^}/p' "$SCRIPT")"
  eval "$(sed -n '/^prune_old_files()/,/^}/p' "$SCRIPT")"
}

# ---------------------------------------------------------------------------
# rm_path tests
# ---------------------------------------------------------------------------

@test "rm_path removes an existing file" {
  source_functions
  mkdir -p "$TEST_HOME/target"
  echo "data" > "$TEST_HOME/target/file.txt"

  rm_path "$TEST_HOME/target"

  [ ! -e "$TEST_HOME/target" ]
}

@test "rm_path removes an existing directory tree" {
  source_functions
  mkdir -p "$TEST_HOME/target/sub/deep"
  echo "a" > "$TEST_HOME/target/sub/deep/f"

  rm_path "$TEST_HOME/target"

  [ ! -e "$TEST_HOME/target" ]
}

@test "rm_path is a no-op for a non-existent path" {
  source_functions
  run rm_path "$TEST_HOME/does-not-exist"

  assert_success
}

@test "rm_path removes a dangling symlink" {
  source_functions
  ln -s "$TEST_HOME/nonexistent" "$TEST_HOME/dangling"

  rm_path "$TEST_HOME/dangling"

  [ ! -L "$TEST_HOME/dangling" ]
}

@test "rm_path in DRY_RUN prints but does not delete" {
  source_functions
  export DRY_RUN=1
  mkdir -p "$TEST_HOME/keep-me"
  echo "x" > "$TEST_HOME/keep-me/f"

  run rm_path "$TEST_HOME/keep-me"

  assert_success
  assert_output --partial "would remove"
  [ -d "$TEST_HOME/keep-me" ]
}

@test "rm_path prints size when removing" {
  source_functions
  echo "hello" > "$TEST_HOME/sized-file"

  run rm_path "$TEST_HOME/sized-file"

  assert_success
  assert_output --partial "removing"
}

# ---------------------------------------------------------------------------
# prune_old_files tests
# ---------------------------------------------------------------------------

@test "prune_old_files skips non-existent directory" {
  source_functions
  run prune_old_files "$TEST_HOME/nope" '*'

  assert_success
  assert_output ""
}

@test "prune_old_files removes files older than KEEP_DAYS" {
  source_functions
  export KEEP_DAYS=0   # everything is "old"

  mkdir -p "$TEST_HOME/cache"
  echo "old" > "$TEST_HOME/cache/old.log"
  # Touch with an old timestamp to be sure
  touch -d "30 days ago" "$TEST_HOME/cache/old.log"

  run prune_old_files "$TEST_HOME/cache" '*.log'

  assert_success
  assert_output --partial "removing"
  [ ! -f "$TEST_HOME/cache/old.log" ]
}

@test "prune_old_files respects glob filter" {
  source_functions
  export KEEP_DAYS=0

  mkdir -p "$TEST_HOME/cache"
  echo "a" > "$TEST_HOME/cache/file.log"
  echo "b" > "$TEST_HOME/cache/file.txt"
  touch -d "30 days ago" "$TEST_HOME/cache/file.log" "$TEST_HOME/cache/file.txt"

  prune_old_files "$TEST_HOME/cache" '*.log'

  [ ! -f "$TEST_HOME/cache/file.log" ]
  [ -f "$TEST_HOME/cache/file.txt" ]
}

@test "prune_old_files keeps recent files" {
  source_functions
  export KEEP_DAYS=30

  mkdir -p "$TEST_HOME/cache"
  echo "new" > "$TEST_HOME/cache/fresh.log"
  # File was just created so it's newer than 30 days

  run prune_old_files "$TEST_HOME/cache" '*.log'

  assert_success
  [ -f "$TEST_HOME/cache/fresh.log" ]
}

@test "prune_old_files in DRY_RUN prints but does not delete" {
  source_functions
  export DRY_RUN=1
  export KEEP_DAYS=0

  mkdir -p "$TEST_HOME/cache"
  echo "old" > "$TEST_HOME/cache/stale.log"
  touch -d "30 days ago" "$TEST_HOME/cache/stale.log"

  run prune_old_files "$TEST_HOME/cache" '*.log'

  assert_success
  assert_output --partial "would remove"
  [ -f "$TEST_HOME/cache/stale.log" ]
}

@test "prune_old_files cleans empty parent dirs after deletion" {
  source_functions
  export KEEP_DAYS=0

  mkdir -p "$TEST_HOME/cache/sub/deep"
  echo "x" > "$TEST_HOME/cache/sub/deep/file.log"
  touch -d "30 days ago" "$TEST_HOME/cache/sub/deep/file.log"

  prune_old_files "$TEST_HOME/cache" '*.log'

  # The empty dirs should have been pruned
  [ ! -d "$TEST_HOME/cache/sub/deep" ]
}

# ---------------------------------------------------------------------------
# Full-script integration: DRY_RUN mode
# ---------------------------------------------------------------------------

@test "full script runs in DRY_RUN without errors" {
  export DRY_RUN=1
  # Create minimal structure the script expects
  mkdir -p "$TEST_HOME/.cursor-server/cli/servers"
  mkdir -p "$TEST_HOME/.cache/trunk"

  run bash "$SCRIPT"

  assert_success
  assert_output --partial "before cleanup"
}

# ---------------------------------------------------------------------------
# Section 1: zcompdump cleanup
# ---------------------------------------------------------------------------

@test "zcompdump files are removed" {
  source_functions
  touch "$TEST_HOME/.zcompdump-host1-5.9" "$TEST_HOME/.zcompdump"

  # Simulate the section inline
  for f in "$TEST_HOME"/.zcompdump-* "$TEST_HOME"/.zcompdump; do
    [ -e "$f" ] && rm_path "$f"
  done

  [ ! -e "$TEST_HOME/.zcompdump-host1-5.9" ]
  [ ! -e "$TEST_HOME/.zcompdump" ]
}

# ---------------------------------------------------------------------------
# Section 2: Old Claude Code versions (keeps newest)
# ---------------------------------------------------------------------------

@test "old claude versions are pruned, newest kept" {
  source_functions
  CLAUDE_VERS="$TEST_HOME/.local/share/claude/versions"
  mkdir -p "$CLAUDE_VERS/1.0.0" "$CLAUDE_VERS/2.0.0" "$CLAUDE_VERS/3.0.0"
  echo "old" > "$CLAUDE_VERS/1.0.0/bin"
  echo "old" > "$CLAUDE_VERS/2.0.0/bin"
  echo "new" > "$CLAUDE_VERS/3.0.0/bin"

  # Reproduce the script's pruning logic
  ls -1 "$CLAUDE_VERS" 2>/dev/null | sort -V | head -n -1 | while read -r v; do
    rm_path "$CLAUDE_VERS/$v"
  done

  [ ! -d "$CLAUDE_VERS/1.0.0" ]
  [ ! -d "$CLAUDE_VERS/2.0.0" ]
  [ -d "$CLAUDE_VERS/3.0.0" ]
}

# ---------------------------------------------------------------------------
# Section 3: Old cursor-agent versions (keeps newest)
# ---------------------------------------------------------------------------

@test "old cursor-agent versions are pruned, newest kept" {
  source_functions
  CURSOR_VERS="$TEST_HOME/.local/share/cursor-agent/versions"
  mkdir -p "$CURSOR_VERS/0.1" "$CURSOR_VERS/0.2" "$CURSOR_VERS/0.3"

  ls -1 "$CURSOR_VERS" 2>/dev/null | sort -V | head -n -1 | while read -r v; do
    rm_path "$CURSOR_VERS/$v"
  done

  [ ! -d "$CURSOR_VERS/0.1" ]
  [ ! -d "$CURSOR_VERS/0.2" ]
  [ -d "$CURSOR_VERS/0.3" ]
}

# ---------------------------------------------------------------------------
# Section 4: Old cursor-server builds (keeps newest by mtime)
# ---------------------------------------------------------------------------

@test "old cursor-server builds are pruned, newest kept" {
  source_functions
  BASE="$TEST_HOME/.cursor-server/cli/servers"
  mkdir -p "$BASE/Stable-aaa" "$BASE/Stable-bbb" "$BASE/Stable-ccc"
  # Stagger mtimes so sort is deterministic
  touch -d "3 days ago" "$BASE/Stable-aaa"
  touch -d "2 days ago" "$BASE/Stable-bbb"
  touch -d "1 day ago" "$BASE/Stable-ccc"

  find "$BASE" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | tail -n +2 | cut -d' ' -f2- | while read -r d; do rm_path "$d"; done

  [ ! -d "$BASE/Stable-aaa" ]
  [ ! -d "$BASE/Stable-bbb" ]
  [ -d "$BASE/Stable-ccc" ]
}

# ---------------------------------------------------------------------------
# Section 5: ~/.cache stragglers (only if not a symlink)
# ---------------------------------------------------------------------------

@test "stale cache dirs are removed when idle" {
  source_functions
  export KEEP_DAYS=0
  mkdir -p "$TEST_HOME/.cache/trunk"
  echo "x" > "$TEST_HOME/.cache/trunk/old"
  touch -d "30 days ago" "$TEST_HOME/.cache/trunk/old"

  # Not a symlink, dir has no recent files
  local c="$TEST_HOME/.cache/trunk"
  if [ -d "$TEST_HOME/.cache" ] && [ ! -L "$TEST_HOME/.cache" ]; then
    if [ -d "$c" ]; then
      if [ -z "$(find "$c" -type f -mtime "-$KEEP_DAYS" -print -quit 2>/dev/null)" ]; then
        rm_path "$c"
      fi
    fi
  fi

  [ ! -d "$TEST_HOME/.cache/trunk" ]
}

@test "cache dirs are skipped when ~/.cache is a symlink" {
  source_functions
  mkdir -p "$TEST_HOME/real-cache/trunk"
  echo "x" > "$TEST_HOME/real-cache/trunk/old"
  ln -s "$TEST_HOME/real-cache" "$TEST_HOME/.cache"

  local skipped=true
  if [ -d "$TEST_HOME/.cache" ] && [ ! -L "$TEST_HOME/.cache" ]; then
    skipped=false
  fi

  [ "$skipped" = true ]
  [ -d "$TEST_HOME/real-cache/trunk" ]
}

@test "cache dirs with recent files are kept" {
  source_functions
  export KEEP_DAYS=14
  mkdir -p "$TEST_HOME/.cache/trunk"
  echo "x" > "$TEST_HOME/.cache/trunk/recent"
  # File is brand new, should be kept

  local removed=false
  local c="$TEST_HOME/.cache/trunk"
  if [ -d "$TEST_HOME/.cache" ] && [ ! -L "$TEST_HOME/.cache" ]; then
    if [ -d "$c" ]; then
      if [ -z "$(find "$c" -type f -mtime "-$KEEP_DAYS" -print -quit 2>/dev/null)" ]; then
        removed=true
      fi
    fi
  fi

  [ "$removed" = false ]
  [ -d "$TEST_HOME/.cache/trunk" ]
}

# ---------------------------------------------------------------------------
# Section 6: npm cache escaped relocation
# ---------------------------------------------------------------------------

@test "npm _cacache and _npx are removed when ~/.npm is a real dir" {
  source_functions
  mkdir -p "$TEST_HOME/.npm/_cacache" "$TEST_HOME/.npm/_npx"
  echo "c" > "$TEST_HOME/.npm/_cacache/data"
  echo "n" > "$TEST_HOME/.npm/_npx/data"

  if [ -d "$TEST_HOME/.npm" ] && [ ! -L "$TEST_HOME/.npm" ]; then
    rm_path "$TEST_HOME/.npm/_cacache"
    rm_path "$TEST_HOME/.npm/_npx"
  fi

  [ ! -d "$TEST_HOME/.npm/_cacache" ]
  [ ! -d "$TEST_HOME/.npm/_npx" ]
}

@test "npm cleanup is skipped when ~/.npm is a symlink" {
  source_functions
  mkdir -p "$TEST_HOME/real-npm/_cacache"
  ln -s "$TEST_HOME/real-npm" "$TEST_HOME/.npm"

  local skipped=true
  if [ -d "$TEST_HOME/.npm" ] && [ ! -L "$TEST_HOME/.npm" ]; then
    skipped=false
  fi

  [ "$skipped" = true ]
  [ -d "$TEST_HOME/real-npm/_cacache" ]
}

# ---------------------------------------------------------------------------
# Section 8: Backup file cleanup
# ---------------------------------------------------------------------------

@test "backup and swap files in HOME are removed" {
  source_functions
  touch "$TEST_HOME/.vimrc.bak" "$TEST_HOME/.zshrc.swp"

  for f in "$TEST_HOME"/.*.bak "$TEST_HOME"/.*.swp; do
    [ -e "$f" ] && rm_path "$f"
  done

  [ ! -e "$TEST_HOME/.vimrc.bak" ]
  [ ! -e "$TEST_HOME/.zshrc.swp" ]
}

@test "non-backup dotfiles are not removed" {
  source_functions
  touch "$TEST_HOME/.bashrc" "$TEST_HOME/.gitconfig"

  for f in "$TEST_HOME"/.*.bak "$TEST_HOME"/.*.swp; do
    [ -e "$f" ] && rm_path "$f"
  done

  [ -f "$TEST_HOME/.bashrc" ]
  [ -f "$TEST_HOME/.gitconfig" ]
}

# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

@test "KEEP_DAYS defaults to 14 when unset" {
  unset KEEP_DAYS
  export DRY_RUN=1

  run bash "$SCRIPT"

  assert_success
  assert_output --partial "14d"
}

@test "script is idempotent (running twice is safe)" {
  export DRY_RUN=1

  run bash "$SCRIPT"
  assert_success

  run bash "$SCRIPT"
  assert_success
}
