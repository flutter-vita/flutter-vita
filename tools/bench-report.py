#!/usr/bin/env python3
"""Print the benchmark table and gate against the committed baseline.

ADR-0017. Two jobs, deliberately in one place: the table a person reads and
the pass/fail a script acts on come from the same numbers, so they cannot
disagree about what happened.
"""
import argparse
import json
import os
import sys

# ADR-0017 decision 8. Wide enough to absorb this console's thermal and Wi-Fi
# noise, tight enough to catch a real slowdown. Gates on worst-frame rather
# than mean, because worst-frame is the number the stall rule is made of.
MARGIN = 0.10

# Worst-frame is quantised: at 60 Hz a frame period is always a multiple of
# 16.67 ms, so the smallest change any scene can report is one vsync. Near
# 100 ms that is 17%, which means a flat 10% margin flags a single-step move as
# a regression -- and it did, three times at once, on 2026-08-24. A change
# smaller than the measurement's own resolution is not a change.
VSYNC_MS = 1000.0 / 60.0

# A scene has been sampled adequately when it ran long enough, not when it
# produced many frames. The first run on hardware graded route_hero "pass" off
# three frames -- worse than reporting nothing, because a green row is read as
# evidence. But gating on frame count alone then refused to grade
# blur_backdrop, which produced twelve frames across three seconds *because it
# is terrible*. Span is the honest test; the frame floor only rejects windows
# that are too short to contain an animation at all.
MIN_SPAN_MS = 1200
MIN_FRAMES = 5

RED = "\033[31m"
GREEN = "\033[32m"
DIM = "\033[2m"
OFF = "\033[0m"


def load(path):
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return json.load(f)


def scenes_of(doc):
    return {s["name"]: s for s in doc["scenes"]} if doc else {}


