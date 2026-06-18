#!/usr/bin/env bash
# Reclaim space on the 5G $HOME NFS mount. Safe to run any time; idempotent.
# Handles the stuff that can't simply be relocated to /cache — app auto-updaters
# that hoard old versions, per-session shell droppings, and stale caches.
#
#   ./cleanup-home.sh            # do it
#   DRY_RUN=1 ./cleanup-home.sh  # show what would be removed, touch nothing
#
# Root causes for the relocatable dirs (npm, pulumi, go, cargo, zcompdump,
# ~/.cache, ~/.config/sst, ~/.cursor-server, claude/cursor-agent installs) are
# fixed in firewatch-setup.sh — re-run that once and they stop landing in
# $HOME at all.
set -euo pipefail
trap 'echo "ERROR: command failed at line $LINENO (exit code $?)" >&2' ERR

DRY_RUN="${DRY_RUN-}"
KEEP_DAYS="${KEEP_DAYS:-14}" # age threshold for version/cache pruning

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

prune_old_files() {
	# prune_old_files <dir> <name-glob> — remove files older than KEEP_DAYS,
	# reported as one summary line instead of one line per file.
	local dir="$1" glob="$2"
	[ -d "$dir" ] || return 0
	local files count sz
	files="$(find "$dir" -name "$glob" -type f -mtime "+$KEEP_DAYS" 2>/dev/null)"
	[ -n "$files" ] || return 0
	count="$(printf '%s\n' "$files" | wc -l)"
	sz="$(printf '%s\n' "$files" | xargs -d '\n' du -ch 2>/dev/null | tail -n1 | cut -f1)"
	if [ -n "$DRY_RUN" ]; then
		echo "  would remove $count files from $dir ($sz)"
	else
		echo "  removing $count files from $dir ($sz)"
		printf '%s\n' "$files" | xargs -d '\n' rm -f
		find "$dir" -mindepth 1 -type d -empty -delete 2>/dev/null || true
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
# Each server build gets its own ~370M dir (cli/servers/Stable-<commit> on
# Cursor, bin/<commit> on VS Code); old ones linger after client updates.
# Keep the newest build, drop the rest.
echo "→ old cursor-server builds (keeping newest)"
for base in "$HOME/.cursor-server/cli/servers" "$HOME/.cursor-server/bin"; do
	[ -d "$base" ] || continue
	find "$base" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null |
		sort -rn | tail -n +2 | cut -d' ' -f2- | while read -r d; do rm_path "$d"; done
done
# Per-commit log/data dirs at the top level (cursor-<commit>, ~20M each).
echo "→ cursor-server data dirs older than ${KEEP_DAYS}d"
if [ -d "$HOME/.cursor-server" ]; then
	find "$HOME/.cursor-server" -mindepth 1 -maxdepth 1 -type d -name 'cursor-*' \
		-mtime "+$KEEP_DAYS" -print0 2>/dev/null |
		while IFS= read -r -d '' d; do rm_path "$d"; done
fi

# --- 5. ~/.cache stragglers (only while ~/.cache still lives on $HOME) ------
# firewatch-setup.sh now symlinks ~/.cache → /cache; once that's done these
# cost nothing and are skipped. Until then, sweep caches that tools rebuild on
# demand if nothing has touched them in KEEP_DAYS.
if [ -d "$HOME/.cache" ] && [ ! -L "$HOME/.cache" ]; then
	echo "→ stale caches under ~/.cache (trunk, prisma)"
	for c in "$HOME/.cache/trunk" "$HOME/.cache/prisma"; do
		[ -d "$c" ] || continue
		if [ -z "$(find "$c" -type f -mtime "-$KEEP_DAYS" -print -quit 2>/dev/null)" ]; then
			rm_path "$c"
		else
			echo "  skipping $c — has files newer than ${KEEP_DAYS}d (may still be in use)"
		fi
	done
fi

# --- 5b. ~/.config/sst (only while it still lives on $HOME) ------------------
# SST's provider plugins + bundled binaries run 1.4G+; firewatch-setup.sh now
# symlinks the dir onto /cache. Until then, sweep it if idle — sst re-downloads
# what it needs on the next run.
if [ -d "$HOME/.config/sst" ] && [ ! -L "$HOME/.config/sst" ]; then
	echo "→ stale ~/.config/sst"
	if [ -z "$(find "$HOME/.config/sst" -type f -mtime "-$KEEP_DAYS" -print -quit 2>/dev/null)" ]; then
		rm_path "$HOME/.config/sst"
	else
		echo "  skipping — has files newer than ${KEEP_DAYS}d (re-run firewatch-setup.sh to relocate it)"
	fi
fi

# --- 6. npm cache that escaped relocation -----------------------------------
# After firewatch-setup.sh, ~/.npm is a symlink to /cache. If it's still a real
# directory (setup not yet re-run), prune the download cache to reclaim now.
# shellcheck disable=SC2016
echo '→ npm cache on $HOME'
if [ -d "$HOME/.npm" ] && [ ! -L "$HOME/.npm" ]; then
	rm_path "$HOME/.npm/_cacache"
	rm_path "$HOME/.npm/_npx"
fi

# --- 7. Claude transient state ----------------------------------------------
echo "→ old Claude shell-snapshots / paste-cache / file-history (> ${KEEP_DAYS}d)"
for dir in "$HOME/.claude/shell-snapshots" "$HOME/.claude/paste-cache" "$HOME/.claude/file-history"; do
	prune_old_files "$dir" '*'
done

# --- 7b. Old Claude session transcripts ---------------------------------------
# ~/.claude/projects accumulates one .jsonl per session forever (~100M observed).
# Old transcripts only matter for /resume; prune by age. The .jsonl filter
# leaves persistent memory files (*.md) untouched.
echo "→ Claude session transcripts older than ${KEEP_DAYS}d"
prune_old_files "$HOME/.claude/projects" '*.jsonl'

# --- 8. Editor / shell backup crumbs ----------------------------------------
# shellcheck disable=SC2016
echo '→ *.bak / *.swp backup files in $HOME'
for f in "$HOME"/.*.bak "$HOME"/.*.swp; do
	[ -e "$f" ] && rm_path "$f"
done

after="$(du -sm "$HOME" 2>/dev/null | cut -f1)"
echo "=== $HOME is ${after}M after cleanup (was ${before}M) ==="
