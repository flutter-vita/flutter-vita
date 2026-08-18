# The abort is a newlib heap limit, not the memory budget

Both keklist and the gallery app abort after a while. The bail reason is
specific:

```
ux0:data/flutter-vita/bailout.txt:
emutls: memalign failed for thread_local storage
```

That is [emutls_vita.cc:233](../../third_party/sdk/runtime/platform/emutls_vita.cc),
the honest exit added when the 32-thread table bug was fixed — a `memalign` for
a `thread_local` slot returned NULL and the process left cleanly rather than
handing NULL to a caller that dereferences it unconditionally.

## Why it is not "out of memory"

The frame log records free memory every sixty frames, and across the run that
ended in this abort:

```
free user=88064K   ...   free user=86016K
```

**86 MB free**, and the whole run consumed 2 MB. The console was not short of
memory.

## What is actually full

`grep -rn '_newlib_heap_size_user' templates/ ` finds **nothing**. The variable
is not set anywhere in this project.

VitaSDK carves the C heap out of the process budget once, at startup, as a
fixed arena sized by that symbol — and applies a modest default when an app does
not define it. `sceKernelGetFreeMemorySize`, which is what the frame log prints,
reports the *process* budget and knows nothing about how much of it newlib was
given. So the two numbers can disagree completely, and here they do: the heap is
exhausted while 86 MB of the budget sits unclaimed because nothing ever asked
for it.

`malloc` returning NULL with plenty of free memory is exactly that shape.

## Why emutls is the one that reports it

Nothing special about TLS — it is simply a small allocation that happens
constantly, on a path with an explicit NULL check and a clean exit. Every other
allocation in the engine hits the same wall; most of them either crash less
legibly or are large enough to have failed earlier. emutls is the messenger.

Worth noting for the history: the two-session "non-deterministic crash" was a
32-entry table in this same file. This is a different bug at the same call site,
and the bail-out added during that investigation is what made it diagnosable in
one reading instead of two days.

## The fix, untested

Define `_newlib_heap_size_user` in the app template, sized against the extended
memory budget rather than the default. It is one line, and it needs measuring
rather than guessing: too large and the allocation fails at startup, too small
and this recurs later.

Unverified as of this writing — a full engine rebuild was in progress and
nothing could be packaged.
