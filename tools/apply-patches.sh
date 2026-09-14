#!/usr/bin/env bash
# Apply and verify the vendored patch series. The patch series is the port.
#
#   ./tools/apply-patches.sh --verify     check the series against the trees
#   ./tools/apply-patches.sh --apply      apply every series to a pristine checkout
#   ./tools/apply-patches.sh --dry-run    say what --apply would do, touching nothing
#   ./tools/apply-patches.sh --list       print the patch -> repo manifest
#
# Three things make this worth automating:
#
#   * `git apply patches/dart-sdk/000*.patch` silently skips 0010, which is 29
#     files including every socket implementation.
#   * Several patches apply to a nested DEPS repo rather than the tree they sit
#     beside. patches/dart-sdk/0005 applies to zlib, and BUILD.gn exists in
#     both, so a careless path intersection matches the wrong file.
#   * The same series applies to two different Dart checkouts, and 0004 goes in
#     only half-way on one of them.
#
# --verify mutates nothing and needs no network.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

pass=0; fail=0; skipped=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=$((fail+1)); }
skip() { printf '  \033[33mskip\033[0m  %s\n' "$*"; skipped=$((skipped+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- the manifest
#
# Where each vendored repo lives. The standalone Dart checkout (third_party/sdk,
# Phase 1, still used by experiments/m1-vpk) and the engine's DEPS-managed copy are
# separate repos carrying the same series -- that duplication is why checks 5
# and 6 below exist. They replace tools/check-dart-trees.sh, which asked the
# same question but could not tell a deliberate difference from drift.

tree_path() {
  case "$1" in
    sdk)      echo "third_party/sdk" ;;
    sdk_zlib) echo "third_party/sdk/third_party/zlib" ;;
    flutter)  echo "third_party/flutter" ;;
    e_dart)   echo "third_party/flutter/engine/src/flutter/third_party/dart" ;;
    e_zlib)   echo "third_party/flutter/engine/src/flutter/third_party/zlib" ;;
    e_skia)   echo "third_party/flutter/engine/src/flutter/third_party/skia" ;;
    e_abseil) echo "third_party/flutter/engine/src/third_party/abseil-cpp" ;;
    e_ssl)    echo "third_party/flutter/engine/src/flutter/third_party/boringssl/src" ;;
    *) return 1 ;;
  esac
}

# Which trees each patch belongs in. "e_dart:runtime-only" means apply just the
# runtime/ hunks: 0004's build/ half is dead weight in the engine checkout,
# because the engine resolves //build/... to engine/src/build and carries its
# own vita toolchain from flutter-engine/0001.
targets_for() {
  case "$1" in
    patches/dart-sdk/0005-*)      echo "sdk_zlib e_zlib" ;;
    patches/dart-sdk/0004-*)      echo "sdk e_dart:runtime-only" ;;
    patches/dart-sdk/*)           echo "sdk e_dart" ;;
    patches/flutter-engine/*)     echo "flutter" ;;
    patches/skia/*)               echo "e_skia" ;;
    patches/abseil/*)             echo "e_abseil" ;;
    patches/boringssl/*)          echo "e_ssl" ;;
    patches/test-apps/*)             echo "EXTERNAL" ;;
    *) return 1 ;;
  esac
}

all_patches() { ls patches/*/*.patch 2>/dev/null | sort; }

# Paths a patch writes to, as they appear inside its own target repo.
owned() { grep '^+++ b/' "$1" | sed 's|+++ b/||' | sort -u; }

# The runtime/ half of a patch, per the recipe in flutter-engine/README.md.
runtime_half() {
  awk '/^diff --git a\/runtime\//{p=1} /^diff --git a\/build\//{p=0} p' "$1"
}

# --------------------------------------------------------------------- --list
if [ "${1:---verify}" = "--list" ]; then
  printf '%-58s %s\n' "PATCH" "APPLIES TO"
  while read -r p; do
    t="$(targets_for "$p" || echo '??')"
    printf '%-58s %s\n' "$p" "$t"
  done < <(all_patches)
  exit 0
fi

