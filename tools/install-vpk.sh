#!/usr/bin/env bash
# Install a .vpk onto a running Vita, registering the title id if it is new.
#
#   ./tools/install-vpk.sh <vpk> [--host IP] [--port N] [--no-launch]
#   ./tools/install-vpk.sh <vpk> --replace      the fast dev-loop route
#
# ## The two routes
#
# **promote** (default) is a real install. The extracted package is staged under
# ux0:data/pkg, a package header is generated for its title id, and the bridge
# calls scePromoterUtilityPromotePkgWithRif. The title is registered with the
# shell, a bubble appears, and the id need not have existed.
#
# **--replace** is the edit-run loop: overwrite eboot.bin and the data files in
# a slot that already exists. Faster, and it cannot create a title.
#
# ## What the promote route needs
#
# No taiHEN, no kernel plugin, no VitaShell, no card swap. It does need the
# bridge, because PromotePkgWithRif must be called from a process on the
# console. Three things were load-bearing, each costing an experiment:
#
#   PAF must be resident before the promoter loads and must stay resident.
#   Unloading it kills the console about ten seconds later. See
#   experiments/promoter, in git history at c91294a.
#
#   The staging directory is ux0:data/pkg and nowhere else. PromotePkgWithRif
#   returns 0x8010111C from anywhere else.
#
#   sce_sys/package/head.bin must exist and carry the right content id with
#   valid digests. tools/make-head-bin.dart writes one; no key is involved.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# fluttervita.local, not an address. The dev server answers mDNS for that name
# (see the mDNS section of devserver.c), so this survives the console coming
# back on a different lease -- which it does, often. VITA_HOST still overrides
# it, and an IP is still the right answer when the name will not resolve.
HOST="${VITA_HOST:-fluttervita.local}"
PORT="${BRIDGE_PORT:-1341}"
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

say() { printf '%s\n' "$2" | nc -4 -w "${3:-30}" "$HOST" "$1"; }
# The console is addressed by name, always, everywhere.
#
# An earlier version of this resolved the name once and used the address for
# the rest of the run, to avoid paying mDNS on each of about sixty connections.
# That is gone. An address held anywhere is an address that goes stale, and on
# 2026-09-09 a stale one cost a bench run: the laptop changed network, the
# address in hand pointed at nothing, and a console that was awake and well
# read as asleep for half an hour. The name would have said so at once.
#
# If resolving the name is slow, that is a fault in the responder and it is
# visible in ux0:data/flutter-vita/mdns.txt. Read that instead of caching
# around it.


# Retried, because one connect is not evidence. The bridge's listener is
# non-blocking and a single ping races with its accept loop: it reported "no
# bridge" three times in a row on 2026-08-15 against a bridge that answered
# `ls` on the same port a second later.
alive=0
for _ in 1 2 3; do
  if say "$PORT" ping 8 2>/dev/null | grep -q bridge; then alive=1; break; fi
  sleep 2
done
[ "$alive" -eq 1 ] || {
  echo "!! no bridge on $HOST:$PORT — open the bridge" >&2; exit 1; }

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
  { printf 'put %s %s\n' "$size" "$2"; cat "$1"; } | nc -4 -w 300 "$HOST" "$PORT" \
    | grep -q OK || { echo "!! put failed: $2" >&2; return 1; }
  printf '    %-44s %9s B\n' "$2" "$size"
}

