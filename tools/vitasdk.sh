#!/usr/bin/env bash
# VitaSDK, the compiler and the console's libraries that each build uses.
#
#   tools/vitasdk.sh             print its directory, installing it first if needed
#   tools/vitasdk.sh --find      print its directory, or nothing; install nothing
#   . tools/vitasdk.sh; flutter_vita_vitasdk [--find]    the same, as a function
#
# The first one found wins:
#
#   1. VITASDK, when it is set. A VITASDK without the compiler is an error,
#      not a reason to look somewhere else.
#   2. ~/.flutter-vita/vitasdk/<release>, which this script installs.
#   3. ~/vitasdk and /usr/local/vitasdk, where VitaSDK's own install puts it.
#   4. None: this script installs the release in versions.json. That is
#      VitaSDK's own archive for this host (about 100 MB), checked against the
#      pinned sha256 and unpacked to ~/.flutter-vita/vitasdk/<release>.
#
# An app build needs the toolchain and the console's stub libraries (the
# Sce*_stub that the template and the plugins link), and the archive has both.
# The Khronos GLES headers are in gles2/include. vdpm and its packages
# (install-all.sh) are not needed; only the bridge needs vdpm's zlib, and
# tools/build-bridge.sh checks for it.
#
# Until 2026-10-27 the build stopped with "Define VITASDK" when the variable
# was not set, also on a Mac where VitaSDK was in ~/vitasdk: the last line of
# the install steps, which puts VITASDK into the shell profile, was easy to
# miss. Now the tool finds VitaSDK, or installs it, as it does with Flutter.
#
# Messages go to stderr, the directory alone to stdout, so callers can capture it.

flutter_vita_vitasdk() (
  set -euo pipefail

  local find_only=0
  [ "${1:-}" = --find ] && find_only=1

  has_compiler() { [ -x "$1/bin/arm-vita-eabi-gcc" ]; }

  if [ -n "${VITASDK:-}" ]; then
    has_compiler "$VITASDK" || {
      echo "!! VITASDK=$VITASDK has no bin/arm-vita-eabi-gcc. Unset VITASDK, and the tool finds or installs VitaSDK." >&2
      return 1
    }
    echo "$VITASDK"
    return 0
  fi

  local here root versions
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  root="$(cd "$here/.." && pwd)"
  versions="$root/versions.json"
  get() { awk -v want="$1" -f "$here/json-get.awk" "$versions"; }

  local home release dest marker
  home="${FLUTTER_VITA_HOME:-$HOME/.flutter-vita}"
  release="$(get vitasdk.release)" || {
    echo "!! $versions has no vitasdk.release" >&2
    return 1
  }
  dest="$home/vitasdk/$release"
  marker="$dest/.flutter-vita-vitasdk"

  local candidate
  for candidate in "$dest" "$HOME/vitasdk" /usr/local/vitasdk; do
    # The marker is written last, so our own directory without it is an
    # unpack that did not finish.
    if [ "$candidate" = "$dest" ] && [ ! -f "$marker" ]; then continue; fi
    if has_compiler "$candidate"; then
      echo "$candidate"
      return 0
    fi
  done

  [ "$find_only" = 0 ] || return 0

  local host
  case "$(uname -s)" in Darwin) host=darwin ;; Linux) host=linux ;; *) host=unknown ;; esac
  case "$(uname -m)" in arm64 | aarch64) host="$host-arm64" ;; x86_64) host="$host-x64" ;; esac

  local name sha url
  name="$(get "vitasdk.hosts.$host.archive")" &&
    sha="$(get "vitasdk.hosts.$host.sha256")" || {
    echo "!! versions.json has no VitaSDK for $host. Install VitaSDK from https://vitasdk.org and set VITASDK." >&2
    return 1
  }
  url="$(get vitasdk.base_url)$name"

  mkdir -p "$home/vitasdk"
  local archive="$home/vitasdk/$name"
  echo "==> VitaSDK $release for $host, one time, into $dest" >&2

  # -C - resumes a download that stopped.
  if [ ! -f "$archive" ] || ! echo "$sha  $archive" | shasum -a 256 -c - >/dev/null 2>&1; then
    curl -fL -C - --progress-bar -o "$archive" "$url" || {
      echo "!! download failed: $url" >&2
      return 1
    }
  fi
  echo "    checking sha256" >&2
  echo "$sha  $archive" | shasum -a 256 -c - >/dev/null 2>&1 || {
    echo "!! $archive does not match the sha256 in versions.json; deleted it" >&2
    rm -f "$archive"
    return 1
  }

  echo "    unpacking" >&2
  local tmp="$home/vitasdk/.unpack-$release"
  rm -rf "$tmp" "$dest"
  mkdir -p "$tmp"
  tar -xjf "$archive" -C "$tmp"
  mv "$tmp/vitasdk" "$dest"
  rm -rf "$tmp"

  has_compiler "$dest" || {
    echo "!! $dest has no bin/arm-vita-eabi-gcc after the unpack" >&2
    return 1
  }
  "$dest/bin/arm-vita-eabi-gcc" --version >/dev/null 2>&1 || {
    echo "!! $dest/bin/arm-vita-eabi-gcc does not run on this computer" >&2
    return 1
  }
  echo "    $("$dest/bin/arm-vita-eabi-gcc" --version | head -1)" >&2

  echo "$sha" >"$marker"
  rm -f "$archive"
  echo "$dest"
)

# Run, not sourced: print the directory.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  flutter_vita_vitasdk "$@"
fi
