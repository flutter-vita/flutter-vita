# How to help

One person made this port, for one console. This had an effect on the code. The
sharpest edges are where an assumption was correct for one machine only.

We want help. The most useful help is not the help you expect.

## The most useful thing you can do

**Operate a Flutter application that we did not write. Tell us what failed.**

The application in `samples/gallery` gives a good score. But the persons who
wrote it also wrote the port, so it tests only what we knew to test. A real
application finds what we cannot see.

Get an application from pub.dev or from GitHub. Point `flutter-vita run` at it.
Then make an issue and tell us what occurred.

A good report has the name of the application, its commit, and one of these:

- **It did not build.** Give the output of the compiler or the linker, and the
  last 30 lines.
- **It built, but it did not start.** Give `flutter-vita logs`. Give the crash
  dump if there is one. `tools/analyse-crash.sh` puts the symbols into it.
- **It operated, but it looked incorrect.** Give `flutter-vita screenshot`, and
  tell us what you expected.
- **It operated, but it was slow.** Tell us which screen, and what you did.

We cannot correct a fault that we cannot cause again. "Wonderous is broken" does
not let us cause it again. This does: "Wonderous at `a1b2c3d`. The screen is
empty after the splash. The log stops at
`MissingPluginException(getApplicationDocumentsDirectory)`."

## You do not need a Vita to help

- **Host tools.** The CLI is Dart only. There is no Windows support at all, and
  you can start that work with no console.
- **Plugins.** The packages in `plugins/*_vita` are usual federated
  implementations. To write one, you use the `sce*` API in C, and Dart. Copy the
  shape of one that is there.
- **Documentation.** If a step in the README did not operate for you, that step
  is a fault in the README.

## If you have a Vita

You must have HENkaku and [VitaSDK](https://vitasdk.org).

You do **not** need taiHEN, a kernel plugin, a card change, or VitaShell. If a
step tells you to use one of them, that step is old. Tell us.

The console does not need a special condition. The bridge holds a TCP port,
and everything goes through it.

## Rules that came from failures

**Real hardware is the only truth.** Vita3K is useful to make changes quickly,
but its performance numbers have no value. The numbers from QEMU also have no
value. If a measurement is the reason for a change, take that measurement on a
console.

**The engine tree is the fork's branch.** `third_party/flutter` is
[flutter-vita/flutter](https://github.com/flutter-vita/flutter) on branch
`vita-3.44.8`, so an engine change is a commit there, and `git log` and
`git blame` answer for it. The five dependencies that also change are forks
of the same kind, named in `DEPS`. There are no patch files. Use
`tools/engine-tree.sh --verify` to check the tree and the five. Do not do `git checkout` of another revision in `third_party/`:
the other trees there come from other projects, and a checkout removes
work that is not committed.

**A version change is a project, not maintenance.** Flutter 3.44.8 is not an
arbitrary choice. It is the version that has prebuilt 32-bit ARM engine
binaries. To move it is work with a cost. Calculate the cost first.

**A number with no method is not a result.** Measure frame times with
[flutter-vita-bench](https://github.com/flutter-vita/flutter-vita-bench), so
that the next person can do the measurement again. It compares each run with
a baseline and tells you which scenes got slower.

## Before you change something large

Read the ADR first. Each decision in this port has a record in
[docs/adr/](docs/adr/README.md), with the forces behind it and what must change
for it to be examined again.

Some decisions look arbitrary and are not. Skia and not Impeller, AOT and not
JIT, one static binary and not shared libraries: each has a record, and each
record names the measurement that closed it. If you disagree with a decision,
disagree with its ADR. That is what they are for.

## Code

Write in the style of the file you change. The C is C11. The Dart is clean under
`flutter analyze`. Both agree with the code near them.

Comments tell you **why**. The best comments name a measurement and its date. A
comment that says again what the code says is noise. This comment is the reason
that the next person does not delete the loop: *this loop tries four times,
because the shell refuses `psgm:play` while it closes the old process. Measured
2026-09-08.*

Commit messages have the form `area: what changed`. Use lower case. Do not put a
full stop at the end. The subject tells what changed. The body tells what it
cost to find out.

## Pull requests

Tell us what you changed, and how you know that it operates.

Use the right branch. Our own repositories (the tool, the embedder, the
packages and the bench) have one branch, `main`. Each fork has one branch for
each Flutter version, now `vita-3.44.8`. A Flutter upgrade adds a new fork
branch, `vita-<version>`, and changes `versions.json` on `main`. A release is a
tag, `<flutter>_<ours>`, and not a branch.

If your change touches the console, tell us which console and which firmware. If
it touches performance, attach the output of the bench.

A small and complete change is better than a large and almost complete change. A
pull request that corrects one plugin is more useful than one that moves the
tree around.

We accept your contribution under BSD-3-Clause, the licence in
[LICENSE](LICENSE). A change to the engine or to one of its dependencies is
different: it is a derivative of that project and it keeps that project's
licence. It belongs in the fork, not here. [NOTICE](NOTICE) says which is
which.

## Security

If you find something that looks like a security fault, make a usual issue.

This is homebrew for a console that Sony no longer supports. There is no embargo
process, and nothing here is a trust boundary. Do not send anything that you do
not want in public.
