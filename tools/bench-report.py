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

# ADR-0017 decision 8 gated on worst-frame, with raster and stall added later
# as the backstops worst-frame could not be. All three were retired on
# 2026-09-24 when they were measured against their own noise; what replaced
# them is below. RASTER_FLOOR_MS survives as one of the absolute floors.
RASTER_FLOOR_MS = 1.0

# ---- what a run can actually resolve ---------------------------------------
#
# Measured on 2026-09-24, three runs of the gallery where two carried the same
# code and the third carried the layer from before that day's work. Across the
# 31 scenes all three produced, the run-to-run spread of each metric was:
#
#   build (ui)  median  1.0%   p90   8.3%   max  14.3%
#   raster      median  9.2%   p90  67.4%   max  77.8%
#   worst       median  0.0%   p90  80.0%   max  83.3%
#   stall       median 36.6%   p90 100.0%   max 100.0%
#
# The gate fired at 10% on worst and 25% on raster and stall. Fifteen scenes
# moved more than 10% on worst between runs of the same code, twelve moved
# more than 25% on raster, and nine moved more than 25% on stall. So the three
# graded metrics were all noisier than their own thresholds, and the one that
# held still was not graded at all.
#
# Worst-frame and stall cannot be fixed by a wider band. Worst-frame is a
# maximum over a few hundred samples, quantised to whole vsyncs, so it moves in
# 16.67 ms steps or not at all. Stall counts rare events and is usually zero,
# which makes every occurrence an infinite increase. Both are reported and
# neither is graded.
#
# What is graded is the median across a scene's repetitions, of three metrics
# that are means or medians over every frame. And the band is not a constant:
# each scene measures its own spread across its repetitions and is graded
# against that, so a scene that cannot resolve a change does not claim to.
GRADED = (
    # key          label      absolute floor, below which a move is not news
    ("median_ms", "median", 1.0),
    ("build_ms", "build", 0.5),
    ("raster_ms", "raster", RASTER_FLOOR_MS),
)

# Never claim to resolve better than this, however tight the repetitions look.
# Three samples cannot measure a 2% spread.
MIN_BAND = 0.10

# A scene whose own repetitions disagree by more than this is not graded. It
# is printed instead, with the spread, because a scene that cannot be measured
# is a finding and not a silence.
#
# 35%, and a run at 100% is what settled it. The argument for 100% was that
# the band is the scene's own spread, so a noisy scene already gets a wide band
# and refusing to grade it as well throws away the doubling the band would have
# caught. Two runs of the same code then produced three regressions -- switch_fade
# raster +64% inside a 46% band, route_push +75% inside 64%, route_boxes +55%
# inside 40%.
#
# The band is built from the spread of three repetitions and compared against
# the median of them. That holds while the repetitions differ by chance. It
# breaks when they drift: switch_fade rastered 5.70, 7.31, 9.09 ms in one run,
# a ramp, and the median of a ramp sits wherever the run happened to start. A
# band drawn from the ramp's width does not contain that.
#
# Nothing here can tell a ramp from noise with three samples, so a scene that
# moves more than a third across its own repetitions is not graded at all.
MAX_GRADEABLE_SPREAD = 0.35


def spread(values, floor=0.0):
    """How far apart the repetitions of one scene are, relative to the middle.

    The number the gate's band is built from, and the number that decides
    whether a scene can be graded at all.

    `floor` is the metric's absolute floor from GRADED, and it protects the
    denominator. Raster on a cheap scene sits near 1 ms, where a 0.4 ms wobble
    is 40% of nothing. The same 0.4 ms is declared "not news" by the floor when
    the gate compares two runs, so it cannot be allowed to disqualify the scene
    here.
    """
    values = [v for v in values if v is not None]
    if len(values) < 2:
        return None
    mid = max(median(values), floor)
    if mid <= 0:
        return None
    return (max(values) - min(values)) / mid


