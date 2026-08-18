# Corpus patches

One patch series per app in [`apps/corpus/manifest.txt`](../../apps/corpus/manifest.txt),
applied to that app's pinned commit. No third-party source lives in this
repository; a diff against a pinned upstream is a complete and reproducible
description of what had to change.

**Patch count and lines changed are the score** ([ADR-0012](../../docs/adr/0012-app-corpus-as-measurement-instrument.md)).
Pass/fail is not available to us: ADR-0009's `registerWith()` is itself an app
edit, so no app here runs unmodified and the only honest question is *how much*
had to change.

Apply with `git apply` from inside the app's checkout.

## Naming

`<app>-NNNN-<what>.patch`, numbered in the order they were needed, which is also
the order the app failed in.

## A wrinkle worth knowing

Some of these touch files the upstream app **gitignores** — `keklist-0001` adds
a `dotenv` the real app keeps out of version control because it holds keys. A
plain `git diff` will not produce such a patch; it needs `git add -f -N` first.
That is a property of the app, not of the tooling.