if [ "$REPLACE" -eq 1 ]; then
  echo "==> replacing $TITLE_ID in place (no promote)"
  SIZE="$(wc -c < "$WORK/eboot.bin" | tr -d ' ')"
  { printf 'stage %s\n' "$SIZE"; cat "$WORK/eboot.bin"; } \
    | nc -4 -w 300 "$HOST" "$PORT" | grep -q OK || {
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
  # pic0.png, the picture the system shows while it loads the app, is read
  # from ur0:appmeta/<id>. A promote copies it there, also over an installed
  # title (measured 2026-10-29); this route does not promote. Without a splash
  # the old one goes, or it would show.
  if [ -f "$WORK/sce_sys/pic0.png" ]; then
    put "$WORK/sce_sys/pic0.png" "ur0:appmeta/$TITLE_ID/pic0.png"
  else
    say "$PORT" "rm ur0:appmeta/$TITLE_ID/pic0.png" 10 >/dev/null || true
  fi
else
  echo "==> promoting $(basename "$VPK") as $TITLE_ID"
  # Generated per install rather than shipped, because the content id inside it
  # has to be this title's. A header signed for another id gets as far as NpDrm
  # and is refused with 0x80870005.
  mkdir -p "$WORK/sce_sys/package"
  DART="$("$HERE/flutter-sdk.sh")/bin/cache/dart-sdk/bin/dart"
  "$DART" "$HERE/make-head-bin.dart" "$TITLE_ID" -o "$WORK/sce_sys/package/head.bin" \
    | sed 's/^/    /'

  # Cleared first. The promoter reads the whole staging directory, so a file
  # left by a previous install of something else becomes part of this package.
  # `rmtree` is confined to ux0:data on the bridge side; see cmd_rmtree.
  say "$PORT" "rmtree $STAGE" 120 | sed 's/^/    /'

  # The LiveArea art goes into the package. The shell takes the bubble and the
  # LiveArea out of the package at the promote; a copy into
  # ux0:app/<id>/sce_sys afterwards changes nothing on screen. Measured
  # 2026-10-20: the bridge's new art, copied in that way, left the old bubble
  # and the default LiveArea (a white circle on the stock background), and so
  # had every app installed by this script until then.
  #
  # Only the first promote of a title counts. A promote over an installed
  # title keeps the LiveArea it had: the gallery got its row in tbl_livearea
  # of ur0:shell/db/app.db only after a delete and a new install. A title
  # installed before this change keeps the default until then.
  # scePromoterUtilityUpdateLiveArea answered 0x80010015 to each layout tried.
  #
  # The promoter validates the three PNGs and answers 0x8010113D when they are
  # not 8-bit indexed. On 2026-08-31 ours were 32-bit RGBA, so staging them
  # failed and leaving them out passed, and this file blamed the header for it.
  # tools/check-livearea-art.dart refuses RGBA at build time now.
  # The supervisor pair stays out too. PromotePkgWithRif answers 0x80101104
  # to a package that carries eboot2.bin and sce_sys/param2.sfo, and 0 to the
  # same package without them; measured 2026-09-11 on a fresh console, the
  # gallery both ways. The background app was abandoned in ADR-0011 and is
  # not reachable, so nothing is lost. The first console never showed this
  # because FVTA00002 there predates the pair and only ever got `--replace`.
  echo "==> staging into $STAGE"
  ( cd "$WORK" && find . -type f | sed 's|^\./||' \
      | grep -v -e '^eboot2\.bin$' -e '^sce_sys/param2\.sfo$' | sort ) \
    | while read -r rel; do put "$WORK/$rel" "$STAGE/$rel"; done
  say "$PORT" "ls $STAGE" 30 | sed 's/^/    /'

  echo "==> promote"
  # Captured rather than piped into grep, so the codes are on screen either way.
  # 0x8010111C is a missing or misplaced header, 0x80871004 a bad digest,
  # 0x80870005 a header signed for a different title.
  # The title id is passed even though the promoter reads it out of head.bin:
  # the bridge writes it into installed.txt, which the APPS tab lists.
  RESULT="$(say "$PORT" "promoterif $STAGE $TITLE_ID" 600 || true)"
  printf '    %s\n' "$RESULT"
  case "$RESULT" in
    OK*) ;;
    *) echo "!! promote failed. More in the bridge's log:" >&2
       echo "     printf 'log\\n' | nc -4 $HOST $PORT | tail -20" >&2
       exit 1 ;;
  esac
  say "$PORT" "exist $TITLE_ID" 30 | sed 's/^/    /'
  # A package built with `splash: none` has no pic0.png. Whether a promote then
  # removes the one an earlier install left is not measured; this makes sure.
  [ -f "$WORK/sce_sys/pic0.png" ] \
    || say "$PORT" "rm ur0:appmeta/$TITLE_ID/pic0.png" 10 >/dev/null || true
fi

if [ "$LAUNCH" -eq 1 ]; then
  echo "==> launching $TITLE_ID"
  say "$PORT" "launch $TITLE_ID" 20 || true
fi
