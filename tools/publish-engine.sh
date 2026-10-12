#!/usr/bin/env bash
# Publish the engine artifact as a release of the fork, named by its commit.
#
#   ./tools/publish-engine.sh            package, publish, pin in versions.json, push
#   ./tools/publish-engine.sh --dry-run  package and print the plan; publish nothing
#   ./tools/publish-engine.sh --check    download the engine versions.json names,
#                                        as a toolchain user's first precache does
#
# Each engine the tool pins is a release of flutter-vita/flutter. Its tag is the
# engine commit's first eight characters, and versions.json names that tag, its
# URL and its sha256. The release exists before master points at it, so a clone
# of master can always download its engine. flutter-tizen works the same way,
# with CI in place of this script. docs/release.md has the whole flow.
#
# The engine is the build in third_party/flutter/engine/src/out/vita_release,
# at the fork's HEAD. package-engine.sh refuses a build with steps pending.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FORK="$ROOT/third_party/flutter"
REPO="flutter-vita/flutter"
MODE=publish
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) MODE=dry; shift ;;
    --check)   MODE=check; shift ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

die() { echo "!! $*" >&2; exit 1; }
field() {  # a Python expression over v, the parsed versions.json
  python3 -c "import json,sys; v=json.load(open(sys.argv[1])); print($1)" "$ROOT/versions.json"
}
FLUTTER="$(field "v['flutter']")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fv-publish-engine.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Download what versions.json names into an empty root, through the CLI's own
# precache: the download, the sha256 and the unpacked tree are what a toolchain
# user gets, so they are what this checks.
check() {
  local tag url unpacks s="$WORK/root"
  tag="$(field "v['engine']['release']")"
  url="$(field "v['engine']['url']")"
  unpacks="$(field "v['engine']['unpacks_to']")"
  [ -n "$tag" ] && [ -n "$url" ] \
    || die "versions.json names no engine release; run tools/publish-engine.sh"
  mkdir -p "$s/tools"
  cp "$ROOT/versions.json" "$s/"
  touch "$s/tools/build-vita-app.sh"  # what the CLI takes for a checkout
  echo "==> precache of engine $tag into an empty root"
  FLUTTER_VITA_ROOT="$s" "$ROOT/cli/flutter-vita" precache \
    || die "precache failed for $url"
  [ -f "$s/out/artifacts/$unpacks/include/engine_version.h" ] \
    || die "the archive has no $unpacks/include/engine_version.h"
  grep -q "^release  *$tag\$" "$s/out/artifacts/$unpacks/MANIFEST.txt" \
    || die "the archive's MANIFEST.txt names another release than $tag"
  echo "    engine $tag downloads, matches its sha256 and unpacks"
}

if [ "$MODE" = check ]; then check; exit 0; fi

: "${VITASDK:?Define VITASDK. See docs/dev-environment.md}"
command -v gh >/dev/null || die "needs the GitHub CLI (gh), signed in"

# What is published is the fork's HEAD, and only once that commit is on the
# fork's branch: a release of a commit nobody can fetch is an engine nobody can
# rebuild.
HEAD="$(git -C "$FORK" rev-parse HEAD)"
TAG="${HEAD:0:8}"
BRANCH="vita-$FLUTTER"
echo "==> checks"
[ -z "$(git -C "$FORK" status --porcelain --untracked-files=no)" ] \
  || die "third_party/flutter has uncommitted changes; commit them on $BRANCH"
git -C "$FORK" fetch -q fork "$BRANCH"
git -C "$FORK" merge-base --is-ancestor "$HEAD" "fork/$BRANCH" \
  || die "$TAG is not on fork/$BRANCH; run: git -C third_party/flutter push --no-verify fork $BRANCH"
"$HERE/engine-tree.sh" --verify >/dev/null \
  || die "tools/engine-tree.sh --verify failed; run it to see which fork"

# The pin goes to master as one commit, pushed on its own.
[ "$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)" = master ] || die "the tool is not on master"
[ -z "$(git -C "$ROOT" status --porcelain -- versions.json)" ] \
  || die "versions.json has uncommitted changes"
