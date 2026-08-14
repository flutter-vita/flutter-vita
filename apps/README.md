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

## `corpus/` — gitignored

Real third-party apps, cloned for bug-finding. The checkouts are disposable and
are not committed; `corpus/manifest.txt` is, because a bug found in an app you
cannot name again is a bug you cannot regression-test.
