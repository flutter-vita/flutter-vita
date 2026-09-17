# BoringSSL patches

**Applies to a separate repository.** BoringSSL is a gclient dependency nested
inside the engine checkout at
`third_party/flutter/engine/src/flutter/third_party/boringssl/src`, and the
flutter tree gitignores it (`engine/src/flutter/third_party/.gitignore`, line
4). So a `git diff` from the flutter repo shows nothing for these files, and
the patch has to be generated and applied from inside the nested repo — the
same arrangement as
[`0005-zlib-no-armv8-on-vita`](../dart-sdk/0005-zlib-no-armv8-on-vita.patch) in
the Dart series.

Pinned at `b0ae229`, whatever the engine's DEPS resolves for the Flutter
revision in [VERSIONS.md](../../../VERSIONS.md).

| # | Patch | What it does |
|---|---|---|
| 0001 | [vita-entropy-backend](0001-vita-entropy-backend.patch) | Gives `CRYPTO_sysrand` a Vita implementation, without which TLS aborts the process |

## Applying

```bash
cd third_party/flutter/engine/src/flutter/third_party/boringssl/src
git apply ../../../../../../../patches/boringssl/0001-vita-entropy-backend.patch
```

## Why 0001 exists

BoringSSL supplies its own entropy and never calls Dart's, so the correct,
64-byte-chunked `sceKernelGetRandomNumber` in `runtime/bin/crypto_linux.cc` is
not in the TLS path at all.

`crypto/rand/internal.h` selects a backend from platform macros. Vita matched
none of them and fell through the `#else` to `OPENSSL_RAND_GETENTROPY`, whose
`CRYPTO_sysrand` calls `getentropy()` and `abort()`s on failure. Newlib has no
`getentropy`, so the first use of the RNG killed the process — silently, since
the `perror` beside the `abort` goes to a stderr nothing on this platform
reads.

Measured on hardware before the fix: an empty `SecurityContext` constructs, the
240 KB compiled-in CA bundle parses into an X509 store, and then
`SecureSocket.connect` takes the process down with no diagnostic of any kind.

The patch adds an `OPENSSL_RAND_VITA` branch ahead of `OPENSSL_LINUX` and
implements `CRYPTO_sysrand` over `sceKernelGetRandomNumber`, chunked to its
documented 64-byte maximum. It aborts on failure like every other backend
rather than degrading to a weaker source: a quietly weak CSPRNG is a worse
outcome than a loud dead process.

### Why it is in `urandom.cc`

It belongs in a `vita.cc` beside `trusty.cc` and `windows.cc`, and it is not
there because the engine's BoringSSL source list is **generated** — a new file
is a diff that regeneration silently erases. `urandom.cc` is already compiled
for every target with its body behind a macro, so a second gated body costs
nothing and cannot be lost.

### Two mistakes worth not repeating

`CRYPTO_sysrand_for_seed` does not exist in this version. The contract is
`CRYPTO_init_sysrand` and `CRYPTO_sysrand`, as `trusty.cc` shows in fifteen
lines; inventing the third produced a compile error reading *"should have been
declared inside 'bssl'"*, which sounds like a namespace problem and is not one.

After editing `internal.h`, rebuilding only `urandom.o` left a stale
`getentropy.o` in the archive still holding a `CRYPTO_sysrand` from the
previous macro state, and the app link failed on multiple definition. Every
object that includes `rand/internal.h` has to be rebuilt when the backend
selection changes. That failure was useful: it proved Vita had been on the
`getentropy` path all along rather than the `urandom` path first blamed.