def fmt(v):
    return f"{v:.1f}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--baseline", required=True)
    ap.add_argument("--modes", default="sw gl")
    ap.add_argument("--write-baseline", action="store_true")
    ap.add_argument(
        "--frames", nargs="*", metavar="SCENE",
        help="print the slowest frames split by phase; no names means every "
             "scene that stalled")
    args = ap.parse_args()

    modes = args.modes.split()
    results = {m: load(os.path.join(args.out, f"{m}.json")) for m in modes}
    have = [m for m in modes if results[m]]
    if not have:
        print("no results to report", file=sys.stderr)
        return 2

    names = []
    for m in have:
        for s in results[m]["scenes"]:
            if s["name"] not in names:
                names.append(s["name"])

    # ---- the table -------------------------------------------------------
    # worst-frame first, because that is what the gate uses and what the stall
    # rule is derived from. The UI/raster split is the column that says whether
    # the GPU could help a red row at all.
    head = f"{'scene':<18}{'stresses':<11}"
    for m in have:
        head += f"{m + ' worst':>11}{m + ' stall':>11}{m + ' ui/ras':>13}{m + ' bad bld':>12}"
    if len(have) == 2:
        head += f"{'gpu':>8}"
    print(head)
    print("-" * len(head))

    def sound(scene):
        """Enough frames over enough time for its numbers to mean anything."""
        if not scene or scene.get("error"):
            return False
        return (scene["frames"] >= MIN_FRAMES
                and scene.get("span_ms", 0) >= MIN_SPAN_MS)

    def bad_build(scene):
        """UI-thread time in a typical bad frame, not in a typical frame.

        `build_ms` is a median over every frame, and for a route scene most
        frames are the transition coasting -- it reads 1.2 ms while the frame
        that builds the incoming page takes 46. `build_max_ms` overcorrects: it
        catches each scene's cold first frame, so an animated scene with a
        0.6 ms median reports 30. The median of the five slowest frames is
        neither. Those five cluster within a millisecond of each other on every
        route scene measured, which is what makes it the steady number.
        """
        # Ranked by build, not by period. Ranking by period made this wander
        # on any scene whose builds sit near the vsync grid -- route_boxes read
        # 11.6 and 29.4 on one binary -- because the five worst periods there
        # need not be the five heaviest builds.
        rows = (scene.get("heaviest_builds")
                or scene.get("worst_frames") or [])
        if not rows:
            return scene.get("build_max_ms", 0)
        builds = sorted(f["build_ms"] for f in rows)
        return builds[len(builds) // 2]

    failures = []
    for name in names:
        row = f"{name:<18}"
        tag = ""
        cells = {}
        for m in have:
            s = scenes_of(results[m]).get(name)
            cells[m] = s
            if not s:
                row += f"{'-':>11}{'-':>11}{'-':>13}{'-':>12}"
                continue
            tag = s.get("stresses_label", "")
            if s.get("error"):
                row += f"{'threw':>11}{'-':>11}{'-':>13}{'-':>12}"
                failures.append((name, m, "error", s["error"]))
                continue
            if s["frames"] < MIN_FRAMES or s.get("span_ms", 0) < MIN_SPAN_MS:
                row += f"{fmt(s['worst_ms']):>11}{'few':>11}"
                thin_note = f"{s['frames']}f/{int(s.get('span_ms', 0))}ms"
                row += f"{thin_note:>13}"
                row += f"{fmt(bad_build(s)):>12}"
                failures.append((name, m, "thin", s["frames"]))
                continue
            stall = s["stall_ms"]
            mark = "" if stall == 0 else "*"
            row += f"{fmt(s['worst_ms']):>11}"
            row += f"{fmt(stall) + mark:>11}"
            row += f"{fmt(s['build_ms']) + '/' + fmt(s['raster_ms']):>13}"
            row += f"{fmt(bad_build(s)):>12}"
            if stall > 0:
                failures.append((name, m, "stall", stall))
        row = f"{name:<18}{tag:<11}" + row[18:]
        if len(have) == 2 and cells.get("sw") and cells.get("gl"):
            # A ratio between worst frames is only a ratio if both sides
            # actually have frames. Software route_push produces one frame in
            # six seconds -- its "worst" is its only, and dividing by it says
            # 1.22x about a scene the GPU wins by two orders of magnitude.
            if any(sound(cells[m]) is False for m in ("sw", "gl")):
                row += f"{'n/a':>8}"
            else:
                sw, gl = cells["sw"]["worst_ms"], cells["gl"]["worst_ms"]
                row += f"{(sw / gl if gl else 0):>7.2f}x"
        print(row)

    if len(have) == 2:
        print(f"\n{DIM}gpu column is software worst-frame / GPU worst-frame; "
              f"above 1.00 means the GPU is faster on that scene{OFF}")
    print(f"{DIM}* a stall is 2+ consecutive frames at or below 30 fps"
          f" — see ADR-0017{OFF}")

    if args.frames is not None:
        wanted = set(args.frames)
        for m in have:
            for s_ in scenes_of(results[m]).values():
                if wanted and s_["name"] not in wanted:
                    continue
                if not wanted and not s_.get("stall_ms"):
                    continue
                rows = s_.get("worst_frames") or []
                if not rows:
                    continue
                print(f"\n{m} {s_['name']}{DIM} — slowest frames, "
                      f"{s_['frames']} total{OFF}")
                print(f"{'#':>6}{'period':>9}{'gap':>8}{'build':>8}"
                      f"{'wait':>8}{'raster':>8}{'unaccounted':>13}")
                for f in rows:
                    known = (f["gap_ms"] + f["build_ms"]
                             + f["wait_ms"] + f["raster_ms"])
                    rest = f["period_ms"] - known
                    print(f"{f['i']:>6}{f['period_ms']:>9.1f}"
                          f"{f['gap_ms']:>8.1f}{f['build_ms']:>8.1f}"
                          f"{f['wait_ms']:>8.1f}{f['raster_ms']:>8.1f}"
                          f"{rest:>13.1f}")
                builds = [f["build_ms"] for f in (s_.get("heaviest_builds") or [])]
                if builds:
                    print(f"  heaviest builds: "
                          + "  ".join(f"{b:.1f}" for b in builds))
        print(f"\n{DIM}phases are of the frame that ENDED the period; "
              f"unaccounted is the period minus them, which is mostly the "
              f"previous frame still finishing{OFF}")
    print(f"{DIM}stresses is a label, not a measurement{OFF}")

    # ---- the gate --------------------------------------------------------
    regressions = []
    ungated = []
    vanished = []
    for m in have:
        base = load(os.path.join(args.baseline, f"{m}.json"))
        if not base:
            print(f"\n{DIM}no baseline for {m} — "
                  f"run with --baseline to write one{OFF}")
            continue
        b = scenes_of(base)
        # A scene the baseline has never seen used to be skipped in silence,
        # which is the same shape of bug as the cold shader cache: a green
        # report that is not measuring what its reader thinks it is. Six scenes
        # added on 2026-08-24 went ungraded for a day that way, including the
        # two carrying the whole text finding.
        for name in scenes_of(results[m]):
            if name not in b:
                ungated.append((m, name))
        # And the other direction, which is a quieter loss: a scene that was
        # deleted or renamed keeps its baseline row forever and nothing says
        # the ratchet stopped covering it.
        for name in b:
            if name not in scenes_of(results[m]):
                vanished.append((m, name))
        for name, s in scenes_of(results[m]).items():
            if name not in b:
                continue
            was, now = b[name]["worst_ms"], s["worst_ms"]
            # The half-millisecond is not slack, it is the rounding: worst-frame
            # is stored to two decimals, so 83.33 + 16.67 lands just under a
            # reported 100.0 and a single-vsync step reads as a regression.
            allowed = max(was * (1 + MARGIN), was + VSYNC_MS + 0.5)
            if was > 0 and now > allowed:
                regressions.append((m, name, was, now))

    if regressions:
        print(f"\n{RED}regressions against the baseline "
              f"(worst-frame, >{int(MARGIN * 100)}% and >1 vsync){OFF}")
        for m, name, was, now in regressions:
            print(f"  {m:<3} {name:<18} {fmt(was)}ms -> {fmt(now)}ms "
                  f"({(now / was - 1) * 100:+.0f}%)")

    if ungated:
        print(f"\n{DIM}not graded — no baseline for these scenes; "
              f"run with --baseline to start covering them{OFF}")
        for m, name in ungated:
            print(f"  {m:<3} {name}")

    if vanished:
        print(f"\n{DIM}baseline has scenes this run did not produce — "
              f"deleted, renamed, or filtered out{OFF}")
        for m, name in vanished:
            print(f"  {m:<3} {name}")

    thin = [(n, m, v) for n, m, k, v in failures if k == "thin"]
    if thin:
        print(f"\n{RED}window too short to grade "
              f"(need {MIN_SPAN_MS}ms and {MIN_FRAMES} frames){OFF}")
        for name, m, n_frames in thin:
            print(f"  {m:<3} {name:<18} {n_frames} frames")

    threw = [(n, m, v) for n, m, k, v in failures if k == "error"]
    if threw:
        print(f"\n{RED}threw{OFF}")
        for name, m, err in threw:
            print(f"  {m:<3} {name:<18} {err}")

    stalled = sorted({(n, m) for n, m, k, _ in failures if k == "stall"})
    if stalled:
        print(f"\n{RED}stalled{OFF}")
        for name, m in stalled:
            print(f"  {m:<3} {name}")

    if args.write_baseline:
        os.makedirs(args.baseline, exist_ok=True)
        for m in have:
            dst = os.path.join(args.baseline, f"{m}.json")
            with open(dst, "w") as f:
                json.dump(results[m], f, indent=2)
                f.write("\n")
            print(f"\nbaseline written: {dst}")
        return 0

    if regressions or threw or thin:
        return 1
    if not stalled:
        print(f"\n{GREEN}no stalls, no regressions{OFF}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
