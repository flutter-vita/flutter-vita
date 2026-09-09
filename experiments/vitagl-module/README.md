# Can vitaGL be a loadable module instead of a static link?

vitaGL is LGPL-3.0-or-later and the build puts it inside every `eboot.bin`.
A static link of an LGPL library obliges whoever ships the binary to also
provide the material to relink it with a different version of that library.
That obligation lands on every developer who ships an app built with this
toolchain, which is not a thing a toolchain should do to its users.

LGPL-3 section 4(d)(1) removes the obligation for a *shared library mechanism*,
described as one that uses a copy of the library already present on the user's
system and operates properly with a modified version of it. A `.suprx` at
`ux0:data/flutter-vita/`, loaded by every application, is that.

Three questions decide whether this is possible. This experiment answers the
first.

## 1. Can VitaSDK build a user module, and can an UNSAFE app load and call it?

**Yes. Measured on hardware 2026-09-09.**

```
load     ux0:data/flutter-vita/spike.suprx
  uid    0x4002006D
  status 0x00000000
  call   spike_add(2,3) = 5 OK
  unload 0x00000000 (stop 0x00000000)
```

The application carries an import, not a copy:

```
.vitalink.fstubs.FlutterVitaSpike     16 bytes
.vitalink.fstubs.SceLibKernel        496 bytes
```

Sixteen bytes, sitting beside the system libraries. `spike_add` calls
`sceKernelGetProcessTimeWide`, and the application imports that symbol zero
times, because the call happens inside the module.

## 2. Does SceShaccCg work from inside a module?

Not answered yet. This is the one that decides it. vitaGL compiles every shader
at run time through vitashark, which calls SceShaccCgExt, which patches
SceShaccCg inside the process using taiHEN's `*ForUser` hooks. Whether those
hooks behave when the caller is a separate module is unknown.

## 3. Does the shader cache still find its path?

Not answered yet. Cheap once 2 is known.

## Three toolchain traps, all of which will happen again with vitaGL

**`vita_create_stubs` parses the library name out of the YAML by text match.**
A comment at the top of `exports.yml` becomes the library name, and CMake fails
with a target name containing your prose. Keep that file free of comments.

**A module needs `-nostartfiles`.** Without it `crt0` is linked and the build
fails on an undefined `main`, which a module does not have. `-nostdlib` is too
much: it also drops libc, and then there is no `.vitalink` section either.

**`vita_create_self` is a macro, not a function.** Its `CONFIG` branch appends
`-e <exports.yml>` to `VITA_ELF_CREATE_FLAGS` in the caller's scope, so every
later call in the same file inherits it. The application was built as a module
and rejected with `Could not find symbol 'module_start'`. Reset the variable
between calls.

**A module that imports nothing is not a Vita binary.** `vita-elf-create` says
so outright: no `.vitalink` sections, probably not a Vita binary. Any real
library imports something; this one calls `sceKernelGetProcessTimeWide` so that
it does.

## Running it

```bash
./experiments/vitagl-module/build.sh --run
```

Installs the module to `ux0:data/flutter-vita/spike.suprx`, registers
`FVTA00002` if the console does not have it, runs the app, and prints the
report. The app hands the console back to the receiver on its way out.
