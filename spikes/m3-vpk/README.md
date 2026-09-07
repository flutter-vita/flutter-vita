# m3-vpk — the Flutter Vita `.vpk`

Where the engine's ninja output meets Phase 1's `vita_create_self` pipeline.

```bash
export VITASDK=$HOME/vitasdk
./spikes/m3-vpk/build.sh
```

Three steps, each checking its own exit status: build the embedder objects,
run `gen_snapshot` over an app kernel, then link and package. **Do not add a
step without a check** — Phase 1 lost time three separate times to a step that
failed while the pipeline reported success (`ninja | grep` returning grep's
status, a missing check, and a stale tool that ran after its rebuild failed).

## Why a glob, again

GN emits `source_set`s whose objects link directly; there is no single archive
to point at. M1 globbed ~500 objects, this globs ~2700. Two traps come with
that:

- **`vita_link_check.o` has its own `main()`.** It and `vita_embedder.o` are
  both in the tree, so the glob is filtered. Without the filter the error is a
  duplicate `main`, which reads as a mistake in our code rather than two objects
  that were never meant to meet.
- **Host objects.** ninja writes host-toolchain output under `clang_arm64/`,
  which this glob does not reach. If that ever changes, an ARM linker starts
  being fed Mach-O and the failure will at least be loud.

## Title ID

`FVTA00004`. `FVTA00002` is M1 and `FVTA00003` the receiver — see
`spikes/vita-tooling/README.md`. Note `FVTA00002` currently holds a *receiver*
binary, so the "Flutter Vita M1" icon launches a receiver until someone runs
`./dev.sh cycle` from `spikes/m1-vpk`.

## What is not in the package yet

- **`flutter_assets`.** The embedder points at `app0:/flutter_assets` and
  nothing puts a bundle there, so asset loading will fail on the first run. That
  is expected: the first run is asking whether anything reaches the screen.
- **`icudtl.dat`.** Same — pointed at, not shipped. ICU's data is ~10 MB and
  slimming it is still on the Phase 2 list.