# ------------------------------------------------------------ --apply/--dry-run
#
# The whole reason to have this: applying the series is six `cd`s and a glob
# that lies. Order is numeric within a series; the series are independent of
# each other because no two of them share a repo.
if [ "${1:---verify}" = "--apply" ] || [ "${1:-}" = "--dry-run" ]; then
  dry=0; [ "$1" = "--dry-run" ] && dry=1

  # Refuse a tree that is already carrying changes. Each patch is a diff
  # against the *pristine* tree, so applying onto a patched one does not
  # reliably fail -- on 2026-08-14 it found matching context elsewhere and
  # inserted a second copy of the vita gen_snapshot targets, with no error.
  {
    dirty=0
    seen=""
    while read -r p; do
      ts="$(targets_for "$p")" || continue
      [ "$ts" = "EXTERNAL" ] && continue
      for spec in $ts; do
        dir="$(tree_path "${spec%%:*}")"
        case " $seen " in *" $dir "*) continue ;; esac
        seen="$seen $dir"
        [ -e "$dir/.git" ] || continue
        if ! git -C "$dir" diff --quiet || ! git -C "$dir" diff --cached --quiet; then
          echo "  dirty: $dir" >&2; dirty=1
        fi
      done
    done < <(all_patches)
    if [ "$dirty" -ne 0 ] && [ "$dry" -eq 1 ]; then
      cat >&2 <<'EOF'

Those trees already carry changes, so every patch below will report a failure
that means "already applied" rather than "will not apply". --dry-run is only
informative against a pristine checkout. To get one:

    git -C <tree> reset && git -C <tree> checkout -- . && git -C <tree> clean -fd

EOF
    elif [ "$dirty" -ne 0 ]; then
      cat >&2 <<'EOF'

Refusing to apply onto a tree that already has changes. To start from pristine:

    git -C <tree> reset && git -C <tree> checkout -- . && git -C <tree> clean -fd

`git clean -fd` alone is not enough once files have been `git add -N`'d --
intent-to-add makes them tracked and clean skips them. Reset first.
EOF
      exit 1
    fi
  }

  rc=0
  while read -r p; do
    ts="$(targets_for "$p")" || continue
    if [ "$ts" = "EXTERNAL" ]; then continue; fi
    for spec in $ts; do
      key="${spec%%:*}"; mode="${spec#*:}"; [ "$mode" = "$key" ] && mode=full
      dir="$(tree_path "$key")"
      if [ ! -e "$dir/.git" ]; then skip "$(basename "$p") -> $key (not checked out)"; continue; fi
      args=(apply); [ "$dry" -eq 1 ] && args+=(--check)
      if [ "$mode" = runtime-only ]; then
        if runtime_half "$p" | git -C "$dir" "${args[@]}" - 2>&1 | sed 's/^/        /'; then
          ok "$(basename "$p") (runtime/ half) -> $key"
        else bad "$(basename "$p") (runtime/ half) -> $key"; rc=1; fi
      else
        if git -C "$dir" "${args[@]}" "$ROOT/$p" 2>&1 | sed 's/^/        /'; then
          ok "$(basename "$p") -> $key"
        else bad "$(basename "$p") -> $key"; rc=1; fi
      fi
    done
  done < <(all_patches)

  head_ "Summary"
  printf '  %d applied, %d failed, %d skipped\n' "$pass" "$fail" "$skipped"
  [ "$dry" -eq 1 ] && printf '  (dry run -- nothing was written)\n'
  echo
  exit "$rc"
fi

if [ "${1:---verify}" != "--verify" ]; then
  echo "usage: $0 [--verify|--apply|--dry-run|--list]" >&2; exit 2
fi

# ------------------------------------------------- 1. every patch is accounted
head_ "Manifest covers the series"
n_patches=0; unmapped=0
while read -r p; do
  n_patches=$((n_patches+1))
  if ! targets_for "$p" >/dev/null; then
    bad "$p is not in the manifest -- add a rule to targets_for()"; unmapped=1
  fi
done < <(all_patches)
[ "$unmapped" -eq 0 ] && ok "$n_patches patch files, all mapped to a repo"

