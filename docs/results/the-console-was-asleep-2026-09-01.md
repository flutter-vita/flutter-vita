# The console was not dropping off the network. It was going to sleep.

Four times on 2026-09-01 the Vita stopped answering mid-session, always while a
build was running and nobody was touching it. Every time it was recorded as the
Wi-Fi dropping, which this console genuinely does often enough to have its own
note. Every time that was wrong.

The user said so plainly -- *"its cannot be dropped off several times already,
its not because of wifi"* -- and checking properly took two commands.

## What the check got wrong

The reachability test was `ping flutter-vita.local`. Three things hide behind a
failure of that:

1. The console is off the network.
2. The console is answering but mDNS is not.
3. **The app is gone**, and the mDNS responder went with it -- `fvita-mdns` is a
   thread inside the app, not a system service.

Only the first was ever reported. When the name failed, the conclusion was
"console offline", and the evidence for it was the same single failed lookup.

The correct check separates them, and did:

    ping flutter-vita.local        -> answers
    nc 192.168.0.32 1339           -> silent          (the app)
    nc 192.168.0.32 1341           -> pong, bridge    (the bridge)

The console was up. The app was not.

## Why the app was gone

`ux0:data/flutter-vita/receiver-state.txt`:

    log 09-01 16:45:22 ---- bridge FVTA00001 up ----
    log 09-01 16:45:22 - left FVTA00002

and the newest core dump on the card was from 09:23 that morning. So the app had
not crashed. It had stopped, hours after the last dump, with no fault recorded.

`sceKernelPowerTick` is what tells the Vita a user is still present. Without it
the console suspends on its idle timeout, and suspending takes the network with
it. Grepping for it found exactly one caller:

    experiments/m1-vpk/src/main.c:216:  sceKernelPowerTick(SCE_KERNEL_POWER_TICK_DEFAULT);

with a comment that describes this exact failure, written months earlier:

> Keep the console awake in both senses: no suspend (it would kill the network
> and the deploy loop with it) and no system-driven display off.

Nothing in `vita_embedder.cc` and nothing in `templates/vita-app` called it. The
M1 experiment solved this and the Flutter app path never inherited the fix. Every
stretch of ten-plus minutes spent building -- which is most of them -- was long
enough for the console to put itself away.

## The fix

The platform loop now ticks once per iteration, about sixty times a second,
which is what the M1 experiment does and costs nothing measurable: the call resets a
timer.

It is behind `flutter_vita_keep_awake`, weak-defaulted to 1 in the embedder, the
same shape as `flutter_vita_debug_overlay`. A handheld that never sleeps while an
app is open is user-hostile and a shipping build should be able to say so. What
must not happen is the console sleeping under a file transfer or a benchmark
run.

## What else this explains

**Blocker 6, wakelock_plus throwing on every toggle**, is the same hole seen from
the Dart side: localsend asks to keep the screen awake during a transfer and
nothing answers, because nothing on this port implements staying awake. A
`wakelock_plus` implementation now has something real to call.

**It does not explain the memory leak.** The heap growth is reproducible inside a
single 90-second run with the console plainly awake.

## What to be careful about now

`tools/deploy.sh` reports *"nothing is answering — a hard crash, so this one
needs a tap"* when a port goes quiet, and that message has the same three
meanings the ping did. A quiet app port with a live bridge port is the bridge
having taken over, which is a different event from a crash and a very different
event from the console being away.
