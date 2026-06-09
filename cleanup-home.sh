#!/usr/bin/env bash
# Reclaim space on the 5G $HOME NFS mount. Safe to run any time; idempotent.
# Handles the stuff that can't simply be relocated to /cache — app auto-updaters
# that hoard old versions, per-session shell droppings, and stale caches.
#
#   ./cleanup-home.sh            # do it
#   DRY_RUN=1 ./cleanup-home.sh  # show what would be removed, touch nothing
#
# Root causes for the relocatable caches (npm, pulumi, go, cargo, zcompdump)
# are fixed in firewatch-setup.sh — re-run that once and they stop landing in
# $HOME at all.
set -euo pipefail

DRY_RUN="${DRY_RUN:-}"
KEEP_DAYS="${KEEP_DAYS:-14}"   # age threshold for version/cache pruning

rm_path() {
  # rm_path <path> — honors DRY_RUN, reports size reclaimed.
  local p="$1"
  [ -e "$p" ] || [ -L "$p" ] || return 0
  local sz
  sz="$(du -sh "$p" 2>/dev/null | cut -f1)"
  if [ -n "$DRY_RUN" ]; then
    echo "  would remove $p ($sz)"
  else
    echo "  removing $p ($sz)"
    rm -rf "$p"
  fi
}

before="$(du -sm "$HOME" 2>/dev/null | cut -f1)"
echo "=== $HOME is ${before}M before cleanup ==="

# --- 1. Per-session zcompdump droppings -------------------------------------
# oh-my-zsh names the dump after the (randomized) sandbox hostname, so a new
# pair appears every shell. The fix lives in ~/.zshenv (ZSH_COMPDUMP on /cache);
# this just sweeps the ones already accumulated.
echo "→ stale zcompdump files"
for f in "$HOME"/.zcompdump-* "$HOME"/.zcompdump; do
  [ -e "$f" ] && rm_path "$f"
done

# --- 2. Old Claude Code versions --------------------------------------------
# The native auto-updater keeps every version it ever downloaded (~240M each).
echo "→ old Claude Code versions (keeping newest)"
CLAUDE_VERS="$HOME/.local/share/claude/versions"
if [ -d "$CLAUDE_VERS" ]; then
  ls -1 "$CLAUDE_VERS" 2>/dev/null | sort -V | head -n -1 | while read -r v; do
    rm_path "$CLAUDE_VERS/$v"
  done
fi

# --- 3. Old cursor-agent versions -------------------------------------------
echo "→ old cursor-agent versions (keeping newest)"
CURSOR_VERS="$HOME/.local/share/cursor-agent/versions"
if [ -d "$CURSOR_VERS" ]; then
  ls -1 "$CURSOR_VERS" 2>/dev/null | sort -V | head -n -1 | while read -r v; do
    rm_path "$CURSOR_VERS/$v"
  done
fi

# --- 4. Stale Cursor/VS Code remote server binaries -------------------------
# Each server commit gets its own dir under bin/; old ones linger after updates.
echo "→ cursor-server binaries older than ${KEEP_DAYS}d"
if [ -d "$HOME/.cursor-server/bin" ]; then
  find "$HOME/.cursor-server/bin" -mindepth 1 -maxdepth 1 -type d -mtime "+$KEEP_DAYS" \
    -print0 2>/dev/null | while IFS= read -r -d '' d; do rm_path "$d"; done
fi

# --- 5. Stale ~/.cache/trunk -------------------------------------------------
# Trunk now caches under /cache (XDG_CACHE_HOME); ~/.cache/trunk is pre-/cache
# leftover. Only sweep it if nothing has touched it in KEEP_DAYS.
echo "→ stale ~/.cache/trunk"
if [ -d "$HOME/.cache/trunk" ]; then
  if [ -z "$(find "$HOME/.cache/trunk" -type f -mtime "-$KEEP_DAYS" -print -quit 2>/dev/null)" ]; then
    rm_path "$HOME/.cache/trunk"
  else
    echo "  skipping — has files newer than ${KEEP_DAYS}d (trunk may still use it)"
  fi
fi

# --- 6. npm cache that escaped relocation -----------------------------------
# After firewatch-setup.sh, ~/.npm is a symlink to /cache. If it's still a real
# directory (setup not yet re-run), prune the download cache to reclaim now.
echo "→ npm cache on \$HOME"
if [ -d "$HOME/.npm" ] && [ ! -L "$HOME/.npm" ]; then
  rm_path "$HOME/.npm/_cacache"
  rm_path "$HOME/.npm/_npx"
fi

# --- 7. Claude transient state ----------------------------------------------
echo "→ old Claude shell-snapshots / paste-cache (> ${KEEP_DAYS}d)"
for dir in "$HOME/.claude/shell-snapshots" "$HOME/.claude/paste-cache"; do
  [ -d "$dir" ] || continue
  find "$dir" -type f -mtime "+$KEEP_DAYS" -print0 2>/dev/null \
    | while IFS= read -r -d '' f; do rm_path "$f"; done
done

# --- 8. Editor / shell backup crumbs ----------------------------------------
echo "→ *.bak / *.swp backup files in \$HOME"
for f in "$HOME"/.*.bak "$HOME"/.*.swp; do
  [ -e "$f" ] && rm_path "$f"
done

after="$(du -sm "$HOME" 2>/dev/null | cut -f1)"
echo "=== $HOME is ${after}M after cleanup (was ${before}M) ==="
