#!/usr/bin/env bash
# Check that the engine checkout carries the port.
#
#   ./tools/engine-tree.sh --verify   the tree is the fork's branch, and each
#                                     changed dependency is our fork (default)
#   ./tools/engine-tree.sh --list     the forks, the branches and the commits
#   ./tools/engine-tree.sh --apply    put the branch into a fresh checkout
#
# ## Where the port lives
#
# In the repository that owns each file, as commits. There are no patch files.
#
#   flutter-vita/flutter      the engine's commits on vita-<flutter>, above the
#                             tag <flutter>. third_party/flutter is this branch,
#                             so `git log` and `git blame` answer for the
#                             engine. An engine change is a commit.
#   flutter-vita/dart-sdk     the Vita OS layer for the Dart VM
#   flutter-vita/skia         1 commit: platform detection, and a file reader
#                             in place of mmap
#   flutter-vita/abseil-cpp   1 commit: no ELF introspection, no tm_gmtoff,
#                             memalign in place of mmap
#   flutter-vita/boringssl    1 commit: an entropy source on the kernel RNG
#   flutter-vita/zlib         1 commit: no ARMv8 code paths on this ARMv7
#
# The five dependencies cannot be commits in the Flutter fork, because Flutter
# does not contain them: DEPS names a revision of each and gclient checks them
# out. So DEPS names our fork and our commit. Each fork is the upstream tree at
# the revision DEPS named before, as one root commit, plus the port's commits.
#
# Until 2026-09-23 the port was 27 patch files. It is not any more, and this
# script is what apply-patches.sh became.
#
# `--verify` mutates nothing and needs no network.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TREE="third_party/flutter"
FLUTTER="$(sed -n 's/^[[:space:]]*"flutter":[[:space:]]*"\([0-9.]*\)".*/\1/p' versions.json | head -1)"
BRANCH="vita-$FLUTTER"

pass=0; fail=0; skipped=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=$((fail+1)); }
skip() { printf '  \033[33mskip\033[0m  %s\n' "$*"; skipped=$((skipped+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# The dependencies DEPS takes from our forks: "<path> <url> <commit>" a line.
ours() {
  python3 - "$TREE/DEPS" <<'PY'
import sys
ns = {"Var": lambda k: "<%s>" % k}
src = open(sys.argv[1]).read()
exec(compile(src, "DEPS", "exec"), ns)
git = ns["vars"]["vita_git"]
for path, spec in ns["deps"].items():
    if not isinstance(spec, str):
        continue
    spec = spec.replace("<vita_git>", git)
    if git not in spec:
        continue
    url, _, rev = spec.partition("@")
    print(path, url, rev)
PY
}

# --------------------------------------------------------------------- --list
if [ "${1:---verify}" = "--list" ]; then
  echo "engine: commits on $BRANCH in $TREE"
  git -C "$TREE" log --oneline --no-decorate "$FLUTTER..$BRANCH" 2>/dev/null | sed 's/^/  /'
  echo
  echo "dependencies: forks named in DEPS"
  ours | while read -r path url rev; do
    printf '  %-52s %s  %s\n' "${path#engine/src/}" "${rev:0:12}" "$url"
    d="$TREE/$path"
    [ -d "$d/.git" ] || continue
    if [ "$(git -C "$d" rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
      echo "      (shallow checkout; git -C $d fetch --unshallow to read the commits)"
    else
      git -C "$d" log --oneline --no-decorate \
        "$(git -C "$d" rev-list --max-parents=0 HEAD 2>/dev/null | head -1)..HEAD" 2>/dev/null |
        sed 's/^/      /'
    fi
  done
  exit 0
fi

# -------------------------------------------------------------------- --apply
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
  echo "    the sync takes each changed dependency from its fork; there is"
  echo "    nothing to apply afterwards"
  exit 0
fi

if [ "${1:---verify}" != "--verify" ]; then
  sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi

# ----------------------------------------------------- 1. the engine's changes
head_ "The engine tree is the fork's branch"
if [ ! -d "$TREE/.git" ]; then
  skip "$TREE is not a checkout (run ./tools/engine-tree.sh --apply)"
else
  on="$(git -C "$TREE" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [ "$on" = "$BRANCH" ] && ok "$TREE is on $BRANCH" ||
    bad "$TREE is on '$on', not $BRANCH"

  dirty="$(git -C "$TREE" status --porcelain | grep -v '^?? engine/src/out/' | head -5)"
  if [ -z "$dirty" ]; then
    ok "no uncommitted change in the engine tree"
  else
    bad "the engine tree has uncommitted changes; commit them, they are the port:"
    printf '        %s\n' $dirty
  fi

  n="$(git -C "$TREE" log --oneline "$FLUTTER..HEAD" 2>/dev/null | wc -l | tr -d ' ')"
  [ "$n" -gt 0 ] && ok "$n commits above the tag $FLUTTER" ||
    bad "no commits above the tag; this tree carries no port"

  if git -C "$TREE" rev-parse --verify --quiet "fork/$BRANCH" >/dev/null; then
    ahead="$(git -C "$TREE" rev-list --count "fork/$BRANCH..HEAD" 2>/dev/null)"
    [ "$ahead" = "0" ] && ok "the fork has every commit in this tree" ||
      bad "$ahead commit(s) are not pushed: git -C $TREE push fork $BRANCH"
  else
    skip "no fork/$BRANCH here yet (git -C $TREE fetch fork)"
  fi
fi

# ------------------------------------------------ 2. the dependencies' changes
head_ "Each changed dependency comes from our fork"
if [ ! -f "$TREE/DEPS" ]; then
  skip "no DEPS in the tree"
else
  count=0
  while read -r path url rev; do
    count=$((count + 1))
    d="$TREE/$path"
    name="${url##*/}"; name="${name%.git}"
    if [ ! -d "$d/.git" ]; then
      skip "$name is not checked out yet (gclient sync -D)"
      continue
    fi
    at="$(git -C "$d" rev-parse HEAD)"
    if [ "$at" != "$rev" ]; then
      bad "$name is at ${at:0:12}, DEPS says ${rev:0:12} (gclient sync -D)"
      continue
    fi
    if [ -n "$(git -C "$d" status --porcelain)" ]; then
      bad "$name has uncommitted changes; commit and push them to the fork"
    else
      ok "$name at ${rev:0:12}"
    fi
  done < <(ours)
  [ "$count" -gt 0 ] || bad "DEPS names no fork of ours; is vita_git still in it?"
fi

# --------------------------------------------------------- 3. nothing is left
head_ "No patch files are left"
if [ -d engine/patches ] || [ -d "$TREE/engine/src/flutter/tools/vita" ]; then
  bad "a patch directory is back; the port belongs in commits"
else
  ok "no patch directory, here or in the fork"
fi

head_ "Summary"
printf '  %d ok, %d failed, %d skipped\n\n' "$pass" "$fail" "$skipped"
[ "$fail" -eq 0 ]
