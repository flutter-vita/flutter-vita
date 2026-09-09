# Contributing

This port was built by one person for one console. That shaped it, and the
sharpest edges are where an assumption held for exactly one machine. Help is
wanted, and the most useful help is not what you might expect.

## The most useful thing you can do

**Run a Flutter app we did not write, and tell us what broke.**

`apps/conformance` reports a clean score because the people who wrote it also
wrote the port, so it tests what we already knew to test. A real app finds the
things we cannot see. Clone something off pub.dev or GitHub, point
`flutter-vita run` at it, and open an issue with what happened.

A good report has the app, the commit, and one of:

- **It did not build.** The compiler or linker output, and the last 30 lines.
- **It built and did not start.** `flutter-vita logs`, plus the crash dump if
  there is one — `tools/analyse-crash.sh` symbolicates it.
- **It ran and looked wrong.** `flutter-vita screenshot`, and what you expected.
- **It ran and was slow.** Which screen, and what you were doing.

We cannot fix what we cannot reproduce, and "Wonderous is broken" is not
reproducible. "Wonderous at `a1b2c3d`, blank screen after the splash, log ends
at `MissingPluginException(getApplicationDocumentsDirectory)`" is.

## You do not need a Vita to help

- **Host tooling.** The CLI is plain Dart. Windows support is missing entirely
  and needs no console to start on.
- **Plugins.** `packages/*_vita` are ordinary federated implementations. Writing
  one against the `sce*` API is C and Dart, and the shape is already there to
  copy.
- **Docs.** If a step in the README did not work for you, that is a bug in the
  README.

## If you do have a Vita

You need HENkaku and [VitaSDK](https://vitasdk.org). You do **not** need
taiHEN, a kernel plugin, a card swap, or VitaShell in the loop — if a step asks
for one of those, it is out of date and we want to know.

The console never needs to be in a special state. The receiver holds a TCP port
and everything goes through it.

## Ground rules that came from being burned

**Hardware is the only ground truth.** Vita3K is useful for iteration and its
performance numbers mean nothing. So do numbers from QEMU. If a change is
justified by a measurement, the measurement was taken on a console.

**Never `git checkout` inside `third_party/`.** Those trees are vendored and
patched. `patches/` is the real artifact; `tools/apply-patches.sh --verify`
checks the series and the trees still agree. A checkout in there wipes the
patches and has left empty files behind.

**Pins are a project, not maintenance.** Flutter 3.44.8 is not arbitrary: it is
what prebuilt 32-bit ARM engine binaries exist for. Moving it is a piece of
work with its own cost, priced before it starts, never a version bump.

**A number without a method is not a result.** Benchmarks go through
`tools/bench.sh` so the next person can rerun them. The gate grades build,
raster and stall together, because grading worst-frame alone produced three
wrong answers in one report.

## Code

Match the file you are editing. The C is C11 and the Dart is `flutter analyze`
clean; both are formatted the way their neighbours are.

Comments explain **why**, and the good ones name what was measured and when. A
comment that restates the code is noise; a comment saying *this loop retries
four times because the shell refuses `psgm:play` while it is still tearing the
old process down, measured 2026-09-08* is the reason the next person does not
delete the retry.

Commit messages are `area: what changed`, lower case, no trailing full stop. The
subject says what changed and the body says what it cost to find out.

## Pull requests

Say what you changed and how you know it works. If it touches the device, say
which console and which firmware. If it touches performance, attach the bench
output.

Small and finished beats large and nearly. A PR that fixes one plugin is more
useful than one that reorganises the tree.

## Reporting something that looks like a security issue

Open a normal issue. This is homebrew for a console Sony stopped supporting;
there is no embargo process and nothing here is a trust boundary. Do not send
anything you would not put in public.
