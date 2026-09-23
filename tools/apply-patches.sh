#!/usr/bin/env bash
# Check that the vendored engine tree carries the port.
#
#   ./tools/apply-patches.sh --verify     the tree is the fork's branch, and the
#                                         dependency patches are in (default)
#   ./tools/apply-patches.sh --list       the commits, and the dependency patches
#   ./tools/apply-patches.sh --apply      put the branch into a fresh checkout
#
# ## Where the port lives
#
# The engine's own changes are **commits** on the fork's branch
# `vita-<flutter>` (flutter-vita/flutter). `third_party/flutter` is that
# branch, so `git log` and `git blame` answer for every line of the port.
# There is no patch series for the engine any more, and nothing to regenerate
# after an edit: commit it.
#
# Five dependencies change too: the Dart SDK, zlib, Skia, abseil and
# BoringSSL. `DEPS` names their revisions and gclient checks them out, so a
# commit on the fork cannot reach them. Their changes are patch files **inside
# the fork**, under `engine/src/flutter/tools/vita/patches/`, applied by the
# `vita_patches` hook after every `gclient sync`. This script asks that hook
# whether they are in; it does not own them.
#
# The plan is to fork those five as well, so each change becomes a commit in
# the repository it belongs to and the patch files go away. Until then the
# hook is the one place they live.
#
# `--verify` mutates nothing and needs no network.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TREE="third_party/flutter"
HOOK="engine/src/flutter/tools/vita/apply_patches.py"
BRANCH="vita-$(sed -n 's/^[[:space:]]*"flutter":[[:space:]]*"\([0-9.]*\)".*/\1/p' versions.json | head -1)"

pass=0; fail=0; skipped=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=$((fail+1)); }
skip() { printf '  \033[33mskip\033[0m  %s\n' "$*"; skipped=$((skipped+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# --------------------------------------------------------------------- --list
if [ "${1:---verify}" = "--list" ]; then
  echo "engine: commits on $BRANCH in $TREE"
  git -C "$TREE" log --oneline --no-decorate "3.44.8..$BRANCH" 2>/dev/null |
    sed 's/^/  /'
  echo
  echo "dependencies: patch files in the fork, applied by the DEPS hook"
  (cd "$TREE" && ls engine/src/flutter/tools/vita/patches/*/*.patch 2>/dev/null) |
    sed 's|engine/src/flutter/tools/vita/patches/|  |'
  exit 0
fi

# -------------------------------------------------------------------- --apply
#
# For a checkout that is still plain upstream. The branch carries the engine
# changes; `gclient sync` then runs the hook, which carries the rest.
if [ "${1:-}" = "--apply" ]; then
  [ -d "$TREE/.git" ] || { echo "No checkout at $TREE." >&2; exit 1; }
  if [ -n "$(git -C "$TREE" status --porcelain)" ]; then
    echo "$TREE has local changes. Commit them or put them somewhere safe first." >&2
    exit 1
  fi
  git -C "$TREE" remote get-url fork >/dev/null 2>&1 ||
    git -C "$TREE" remote add fork git@github.com:flutter-vita/flutter.git
  git -C "$TREE" fetch fork "$BRANCH" || exit 1
  git -C "$TREE" switch -c "$BRANCH" --track "fork/$BRANCH" 2>/dev/null ||
    git -C "$TREE" switch "$BRANCH" || exit 1
  echo "==> $TREE is on $BRANCH"
  echo "    now run: cd $TREE && gclient sync -D"
  echo "    the sync applies the dependency patches through the DEPS hook"
  exit 0
fi

if [ "${1:---verify}" != "--verify" ]; then
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi

# ----------------------------------------------------- 1. the engine's changes
head_ "The engine tree is the fork's branch"
if [ ! -d "$TREE/.git" ]; then
  skip "$TREE is not a checkout (run ./tools/apply-patches.sh --apply)"
else
  on="$(git -C "$TREE" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ "$on" = "$BRANCH" ]; then
    ok "$TREE is on $BRANCH"
  else
    bad "$TREE is on '$on', not $BRANCH"
  fi

  dirty="$(git -C "$TREE" status --porcelain | grep -v '^?? engine/src/out/' | head -5)"
  if [ -z "$dirty" ]; then
    ok "no uncommitted change in the engine tree"
  else
    bad "the engine tree has uncommitted changes; commit them, they are the port:"
    printf '        %s\n' $dirty
  fi

  n="$(git -C "$TREE" log --oneline "3.44.8..HEAD" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$n" -gt 0 ]; then
    ok "$n commits above the tag 3.44.8"
  else
    bad "no commits above the tag; this tree carries no port"
  fi

  if git -C "$TREE" rev-parse --verify --quiet "fork/$BRANCH" >/dev/null; then
    ahead="$(git -C "$TREE" rev-list --count "fork/$BRANCH..HEAD" 2>/dev/null)"
    if [ "$ahead" = "0" ]; then
      ok "the fork has every commit in this tree"
    else
      bad "$ahead commit(s) are not pushed: git -C $TREE push fork $BRANCH"
    fi
  else
    skip "no fork/$BRANCH here yet (git -C $TREE fetch fork)"
  fi
fi

# ------------------------------------------------ 2. the dependencies' changes
head_ "The dependency patches are in the DEPS trees"
if [ ! -f "$TREE/$HOOK" ]; then
  skip "no $HOOK in the tree"
else
  out="$(cd "$TREE" && python3 "$HOOK" --check 2>&1)"
  missing="$(printf '%s\n' "$out" | grep -v 'already applied' | grep -v '^$')"
  n="$(printf '%s\n' "$out" | grep -c 'already applied')"
  if [ -z "$missing" ]; then
    ok "$n dependency patches are applied (dart, zlib, skia, abseil, boringssl)"
  else
    bad "the hook reports work to do; run: cd $TREE && gclient sync -D"
    printf '        %s\n' "$missing" | head -8
  fi
fi

# ------------------------------------------------------------------- 3. docs
head_ "The documents point at the right place"
for f in engine/README.md docs/dev-environment.md; do
  if [ ! -f "$f" ]; then
    skip "$f is missing"
  elif grep -q 'engine/patches' "$f"; then
    bad "$f still names engine/patches, which no longer exists"
  else
    ok "$f"
  fi
done

head_ "Summary"
printf '  %d ok, %d failed, %d skipped\n\n' "$pass" "$fail" "$skipped"
[ "$fail" -eq 0 ]
