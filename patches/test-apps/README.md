# Test apps patches

One patch series per app in [`apps/test-apps/manifest.txt`](../../apps/test-apps/manifest.txt),
applied to that app's pinned commit. No third-party source lives in this
repository; a diff against a pinned upstream is a complete and reproducible
description of what had to change.

**Patch count and lines changed are the score** ([ADR-0012](../../docs/adr/0012-test-apps-as-measurement-instrument.md)).
Pass/fail is not available to us: ADR-0009's `registerWith()` is itself an app
edit, so no app here runs unmodified and the only honest question is *how much*
had to change.

Apply with `git apply` from inside the app's checkout.

## Naming

`<app>-NNNN-<what>.patch`, numbered in the order they were needed, which is also
the order the app failed in.

## localsend-0002

Worth a note because it reaches outside the app. "Open" and "Show in folder"
both called `open_filex`, which takes its Linux branch here and
`DynamicLibrary.open('libc.so.6')` to reach `system()`. It **throws** rather
than returning a failure, so the app's own `CannotOpenFileDialog` was never
reached and the tap did nothing at all.

The patch catches that, and adds a button that opens VitaShell in the file's
folder through the `vita/shell` channel added to the embedder in the same
commit. The string on that button is a literal rather than a slang key: adding
one means regenerating the whole catalogue for a control that exists on one
platform.

## A wrinkle worth knowing

Some of these touch files the upstream app **gitignores** — `keklist-0001` adds
a `dotenv` the real app keeps out of version control because it holds keys. A
plain `git diff` will not produce such a patch; it needs `git add -f -N` first.
That is a property of the app, not of the tooling.
