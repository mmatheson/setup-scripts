#!/usr/bin/env bash
# Shared utilities for setup-scripts.
# Source this file; do not execute it directly.
#   . "$(dirname "$0")/lib/common.sh"

# Guard against double-sourcing.
[ -n "${_COMMON_SH_LOADED:-}" ] && return 0
_COMMON_SH_LOADED=1

# ---------------------------------------------------------------------------
# rm_path <path>
# Remove a file or directory. Honors DRY_RUN; reports size reclaimed.
# ---------------------------------------------------------------------------
rm_path() {
  local p="$1"
  [ -e "$p" ] || [ -L "$p" ] || return 0
  local sz
  sz="$(du -sh "$p" 2>/dev/null | cut -f1)"
  if [ -n "${DRY_RUN:-}" ]; then
    echo "  would remove $p ($sz)"
  else
    echo "  removing $p ($sz)"
    rm -rf "$p"
  fi
}

# ---------------------------------------------------------------------------
# prune_old_files <dir> <name-glob>
# Remove files older than KEEP_DAYS, reported as one summary line.
# ---------------------------------------------------------------------------
prune_old_files() {
  local dir="$1" glob="$2"
  [ -d "$dir" ] || return 0
  local files count sz
  files="$(find "$dir" -name "$glob" -type f -mtime "+${KEEP_DAYS:-14}" 2>/dev/null)"
  [ -n "$files" ] || return 0
  count="$(printf '%s\n' "$files" | wc -l)"
  sz="$(printf '%s\n' "$files" | xargs -d '\n' du -ch 2>/dev/null | tail -n1 | cut -f1)"
  if [ -n "${DRY_RUN:-}" ]; then
    echo "  would remove $count files from $dir ($sz)"
  else
    echo "  removing $count files from $dir ($sz)"
    printf '%s\n' "$files" | xargs -d '\n' rm -f
    find "$dir" -mindepth 1 -type d -empty -delete 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# prune_old_versions <versions-dir>
# Keep only the newest version directory (by version sort); remove the rest.
# ---------------------------------------------------------------------------
prune_old_versions() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  ls -1 "$dir" 2>/dev/null | sort -V | head -n -1 | while read -r v; do
    rm_path "$dir/$v"
  done
}

# ---------------------------------------------------------------------------
# prune_stale_dir_if_real <dir> [skip-message]
# Remove <dir> if it is a real directory (not a symlink) with no files newer
# than KEEP_DAYS. Optional skip-message overrides the default hint.
# ---------------------------------------------------------------------------
prune_stale_dir_if_real() {
  local dir="$1"
  local skip_msg="${2:-has files newer than ${KEEP_DAYS:-14}d}"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  if [ -z "$(find "$dir" -type f -mtime "-${KEEP_DAYS:-14}" -print -quit 2>/dev/null)" ]; then
    rm_path "$dir"
  else
    echo "  skipping $dir -- $skip_msg"
  fi
}

# ---------------------------------------------------------------------------
# resolve_arch
# Print the musl target triple for the current machine. Exits 1 on unknown.
# ---------------------------------------------------------------------------
resolve_arch() {
  case "$(uname -m)" in
    x86_64) echo "x86_64-unknown-linux-musl" ;;
    aarch64 | arm64) echo "aarch64-unknown-linux-musl" ;;
    *)
      echo "Unsupported arch $(uname -m)" >&2
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# ensure_cmd <cmd> <label> <install-body...>
# Skip if <cmd> is already on PATH; otherwise run the remaining args as the
# install command. Prints idempotency status either way.
# ---------------------------------------------------------------------------
ensure_cmd() {
  local cmd="$1" label="$2"
  shift 2
  if command -v "$cmd" >/dev/null 2>&1; then
    local ver
    ver="$("$cmd" --version 2>/dev/null | head -n1 || true)"
    echo "✓ $label already installed${ver:+ ($ver)}"
    return 0
  fi
  echo "→ installing $label"
  "$@"
}

# ---------------------------------------------------------------------------
# install_github_release <cmd> <label> <url-template> <extract-cmd...>
# Idempotent installer for a prebuilt binary from a GitHub release tarball.
# <url-template> must contain the literal string ARCH which is replaced by
# the resolved musl target triple (see resolve_arch).
# <extract-cmd...> is eval'd after the tarball is downloaded to $TMP/dl.tar.gz.
# ---------------------------------------------------------------------------
install_github_release() {
  local cmd="$1" label="$2" url_tpl="$3"
  shift 3
  if command -v "$cmd" >/dev/null 2>&1; then
    local ver
    ver="$("$cmd" --version 2>/dev/null | head -n1 || true)"
    echo "✓ $label already installed${ver:+ ($ver)}"
    return 0
  fi
  echo "→ installing $label"
  local arch
  arch="$(resolve_arch)" || return 1
  local url="${url_tpl//ARCH/$arch}"
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL "$url" -o "$tmp/dl.tar.gz"
  (cd "$tmp" && "$@")
  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# relocate_to_cache <link> <target>
# Migrate a real dir at <link> into <target> on /cache and leave a symlink.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# upsert_managed_block <file> <begin-marker> <end-marker> <content>
# Insert or replace a marker-delimited block at the end of <file>.
# ---------------------------------------------------------------------------
upsert_managed_block() {
  local file="$1" begin="$2" end="$3" content="$4"
  touch "$file"
  if grep -Fq "$begin" "$file"; then
    echo "→ refreshing managed block in $file"
    sed -i.bak "\|$begin|,\|$end|d" "$file"
  else
    echo "→ adding managed block to $file"
  fi
  printf '%s\n%s\n%s\n' "$begin" "$content" "$end" >> "$file"
}