git -C "$ROOT" fetch -q origin master
[ "$(git -C "$ROOT" rev-parse HEAD)" = "$(git -C "$ROOT" rev-parse origin/master)" ] \
  || die "master and origin/master differ; push or pull first, so the pin goes out alone"
echo "    engine $TAG is on fork/$BRANCH; the six forks verify; master is pushed"

EXISTS=0
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  if [ "$(field "v['engine']['release']")" = "$TAG" ]; then
    echo "==> engine $TAG is published and versions.json names it; nothing to publish"
    [ "$MODE" = publish ] && check
    exit 0
  fi
  EXISTS=1  # published by a run that stopped before the pin: pin that one
fi

if [ "$EXISTS" = 1 ]; then
  echo "==> $REPO $TAG exists; downloading its archive to pin it"
  gh release download "$TAG" --repo "$REPO" --pattern 'flutter-engine-vita-*.tar.gz' --dir "$WORK"
  TARBALL="$(ls "$WORK"/flutter-engine-vita-*.tar.gz | head -1)"
else
  echo "==> packaging engine $TAG"
  "$HERE/package-engine.sh" --release "$TAG" >/dev/null
  TARBALL="$ROOT/out/artifacts/flutter-engine-vita-$FLUTTER-$TAG.tar.gz"
fi
[ -f "$TARBALL" ] || die "no archive at $TARBALL"
ASSET="$(basename "$TARBALL")"
SHA="$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
MANIFEST="$(tar -xzOf "$TARBALL" "flutter-engine-vita-$FLUTTER/MANIFEST.txt")"
grep -q "^engine  *$HEAD " <<<"$MANIFEST" || die "$ASSET was built from another engine commit"
grep -q "^release  *$TAG\$" <<<"$MANIFEST" || die "$ASSET names another release"
BUILT_ON="$(sed -n 's/^built on  *//p' <<<"$MANIFEST")"
URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"

# A file, not $(cat <<EOF): bash 3.2, the one macOS ships, misreads an
# apostrophe in a here-document inside a command substitution.
NOTES="$WORK/notes.md"
cat > "$NOTES" <<EOF
The PS Vita engine for Flutter $FLUTTER, built from \`$HEAD\` on branch \`$BRANCH\`.

\`flutter-vita precache\` downloads it when the tool's versions.json names \`$TAG\`.

It unpacks to \`flutter-engine-vita-$FLUTTER/\`: the engine archive, \`gen_snapshot\` for $BUILT_ON, the headers that the embedder includes, and the data files.

sha256 \`$SHA\`

\`\`\`
$(sed -n '3,/^built at/p' <<<"$MANIFEST")
\`\`\`
EOF

cat <<EOF
==> plan
    release  $REPO $TAG, title "$FLUTTER ($TAG)", at $HEAD
    asset    $ASSET  $(du -h "$TARBALL" | cut -f1)
    sha256   $SHA
    pin      versions.json engine: release $TAG, its url and sha256, hosts [$BUILT_ON]
    commit   "versions: engine $TAG", pushed to origin master
EOF
if [ "$MODE" = dry ]; then
  printf '\n--- release notes ---\n'; cat "$NOTES"
  printf -- '---\n\ndry run: nothing published\n'
  exit 0
fi

if [ "$EXISTS" = 0 ]; then
  echo "==> publishing $REPO $TAG"
  gh release create "$TAG" --repo "$REPO" --target "$HEAD" \
    --title "$FLUTTER ($TAG)" --notes-file "$NOTES" "$TARBALL"
fi

echo "==> pinning $TAG in versions.json"
python3 - "$ROOT/versions.json" "$TAG" "$URL" "$SHA" "$BUILT_ON" <<'EOF'
import json, sys
path, tag, url, sha, host = sys.argv[1:]
v = json.load(open(path))
e = v["engine"]
e["release"], e["url"], e["sha256"], e["hosts"] = tag, url, sha, [host]
open(path, "w").write(json.dumps(v, indent=2, ensure_ascii=False) + "\n")
EOF
git -C "$ROOT" commit -q -m "versions: engine $TAG" -- versions.json
git -C "$ROOT" push -q origin master
echo "    pushed: versions: engine $TAG"

check
echo "==> https://github.com/$REPO/releases/tag/$TAG"
