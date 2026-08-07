#!/usr/bin/env bash
# Produce an armv7 AOT snapshot the Vita runtime will actually accept.
#
# Dart's FeaturesString() embeds the target OS and validates it at load time, so
# a snapshot from a linux-arm gen_snapshot is rejected by a vita runtime. This
# uses the cross-targeting gen_snapshot built by patch 0004:
#
#   ninja -C third_party/sdk/out/host gen_snapshot_product_vita_arm
#
# Verify with:  strings -a out/hello-vita.elf | grep 'arm vita'
set -euo pipefail
cd "$(dirname "$0")"
REPO=$(cd ../.. && pwd)
GS="$REPO/third_party/sdk/out/host/gen_snapshot_product_vita_arm"
DILL="${1:-$REPO/spikes/b1-aot-snapshot/out/hello.dill}"

[[ -x "$GS" ]] || { echo "error: build gen_snapshot_product_vita_arm first" >&2; exit 1; }
[[ -f "$DILL" ]] || { echo "error: no kernel at $DILL -- run spikes/b1-aot-snapshot/build.sh" >&2; exit 1; }

mkdir -p out
"$GS" --snapshot_kind=app-aot-elf --elf=out/hello-vita.elf "$DILL"
echo "==> out/hello-vita.elf"
file out/hello-vita.elf
strings -a out/hello-vita.elf | grep -oE "arm (vita|linux) no-compressed-pointers" | head -1
