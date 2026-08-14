# Phase 7 — TLS, four causes deep and not finished

**Status: HTTPS does not work.** Plain HTTP does, and has since before this
phase started. What follows is what was fixed, what was measured, and what is
still unknown — written down because the unknown part is the useful part.

## Where it started

The [capability audit](phase-5-capability-audit.md) reported:

```
FAIL  net/HTTPS GET   Invalid argument(s): Secure Sockets unsupported on this platform
```

## Four causes, each hidden behind the one before

**1. `dart_disable_secure_socket = true`**, in our own `args.gn`. Almost
certainly set to get M2 linking. This is also why both `secure_socket_filter.o`
and `secure_socket_unsupported.o` were in the archive and the planning notes
called it a link-order ambiguity — it was not ambiguous, the switch made the
real one empty.

**2. Vita was excluded from the root-certificate gate.** The block reads
`if (is_linux || is_win || is_fuchsia)`, so Vita got neither the compiled-in
bundle nor `DART_IO_ROOT_CERTS_DISABLED`: `root_certificates_pem` stayed null
and `AddCompiledInCerts()` had nothing to add. Every request would have failed
verification against an empty trust store.
`dart_use_fallback_root_certificates = true` compiles Mozilla's bundle in —
`.rodata` grew 224 KB, against the ~240 KB the Dart source predicts.

**3. `security_context_linux.cc` was never routed for Vita.** The twelfth
`_linux.cc` to need it and the only one patch 0002 missed, because SSL was off
so nothing referenced it; the absent `TrustBuiltinRoots` surfaced only as a link
error once TLS was on. Its Vita branch skips the fifteen `/etc` probes that
cannot exist here.

**4. BoringSSL's entropy backend.** BoringSSL supplies its own and never calls
Dart's, so the correct, 64-byte-chunked `sceKernelGetRandomNumber` in
`crypto_linux.cc` was never in the handshake path.
[`patches/boringssl/0001`](../patches/boringssl/0001-vita-entropy-backend.patch)
adds a real one.

**Cause 4 was a sound hypothesis and did not fix the crash.** The reasoning was
that Vita fell through to `OPENSSL_RAND_GETENTROPY`, whose `CRYPTO_sysrand`
calls `getentropy()` — absent from newlib — and `abort()`s, which would be a
silent process death matching the symptom exactly. The patch shipped and was
verified in the linked binary: one `CRYPTO_sysrand`, six
`sceKernelGetRandomNumber` call sites, no `getentropy`. The handshake still
dies. Keep the patch — depending on an unexplained newlib `getentropy` was luck
rather than design — but it is not the bug.

## What the hardware says now

Probes split smallest-first, so the journal names the exact failing step:

| | |
|---|---|
| `tls/empty SecurityContext` | **PASS** — BoringSSL initialises |
| `tls/built-in roots` | **PASS** — 240 KB of PEM parses into an X509 store |
| `tls/handshake, no verify` | **crash** — no result line |
| `tls/SecureSocket handshake` | not reached |

The third one is the informative one. It uses an empty context with
`onBadCertificate` accepting everything, so it performs the full key exchange
and cipher negotiation but builds and walks no trust chain. **It crashes too.**

So certificate verification is exonerated, and the failure is in the handshake
itself. It is a hard crash, not a hang: the probe carries a 20-second timeout
and a 25-second outer ceiling, either of which would have produced a `FAIL`
line.

## Ruled out

- **Entropy.** Fixed, verified present in the binary, still crashes.
- **Certificate verification.** The no-verify handshake dies the same way.
- **Trust store contents.** Loading and parsing the bundle passes on its own.
- **Sockets and DNS.** Both pass, and plain HTTP returns `HTTP 200`.
- **The Vita's TLS 1.0/1.1 ceiling and iTLS-Enso.** That ceiling belongs to
  `sceSsl`, which the browser and system services use. We link BoringSSL and
  speak TLS ourselves over raw `sceNetSocket`, so it is not our ceiling and no
  plugin is required. Only the certificate half of that problem was ever ours,
  and cause 2 is the answer to it.
- **ARMv8 crypto extensions — probably.** This was the leading suspect by
  analogy with [the zlib patch](../patches/dart-sdk/0005-zlib-no-armv8-on-vita.patch),
  which exists because the Cortex-A9 has NEON but not the ARMv8 CRC32 and
  crypto extensions. BoringSSL is built with `OPENSSL_STATIC_ARMCAP` and none of
  the `OPENSSL_STATIC_ARMCAP_AES` / `_PMULL` / `_SHA*` sub-macros, so
  `CRYPTO_is_ARMv8_*_capable()` resolves through `OPENSSL_get_armcap()` to zero
  and the ARMv8 paths should never be selected. NEON *is* enabled via
  `__ARM_NEON`, and NEON is genuinely present on this CPU. Marked probable
  rather than certain because it has not been tested by disabling it.

## Stack: investigated, and it is not obviously the problem

`fml::Thread::GetDefaultStackSize()` returns **2 MB**, and every fml thread is
created with it via `pthread_attr_setstacksize`. Dart's own threads get 512 KB
the same way, set explicitly in `os_thread_vita.cc`. A TLS handshake needs tens
of kilobytes. So the leading hypothesis from the previous pass is weak, and no
longer leading.

