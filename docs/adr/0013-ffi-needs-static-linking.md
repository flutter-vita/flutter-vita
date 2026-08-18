# ADR-0013: `dart:ffi` needs static linking, and that is the admission test

**Status:** Accepted
**Date:** 2026-08-18

## Context

A Flutter package reaches native code one of two ways, and on this port they
fail so differently that the distinction decides whether an app is worth
building at all.

**A platform channel** sends a named, asynchronous message that platform code
answers. If nothing answers, the call throws `MissingPluginException`. We can
answer it — in the embedder, or in Dart via a non-endorsed implementation. That
is [ADR-0009](0009-plugins-via-non-endorsed-vita-implementations.md), and
[`path_provider_vita`](../../packages/path_provider_vita) is 80 lines.

**`dart:ffi`** calls a C function directly, in-process and synchronously, at a
real address:

```dart
final lib = DynamicLibrary.open('libmpv.so');
final create = lib.lookupFunction<...>('mpv_create');
```

There is no message to intercept, because the package is not sending one. It
wants the operating system's dynamic loader to find a shared object on disk and
map it in. [ADR-0004](0004-static-single-binary.md) is one statically linked
`eboot.bin`, and there is no dynamic loader for homebrew. Our shim says so
honestly rather than failing somewhere less legible:

```c
void* dlopen(const char* filename, int flags) { return nullptr; }
char* dlerror(void) { return "Dynamic libraries are not supported on this platform"; }
```

This came up as a concrete decision, not a hypothetical: spotube was proposed
for the app corpus, and eleven of its twelve pre-`runApp` awaits go through FFI.

## Decision

**`dlopen` stays unimplemented.** There is nothing to point it at.

**The supported path for an FFI package is: statically link the C into the
eboot, then patch the package to look symbols up in the running binary rather
than opening a file.** Dart supports that shape. Two things stand in the way
today and both are honest work rather than research: our `dlopen` returns null
for *every* input, including the self-handle case that lookup needs, and each
package's binding has to be patched at its `DynamicLibrary.open` call.

**Admission test for the corpus, and triage rule generally — the question is
never "does it use FFI", it is these two:**

1. *Is the C library small enough to cross-compile and statically link?*
   sqlite3 is a single-file amalgamation and plausible. libmpv is a complete
   media player with ffmpeg inside it, and is not.
2. *Is the FFI call on the path to the first frame?* A lazily-opened database
   fails **after** first frame, as a visible in-app error. An FFI call in
   `main()` prevents the frame and leaves a black screen with nothing to read.

An app failing (1) is rejected — the work is a cross-compilation project and
teaches nothing about Flutter. An app failing only (2) is a judgement call.
An app passing both is ordinary corpus material.

This is what dropped spotube and admitted `flutter_manga_reader`, whose drift
and sqlite3 sit behind lazy initialisation while both of its *pre-frame*
blockers are plugins we have already implemented.

## Consequences

- The plugin survey's numbers understate the problem. It counts packages that
  need an implementation; it does not separate the ones we *can* implement from
  the ones that need a C library cross-compiled first. Those are different
  costs by an order of magnitude and the survey reports them as one.
- Any future "the corpus is unrepresentative" objection is partly correct by
  construction: FFI-heavy apps are systematically excluded, and the excluded set
  includes most of the database, media and machine-learning ecosystem.
- Rejecting an app on this basis is a *finding*, not a gap in the corpus, and
  belongs in the results table as one.
- The rule cuts the other way too: an FFI package whose C is small and whose
  calls are lazy is a *better* corpus candidate than a channel-heavy one,
  because it exercises the AOT and linking path rather than the plugin path.

## Revisit trigger

If several otherwise-admissible apps are blocked on the *same* C library, that
library becomes worth statically linking once, and the shim work to support
self-lookup becomes worth doing. sqlite3 is the obvious first candidate: it is
one C file, and drift, sqflite and isar all land on it.

## Related

[ADR-0004](0004-static-single-binary.md) — the reason there is no loader.
[ADR-0009](0009-plugins-via-non-endorsed-vita-implementations.md) — the path
that works for the other kind of package.
[ADR-0012](0012-app-corpus-as-measurement-instrument.md) — where the test is applied.
