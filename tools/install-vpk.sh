#!/usr/bin/env bash
# Install a .vpk onto a running Vita, registering the title id if it is new.
#
#   ./tools/install-vpk.sh <vpk> [--host IP] [--port N] [--no-launch]
#   ./tools/install-vpk.sh <vpk> --replace      the fast dev-loop route
#
# ## The two routes
#
# **promote** (default) is a real install. The extracted package is staged under
# ux0:data/pkg, a package header is generated for its title id, and the receiver
# calls scePromoterUtilityPromotePkgWithRif. The title is registered with the
# shell, a bubble appears, and the id need not have existed.
#
# **--replace** is the edit-run loop: overwrite eboot.bin and the data files in
# a slot that already exists. Faster, and it cannot create a title.
#
# ## What the promote route needs
#
# No taiHEN, no kernel plugin, no VitaShell, no card swap. It does need the
# receiver, because PromotePkgWithRif must be called from a process on the
# console. Three things were load-bearing, each costing an experiment:
#
#   PAF must be resident before the promoter loads and must stay resident.
#   Unloading it kills the console about ten seconds later. See
#   experiments/promoter.
#
#   The staging directory is ux0:data/pkg and nowhere else. PromotePkgWithRif
#   returns 0x8010111C from anywhere else.
#
#   sce_sys/package/head.bin must exist and carry the right content id with
#   valid digests. tools/make-head-bin.py writes one; no key is involved.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# flutter-vita.local, not an address. The dev server answers mDNS for that name
# (see the mDNS section of devserver.c), so this survives the console coming
# back on a different lease -- which it does, often. VITA_HOST still overrides
# it, and an IP is still the right answer when the name will not resolve.
HOST="${VITA_HOST:-flutter-vita.local}"
PORT="${RECEIVER_PORT:-1341}"
STAGE="ux0:data/pkg"
VPK=""
TITLE_ID=""
LAUNCH=1
REPLACE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --host)      HOST="$2"; shift 2 ;;
    --port)      PORT="$2"; shift 2 ;;
    --title-id)  TITLE_ID="$2"; shift 2 ;;
    --replace)   REPLACE=1; shift ;;
    --no-launch) LAUNCH=0; shift ;;
    -h|--help)   sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)          echo "unknown option: $1" >&2; exit 2 ;;
    *)           VPK="$1"; shift ;;
  esac
done

[ -n "$VPK" ] && [ -f "$VPK" ] || { sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
VPK="$(cd "$(dirname "$VPK")" && pwd)/$(basename "$VPK")"

say() { printf '%s\n' "$2" | nc -w "${3:-30}" "$HOST" "$1"; }

# ------------------------------------------------------- one lookup per run
#
# Measured 2026-09-09: `nc flutter-vita.local 1341` takes 5.12 s, `nc` against
# the address it resolves to takes 0.08 s. The whole difference is getaddrinfo
# asking mDNSResponder, and it is paid once per connection -- so a promote,
# which opens about sixty of them, spends five minutes resolving one name sixty
# times.
#
# The name is still how you address the console: its lease changes whenever its
# Wi-Fi does, which is often. It does not change during one run of one script,
# so resolving once and reusing the answer is the same guarantee for 1/60th of
# the cost. The address is printed, because a run that talked to the wrong
# console should say so.
resolve_once() {
  case "$HOST" in
    *[!0-9.]*) ;;
    *) return 0 ;;
  esac
  local addr
  addr="$(python3 -c 'import socket,sys
try:
    print(socket.gethostbyname(sys.argv[1]))
except OSError:
    pass' "$HOST" 2>/dev/null || true)"
  [ -n "$addr" ] || return 0
  echo "==> $HOST is $addr"
  HOST="$addr"
}
resolve_once

# Retried, because one connect is not evidence. The receiver's listener is
# non-blocking and a single ping races with its accept loop: it reported "no
# receiver" three times in a row on 2026-08-15 against a receiver that answered
# `ls` on the same port a second later.
alive=0
for _ in 1 2 3; do
  if say "$PORT" ping 8 2>/dev/null | grep -q receiver; then alive=1; break; fi
  sleep 2
done
[ "$alive" -eq 1 ] || {
  echo "!! no receiver on $HOST:$PORT — open the receiver" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
unzip -q "$VPK" -d "$WORK"
[ -f "$WORK/eboot.bin" ] || { echo "!! no eboot.bin in $VPK" >&2; exit 1; }

# The package decides its own title id. Overriding it is possible and is almost
# always a mistake, so it is a flag rather than the default.
[ -n "$TITLE_ID" ] || TITLE_ID="$(strings "$WORK/sce_sys/param.sfo" 2>/dev/null \
  | grep -m1 -oE '^[A-Z]{4}[0-9]{5}$' || true)"
case "$TITLE_ID" in
  [A-Z][A-Z][A-Z][A-Z][0-9][0-9][0-9][0-9][0-9]) ;;
  *) echo "!! no title id in the vpk's param.sfo; pass --title-id" >&2; exit 1 ;;
