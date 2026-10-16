#!/usr/bin/env bash
# The Flutter SDK the tools build with, owned by the tools.
#
#   tools/flutter-sdk.sh                 print its directory, downloading it first if needed
#   . tools/flutter-sdk.sh; flutter_vita_sdk    the same, as a function
#
# The SDK is Google's own release archive for the version in versions.json,
# checked against the sha256 pinned there and unpacked to
# ~/.flutter-vita/flutter/<version>. Nothing else on the machine changes: the
# Flutter a developer uses for other projects is not read, not replaced and not
# required. flutter-tizen does the same with a git clone; the archive is used
# here because its hash is published and can be pinned.
#
# Until 2026-10-01 the tools read ~/fvm/versions/<version> and the install pages
# asked for fvm. Nothing needed fvm in particular, only a stock SDK of the
# right version in a known place, and that is now this script's job.
#
# FLUTTER_ROOT wins when set, and nothing is downloaded. The build still
# refuses an SDK whose revision does not match the engine.
#
# Messages go to stderr, the directory alone to stdout, so callers can capture it.

flutter_vita_sdk() (
  set -euo pipefail

  if [ -n "${FLUTTER_ROOT:-}" ]; then
    [ -x "$FLUTTER_ROOT/bin/flutter" ] || {
      echo "!! FLUTTER_ROOT=$FLUTTER_ROOT has no bin/flutter" >&2
      return 1
    }
    echo "$FLUTTER_ROOT"
    return 0
  fi

  local here root versions
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  root="$(cd "$here/.." && pwd)"
  versions="$root/versions.json"

  local host
  case "$(uname -s)" in Darwin) host=darwin ;; Linux) host=linux ;; *) host=unknown ;; esac
  case "$(uname -m)" in arm64 | aarch64) host="$host-arm64" ;; x86_64) host="$host-x64" ;; esac

  # versions.json is nested, so not sed. No Dart exists yet: this downloads it.
  get() { awk -v want="$1" -f "$here/json-get.awk" "$versions"; }
  local version rev url sha archive
  version="$(get flutter)" && rev="$(get framework_rev)" || {
    echo "!! $versions has no flutter or framework_rev" >&2
    return 1
  }
  archive="$(get "flutter_sdk.hosts.$host.archive")" &&
    sha="$(get "flutter_sdk.hosts.$host.sha256")" || {
    echo "!! versions.json has no Flutter SDK for $host; set FLUTTER_ROOT to a Flutter $version" >&2
    return 1
  }
  url="$(get flutter_sdk.base_url)$archive"

  local home dest marker
  home="${FLUTTER_VITA_HOME:-$HOME/.flutter-vita}"
  dest="$home/flutter/$version"
  marker="$dest/.flutter-vita-sdk"

  # The marker is written last, so a directory without it is an unpack that
  # did not finish, and it is safe to throw away.
  if [ -f "$marker" ] && [ "$(cat "$marker")" = "$sha" ] && [ -x "$dest/bin/flutter" ]; then
    echo "$dest"
    return 0
  fi

  mkdir -p "$home/flutter"
  local archive="$home/flutter/${url##*/}"
  echo "==> Flutter $version for $host, one time, into $dest" >&2

  # -C - resumes: a 2 GB download that fails at 80% should not start again.
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
  local tmp="$home/flutter/.unpack-$version"
  rm -rf "$tmp" "$dest"
  mkdir -p "$tmp"
  case "$archive" in
    *.zip) unzip -q "$archive" -d "$tmp" ;;
    *.tar.xz) tar -xJf "$archive" -C "$tmp" ;;
    *) echo "!! unknown archive type: $archive" >&2; return 1 ;;
  esac
  mv "$tmp/flutter" "$dest"
  rm -rf "$tmp"

  # The archive is a git checkout. Its HEAD has to be the revision the engine
  # was built against, or the hash in versions.json pins the wrong file.
  local head
  head="$(git -C "$dest" rev-parse HEAD 2>/dev/null || echo unknown)"
  if [ "$head" != "$rev" ]; then
    echo "!! $dest is at $head, versions.json pins $rev" >&2
    return 1
  fi

  # First run: writes bin/cache/flutter.version.json, which the build's
  # lockstep check reads. Quiet, because Flutter's first run says "a new
  # version is available, run flutter upgrade", and on this SDK that advice
  # would break the pin.
  "$dest/bin/flutter" --suppress-analytics --version >/dev/null 2>&1 || {
    echo "!! $dest/bin/flutter does not run" >&2
    return 1
  }
  echo "    Flutter $version at ${rev:0:10}" >&2

  echo "$sha" >"$marker"
  rm -f "$archive"
  echo "$dest"
)

# Run, not sourced: print the directory.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  flutter_vita_sdk
fi
