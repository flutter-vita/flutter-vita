# ADR-0001: AOT-only; JIT is permanently out of scope

**Status:** Accepted (rationale corrected 2026-08-06 — see *Correction* below)
**Date:** 2026-08-06 (back-filled from `Flutter Vita Plan.md` §1)

## Correction to the original premise

The plan justified this decision with: *"Runtime code generation is forbidden
without kernel plugins."* **That premise is factually wrong.** VitaSDK exposes a
user-mode W^X mechanism in `psp2/kernel/sysmem.h`, requiring no taiHEN kernel
plugin:

- `sceKernelAllocMemBlockForVM(name, size)` — allocate a VM-domain block
- `sceKernelOpenVMDomain()` — put all VM-domain blocks in the **writable** state
- `sceKernelCloseVMDomain()` — put them in the **executable** state
- `sceKernelSyncVMDomain(uid, data, size)` — flush I-cache for the region

> **Corrected 2026-08-07 by hardware.** The VitaSDK header summarises these as
> "makes memblocks executeable" / "non executeable", and this ADR originally
> repeated that. It is misleading: Track A run 2 faulted writing to a VM block
> with the domain closed, proving the block is not writable by default. The JIT
> example in the VitaSDK docs had it right all along — Open is the *write*
> state, Close is the *execute* state. Plain W^X.
>
> Measured limits: VM blocks have a **1 MiB minimum** (4 KiB, 16 KiB, 64 KiB and
> 256 KiB are all rejected with `SCE_KERNEL_ERROR_ILLEGAL_MEMBLOCK_SIZE`) and a
> **16 MiB maximum**, confirmed exactly.

This is the documented mechanism Vita dynarecs and emulator ports use. Userland
JIT on Vita is possible.

The decision to be AOT-only still stands, but for different and better reasons.
Keeping a wrong premise in an ADR is worse than having no ADR, because it makes
the decision look fragile to anyone who later discovers the VM domain API.

## Context (corrected)

Three properties of the VM domain mechanism make it unsuitable for Dart's JIT,
as opposed to merely inconvenient:

1. **`sceKernelAllocMemBlockForVM` is capped at 16 MiB per block** (documented in
   VitaSDK). Dart's JIT code heap for a Flutter app would exceed this, and the
   blocks are not guaranteed contiguous.
2. **`Open`/`CloseVMDomain` are process-global W^X toggles, not per-page
   protections.** Dart's JIT writes new code on a compiler thread while other
   threads execute existing code. Flipping the whole domain to writable in
   order to compile one method makes *all* JIT code non-executable for that
   window — every running thread would fault. This is a structural mismatch,
   not a tuning problem, and hardware confirms the states are genuinely
   exclusive rather than additive.
3. The Dart JIT also needs the Dart *compiler* on device, roughly doubling the
   binary and the memory footprint, on a device where both are scarce.

Separately, JIT would buy hot reload and debug mode — real value — but only
after the entire AOT path already works.

## Decision

Target Dart AOT exclusively for v1. Snapshots are produced on the host by
`gen_snapshot` targeting armv7. The device runs the AOT *runtime* only.

## Consequences

- No hot reload, no DevTools, no debug/profile modes. The inner development loop
  is a full host rebuild plus redeploy to hardware. **Iteration cost is the
  dominant DX risk of this project, not a footnote.**
- `virtual_memory_vita.cc` never needs page-permission changes for the Dart heap.
- `dart:mirrors` unavailable (already true for Flutter AOT everywhere).
- Tree shaking is mandatory, which helps the binary size budget.
- **Important non-consequence:** the VM domain API remains available and is
  probably the right way to load AOT *instructions* at runtime. Being AOT-only
  does not mean the binary must be self-contained. See
  [ADR-0005](0005-aot-snapshot-delivery.md).

## Revisit trigger

If Sony's per-block VM cap turns out to be lifted, *and* a per-page protection
path is found, *and* the AOT path is shipped and stable — then debug-mode JIT
becomes a plausible v2 project. All three conditions, in that order.

## Related

[ADR-0004](0004-static-single-binary.md), [ADR-0005](0005-aot-snapshot-delivery.md)

## Sources

- https://docs.vitasdk.org/kernel_2sysmem_8h_source.html
- https://docs.vitasdk.org/group__SceSysmemUser.html