esac

put() {  # <local> <device path>
  local size; size=$(wc -c <"$1" | tr -d ' ')
  [ "${size:-0}" -gt 0 ] || { echo "!! refusing to put an empty $1" >&2; return 1; }
  { printf 'put %s %s\n' "$size" "$2"; cat "$1"; } | nc -w 300 "$HOST" "$PORT" \
    | grep -q OK || { echo "!! put failed: $2" >&2; return 1; }
  printf '    %-44s %9s B\n' "$2" "$size"
}

if [ "$REPLACE" -eq 1 ]; then
  echo "==> replacing $TITLE_ID in place (no promote)"
  SIZE="$(wc -c < "$WORK/eboot.bin" | tr -d ' ')"
  { printf 'stage %s\n' "$SIZE"; cat "$WORK/eboot.bin"; } \
    | nc -w 300 "$HOST" "$PORT" | grep -q OK || {
      echo "!! stage failed — wifi drop mid-transfer?" >&2; exit 1; }
  say "$PORT" "install $TITLE_ID" 60 | grep -q OK || {
    echo "!! install failed" >&2; exit 1; }
  # `install` replaces eboot.bin only, so without this the app runs against
  # whatever data files the last install left behind -- which is how an engine
  # with no icudtl.dat and an unreachable flutter_assets got debugged for an
  # hour.
  ( cd "$WORK" && find . -type f ! -name eboot.bin \
      \( -not -path "./sce_sys/*" -o -path "./sce_sys/param2.sfo" \) \
      | sed 's|^\./||' ) \
  | while read -r rel; do put "$WORK/$rel" "ux0:app/$TITLE_ID/$rel"; done
else
  echo "==> promoting $(basename "$VPK") as $TITLE_ID"
  # Generated per install rather than shipped, because the content id inside it
  # has to be this title's. A header signed for another id gets as far as NpDrm
  # and is refused with 0x80870005.
  mkdir -p "$WORK/sce_sys/package"
  "$HERE/make-head-bin.py" "$TITLE_ID" -o "$WORK/sce_sys/package/head.bin" \
    | sed 's/^/    /'

  # Cleared first. The promoter reads the whole staging directory, so a file
  # left by a previous install of something else becomes part of this package.
  # `rmtree` is confined to ux0:data on the receiver side; see cmd_rmtree.
  say "$PORT" "rmtree $STAGE" 120 | sed 's/^/    /'

  # The LiveArea art is staged nowhere and copied in after the promote.
  #
  # PromotePkgWithRif validates sce_sys against the package header, and head.bin
  # is a keyless template describing some other package's file set -- so an
  # icon0.png the header never heard of is rejected outright, 0x8010113D.
  # Measured 2026-08-31, both ways.
  #
  # The shell reads the art out of ux0:app/<id>/sce_sys, not out of the package,
  # so putting it there afterwards gives the same result.
  echo "==> staging into $STAGE"
  ( cd "$WORK" && find . -type f | sed 's|^\./||' \
      | grep -v -e '^sce_sys/icon0\.png$' -e '^sce_sys/livearea/' | sort ) \
    | while read -r rel; do put "$WORK/$rel" "$STAGE/$rel"; done
  say "$PORT" "ls $STAGE" 30 | sed 's/^/    /'

  echo "==> promote"
  # Captured rather than piped into grep, so the codes are on screen either way.
  # 0x8010111C is a missing or misplaced header, 0x80871004 a bad digest,
  # 0x80870005 a header signed for a different title.
  # The title id is passed even though the promoter reads it out of head.bin:
  # the receiver writes it into installed.txt, which the APPS tab lists.
  RESULT="$(say "$PORT" "promoterif $STAGE $TITLE_ID" 600 || true)"
  printf '    %s\n' "$RESULT"
  case "$RESULT" in
    OK*) ;;
    *) echo "!! promote failed. More in the receiver's log:" >&2
       echo "     printf 'log\\n' | nc $HOST $PORT | tail -20" >&2
       exit 1 ;;
  esac
  say "$PORT" "exist $TITLE_ID" 30 | sed 's/^/    /'

  ART="$( cd "$WORK" && find . -type f \
      \( -name icon0.png -o -path './sce_sys/livearea/*' \) \
      | sed 's|^\./||' | sort )"
  if [ -n "$ART" ]; then
    echo "==> livearea"
    printf '%s\n' "$ART" \
      | while read -r rel; do put "$WORK/$rel" "ux0:app/$TITLE_ID/$rel"; done
  fi
fi

if [ "$LAUNCH" -eq 1 ]; then
  echo "==> launching $TITLE_ID"
  say "$PORT" "launch $TITLE_ID" 20 || true
fi
