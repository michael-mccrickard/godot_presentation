#!/usr/bin/env python3
"""
export_logic.py — lay out the dialogue clips from manifest.json on a timeline and
export them for Logic Pro.

Writes:
  logic/wav/<clip>.wav      48 kHz / 24-bit Broadcast WAVs with the timeline position
                            embedded (BWF time reference) -> "Move to Recorded Position"
  logic/dialogue.fcpxml     File > Import > Final Cut Pro XML in Logic. One lane + role
                            per character, clips named by line ID, a marker at every panel.
  timeline.json / .csv      start/end of every line and every panel (reusable in Godot)

Layout: lines play one after another with gaps you set. Positions are LOCKED in
timeline.json once written, so regenerating a line later does not shift everything
after it. Use --relayout to recompute all positions from scratch.

Usage:
  python3 export_logic.py
  python3 export_logic.py --line-gap 0.3 --panel-gap 1.2 --page-gap 2.5 --relayout
  python3 export_logic.py --lead-in 2           # seconds of silence before the first line
  python3 export_logic.py --scenes --page-gap 1.5   # per-page scene files end to end on one track

Requires ffmpeg / ffprobe on PATH.
"""
import argparse, csv, json, math, subprocess, sys
import xml.etree.ElementTree as ET
from pathlib import Path

FPS = 30            # sequence frame rate (audio-only, but FCPXML wants a video format)
SR = 48000          # output sample rate


def frames(sec):                       # seconds -> whole frames (round to nearest)
    return int(round(sec * FPS))


def ft(n):                             # frames -> FCPXML rational time
    return "0s" if n == 0 else f"{n}/{FPS}s"


def probe_samples(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a:0",
                          "-show_entries", "stream=duration_ts,channels",
                          "-of", "json", str(path)], capture_output=True, text=True, check=True)
    s = json.loads(out.stdout)["streams"][0]
    return int(s["duration_ts"]), int(s.get("channels", 1))


def to_bwf(src, dst, start_sec, line):
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(src),
                    "-ar", str(SR), "-c:a", "pcm_s24le",
                    "-write_bext", "1",
                    "-metadata", f"time_reference={int(round(start_sec * SR))}",
                    "-metadata", f"description={line['id']} {line['character']}: {line['text'][:200]}",
                    "-metadata", "originator=generate.py",
                    str(dst)], check=True)