## What the dumps say, now that they have been counted

52 `psp2core` files on the device: **36 complete, 16 truncated**. So the dump
pipeline works most of the time, and the truncation is not a broken tool.

The 16 truncated ones cluster, and today's cluster is ours. Every
TLS-handshake crash truncated. One crash today did **not** — the teardown crash
after `== run complete ==`, from the same binary an hour earlier, which wrote a
complete 363 KB dump and parses fine.

**That contrast is the finding.** The same process, same build, same console:
an ordinary fault produces a readable dump, and the handshake crash does not.
Whatever kills the handshake also stops the core writer finishing — which is a
resource-exhaustion signature rather than a plain bad pointer, and points away
from illegal instructions and towards memory.

The complete one is worth recording even though it is a different bug: **data
abort exception, R0 = 0x0**, a null-pointer dereference during teardown.
Function names from it are discarded — the only ELF still on disk is from a
later build, its PC does not match the disassembly range, and this project has
already been burned once by plausible wrong symbols.

## Memory: measured, and it is not the problem

The embedder logs `sceKernelGetFreeMemorySize` alongside its frame counter.
Across a full probe run, up to and including the frame before the crash:

```
present #0    free user=93184K   cdram=112640K   phycont=26624K
present #31   free user=91136K   cdram=112640K   phycont=26624K
```

**2 MB consumed for the entire run** — including parsing the 240 KB CA bundle
into an X509 store — with **89 MB still free** when the process died. `cdram`
and `phycont` never move at all. Exhaustion is ruled out, and with it the
inference drawn from the truncated dumps: the core writer failing is a symptom
of something else, not of a full heap.

Worth recording how nearly this measured nothing. The first version logged
every sixtieth frame, which is right for an app that paints continuously and
useless for this one: the conformance app repaints once per probe and reaches
about thirty-five frames in its whole life, so frame sixty never arrived and
the run produced a single sample, at startup, before anything had happened.
Painting is the only clock that log has, so the rate has to match the app being
watched rather than the display.

## What is actually left

Everything cheap has been eliminated by measurement rather than argument:

| | |
|---|---|
| Secure sockets disabled | fixed |
| Root certificates missing | fixed |
| `security_context_linux.cc` unrouted | fixed |
| Entropy `abort()` | fixed — **and not the bug** |
| Certificate verification | ruled out — the no-verify probe dies identically |
| Stack | ruled out — 2 MB fml threads, 512 KB Dart threads |
| Memory | ruled out — 89 MB free at the crash |

That leaves the crypto itself, and one thing was dismissed too early.
`CRYPTO_is_NEON_capable()` returns 1 **unconditionally** on this build, because
`-mfpu=neon` defines `__ARM_NEON` and the inline function short-circuits on it.
So every handshake executes hand-written NEON assembly on a Cortex-A9 that has
never run any of it.

The earlier dismissal was of ARMv8 *extensions* — AES, PMULL, SHA — and that
still holds: those resolve through `OPENSSL_get_armcap()` to zero. It said
nothing about the ARM assembly in general, which is selected separately and is
very much in the path.

[`patches/flutter-engine/0007`](../patches/flutter-engine/0007-boringssl-no-asm-for-vita.patch)
puts Vita on BoringSSL's `no_asm_config` — pure C, no hand-written assembly
anywhere. **It is a diagnostic, not a decision.** If it fixes the handshake the
real change is narrower, because pure-C bignum and curve25519 on a 444 MHz A9 is
a real per-handshake cost. If it does not, the patch comes back out.

## Superseded hypothesis, kept for the record

**Memory.** The truncation contrast above is the evidence: the handshake crash
takes the core writer with it, and an ordinary null dereference in the same
binary does not.

This app is large before TLS — 14.6 MB `.text`, 3.5 MB `.rodata` — and the
build does not request extended memory in `param.sfo`. The compiled-in CA
bundle adds 224 KB of `.rodata` and, once parsed, an X509 store holding on the
order of 150 certificates as live objects, which is several times that in heap.

The cheapest test is not a code change: **request extended memory** and see
whether the handshake survives. Whether homebrew reliably receives it is
already an open question in Phase 0.5, so the experiment settles two things.

The next cheapest is to stop testing against the open internet. A TLS server on
the LAN with a self-signed certificate and no verification separates *TLS at
all* from *real-world chains, TLS 1.3, and large cipher negotiations*. The Vita
dials out, so nothing about the macOS Local Network restriction blocks it.

## Cheaper diagnosis than any of this would have been

No usable crash dump was obtained in this phase. Every `psp2core` file arrived
as `.psp2dmp.tmp` and truncated — the core writer never finishes on this crash
class — and `vita-parse-core` fails on the ELF notes. Every conclusion above
came from the journal file naming the probe that was running, which cost one
line of Dart and works when nothing else does.

The `.tmp` suffix also broke `newest_dump()` in `dev.sh`, whose pattern anchored
on `\.psp2dmp` and silently produced a filename that does not exist; that failure
reads as a missing dump and sent this investigation to an unrelated app's
month-old crash before the real one was found. Fixed.

## Related

- [Phase 5 audit](phase-5-capability-audit.md) — where the failure was first measured
- [patches/boringssl](../patches/boringssl/README.md) — the entropy backend and why it lives where it does
