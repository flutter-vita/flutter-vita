#!/usr/bin/env bash
# Publish a release of the tool: a tag on this repository and the Bridge.
#
#   ./tools/publish-release.sh <tag>               check, build the Bridge, tag, publish
#   ./tools/publish-release.sh <tag> --dry-run     check, print the plan and the notes
#   ./tools/publish-release.sh <tag> --prerelease  mark the GitHub releases as pre-releases
#
# <tag> is <flutter>-vita.<X.Y.Z>, for example 3.47.7-vita.1.0.0. X.Y.Z starts
# at 1.0.0 on each Flutter version, as flutter-tizen's does: Z for a fix, Y for
# a feature. 1.0.0 does not mean stable; --prerelease says not ready.
#
# A tool release publishes no engine. versions.json must already name an engine
# release (tools/publish-engine.sh), and this downloads it the way a toolchain
# user's first precache does before it tags anything. docs/release.md has the
# whole flow and the checks to run on the console first.
#
# What it publishes:
#   flutter-vita/flutter-vita           tag <tag>, a release with the Bridge .vpk
#   flutter-vita/flutter-vita-embedder  tag <tag> and a release, when the
#                                       submodule moved since its last tag
# The packages go to pub.dev on their own, never from here.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TOOL_REPO="flutter-vita/flutter-vita"
EMB_REPO="flutter-vita/flutter-vita-embedder"
TAG=""
DRY=0
PRE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --prerelease) PRE="--prerelease"; shift ;;
    -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) [ -z "$TAG" ] || { echo "one tag only" >&2; exit 2; }; TAG="$1"; shift ;;
  esac