def median(values):
    values = sorted(values)
    n = len(values)
    if not n:
        return 0.0
    return values[n // 2] if n % 2 else (values[n // 2 - 1] + values[n // 2]) / 2


def repeats_of(scene, key):
    """One metric, once per repetition, or None when the run did not record
    them. A result from before 2026-09-24 has no `repeats`."""
    rs = (scene or {}).get("repeats")
    if not rs:
        return None
    vals = [r.get(key) for r in rs if r.get(key) is not None and r.get("frames", 0) >= 2]
    return vals if len(vals) >= 2 else None


# ---- a baseline over several launches ---------------------------------------
#
# Three repetitions in one launch measure how a scene varies within a launch.
# They cannot see how it varies between launches, and some scenes do: on
# 2026-10-01 route_push rastered at 4.4 ms in one launch and 12.8 ms in the
# next, each launch's repetitions agreeing within 34%, and the gate called the
# second launch a +191% regression on unchanged code. On 2026-09-25 a single
# launch had gone 12.5, 14.0, 4.6.
#
# So a baseline can be several launches. `--add-to-baseline` appends a run's
# repetitions to the baseline's, scene by scene, and the band and the grading
# limit are then measured over all of them. A scene that jumps between launches
# shows it in the baseline's own spread and is listed as not graded, which is
# what was decided for scenes that cannot be measured.

# The newest repetitions a merged baseline keeps per scene: four launches.
BASELINE_REPEATS_KEPT = 12


def merge_into_baseline(old, new):
    """`new` with `old`'s repetitions in front of its own, per scene.

    Returns (merged, None), or (None, reason) when the two runs measured
    different things: repetitions of another suite, engine or clock are not
    more samples of this one.
    """
    if not old:
        return dict(new, launches=1), None
    for key in ("method", "engine", "clocks", "scene_count"):
        if old.get(key) != new.get(key):
            return None, f"{key} differs ({old.get(key)} vs {new.get(key)})"
    old_scenes = {s["name"]: s for s in old.get("scenes", [])}
    scenes = []
    for s in new.get("scenes", []):
        was = old_scenes.pop(s["name"], None)
        if was and was.get("repeats") and s.get("repeats"):
            s = dict(s, repeats=(was["repeats"] + s["repeats"])[-BASELINE_REPEATS_KEPT:])
        scenes.append(s)
    scenes.extend(old_scenes.values())
    return dict(new, scenes=scenes, launches=old.get("launches", 1) + 1), None

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
        "--add-to-baseline", action="store_true",
        help="append this run's repetitions to the baseline instead of "
             "replacing it, so the baseline covers several launches")
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

    # ---- what to fix first ----------------------------------------------
    # The table is one row per scene and up to nine columns per renderer, which
    # is the wrong shape for the question people arrive with: which of these
    # is bad.
    #
    # Ranked by stall, total time below 30 fps, because that corresponds to
    # something a person felt and is a total over the window rather than one
    # frame.
    #
    # `where` names the thread the time went to: the difference between a scene
    # the GPU could help and a scene no renderer change will touch.
    rank_mode = "gl" if "gl" in have else have[0]
    ranked = []
    for name, s_ in scenes_of(results[rank_mode]).items():
        if not sound(s_):
            continue
        b = bad_build(s_)
        r = s_["raster_ms"]
        # "neither" is decided first, and on an absolute threshold rather than
        # the ratio between the two. A scene whose build is 4.5 ms and whose
        # raster is 1.1 ms has a build four times the raster and a perfectly
        # healthy build; ranking that as "UI thread" sends someone to optimise
        # something that is not the problem.
        #
        # 8 ms is half a vsync: under it, neither thread can be what made the
        # frame late. Nothing has measured what does; the port has no VM
        # service.
        if s_["stall_ms"] > 0 and b < 8.0 and r < 8.0:
            where = "neither"
        elif b > max(2 * r, 4.0):
            where = "UI thread"
        elif r > max(2 * b, 4.0):
            where = "raster"
        else:
            where = "both"
        ranked.append((s_["stall_ms"], bad_build(s_), name, s_, where))
    ranked.sort(key=lambda t: (-t[0], -t[1]))
    worst = [t for t in ranked if t[0] > 0 or t[1] >= 16.67][:12]
    if worst:
        print(f"\n{rank_mode}: what to fix first{DIM} — ranked by time below "
              f"30 fps, then by the build time of a bad frame{OFF}")
        print(f"{'scene':<18}{'stresses':<11}{'stall':>9}{'worst':>9}"
              f"{'bad bld':>9}{'raster':>9}  where")
        for stall, bld, name, s_, where in worst:
            print(f"{name:<18}{s_.get('stresses_label',''):<11}"
                  f"{fmt(stall):>9}{fmt(s_['worst_ms']):>9}"
                  f"{fmt(bld):>9}{fmt(s_['raster_ms']):>9}  {where}")
        print(f"{DIM}where: which thread the time went to. \"UI thread\" means "
              f"no renderer change will help it{OFF}")

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
    # Scenes whose own repetitions disagree too much to grade, and runs too old
    # to carry repetitions at all.
    unresolvable = []
    no_repeats = set()
    ungated = []
    vanished = []
    stale_method = []
    for m in have:
        base = load(os.path.join(args.baseline, f"{m}.json"))
        if not base:
            print(f"\n{DIM}no baseline for {m} — "
                  f"run with --baseline to write one{OFF}")
            continue
        # The suite's own definition, as the app computes it: every scene's
        # name, repeat count and duration. A repeat count changes what a number
        # means, and until 2026-09-23 nothing said so -- the route scenes went
        # from eight repeats to three and every stored result still compared as
        # though nothing had happened. A baseline from another method is not a
        # baseline, and a baseline with no method at all is older than this
        # rule, so it is not one either.
        was_id = base.get("method")
        now_id = results[m].get("method")
        # Unconditional, so that a binary too old to report a method cannot
        # gate against a baseline that has one. Two files that both predate
        # the field still compare, which is the behaviour they always had.
        if was_id != now_id:
            stale_method.append((m, was_id, now_id))
            continue
        # The clocks belong to the method as much as the repeat counts do.
        # The embedder runs every app at 444/222, and from 2026-09-18 to
        # 2026-09-23 the gallery undid that at startup and ran at 333/111.
        # Every scene read a third slow, the gate compared the two happily,
        # and it cost an afternoon to find. One line stops it happening again.
        was_hz = base.get("clocks")
        now_hz = results[m].get("clocks")
        if was_hz != now_hz:
            stale_method.append((m, f"{was_id} at {was_hz or 'unrecorded clocks'}",
                                 f"{now_id} at {now_hz or 'unrecorded clocks'}"))
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
            # A scene the run could not sample properly is not a scene that got
            # slower, and grading one produces the loudest numbers in the report
            # off the fewest frames: four frames in 1933 ms once read as +492%.
            #
            # Both sides, because a baseline written from a thin window is as
            # untrustworthy as a thin result measured against it.
            if not sound(s) or not sound(b[name]):
                continue
            # Each metric is graded on the median of the scene's repetitions
            # against the same from the baseline, inside a band the scene
            # measured for itself. See GRADED.
            now_reps = {k: repeats_of(s, k) for k, _, _ in GRADED}
            was_reps = {k: repeats_of(b[name], k) for k, _, _ in GRADED}
            if all(v is None for v in now_reps.values()):
                # A run from before repetitions were recorded. Nothing to
                # grade it with, and the old gate is gone, so say so once.
                no_repeats.add(m)
                continue
            for key, label, floor in GRADED:
                now_v, was_v = now_reps[key], was_reps[key]
                if not now_v or not was_v:
                    continue
                now_m, was_m = median(now_v), median(was_v)
                if was_m <= 0:
                    continue
                # The band is whichever side is less certain, never tighter
                # than MIN_BAND. A scene that wobbles is a scene the report
                # cannot make fine claims about, in either direction.
                noise = max(
                    spread(now_v, floor) or 0.0, spread(was_v, floor) or 0.0
                )
                if noise > MAX_GRADEABLE_SPREAD:
                    unresolvable.append((m, name, label, noise, now_m))
                    continue
                band = max(noise, MIN_BAND)
                if now_m > max(was_m * (1 + band), was_m + floor):
                    regressions.append((m, name, label, was_m, now_m, band))

    if stale_method:
        print(f"\n{RED}not graded — the baseline measured a different "
              f"suite{OFF}")
        for m, was_id, now_id in stale_method:
            print(f"  {m:<3} baseline method {was_id or 'none recorded'}, "
                  f"this run {now_id}")
        print(f"{DIM}a scene's repeat count, duration or settle changed, or a "
              f"scene came or went. The old numbers measured something else, "
              f"so nothing is gated. Delete the baseline and write a new one "
              f"with --baseline{OFF}")

    if no_repeats:
        print(f"\n{RED}not graded — no repetitions recorded{OFF}")
        print(f"{DIM}{', '.join(sorted(no_repeats))}: this result predates "
              f"2026-09-24, when the runner began measuring each repetition of "
              f"a scene on its own. Without them the report cannot tell a "
              f"change from its own noise, and it no longer guesses. Take the "
              f"run again{OFF}")

    if regressions:
        print(f"\n{RED}regressions against the baseline{OFF}")
        print(f"{DIM}the median of a scene's repetitions, against the same "
              f"from the baseline, outside the band that scene measured for "
              f"itself (never tighter than {int(MIN_BAND * 100)}%){OFF}")
        for m, name, metric, was, now, band in regressions:
            pct = f"{(now / was - 1) * 100:+.0f}%" if was > 0 else "new"
            print(f"  {m:<3} {name:<18} {metric:<6} {fmt(was)}ms -> "
                  f"{fmt(now)}ms ({pct}, band {band * 100:.0f}%)")
        print(f"{DIM}worst-frame and stall are printed in the table above and "
              f"graded nowhere: a maximum quantised to whole vsyncs and a "
              f"count of rare events cannot resolve a change. See GRADED in "
              f"tools/bench-report.py{OFF}")

    if unresolvable:
        print(f"\n{DIM}not graded — the scene disagrees with itself{OFF}")
        for m, name, metric, noise, now in sorted(unresolvable,
                                                  key=lambda r: -r[3]):
            print(f"  {DIM}{m:<3} {name:<18} {metric:<6} {fmt(now)}ms, "
                  f"its own repetitions spread {noise * 100:.0f}%{OFF}")
        print(f"{DIM}over {int(MAX_GRADEABLE_SPREAD * 100)}% between "
              f"repetitions of the same scene in the same run. Nothing can be "
              f"concluded about a change smaller than that, so nothing is{OFF}")

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

    # Listed and not graded, and not a failure. Until 2026-10-01 a thin window
    # failed the run, and route_tx_none (6 frames) and modal_dialog (1000 ms)
    # are thin on every run, so the gate failed on unchanged code every time.
    # A scene that cannot be measured is the same case as one whose repetitions
    # disagree: say so, grade nothing, and keep the exit code for regressions.
    thin = [(n, m, v) for n, m, k, v in failures if k == "thin"]
    if thin:
        print(f"\n{DIM}not graded — window too short "
              f"(need {MIN_SPAN_MS}ms and {MIN_FRAMES} frames){OFF}")
        for name, m, n_frames in thin:
            print(f"  {DIM}{m:<3} {name:<18} {n_frames} frames{OFF}")

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

    if args.write_baseline or args.add_to_baseline:
        os.makedirs(args.baseline, exist_ok=True)
        for m in have:
            dst = os.path.join(args.baseline, f"{m}.json")
            doc = dict(results[m], launches=1)
            if args.add_to_baseline:
                doc, why = merge_into_baseline(load(dst), results[m])
                if doc is None:
                    print(f"\n{RED}not added to the baseline: {why}{OFF}")
                    print(f"{DIM}start a new one with --baseline{OFF}")
                    return 1
            with open(dst, "w") as f:
                json.dump(doc, f, indent=2)
                f.write("\n")
            print(f"\nbaseline written: {dst} "
                  f"({doc.get('launches', 1)} launch"
                  f"{'es' if doc.get('launches', 1) != 1 else ''})")
        return 0

    if regressions or threw:
        return 1
    # "no regressions" from a run that gated nothing is the green report this
    # file exists to prevent. Say which it was.
    if stale_method:
        print(f"\n{DIM}nothing was gated this run{OFF}")
    elif not stalled:
        print(f"\n{GREEN}no stalls, no regressions{OFF}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
