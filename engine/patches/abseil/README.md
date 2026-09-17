# Abseil patches

Against the `third_party/abseil-cpp` DEPS entry of the Flutter monorepo at
`3.44.8`. Abseil is not optional here: `//flutter/flow` and the non-rendering
parts of Impeller depend on it, so it is in the graph even with
`impeller_supports_rendering = false`.

| # | Patch | What it does |
|---|---|---|
| 0001 | [vita-has-no-elf-introspection-or-tm-gmtoff](0001-vita-has-no-elf-introspection-or-tm-gmtoff.patch) | Two portability exclusions |

## Applying

```bash
cd third_party/flutter/engine/src/third_party/abseil-cpp
git apply ../../../../../patches/abseil/0001-vita-has-no-elf-introspection-or-tm-gmtoff.patch
```

---

## 0001 — no ELF introspection, no `tm_gmtoff`

Both changes add `__vita__` to a list upstream already maintains for exactly
this purpose, which is the cheapest kind of port there is.

**`absl/debugging/internal/elf_mem_image.h`** gates itself on `__ELF__` minus a
list of platforms — OpenBSD, QNX, VxWorks, Xtensa and others — whose ELF support
lacks glibc's symbol extensions. The Vita belongs on that list: VitaSDK has no
`<link.h>` and no `dl_iterate_phdr`. Excluding it also disables
`ABSL_HAVE_VDSO_SUPPORT`, which derives from it.

This costs nothing real. Homebrew is one statically linked `eboot.bin` with no
loaded objects to enumerate, and Phase 1 already found that Dart's own
`GetAppDSOBase` had the same problem for the same reason.

**`absl/time/internal/cctz/src/time_zone_libc.cc`** picks how to read a UTC
offset out of `struct tm`. newlib only gives `struct tm` the `tm_gmtoff` and
`tm_zone` extension fields when `__TM_GMTOFF` and `__TM_ZONE` are defined, and
VitaSDK's build defines neither — so the default branch, which probes for those
fields, cannot work.

The Vita joins the `__native_client__ || __myriad2__ || __EMSCRIPTEN__` branch,
which uses the `_timezone` and `_tzname` globals that VitaSDK *does* export.
The tradeoff is the one those platforms already accept: **the DST offset is
assumed to be exactly one hour.** Worth remembering alongside the parked NTP
work in `experiments/vita-ntp/` — the Vita's wall clock is already approximate, and
this makes its timezone handling approximate too.