def export_scenes(a, root, name, all_lines):
    """One track: each page's scene file end to end, page-gap apart, markers at every panel."""
    scenes = {}
    for l in all_lines:
        sf = l.get("scene_file")
        sel = next((t for t in l.get("takes", []) if t["take"] == l.get("selected_take")), {})
        if not sf:
            sys.exit(f'{l["id"]} has no scene take — run generate.py --scenes-only first')
        scenes.setdefault(sf, {"file": sf, "page": l["page"], "lines": []})["lines"].append(
            {**l, "in_start": sel.get("scene_start", 0), "in_end": sel.get("scene_end", 0)})
    scenes = sorted(scenes.values(), key=lambda s: (s["page"], s["file"]))

    wav_dir = root / "logic" / "scenes"
    wav_dir.mkdir(parents=True, exist_ok=True)
    cursor, placed = frames(a.lead_in), []
    for i, sc in enumerate(scenes):
        if i:
            cursor += frames(a.page_gap)
        src, dst = root / sc["file"], wav_dir / (Path(sc["file"]).stem + ".wav")
        start = cursor
        stamp = f'{start}|{src.stat().st_mtime_ns}'
        sf = dst.with_suffix(".stamp")
        if not dst.exists() or not sf.exists() or sf.read_text() != stamp:
            to_bwf(src, dst, start / FPS, {"id": Path(sc["file"]).stem, "character": "scene",
                                           "text": f'page {sc["page"]}'})
            sf.write_text(stamp)
        samples, ch = probe_samples(dst)
        dur = max(1, math.floor(samples * FPS / SR))
        placed.append({**sc, "wav": dst, "samples": samples, "channels": ch,
                       "start_frame": start, "end_frame": start + dur})
        cursor = start + dur
    total = cursor + frames(2.0)

    # absolute times for every line / panel (for Godot)
    tl_lines, panels = [], {}
    for sc in placed:
        t0 = sc["start_frame"] / FPS
        for l in sc["lines"]:
            s, e = round(t0 + l["in_start"], 3), round(t0 + l["in_end"], 3)
            tl_lines.append({"id": l["id"], "panel": l["panel"], "character": l["character"],
                             "scene": sc["file"], "start": s, "end": e})
            p = panels.setdefault(l["panel"], {"panel": l["panel"], "start": s, "end": e})
            p["start"], p["end"] = min(p["start"], s), max(p["end"], e)
    (root / "timeline.json").write_text(json.dumps(
        {"fps": FPS, "mode": "scenes", "lines": tl_lines, "panels": list(panels.values()),
         "scenes": [{"file": sc["file"], "start": round(sc["start_frame"] / FPS, 3),
                     "end": round(sc["end_frame"] / FPS, 3)} for sc in placed],
         "duration": round(total / FPS, 3)}, indent=2))
    with open(root / "timeline.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["id", "panel", "character", "start", "end"])
        for t in tl_lines:
            w.writerow([t["id"], t["panel"], t["character"], t["start"], t["end"]])

    fcp = ET.Element("fcpxml", version="1.9")
    res = ET.SubElement(fcp, "resources")
    ET.SubElement(res, "format", id="r1", name="FFVideoFormat1080p30",
                  frameDuration=f"1/{FPS}s", width="1920", height="1080")
    for i, sc in enumerate(placed, 2):
        sc["ref"] = f"r{i}"
        asset = ET.SubElement(res, "asset", id=sc["ref"], name=sc["wav"].stem, start="0s",
                              duration=f'{sc["samples"]}/{SR}s', hasAudio="1", audioSources="1",
                              audioChannels=str(sc["channels"]), audioRate=str(SR))
        ET.SubElement(asset, "media-rep", kind="original-media", src=sc["wav"].resolve().as_uri())
    ev = ET.SubElement(ET.SubElement(fcp, "library"), "event", name=name)
    seq = ET.SubElement(ET.SubElement(ev, "project", name=f"{name} dialogue"), "sequence",
                        format="r1", duration=ft(total), tcStart="0s", tcFormat="NDF",
                        audioLayout="stereo", audioRate="48k")
    gap = ET.SubElement(ET.SubElement(seq, "spine"), "gap", name="Dialogue",
                        offset="0s", start="0s", duration=ft(total))
    for p in panels.values():
        ET.SubElement(gap, "marker", start=ft(frames(p["start"])), duration=ft(1), value=p["panel"])
    for sc in placed:
        ET.SubElement(gap, "asset-clip", ref=sc["ref"], lane="-1", offset=ft(sc["start_frame"]),
                      start="0s", duration=ft(sc["end_frame"] - sc["start_frame"]),
                      name=f'Page {sc["page"]}', audioRole="Dialogue")
    ET.indent(fcp)
    out = root / "logic" / "dialogue_scenes.fcpxml"
    out.write_text('<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE fcpxml>\n\n'
                   + ET.tostring(fcp, encoding="unicode") + "\n", encoding="utf-8")
    print(f"{len(placed)} scenes on one track, {len(panels)} panel markers, "
          f"length {total / FPS / 60:.0f}:{total / FPS % 60:04.1f}")
    print(f"→ {out.relative_to(root)}\n→ logic/scenes/ (BWF)\n→ timeline.json / timeline.csv")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", default="manifest.json")
    ap.add_argument("--line-gap", type=float, default=0.35, help="pause between lines in the same panel")
    ap.add_argument("--panel-gap", type=float, default=1.0, help="pause before a new panel")
    ap.add_argument("--page-gap", type=float, default=0.5, help="pause before a new page")
    ap.add_argument("--lead-in", type=float, default=1.0)
    ap.add_argument("--relayout", action="store_true", help="ignore locked positions in timeline.json")
    ap.add_argument("--name", help="project name (default: folder name)")
    ap.add_argument("--role-style", choices=["main", "sub"], default="main",
                    help="main: role per character (separate tracks); sub: dialogue.<character>")
    ap.add_argument("--stems", action="store_true",
                    help="also write logic/stems/<CHARACTER>.wav, one full-length file per character")
    ap.add_argument("--scenes", action="store_true",
                    help="place the per-page scene files (from --scenes-only) end to end on ONE track")
    a = ap.parse_args()

    root = Path(a.manifest).resolve().parent
    name = a.name or root.name
    all_lines = json.loads(Path(a.manifest).read_text())["lines"]
    if a.scenes or (not any(l.get("file") for l in all_lines) and any(l.get("scene_file") for l in all_lines)):
        return export_scenes(a, root, name, all_lines)
    lines = [l for l in all_lines if l.get("file")]
    missing = [l["id"] for l in lines if not (root / l["file"]).exists()]
    if missing:
        sys.exit("Clip files missing for: " + ", ".join(missing))
    if not lines:
        sys.exit("No generated clips in manifest.")

    tl_path = root / "timeline.json"
    locked = {}
    if tl_path.exists() and not a.relayout:
        locked = {x["id"]: x for x in json.loads(tl_path.read_text())["lines"]}

    wav_dir = root / "logic" / "wav"
    wav_dir.mkdir(parents=True, exist_ok=True)

    # ---- layout (in frames, so everything lands on FCPXML edit boundaries) ----
    placed, cursor, prev = [], frames(a.lead_in), None
    for l in lines:
        src = root / l["file"]
        dst = wav_dir / (Path(l["file"]).stem + ".wav")

        if prev is None:
            gap = 0
        elif l["page"] != prev["page"]:
            gap = a.page_gap
        elif l["panel"] != prev["panel"]:
            gap = a.panel_gap
        else:
            gap = a.line_gap

        lk = locked.get(l["id"])
        start = lk["start_frame"] if lk else cursor + frames(gap)

        # convert (time reference depends on start, so redo if start or source changed)
        stamp = f'{start}|{src.stat().st_mtime_ns}'
        stamp_file = dst.with_suffix(".stamp")
        if not dst.exists() or not stamp_file.exists() or stamp_file.read_text() != stamp:
            to_bwf(src, dst, start / FPS, l)
            stamp_file.write_text(stamp)

        samples, ch = probe_samples(dst)
        dur = max(1, math.floor(samples * FPS / SR))       # whole frames, never past the audio
        end = start + dur
        if placed and start < placed[-1]["end_frame"]:
            print(f'warning: {l["id"]} overlaps {placed[-1]["id"]} '
                  f'by {(placed[-1]["end_frame"] - start) / FPS:.2f}s (locked position)')
        placed.append({**l, "wav": dst, "samples": samples, "channels": ch,
                       "start_frame": start, "end_frame": end})
        cursor = max(cursor, end)
        prev = l

    total = cursor + frames(2.0)

    # ---- timeline.json / csv ----
    panels = {}
    for p in placed:
        pn = panels.setdefault(p["panel"], {"panel": p["panel"], "start": p["start_frame"], "end": p["end_frame"]})
        pn["start"], pn["end"] = min(pn["start"], p["start_frame"]), max(pn["end"], p["end_frame"])
    tl = {
        "fps": FPS,
        "lines": [{"id": p["id"], "panel": p["panel"], "character": p["character"],
                   "file": p["file"], "wav": str(p["wav"].relative_to(root)),
                   "start_frame": p["start_frame"], "start": round(p["start_frame"] / FPS, 3),
                   "end": round(p["end_frame"] / FPS, 3)} for p in placed],
        "panels": [{"panel": v["panel"], "start": round(v["start"] / FPS, 3),
                    "end": round(v["end"] / FPS, 3)} for v in panels.values()],
        "duration": round(total / FPS, 3),
    }
    tl_path.write_text(json.dumps(tl, indent=2))
    with open(root / "timeline.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["id", "panel", "character", "start", "end", "text"])
        for p, t in zip(placed, tl["lines"]):
            w.writerow([p["id"], p["panel"], p["character"], t["start"], t["end"], p["text"]])

    # ---- FCPXML ----
    chars = list(dict.fromkeys(p["character"] for p in placed))       # order of first appearance
    lane = {c: -(i + 1) for i, c in enumerate(chars)}
    rname = {c: "".join(ch if ch.isalnum() else "_" for ch in c.title()).strip("_") for c in chars}
    # Logic groups imported clips into tracks by MAIN role, so each character gets its own main role
    role = {c: rname[c] if a.role_style == "main" else f"dialogue.{rname[c]}" for c in chars}

    fcp = ET.Element("fcpxml", version="1.9")
    res = ET.SubElement(fcp, "resources")
    ET.SubElement(res, "format", id="r1", name="FFVideoFormat1080p30",
                  frameDuration=f"1/{FPS}s", width="1920", height="1080")
    for i, p in enumerate(placed, 2):
        p["ref"] = f"r{i}"
        asset = ET.SubElement(res, "asset", id=p["ref"], name=p["wav"].stem, start="0s",
                              duration=f'{p["samples"]}/{SR}s', hasAudio="1",
                              audioSources="1", audioChannels=str(p["channels"]), audioRate=str(SR))
        ET.SubElement(asset, "media-rep", kind="original-media", src=p["wav"].resolve().as_uri())

    lib = ET.SubElement(fcp, "library")
    ev = ET.SubElement(lib, "event", name=name)
    proj = ET.SubElement(ev, "project", name=f"{name} dialogue")
    seq = ET.SubElement(proj, "sequence", format="r1", duration=ft(total), tcStart="0s",
                        tcFormat="NDF", audioLayout="stereo", audioRate="48k")
    spine = ET.SubElement(seq, "spine")
    gap = ET.SubElement(spine, "gap", name="Dialogue", offset="0s", start="0s", duration=ft(total))
    for v in panels.values():
        ET.SubElement(gap, "marker", start=ft(v["start"]), duration=ft(1), value=v["panel"])
    for p in placed:
        clip = ET.SubElement(gap, "asset-clip", ref=p["ref"], lane=str(lane[p["character"]]),
                             offset=ft(p["start_frame"]), start="0s",
                             duration=ft(p["end_frame"] - p["start_frame"]),
                             name=f'{p["id"]} {p["character"]}', audioRole=role[p["character"]])
        ET.SubElement(clip, "note").text = p["text"]

    ET.indent(fcp)
    out = root / "logic" / "dialogue.fcpxml"
    out.write_text('<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE fcpxml>\n\n'
                   + ET.tostring(fcp, encoding="unicode") + "\n", encoding="utf-8")

    if a.stems:
        stem_dir = root / "logic" / "stems"
        stem_dir.mkdir(parents=True, exist_ok=True)
        for c in chars:
            mine = [p for p in placed if p["character"] == c]
            cmd = ["ffmpeg", "-v", "error", "-y"]
            for p in mine:
                cmd += ["-i", str(p["wav"])]
            parts = [f'[{i}:a]aresample={SR},pan=mono|c0=c0,adelay={round(p["start_frame"] * 1000 / FPS)}:all=1[a{i}]'
                     for i, p in enumerate(mine)]
            mix = "".join(f"[a{i}]" for i in range(len(mine)))
            flt = ";".join(parts) + f";{mix}amix=inputs={len(mine)}:normalize=0:dropout_transition=0,apad=whole_dur={total / FPS}[out]"
            cmd += ["-filter_complex", flt, "-map", "[out]", "-ar", str(SR), "-c:a", "pcm_s24le",
                    "-write_bext", "1", "-metadata", "time_reference=0",
                    str(stem_dir / f"{rname[c]}.wav")]
            subprocess.run(cmd, check=True)
        print(f"→ logic/stems/ ({len(chars)} character stems, all start at 0:00)")

    print(f"{len(placed)} clips, {len(chars)} characters, {len(panels)} panels, "
          f"length {total / FPS / 60:.0f}:{total / FPS % 60:04.1f}")
    print(f"→ {out.relative_to(root)}\n→ timeline.json / timeline.csv\n→ logic/wav/ (BWF)")


if __name__ == "__main__":
    main()
