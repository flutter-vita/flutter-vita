# ADR-0023: Our code is under the zlib licence

**Status:** Accepted
**Date:** 2026-10-14

## Context

Each `.vpk` that a developer builds with flutter-vita contains our code:

- `eboot.bin` links the embedder, fvita_gles2, the C files of
  `templates/vita-app` and the C halves of the `plugins/*_vita` packages.
- The AOT snapshot contains the Dart code of each `flutter_vita` package that
  the app uses.

On 2026-09-09 we chose BSD-3-Clause for this code, because Flutter, Dart and
Skia use it. Clause 2 of BSD-3 gives a rule to each person who shares a binary
of the code: that person must also share our copyright notice. Thus each
developer who shared a `.vpk` had a duty from our code.

The toolchain did not do this duty for the developer in all cases. Our notice
got into the `.vpk` only through `flutter_assets/NOTICES.Z`, and only when
the app used a `flutter_vita` package. An app without one had our code and
no notice.

[ADR-0018](0018-the-lgpl-obligation-in-every-vpk.md) removed vitaGL for a
similar reason. The user said on 2026-09-09 that a developer must not do
strange things to a `.vpk`. On 2026-10-14 the user said about the BSD-3 duty:
*"we need to avoid this somehow"*.

On 2026-10-14 the user was the only author in the three repositories: 526
commits in flutter-vita, 15 in flutter-vita-embedder and 14 in
flutter-vita-packages. Thus the licence could change without the consent of
other persons. After the first outside contribution, each contributor must
agree.

## Options

| Option | Duty for a developer who shares a `.vpk` | Other effects |
|---|---|---|
| Keep BSD-3, and the toolchain copies `LICENSE` into each `.vpk` | Yes. The toolchain does it, but a developer who removes the file breaks the licence | The clause against the use of our name to promote a product stays |
| **zlib** | **No** | A changed copy of the source must be marked as changed. SDL, GLFW and raylib use it, and game developers link them into their games |
| Boost (BSL-1.0) | No | The same result as zlib. Its text names binaries directly. Few game libraries use it |

## Decision

**The code of flutter-vita, flutter-vita-embedder and flutter-vita-packages
is under the zlib licence.** Each repository has the zlib text in `LICENSE`,
and each package in flutter-vita-packages has its own copy.

flutter-vita-bench changed to zlib on the same day. Its code goes only into
the benchmark's own `.vpk`, so it gave no duty to other developers. The change
gives all repositories of the organisation one licence for our own code.

The zlib licence has three conditions:

1. Do not say that you wrote the original software.
2. Mark a changed copy of the source as changed.
3. Keep the licence text in each copy of the source.

It has no condition for a binary.

## What does not change

- **The forks keep the licence of their upstream.** A change to a file is a
  derivative of that file. flutter-vita/flutter, dart-sdk, skia and zlib stay
  BSD-3-Clause, abseil-cpp stays Apache-2.0, and boringssl keeps BoringSSL's
  licence. [NOTICE](../../NOTICE) has the table.
- **The notices of the other projects still go into each `.vpk`.** The engine,
  Skia, Dart, ICU and HarfBuzz are BSD-3 and other licences, and we cannot
  change them. The developer does nothing for them:
  - `flutter build` writes `flutter_assets/NOTICES.Z` into each app. On
    2026-10-14 the gallery's `NOTICES.Z` contained all 1,594 licence texts of
    `LICENSE.engine`.
  - The template puts each font's own `OFL.txt` beside it.

## Consequences

- A developer who shares a `.vpk` has no duty from our code.
- A person who shares a changed copy of our source must mark the changes.
- We lose the BSD-3 clause that stops a person from using our name to promote
  their product without permission.
- The commits before 2026-10-14 were released under BSD-3-Clause. A person who
  got the code under BSD-3 can keep that licence for that code.
- No package was on pub.dev on 2026-10-14, so no published version has
  BSD-3.
- The engine artifact carries the fork's `LICENSE` (BSD-3), not ours, from
  the next engine release. `tools/package-engine.sh` copied our `LICENSE`
  before. That was correct only while both were BSD-3.
- [CONTRIBUTING.md](../../CONTRIBUTING.md) accepts contributions under the
  zlib licence.
