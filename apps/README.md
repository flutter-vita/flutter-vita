# Apps

## `conformance/` — committed

What this port can actually do, measured on hardware rather than assumed. It
runs one probe per capability and renders the results on the panel.

**The screen is the reporting channel on purpose.** Files, sockets and `print`
are all things being tested here, so reporting through any of them would be
circular. Rendering and the dev server's `shot` are what M3 already proved.

Probes are ordered safest-first, so that a native crash — which takes the app
down and loses the screen with it — still tells you something: everything
visible passed, and the first missing row is the one that killed it.

## `gallery/` — committed

What this port *looks like*, judged by eye. Split from `conformance/` because
the two produce a verdict differently: conformance computes a boolean about
itself and reports 45/45 with no human involved, which is what makes it
runnable on every deploy. A widget either looks right or it does not, and no
app can assess that about itself.

## `corpus/` — checkouts gitignored, manifest committed

Real third-party apps, cloned for bug-finding — the bugs the conformance app
structurally cannot find, because it was written by the people who wrote the
engine. Checkouts are disposable; `corpus/manifest.txt` is not, because a bug
found in an app you cannot name again is a bug you cannot regression-test.

Five apps, one per axis, and one of them is a plugin-free **control** that must
pass. Without it, five failures cannot tell a broken port from a broken
harness. All five share one title id, and the deliverable is a patch series
under `patches/corpus/` — no third-party source enters this repository, and
lines-changed-to-first-frame is the score rather than pass/fail.

See [ADR-0012](../docs/adr/0012-app-corpus-as-measurement-instrument.md) for how
it is run and what it is allowed to conclude, and
[ADR-0013](../docs/adr/0013-ffi-needs-static-linking.md) for the test an app has
to pass to be admitted at all.