done
[ -n "$TAG" ] || { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

die() { echo "!! $*" >&2; exit 1; }
field() {  # a Python expression over v, the parsed versions.json
  python3 -c "import json,sys; v=json.load(open(sys.argv[1])); print($1)" "$ROOT/versions.json"
}
FLUTTER="$(field "v['flutter']")"
re="^${FLUTTER//./\\.}-vita\\.[0-9]+\\.[0-9]+\\.[0-9]+\$"
[[ "$TAG" =~ $re ]] || die "the tag is $FLUTTER-vita.X.Y.Z, for example $FLUTTER-vita.1.0.0"
command -v gh >/dev/null || die "needs the GitHub CLI (gh), signed in"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fv-publish-release.XXXXXX")"

echo "==> checks"
[ "$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)" = master ] || die "the tool is not on master"
[ -z "$(git -C "$ROOT" status --porcelain)" ] || die "the tool has uncommitted changes"
git -C "$ROOT" fetch -q origin master
[ "$(git -C "$ROOT" rev-parse HEAD)" = "$(git -C "$ROOT" rev-parse origin/master)" ] \
  || die "master and origin/master differ; push or pull first"
git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG exists here already"
[ -z "$(git -C "$ROOT" ls-remote --tags origin "refs/tags/$TAG")" ] || die "tag $TAG exists on origin already"

# Each submodule at the commit the tool records, and that commit fetchable: a
# tag whose submodules nobody can check out is a release nobody can build.
bad="$(git -C "$ROOT" submodule status | grep -E '^[-+U]' || true)"
[ -z "$bad" ] || die "submodules are not at the commits the tool records: $bad"
for sub in embedder packages; do
  [ -z "$(git -C "$ROOT/$sub" status --porcelain)" ] || die "$sub has uncommitted changes"
  git -C "$ROOT/$sub" fetch -q origin
  git -C "$ROOT/$sub" merge-base --is-ancestor HEAD origin/master \
    || die "$sub is at a commit that is not on its origin/master; push it"
done
echo "    master, embedder and packages are clean and pushed"

"$HERE/publish-engine.sh" --check
ENGINE="$(field "v['engine']['release']")"

# The Bridge links its own pinned engine (ADR-0016), which may be older than
# the one the tool pins. Say so in the plan; it is not a reason to stop.
PINNED="$(awk '$1 == "engine" { print substr($2, 1, 8) }' "$ROOT/bridge/engine-pin.txt")"

PREV="$(git -C "$ROOT" describe --tags --abbrev=0 HEAD 2>/dev/null || true)"
RANGE="${PREV:+$PREV..}HEAD"

# The embedder gets the same tag when it moved since its last one.
EMB_PREV="$(git -C "$ROOT/embedder" describe --tags --abbrev=0 HEAD 2>/dev/null || true)"
EMB_HEAD="$(git -C "$ROOT/embedder" rev-parse HEAD)"
TAG_EMBEDDER=1
if [ -n "$EMB_PREV" ] && [ "$(git -C "$ROOT/embedder" rev-list -n1 "$EMB_PREV")" = "$EMB_HEAD" ]; then
  TAG_EMBEDDER=0
fi
EMB_TAG="$TAG"
[ "$TAG_EMBEDDER" = 1 ] || EMB_TAG="$EMB_PREV"
EMB_PUSHED=0
if [ "$TAG_EMBEDDER" = 1 ] && [ -n "$(git -C "$ROOT/embedder" ls-remote --tags origin "refs/tags/$TAG")" ]; then
  # Left by a run that stopped after the embedder push: fine if it is this commit.
  [ "$(git -C "$ROOT/embedder" ls-remote origin "refs/tags/$TAG^{}" | cut -f1)" = "$EMB_HEAD" ] \
    || die "the embedder has a tag $TAG on another commit"
  EMB_PUSHED=1
fi

# Commit subjects since the last tag, grouped by their `area:` prefix, the
# largest group first.
changes() {  # <git dir> <range>
  git -C "$1" log --no-merges --format=%s "$2" | python3 -c '
import sys
groups = {}
for line in sys.stdin:
    area, sep, rest = line.rstrip("\n").partition(": ")
    if not sep:
        area, rest = "other", area
    groups.setdefault(area, []).append(rest)
for area in sorted(groups, key=lambda a: (-len(groups[a]), a)):
    print(f"**{area}**\n")
    for rest in groups[area]:
        print(f"- {rest}")
    print()
'
}

# Files, not $(cat <<EOF): bash 3.2, the one macOS ships, misreads an
# apostrophe in a here-document inside a command substitution.
BLOB="https://github.com/$TOOL_REPO/blob/$TAG"
NOTES="$WORK/notes.md"
cat > "$NOTES" <<EOF
flutter-vita $TAG builds Flutter $FLUTTER apps for the PS Vita.

| Part | Version |
|---|---|
| Flutter | $FLUTTER, framework \`$(field "v['framework_rev']" | cut -c1-10)\` |
| Engine | [$ENGINE](https://github.com/flutter-vita/flutter/releases/tag/$ENGINE) |
| Embedder | [$EMB_TAG](https://github.com/$EMB_REPO/releases/tag/$EMB_TAG) |

Install the toolchain with [install-macos.md]($BLOB/docs/install-macos.md) or [install-linux.md]($BLOB/docs/install-linux.md). \`flutter-vita precache\` downloads the engine.

\`flutter-vita-bridge-$TAG.vpk\` is the Bridge, the app on the console that installs and starts your apps. Install it once with VitaShell: [configure-console.md]($BLOB/docs/configure-console.md).

## Changes${PREV:+ since $PREV}

$(changes "$ROOT" "$RANGE")
EOF
EMB_NOTES="$WORK/embedder-notes.md"
cat > "$EMB_NOTES" <<EOF
The embedder that flutter-vita $TAG compiles into each app, with engine [$ENGINE](https://github.com/flutter-vita/flutter/releases/tag/$ENGINE).

## Changes${EMB_PREV:+ since $EMB_PREV}

$(changes "$ROOT/embedder" "${EMB_PREV:+$EMB_PREV..}HEAD")
EOF

VPK="$ROOT/out/flutter-vita-bridge-$TAG.vpk"
cat <<EOF
==> plan
    commit    "release: $TAG": versions.json release $TAG, embedder $EMB_TAG
    tag       $TAG on master, after ${PREV:-no earlier tag}
    build     the Bridge, footer $TAG, engine $PINNED (bridge/engine-pin.txt)
    embedder  $([ "$TAG_EMBEDDER" = 1 ] && echo "tag $TAG at ${EMB_HEAD:0:12}, after ${EMB_PREV:-no earlier tag}" || echo "no tag; $EMB_PREV is current")
    push      master and $TAG to origin, in one atomic push
    release   $TOOL_REPO $TAG with $(basename "$VPK")${PRE:+, marked pre-release}
EOF
[ "$PINNED" = "$ENGINE" ] \
  || echo "    note: the Bridge links engine $PINNED and the tool pins $ENGINE (ADR-0016)"
if [ "$DRY" = 1 ]; then
  printf '\n--- release notes ---\n'; cat "$NOTES"
  if [ "$TAG_EMBEDDER" = 1 ]; then printf -- '--- embedder notes ---\n'; cat "$EMB_NOTES"; fi
  printf -- '---\n\ndry run: nothing published\n'
  rm -rf "$WORK"
  exit 0
fi

# Until the push, all of this is local. If a step fails, undo it: the tag, the
# release commit and the versions.json edit.
START="$(git -C "$ROOT" rev-parse HEAD)"
undo() {
  git -C "$ROOT" tag -d "$TAG" >/dev/null 2>&1 || true
  git -C "$ROOT" reset -q --soft "$START"
  git -C "$ROOT" restore --staged --worktree -- versions.json
  rm -rf "$WORK"
}
trap undo EXIT

echo "==> release commit and tag"
python3 - "$ROOT/versions.json" "$TAG" "$EMB_TAG" <<'EOF'
import json, sys
path, tag, emb = sys.argv[1:]
v = json.load(open(path))
v["release"] = tag
v["embedder"]["release"] = emb
open(path, "w").write(json.dumps(v, indent=2, ensure_ascii=False) + "\n")
EOF
git -C "$ROOT" commit -q -m "release: $TAG" -- versions.json
git -C "$ROOT" tag -a "$TAG" \
  -m "flutter-vita $TAG: the tool for Flutter $FLUTTER, engine $ENGINE, embedder $EMB_TAG"

# After the tag, so git describe, and with it the Bridge's footer, says $TAG.
echo "==> building the Bridge: footer $TAG, engine $PINNED"
"$HERE/build-bridge.sh"
grep -q "kToolBuild = '$TAG';" "$ROOT/bridge/app/lib/build_info.dart" \
  || die "the Bridge's build_info.dart does not name $TAG"
cp "$ROOT/bridge/app/build/vita/flutter_vita_bridge.vpk" "$VPK"

if [ "$TAG_EMBEDDER" = 1 ] && [ "$EMB_PUSHED" = 0 ]; then
  echo "==> embedder tag $TAG"
  git -C "$ROOT/embedder" tag -a "$TAG" -m "Embedder $TAG"
  git -C "$ROOT/embedder" push -q origin "refs/tags/$TAG" \
    || { git -C "$ROOT/embedder" tag -d "$TAG" >/dev/null; die "the embedder tag did not push"; }
fi

echo "==> pushing master and $TAG"
git -C "$ROOT" push -q --atomic origin master "refs/tags/$TAG"
trap 'rm -rf "$WORK"' EXIT  # pushed: nothing to undo now

# A failure from here leaves a pushed tag with no release. Each message names
# the one command that finishes the job.
if [ "$TAG_EMBEDDER" = 1 ]; then
  echo "==> $EMB_REPO release $TAG"
  gh release create "$TAG" --repo "$EMB_REPO" --verify-tag $PRE \
    --title "Embedder $TAG" --notes-file "$EMB_NOTES" \
    || die "tag pushed, release not made. Run: gh release create $TAG --repo $EMB_REPO --verify-tag $PRE --title 'Embedder $TAG' --generate-notes"
fi
echo "==> $TOOL_REPO release $TAG"
gh release create "$TAG" --repo "$TOOL_REPO" --verify-tag $PRE \
  --title "flutter-vita $TAG" --notes-file "$NOTES" "$VPK" \
  || die "tag pushed, release not made. Run: gh release create $TAG --repo $TOOL_REPO --verify-tag $PRE --title 'flutter-vita $TAG' --generate-notes $VPK"

echo
echo "  https://github.com/$TOOL_REPO/releases/tag/$TAG"
[ "$TAG_EMBEDDER" = 0 ] || echo "  https://github.com/$EMB_REPO/releases/tag/$TAG"
echo "  https://github.com/flutter-vita/flutter/releases/tag/$ENGINE"
