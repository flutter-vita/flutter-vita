# Test apps patches

One patch series per app in [`test-apps/manifest.txt`](../manifest.txt),
applied to that app's pinned commit. No third-party source lives in this
repository; a diff against a pinned upstream is a complete and reproducible
description of what had to change.

**These are on their way out.** An app whose changes we carry should be our
fork of it, with the changes as commits on `vita-<flutter>`, the way the port
itself works ([ADR-0021](../../../docs/adr/0021-the-port-is-commits-not-patches.md)).
A patch file cannot be read in the file it changes, and it drifts from the
checkout without saying so. LocalSend moved on 2026-09-23 to
[flutter-vita/localsend](https://github.com/flutter-vita/localsend); keklist,
manga_reader and wonderous have not moved yet.

**Patch count and lines changed are the score** ([ADR-0012](../../../docs/adr/0012-test-apps-as-measurement-instrument.md)).
Pass/fail is not available to us: the `_vita` dependency lines of ADR-0009
are themselves an app edit, so no app here runs unmodified and the only
honest question is *how much* had to change. Since 2026-09-18 the build
generates the plugin registrant, so the `registerWith()` calls left the
series; wonderous and manga_reader are one pubspec hunk each.

Apply with `git apply` from inside the app's checkout.

## Naming

`<app>-NNNN-<what>.patch`, numbered in the order they were needed, which is also
the order the app failed in.

## localsend, now a fork

Kept here because the finding outlives the patch file. "Open" and "Show in
folder" both called `open_filex`, which takes its Linux branch here and
`DynamicLibrary.open('libc.so.6')` to reach `system()`. It **throws** rather
than returning a failure, so the app's own `CannotOpenFileDialog` was never
reached and the tap did nothing at all.

The change catches that, and adds a button that opens VitaShell in the file's
folder through the `vita/shell` channel added to the embedder in the same
commit. The string on that button is a literal rather than a slang key: adding
one means regenerating the whole catalogue for a control that exists on one
platform.

It is the commit `vita: an opened file has somewhere to go` in
[flutter-vita/localsend](https://github.com/flutter-vita/localsend) now.

## A wrinkle worth knowing

Some of these touch files the upstream app **gitignores** — `keklist-0001` adds
a `dotenv` the real app keeps out of version control because it holds keys. A
plain `git diff` will not produce such a patch; it needs `git add -f -N` first.
That is a property of the app, not of the tooling.
