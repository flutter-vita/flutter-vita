#!/usr/bin/env bash
# Are the two vendored Dart trees carrying the same changes?
#
#   ./tools/check-dart-trees.sh
#
# `third_party/sdk` is Phase 1's standalone checkout, still used by
# spikes/m1-vpk. `third_party/flutter/engine/.../dart` is the one the engine
# builds. Both sit at the pin in VERSIONS.md and must carry the same patches:
# patch files are regenerated from one of them, so a file missing from the tree
# you happen to regenerate from is a file silently deleted from the patch.
#
# This replaces the check in patches/flutter-engine/README.md, which had a bug
# that let exactly that happen on 2026-08-14.
#
# **Diff against the pin, not HEAD.** The engine's tree carries a local commit
# above the pinned revision, so `git diff --name-only` from HEAD reports
# nothing for any file changed *inside* that commit -- neither dirty nor
# untracked, therefore never compared. `runtime/bin/virtual_memory_vita.cc`
# lived in that blind spot: present in the engine tree, absent from
# third_party/sdk, and invisible to the check meant to catch it. Regenerating
# patch 0010 from the wrong tree would have dropped the file from the patch
# with no error, and the next clean checkout would have failed to build for
# reasons pointing nowhere near here.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
A="$ROOT/third_party/sdk"
B="$ROOT/third_party/flutter/engine/src/flutter/third_party/dart"
PIN="$(grep -m1 -oE '\bd684a576[0-9a-f]*' "$ROOT/VERSIONS.md" | head -1 || echo d684a576)"

for t in "$A" "$B"; do
  [ -d "$t" ] || { echo "missing tree: $t" >&2; exit 1; }
done

# Every file either tree has touched since the pin, from both trees, so a file
# present in only one of them still gets compared.
changed() {
  ( cd "$1" && git diff --name-only "$PIN" 2>/dev/null
    cd "$1" && git ls-files --others --exclude-standard 2>/dev/null )
}

FILES="$( { changed "$A"; changed "$B"; } | sort -u )"
[ -n "$FILES" ] || { echo "neither tree differs from $PIN — suspicious, are the patches applied?" >&2; exit 1; }

# Only files the patch series owns can be damaged by regenerating from the
# wrong tree, so only those fail the check. Everything else is reported and
# forgiven: the trees are used differently and some drift is uninteresting --
# a stray copy of one of our own docs inside the vendored tree, for instance.
PATCHED="$(cat "$ROOT"/patches/dart-sdk/*.patch 2>/dev/null \
  | grep '^+++ b/' | sed 's|+++ b/||' | sort -u)"

diverged=0; incidental=0
while read -r f; do
  [ -n "$f" ] || continue
  state=""
  if   [ -f "$A/$f" ] && [ ! -f "$B/$f" ]; then state="only in sdk"
  elif [ -f "$B/$f" ] && [ ! -f "$A/$f" ]; then state="only in engine"
  elif [ -f "$A/$f" ] && [ -f "$B/$f" ] && ! cmp -s "$A/$f" "$B/$f"; then state="differs"
  fi
  [ -n "$state" ] || continue
  if printf '%s\n' "$PATCHED" | grep -qx "$f"; then
    printf '  %-15s %s   <- in the patch series\n' "$state" "$f"; diverged=1
  else
    printf '  %-15s %s\n' "$state" "$f"; incidental=$((incidental + 1))
  fi
done <<< "$FILES"

n="$(printf '%s\n' "$FILES" | grep -c . || true)"
if [ "$diverged" -eq 0 ]; then
  echo "trees agree on every patched file ($n changed vs $PIN, $incidental incidental)"
else
  echo
  echo "Files marked 'in the patch series' are the dangerous ones: regenerating a" >&2
  echo "patch from whichever tree is missing them drops them silently, and the next" >&2
  echo "clean checkout fails to build for reasons pointing nowhere near here." >&2
  echo "Regenerate from the complete tree -- normally the engine's, since that is" >&2
  echo "the one that builds -- and copy the missing files across." >&2
  exit 1
fi
