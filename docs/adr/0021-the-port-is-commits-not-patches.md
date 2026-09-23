# ADR-0021: The port is commits in six repositories, not a patch series

**Status:** Accepted
**Date:** 2026-09-23

## Context

Until this date the port changed six programs it does not own: the Flutter
engine, the Dart SDK, Skia, abseil, BoringSSL and zlib. The changes were 27
patch files in `engine/patches/`, applied by `tools/apply-patches.sh` to
checkouts that `gclient` had just made.

The mechanism worked. Every build applied the series, and a check told you
whether the series was in. What it cost was **readability**. To answer "what
does this port do to Skia?" you had to read a unified diff with no history
around it. `git blame` in the checkout showed upstream and nothing else. A
contributor could not see the change in the file they were editing, and a
reviewer could not see it in a pull request. Three other costs came with that:

1. **The patch and the tree drift.** The disk is the truth for the build, the
   patch file is the truth for the record, and nothing forces them to agree.
   On 2026-09-23 the Skia checkout held nine files of spike instrumentation
   (`fvita_gl_trace`) that no patch owned. It was in the shipped engine
   archive `3.44.8_0.1.0`: 20 references, 19 of them undefined.
2. **Regenerating is a chore with a rule.** Patch 0004 had to be regenerated
   from a file list that changed over time, and forgetting the list silently
   dropped work.
3. **A patch has no history.** Why a line exists is in a commit message
   somewhere else, or nowhere.

The user's instruction: *"I dont like patches because this changes are not
transparent for developers. We need to see them not in patch scripts but in
code."*

## Decision

**Every change this port makes is a commit in the repository that owns the
file.** There are no patch files.

| Repository | What it holds |
|---|---|
| [flutter-vita/flutter](https://github.com/flutter-vita/flutter) `vita-3.44.8` | The engine. The tag `3.44.8` plus 16 commits. `third_party/flutter` is a checkout of this branch |
| [flutter-vita/dart-sdk](https://github.com/flutter-vita/dart-sdk) `vita-3.44.8` | 11 commits |
| [flutter-vita/skia](https://github.com/flutter-vita/skia) `vita-3.44.8` | 1 commit |
| [flutter-vita/abseil-cpp](https://github.com/flutter-vita/abseil-cpp) `vita-3.44.8` | 1 commit |
| [flutter-vita/boringssl](https://github.com/flutter-vita/boringssl) `vita-3.44.8` | 1 commit |
| [flutter-vita/zlib](https://github.com/flutter-vita/zlib) `vita-3.44.8` | 1 commit |

Flutter does not contain the other five, so a commit on the engine fork
cannot reach their files: `DEPS` names a revision of each and `gclient`
checks them out. `DEPS` therefore names **our** fork and **our** commit. The
new `vita_git` var holds the organisation, and `github.com` joins
`allowed_hosts`.

Each dependency fork is the upstream tree at the revision `DEPS` named
before, as one `import:` commit, plus our commits on top. `git log
<import>..HEAD` is exactly our change and nothing else.

`tools/apply-patches.sh` becomes `tools/engine-tree.sh`. It applies nothing.
It checks that the tree is on the branch, is clean and is pushed; that each
dependency checkout is at the commit `DEPS` names and is clean; and that no
patch directory has come back.

### Considered and rejected

**Build switches instead of forks.** Where a change only removes something on
this platform, a GN argument can do the same job with no fork. This covers
zlib (the ARMv8 paths) and parts of abseil, but not the Dart SDK's 4 500
lines, not Skia's file reader, and not BoringSSL's entropy source. A rule
that holds for two programs out of five is not a rule, and the two would then
live in a different place from the other three.

**Keep the patch files but check them harder.** A drift check makes the two
places agree more often. It does not make the change readable, which was the
complaint.

**Vendor the five into the engine fork.** `DEPS` would have to stop naming
them, which is a much larger divergence from upstream and makes an upgrade
harder, not easier.

## Consequences

- A developer reads the port with `git log` and `git blame`, in the file they
  are looking at. A change to it is a commit and a push.
- Drift becomes impossible to miss. A changed file in a dependency checkout
  is an uncommitted change, and `engine-tree.sh --verify` fails on it. That
  check is what the `fvita_gl_trace` instrumentation would have tripped.
- An upgrade is priced from the forks: import to HEAD is our file list, and
  the work is a rebase onto a new import.
- Six repositories to push instead of one directory to regenerate. Every fork
  is pinned by SHA in `DEPS`, so a missed push shows up as a build that does
  not reproduce, not as silence.
- `gclient` clones shallow, and GitHub refuses a push from a shallow clone.
  Each fork was built with plumbing (`git commit-tree`) instead: an orphan
  import commit, then our commits, then a push of the two-commit history. Do
  the same for the next one.
- The forks are private, and the engine fork is public. A stranger cloning
  the public fork cannot sync its `DEPS`. **Open the five when the tool
  repository opens.**
- Upstream history is not in the dependency forks. The import commit is a
  tree with no ancestors, so `git blame` on an untouched upstream line stops
  at the import. Upstream's own repository still has it.

## Revisit trigger

A Flutter version change. The engine fork rebases onto the new tag and each
dependency fork rebases onto a new import commit. If that turns out to cost
more than regenerating a patch series did, this decision is wrong, and
[the upgrade cost document](../flutter-upgrade-cost.md) is where the
measurement goes.