# --------------------------------------------- 2. one file, one patch, per repo
#
# The invariant the whole scheme rests on. Each patch is a `git diff` against
# the pristine tree, so two patches touching one file overlap: the later
# contains the earlier's hunks. Applying both need not fail -- `git apply` can
# find matching context elsewhere and insert a second copy, silently.
#
# It is also what makes check 4 sound: if each file has exactly one owner, the
# tree's content for that file is pristine-plus-that-patch, so the patch must
# reverse-apply cleanly.
head_ "One file, one patch"
for series in patches/*/; do
  s="${series%/}"; [ "$s" = "patches/test-apps" ] && continue
  dup="$(for p in "$s"/*.patch; do owned "$p" | sed "s|^|$(basename "$p")\t|"; done \
         | sort -k2 | awk -F'\t' '{if ($2==prev) print prevp" and "$1" both own "$2; prev=$2; prevp=$1}')"
  if [ -n "$dup" ]; then
    while read -r line; do bad "$s: $line"; done <<< "$dup"
  else
    ok "$s: no file owned twice"
  fi
done

# ------------------------------------------------------ 3. every patch parses
head_ "Patch files are well-formed"
malformed=0
while read -r p; do
  git apply --numstat "$p" >/dev/null 2>&1 || { bad "$p does not parse"; malformed=1; }
done < <(all_patches)
[ "$malformed" -eq 0 ] && ok "all patches parse as git diffs"

# ---------------------------------------- 4. the trees agree with the patches
#
# Reverse-apply is the question worth asking. "Does this patch still apply?"
# only proves the patch is applicable; "does this patch reverse out of the
# tree?" proves the file on disk and the patch in git are the *same change*.
# That is the check that catches a patch regenerated from the wrong tree --
# the failure that silently dropped virtual_memory_vita.cc once.
head_ "Vendored trees carry exactly what the patches say"
while read -r p; do
  ts="$(targets_for "$p")" || continue
  [ "$ts" = "EXTERNAL" ] && continue
  for spec in $ts; do
    key="${spec%%:*}"; mode="${spec#*:}"; [ "$mode" = "$key" ] && mode=full
    dir="$(tree_path "$key")"
    if [ ! -e "$dir/.git" ]; then
      skip "$(basename "$p") -> $key (tree not checked out)"
      continue
    fi
    if [ "$mode" = runtime-only ]; then
      if runtime_half "$p" | git -C "$dir" apply --check --reverse - 2>/dev/null; then
        ok "$(basename "$p") (runtime/ half) is present in $key"
      else
        bad "$(basename "$p") (runtime/ half) does not reverse out of $key"
      fi
    else
      if git -C "$dir" apply --check --reverse "$ROOT/$p" 2>/dev/null; then
        ok "$(basename "$p") is present in $key"
      else
        bad "$(basename "$p") does not reverse out of $key"
      fi
    fi
  done
done < <(all_patches)

# ------------------------------------------------ 5. the two Dart trees match
#
# Every file the series owns
# must be byte-identical in both checkouts, because a patch regenerated from
# either one has to describe both. 0004's build/ half is the deliberate
# exception -- it is not applied to the engine tree at all.
head_ "The two Dart checkouts agree on every owned file"
A="$(tree_path sdk)"; B="$(tree_path e_dart)"
if [ ! -e "$A/.git" ] || [ ! -e "$B/.git" ]; then
  skip "one of the Dart trees is not checked out"
else
  drift=0
  while read -r p; do
    case "$p" in patches/dart-sdk/*) ;; *) continue ;; esac
    case "$p" in patches/dart-sdk/0005-*) continue ;; esac   # nested zlib repo
    while read -r f; do
      [ -n "$f" ] || continue
      # 0004's build/ half is intentionally absent from the engine tree.
      case "$p/$f" in patches/dart-sdk/0004-*/build/*) continue ;; esac
      if   [ ! -f "$A/$f" ]; then bad "missing from sdk: $f"; drift=1
      elif [ ! -f "$B/$f" ]; then bad "missing from engine dart: $f"; drift=1
      elif ! cmp -s "$A/$f" "$B/$f"; then bad "differs between trees: $f"; drift=1
      fi
    done < <(owned "$p")
  done < <(all_patches)
  [ "$drift" -eq 0 ] && ok "every file the Dart series owns is identical in both trees"
fi

# ------------------------------- 6. nothing in a tree that no patch accounts for
#
# The other half of check 4. Reverse-apply proves every patch is in the tree;
# this proves every change in the tree is in a patch. A file edited in a
# vendored tree but owned by nothing is a change a fresh checkout loses.
#
# Diff against the pin, not HEAD: the engine's Dart tree carries a local commit
# above the pin, so `git diff` with no revision reports nothing for files
# changed inside it.
head_ "Every change in a vendored tree belongs to a patch"
unowned_check() {
  local dir="$1" pin="$2" series="$3" label="$4"
  if [ ! -e "$dir/.git" ]; then skip "$label (not checked out)"; return; fi
  local owned changed extra
  owned="$(cat patches/$series/*.patch 2>/dev/null | grep '^+++ b/' | sed 's|+++ b/||' | sort -u)"
  changed="$( { git -C "$dir" diff --name-only "$pin" 2>/dev/null
                git -C "$dir" ls-files --others --exclude-standard 2>/dev/null; } | sort -u )"
  if [ -z "$changed" ]; then
    bad "$label differs from $pin in nothing at all -- are the patches applied?"
    return
  fi
  extra="$(comm -13 <(echo "$owned") <(echo "$changed"))"
  if [ -n "$extra" ]; then
    while read -r f; do [ -n "$f" ] && bad "$label: $f is changed but no patch owns it"; done <<< "$extra"
  else
    ok "$label: all $(echo "$changed" | grep -c .) changed files are owned"
  fi
}
unowned_check "$(tree_path sdk)"     d684a576 dart-sdk       "third_party/sdk"
unowned_check "$(tree_path e_dart)"  d684a576 dart-sdk       "engine's Dart tree"
unowned_check "$(tree_path flutter)" 058e0af2 flutter-engine "third_party/flutter"

# ------------------------------------------- 6. the globs in the docs are safe
#
# The bug this script was written for. `000*.patch` reads as "the whole series"
# and is not.
head_ "Globs quoted in the READMEs match the whole series"
partial=0
while read -r line; do
  file="${line%%:*}"; rest="${line#*:}"; lineno="${rest%%:*}"; text="${rest#*:}"
  # Take every whitespace-delimited token that names a patch path, and strip
  # the ../.. prefixes the READMEs use to reach the repo root from a tree.
  for tok in $text; do
    case "$tok" in *patches/*.patch) ;; *) continue ;; esac
    case "$tok" in *'$'*) continue ;; esac   # a loop variable, not a glob
    g="patches/${tok#*patches/}"
    series="${g%/*}"
    [ -d "$series" ] || continue
    total=$(ls "$series"/[0-9]*.patch 2>/dev/null | wc -l | tr -d " ")
    [ "$total" -gt 0 ] || continue
    matched=$(eval ls "$g" 2>/dev/null | wc -l | tr -d " ")
    # A line naming one patch by its full filename is not a glob.
    [ "$matched" -eq 1 ] && [ "${g#*\*}" = "$g" ] && [ "${g#*[}" = "$g" ] && continue
    if [ "$matched" -lt "$total" ]; then
      missing=$(comm -13 <(eval ls "$g" 2>/dev/null | sort) <(ls "$series"/[0-9]*.patch | sort) \
                | sed "s|.*/||" | cut -c1-4 | tr "\n" " ")
      bad "$file:$lineno  \`$g\` matches $matched of $total -- misses $missing"
      partial=1
    fi
  done
done < <(grep -rn "git apply" patches/*/README.md docs/*.md 2>/dev/null)
[ "$partial" -eq 0 ] && ok "every glob quoted in the docs covers its whole series"

# --------------------------------------------------------------------- report
head_ "Summary"
printf '  %d ok, %d failed, %d skipped\n\n' "$pass" "$fail" "$skipped"
[ "$fail" -eq 0 ] || exit 1
