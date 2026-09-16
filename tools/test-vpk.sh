#!/usr/bin/env bash
# Check receiver/src/vpk.c on the host, against unzip and make-head-bin.py.
#
#   ./tools/test-vpk.sh <vpk> [<vpk>...]
#
# The receiver installs a vpk from the card with this file: the zip reader,
# the sfo reader and the head.bin writer. All three are plain bytes, so they
# build with the system zlib and can be held against the host tools that do
# the same job in install-vpk.sh. A mistake found here costs seconds; the
# same mistake on the console costs a redeploy and a promoter error code.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
[ $# -ge 1 ] || { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/main.c" <<'C'
#include "vpk.h"
#include <stdio.h>
#include <string.h>
static void progress(void* ctx, const char* name, uint64_t done, uint64_t total) {
  (void)ctx;
  fprintf(stderr, "  %6.1f%%  %s\n", total ? 100.0 * done / total : 0, name);
}
int main(int argc, char** argv) {
  char err[160] = "";
  if (argc == 5 && strcmp(argv[1], "extract") == 0) {
    const int r = vpk_extract(argv[2], argv[3], strcmp(argv[4], "art") == 0 ? VPK_ART : VPK_STAGE,
                              progress, NULL, err, sizeof err);
    if (r < 0) fprintf(stderr, "!! %s\n", err);
    return r < 0;
  }
  if (argc == 3 && strcmp(argv[1], "titleid") == 0) {
    char id[16];
    if (vpk_title_id(argv[2], id, sizeof id) < 0) return 1;
    printf("%s\n", id);
    return 0;
  }
  if (argc == 5 && strcmp(argv[1], "head") == 0) {
    const int r = vpk_write_head(argv[2], argv[3], argv[4], err, sizeof err);
    if (r < 0) fprintf(stderr, "!! %s\n", err);
    return r < 0;
  }
  fprintf(stderr, "usage: extract <vpk> <dir> stage|art | titleid <sfo> | head <tmpl> <dst> <id>\n");
  return 2;
}
C
# The SDK the linker accepts: on this Mac the command line tools' default
# (27.0) carries .tbd files the linker calls malformed; Xcode's own is fine.
SYSROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)}"
cc -std=gnu11 -Wall -Wextra -O1 ${SYSROOT:+-isysroot "$SYSROOT"} \
  -I"$ROOT/receiver/src" -o "$WORK/vpk" \
  "$ROOT/receiver/src/vpk.c" "$WORK/main.c" -lz

fail=0
for vpk in "$@"; do
  echo "==> $(basename "$vpk")"
  rm -rf "$WORK/ref" "$WORK/stage" "$WORK/art"
  mkdir -p "$WORK/ref"
  unzip -q "$vpk" -d "$WORK/ref"
  "$WORK/vpk" extract "$vpk" "$WORK/stage" stage 2>"$WORK/progress.txt"
  "$WORK/vpk" extract "$vpk" "$WORK/art" art 2>/dev/null
  # What install-vpk.sh stages, and what it copies in afterwards.
  ( cd "$WORK/ref" && find . -type f | sed 's|^\./||' \
      | grep -v -e '^sce_sys/icon0\.png$' -e '^sce_sys/livearea/' \
                -e '^eboot2\.bin$' -e '^sce_sys/param2\.sfo$' | sort ) > "$WORK/want-stage.txt"
  ( cd "$WORK/ref" && find . -type f \( -path './sce_sys/icon0.png' -o -path './sce_sys/livearea/*' \) \
      | sed 's|^\./||' | sort ) > "$WORK/want-art.txt"
  ( cd "$WORK/stage" && find . -type f | sed 's|^\./||' | sort ) > "$WORK/got-stage.txt"
  ( cd "$WORK/art" 2>/dev/null && find . -type f | sed 's|^\./||' | sort ) > "$WORK/got-art.txt" || true
  for which in stage art; do
    if ! diff -q "$WORK/want-$which.txt" "$WORK/got-$which.txt" >/dev/null; then
      echo "!! $which: the file list differs from unzip's"; diff "$WORK/want-$which.txt" "$WORK/got-$which.txt" | head; fail=1
    fi
    while read -r rel; do
      [ -n "$rel" ] || continue
      cmp -s "$WORK/ref/$rel" "$WORK/$which/$rel" || { echo "!! $which: $rel differs"; fail=1; }
    done < "$WORK/want-$which.txt"
    echo "    $which: $(wc -l < "$WORK/want-$which.txt" | tr -d ' ') files, byte-identical to unzip"
  done
  id="$("$WORK/vpk" titleid "$WORK/stage/sce_sys/param.sfo")"
  want_id="$(strings "$WORK/ref/sce_sys/param.sfo" | grep -m1 -oE '^[A-Z]{4}[0-9]{5}$')"
  [ "$id" = "$want_id" ] || { echo "!! title id: got '$id', strings says '$want_id'"; fail=1; }
  echo "    title id $id"
  "$WORK/vpk" head "$ROOT/tools/pkg/head-template.bin" "$WORK/head-c.bin" "$id"
  "$HERE/make-head-bin.py" "$id" --template "$ROOT/tools/pkg/head-template.bin" -o "$WORK/head-py.bin" >/dev/null
  if cmp -s "$WORK/head-c.bin" "$WORK/head-py.bin"; then
    echo "    head.bin: identical to make-head-bin.py's"
  else
    echo "!! head.bin differs from make-head-bin.py's"; fail=1
  fi
  "$HERE/make-head-bin.py" --verify "$WORK/head-c.bin" | sed 's/^/    /'
  echo "    progress lines: $(wc -l < "$WORK/progress.txt" | tr -d ' ')"
done
[ "$fail" -eq 0 ] && echo "==> ok" || { echo "==> FAILED"; exit 1; }
