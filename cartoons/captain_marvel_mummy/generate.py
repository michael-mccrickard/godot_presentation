#!/usr/bin/env python3
"""
generate.py — ElevenLabs voice-clip generator for the cartoon pipeline.

Reads a dialog script tagged [p{page}_f{frame}] SPEAKER (qualifier): text,
cast.json (speaker -> EL voice) and optionally performance.json (the same lines
with audio tags like [panicked] added), and writes one named clip per line plus
manifest.json / manifest.csv.

Two modes (set "mode" in cast.json _defaults, or --mode):
  dialogue (default)  Each page is performed as ONE scene through EL Text to Dialogue
                      (eleven_v4), then cut into per-line clips using the returned
                      timestamps. Consistent voices, real back-and-forth timing.
                      Retakes regenerate the whole page (scene).
  line                One TTS request per line (the original behaviour).

Only scenes/lines whose text, tags, voice, model or settings changed are regenerated.

Usage:
  python3 generate.py script.txt --dry-run           # plan only, no API calls
  python3 generate.py script.txt --voice-test        # one short line per character on the dialogue model
  python3 generate.py script.txt --page 2            # one page
  python3 generate.py script.txt                     # everything new/changed
  python3 generate.py script.txt --retake p3_f5_02   # new take of that line's scene
  python3 generate.py script.txt --retake p3_f5_02 --single   # just that line, on its own
  python3 generate.py script.txt --scenes-only        # one file per page, no per-line clips
  python3 generate.py --list-voices

To keep a particular take (e.g. an older one), add "pin_take": N to that line in manifest.json.

Requires: ELEVENLABS_API_KEY, Python 3.9+, `requests`, ffmpeg/ffprobe.
"""
import argparse, base64, csv, hashlib, json, os, re, subprocess, sys, time
from pathlib import Path

API = "https://api.elevenlabs.io/v1"
LINE_RE = re.compile(r"^\[(p(\d+)_f(\d+))\]\s+([^:(]+?)\s*(?:\(([^)]*)\))?\s*:\s*(.+)$")
TAG_RE = re.compile(r"\[[^\]]*\]")
MAX_CHARS = 1800          # EL asks for <= 2000 per dialogue request; leave headroom
MAX_VOICES = 10
PAD_BEFORE, PAD_AFTER = 0.06, 0.25     # seconds kept around each line when cutting


# ---------- parsing ----------

def parse_script(path):
    lines, counters = [], {}
    for n, raw in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), 1):
        m = LINE_RE.match(raw.strip())
        if not m:
            continue
        panel, page, frame, speaker, qual, text = m.groups()
        counters[panel] = counters.get(panel, 0) + 1
        lines.append({
            "id": f"{panel}_{counters[panel]:02d}",
            "panel": panel, "page": int(page), "frame": int(frame),
            "character": speaker.strip(),
            "qualifier": (qual or "").strip() or None,
            "text": text.strip(),
            "script_line": n,
        })
    return lines


def norm(s):
    return re.sub(r"\s+", " ", s).strip()


def strip_tags(s):
    return norm(TAG_RE.sub(" ", s))


def load_performance(path, lines):
    """performance.json: {"lines": {id: {"text": original, "performed": tagged}}}"""
    if not path.exists():
        return
    perf = json.loads(path.read_text(encoding="utf-8")).get("lines", {})
    by_text = {}
    for k, p in perf.items():
        by_text.setdefault(norm(p.get("text", "")), []).append(p)
    for l in lines:
        p = perf.get(l["id"])
        if not p or norm(p.get("text", "")) != norm(l["text"]):
            # line moved (new ID) or speaker renamed: match by its words instead
            cands = by_text.get(norm(l["text"]), [])
            same_char = [c for c in cands if c.get("character") == l["character"]]
            p = (same_char or cands)[0] if len(same_char or cands) == 1 else None
            if not p:
                print(f'performance.json: no tags found for {l["id"]} ({l["character"]}) — using untagged text')
                continue
        if strip_tags(p["performed"]) != norm(l["text"]):
            print(f'performance.json: {l["id"]} "performed" changes the words, not just tags — check it')
        l["performed"] = norm(p["performed"])


def char_key(name):
    return re.sub(r"[^A-Z0-9]+", "_", name.upper()).strip("_")


def slug(text, words=4):
    w = re.findall(r"[A-Za-z0-9']+", text)[:words]
    return re.sub(r"[^a-z0-9]+", "-", "-".join(w).lower().replace("'", "")).strip("-") or "line"


# ---------- cast ----------

def load_cast(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    defaults = data.get("_defaults", {})
    chars = {char_key(k): v for k, v in data.items() if not k.startswith("_")}
    return defaults, chars


def resolve_voice(line, defaults, chars, allow_placeholder=False):
    entry = chars.get(char_key(line["character"]))
    if not entry or not entry.get("voice_id"):
        return None
    if entry["voice_id"].startswith("FILL") and not allow_placeholder:
        return None
    v = {
        "voice_id": entry["voice_id"],
        "voice_name": entry.get("voice_name", entry["voice_id"]),
        "model_id": entry.get("model_id", defaults.get("model_id", "eleven_multilingual_v2")),
        "settings": {**defaults.get("voice_settings", {}), **entry.get("voice_settings", {})},
    }
    q = line["qualifier"]
    if q and q in entry.get("qualifiers", {}):
        v["settings"] = {**v["settings"], **entry["qualifiers"][q]}
    return v


def dialogue_cfg(defaults):
    d = {"model_id": "eleven_v4", "stability": 0.5, "seed": None, **defaults.get("dialogue", {})}
    return d


def content_hash(*parts):
    return hashlib.sha1(json.dumps(parts, sort_keys=True).encode()).hexdigest()[:12]


# ---------- API ----------

def api_key():
    k = os.environ.get("ELEVENLABS_API_KEY")
    if not k:
        sys.exit("Set ELEVENLABS_API_KEY first (export ELEVENLABS_API_KEY=...)")
    return k


def post(url, body, params):
    import requests
    for attempt in range(5):
        r = requests.post(url, params=params, json=body, timeout=300,
                          headers={"xi-api-key": api_key(), "Content-Type": "application/json"})
        if r.status_code == 429 or r.status_code >= 500:
            time.sleep(2 ** attempt * 2)
            continue
        if not r.ok:
            raise RuntimeError(f"EL API {r.status_code}: {r.text[:400]}")
        return r.json(), r.headers.get("request-id")
    raise RuntimeError("EL API kept rate-limiting / failing; try again later")


def list_voices():
    import requests
    r = requests.get(f"{API}/voices", headers={"xi-api-key": api_key()}, timeout=60)
    if not r.ok:
        sys.exit(f"EL API {r.status_code}: {r.text[:300]}")
    for v in sorted(r.json()["voices"], key=lambda v: v["name"].lower()):
        print(f'{v["name"]:<32} {v["voice_id"]}   ({v.get("category", "")})')


def tts(text, voice_id, model_id, settings, fmt, prev_text=None, next_text=None, prev_ids=None):
    body = {"text": text, "model_id": model_id, "voice_settings": settings}
    if prev_ids:
        body["previous_request_ids"] = prev_ids[-3:]
    elif prev_text:
        body["previous_text"] = prev_text
    if next_text:
        body["next_text"] = next_text
    j, rid = post(f"{API}/text-to-speech/{voice_id}/with-timestamps", body, {"output_format": fmt})
    return base64.b64decode(j["audio_base64"]), j, rid


def dialogue(inputs, cfg, fmt, prev_ids=None, next_ids=None):
    body = {"inputs": inputs, "model_id": cfg["model_id"],
            "settings": {"stability": cfg["stability"]}}
    if cfg.get("seed") is not None:
        body["seed"] = cfg["seed"]
    if prev_ids:
        body["previous_request_ids"] = prev_ids[-3:]
    if next_ids:
        body["next_request_ids"] = next_ids[:3]
    j, rid = post(f"{API}/text-to-dialogue/with-timestamps", body, {"output_format": fmt})
    return base64.b64decode(j["audio_base64"]), j, rid


# ---------- audio helpers ----------

def duration(path):
    try:
        out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                              "-of", "default=nw=1:nk=1", str(path)],
                             capture_output=True, text=True, check=True).stdout.strip()
        return round(float(out), 3)
    except Exception:
        return None


def cut(src, dst, start, end):
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(src), "-ss", f"{start:.3f}",
                    "-to", f"{end:.3f}", "-ac", "1", "-c:a", "pcm_s16le", str(dst)], check=True)


def ext_for(fmt):
    return "wav" if fmt.startswith(("pcm", "wav")) else fmt.split("_")[0]


# ---------- scenes ----------

def build_chunks(lines):
    """One chunk per page; split long/crowded pages at panel boundaries (or lines if needed)."""
    chunks, by_page = [], {}
    for l in lines:
        by_page.setdefault(l["page"], []).append(l)
    for page, pl in by_page.items():
        groups, cur = [], []
        def fits(extra):
            ch = sum(len(x["performed"]) for x in cur + extra)
            vs = {x["character"] for x in cur + extra}
            return ch <= MAX_CHARS and len(vs) <= MAX_VOICES
        panels = []
        for l in pl:
            if panels and panels[-1][0]["panel"] == l["panel"]:
                panels[-1].append(l)
            else:
                panels.append([l])
        for panel in panels:
            if fits(panel):
                cur += panel
                continue
            if cur:
                groups.append(cur)
                cur = []
            for l in panel:                      # panel alone too big: split by line
                if not fits([l]) and cur:
                    groups.append(cur)
                    cur = []
                cur.append(l)
        if cur:
            groups.append(cur)
        for i, g in enumerate(groups):
            cid = f"p{page:02d}" if len(groups) == 1 else f"p{page:02d}_c{i + 1}"
            chunks.append({"id": cid, "page": page, "lines": g})
            for l in g:
                l["chunk"] = cid
    return chunks


def clip_name(l, voice_name, take_no, ext):
    return (f'{l["id"]}__{char_key(l["character"])}__{re.sub(r"[^A-Za-z0-9]+", "", voice_name)}'
            f'__{slug(l["text"])}_t{take_no}.{ext}')


def latest_take(l):
    sel = next((t for t in l["takes"] if t["take"] == l.get("selected_take")), None)
    return sel or (l["takes"][-1] if l["takes"] else None)


# ---------- main ----------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("script", nargs="?")
    ap.add_argument("--cast", default="cast.json")
    ap.add_argument("--performance", default="performance.json")
    ap.add_argument("--out", default="clips")
    ap.add_argument("--mode", choices=["dialogue", "line"])
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--only", help="comma-separated line ids")
    ap.add_argument("--page", type=int)
    ap.add_argument("--retake", help="comma-separated line ids to re-take")
    ap.add_argument("--single", action="store_true", help="with --retake: redo just the line, not its scene")
    ap.add_argument("--scenes-only", action="store_true",
                    help="dialogue mode: keep one audio file per scene, don't cut per-line clips")
    ap.add_argument("--voice-test", action="store_true")
    ap.add_argument("--list-voices", action="store_true")
    a = ap.parse_args()

    if a.list_voices:
        return list_voices()
    if not a.script:
        ap.error("script path required")

    root = Path(a.script).resolve().parent
    out = root / a.out
    for d in ("_alignment", "_scenes"):
        (out / d).mkdir(parents=True, exist_ok=True)
    defaults, chars = load_cast(root / a.cast)
    mode = a.mode or defaults.get("mode", "dialogue")
    fmt = defaults.get("output_format", "mp3_44100_128")
    dcfg = dialogue_cfg(defaults)

    lines = parse_script(a.script)
    for l in lines:
        l["performed"] = l["text"]
    load_performance(root / a.performance, lines)

    missing = sorted({l["character"] for l in lines if not resolve_voice(l, defaults, chars)})
    if missing and not a.dry_run:
        sys.exit("Assign voices in cast.json before generating: " + ", ".join(missing))
    if missing:
        print("No voice assigned in cast.json for:", ", ".join(missing))

    # ---- voice test ----
    if a.voice_test:
        vt = out / "_voicetest"
        vt.mkdir(exist_ok=True)
        seen = {}
        for l in lines:
            if l["character"] not in seen or (len(seen[l["character"]]["text"]) < 25 <= len(l["text"])):
                seen[l["character"]] = l
        for c, l in seen.items():
            v = resolve_voice(l, defaults, chars)
            try:
                audio, _, _ = dialogue([{"text": l["performed"], "voice_id": v["voice_id"]}], dcfg, fmt)
                f = vt / f'{char_key(c)}__{re.sub(r"[^A-Za-z0-9]+", "", v["voice_name"])}.{ext_for(fmt)}'
                f.write_bytes(audio)
                print(f'ok    {c:<20} {v["voice_name"]:<20} → {f.relative_to(root)}')
            except Exception as e:
                print(f'FAIL  {c:<20} {v["voice_name"]:<20} {e}')
        return

    man_path = root / "manifest.json"
    old = {l["id"]: l for l in json.loads(man_path.read_text())["lines"]} if man_path.exists() else {}
    only = set(a.only.split(",")) if a.only else None
    retake = set(a.retake.split(",")) if a.retake else set()
    if retake and only is None:
        only = set(retake)

    def save():
        man_path.write_text(json.dumps({"script": Path(a.script).name, "mode": mode,
                                        "output_format": fmt, "lines": lines}, indent=2))

    # ---- per-line bookkeeping ----
    for l in lines:
        prev = old.get(l["id"], {})
        l["takes"] = prev.get("takes", [])
        l["selected_take"] = prev.get("selected_take")
        if prev.get("pin_take"):
            l["pin_take"] = prev["pin_take"]
        v = resolve_voice(l, defaults, chars, allow_placeholder=a.dry_run)
        l["_v"] = v
        if not v:
            continue
        l.update(voice_name=v["voice_name"], voice_id=v["voice_id"])
        if mode == "dialogue":
            l["model_id"] = dcfg["model_id"]
            l["hash"] = content_hash("dlg", l["performed"], v["voice_id"], dcfg, fmt)
        else:
            l["model_id"] = v["model_id"]
            l["hash"] = content_hash(l["text"], v["voice_id"], v["model_id"], v["settings"], fmt)
        l["_current"] = next((t for t in l["takes"]
                              if t["hash"] == l["hash"] and (root / t["file"]).exists()), None)

    def wanted(l):
        return (only is None or l["id"] in only) and (a.page is None or l["page"] == a.page)

    def needs(l):
        return l["_v"] and (l["_current"] is None or l["id"] in retake)

    def add_take(l, rel, extra, take_no=None):
        take_no = take_no or int(re.search(r"_t(\d+)\.\w+$", rel).group(1))
        l["takes"].append({"take": take_no, "file": rel, "hash": l["hash"],
                           "duration": duration(root / rel),
                           "created": time.strftime("%Y-%m-%dT%H:%M:%S"), **extra})
        l["selected_take"] = take_no
        l["_current"] = l["takes"][-1]

    made = 0
    chunks = build_chunks(lines)
    single = a.single or mode == "line"

    if mode == "dialogue" and not single:
        for ci, ch in enumerate(chunks):
            todo = [l for l in ch["lines"] if needs(l)]
            if not todo or not any(wanted(l) for l in ch["lines"]):
                continue
            if any(not l["_v"] for l in ch["lines"]):
                continue
            n_chars = sum(len(l["performed"]) for l in ch["lines"])
            if a.dry_run:
                print(f'would generate scene {ch["id"]}: {len(ch["lines"])} lines, {n_chars} chars')
                for l in ch["lines"]:
                    l["_would"] = True
                continue

            def chunk_rid(c):
                t = latest_take(c["lines"][0]) if c else None
                return t.get("request_id") if t and t.get("mode") == "dialogue" \
                    and t.get("model") == dcfg["model_id"] else None
            prev_ids = [r for r in [chunk_rid(chunks[ci - 1]) if ci else None] if r]
            next_ids = [r for r in [chunk_rid(chunks[ci + 1]) if ci + 1 < len(chunks) else None] if r]

            print(f'→ scene {ch["id"]}: {len(ch["lines"])} lines, {n_chars} chars')
            inputs = [{"text": l["performed"], "voice_id": l["voice_id"]} for l in ch["lines"]]
            audio, j, rid = dialogue(inputs, dcfg, fmt, prev_ids, next_ids)

            scene_take = 1 + len(list((out / "_scenes").glob(f'{ch["id"]}_t*.*')))
            scene_rel = f'{a.out}/_scenes/{ch["id"]}_t{scene_take}.{ext_for(fmt)}'
            (root / scene_rel).write_bytes(audio)
            (out / "_alignment" / f'{ch["id"]}_t{scene_take}.json').write_text(
                json.dumps({k: j.get(k) for k in ("voice_segments", "alignment")}))
            scene_len = duration(root / scene_rel) or 1e9

            spans = {}
            for s in j.get("voice_segments", []):
                i = s["dialogue_input_index"]
                a0, b0 = spans.get(i, (1e9, -1))
                spans[i] = (min(a0, s["start_time_seconds"]), max(b0, s["end_time_seconds"]))
            for i, l in enumerate(ch["lines"]):
                if i not in spans:
                    print(f'  ! {l["id"]} missing from the scene audio — retake with --single')
                    continue
                s, e = spans[i]
                prev_end = max([spans[k][1] for k in spans if k < i], default=0)
                next_start = min([spans[k][0] for k in spans if k > i], default=scene_len)
                cs, ce = max(prev_end, s - PAD_BEFORE, 0), min(next_start, e + PAD_AFTER, scene_len)
                take_no = 1 + max([t["take"] for t in l["takes"]], default=0)
                info = {"mode": "dialogue", "model": dcfg["model_id"], "chunk": ch["id"],
                        "scene_file": scene_rel, "scene_start": round(cs, 3),
                        "scene_end": round(ce, 3), "request_id": rid}
                if a.scenes_only:          # no clip: the take points at the scene file
                    add_take(l, scene_rel, {**info, "scene_only": True}, take_no)
                    continue
                rel = f'{a.out}/{clip_name(l, l["voice_name"], take_no, "wav")}'
                cut(root / scene_rel, root / rel, cs, ce)
                add_take(l, rel, info)
                made += 1
            print(f'  {scene_rel}  ({scene_len:.1f}s)')
            made += len(ch["lines"]) if a.scenes_only else 0
            save()
    else:
        for i, l in enumerate(lines):
            if not (needs(l) and wanted(l)):
                continue
            if a.dry_run:
                l["_would"] = True
                continue
            v = l["_v"]
            take_no = 1 + max([t["take"] for t in l["takes"]], default=0)
            if mode == "dialogue":       # --single retake on the dialogue model
                model, settings, ext = dcfg["model_id"], {"stability": dcfg["stability"]}, ext_for(fmt)
                text = l["performed"]
                prev_t = lines[i - 1]["text"] if i else None
                next_t = lines[i + 1]["text"] if i + 1 < len(lines) else None
                prev_ids = None
            else:
                model, settings, ext, text = v["model_id"], v["settings"], ext_for(fmt), l["text"]
                same = [x for x in lines if x["character"] == l["character"] and x["page"] == l["page"]]
                k = same.index(l)
                prev_t = same[k - 1]["text"] if k else None
                next_t = same[k + 1]["text"] if k + 1 < len(same) else None
                prev_ids = [t["request_id"] for t in (same[k - 1]["takes"][-1:] if k else [])
                            if t.get("request_id") and t.get("mode", "line") == "line"]
            print(f'→ {l["id"]}  {l["character"]}: {text[:60]}')
            audio, j, rid = tts(text, v["voice_id"], model, settings, fmt, prev_t, next_t, prev_ids)
            rel = f'{a.out}/{clip_name(l, v["voice_name"], take_no, ext)}'
            (root / rel).write_bytes(audio)
            if j.get("alignment"):
                (out / "_alignment" / (Path(rel).stem + ".json")).write_text(json.dumps(j["alignment"]))
            add_take(l, rel, {"mode": "line", "model": model, "request_id": rid})
            made += 1
            save()

    # ---- status + outputs ----
    for l in lines:
        if not l["_v"]:
            l["status"] = "no_voice"
        elif l.pop("_would", False):
            l["status"] = "would_generate"
        elif l["_current"]:
            sel = next((t for t in l["takes"] if t["take"] == l["selected_take"]), None)
            if not sel or sel["hash"] != l["hash"]:
                l["selected_take"] = max(t["take"] for t in l["takes"] if t["hash"] == l["hash"])
            l["status"] = "ok"
        else:
            l["status"] = "stale" if l["takes"] else "pending"
        if l.get("pin_take") and any(t["take"] == l["pin_take"] for t in l["takes"]):
            l["selected_take"] = l["pin_take"]      # your manual choice always wins
        sel = next((t for t in l["takes"] if t["take"] == l.get("selected_take")), None)
        l["file"] = sel["file"] if sel and not sel.get("scene_only") else None
        l["scene_file"] = sel.get("scene_file") if sel else None
        l["duration"] = sel["duration"] if sel else None
        for k in ("_v", "_current"):
            l.pop(k, None)
    save()

    with open(root / "manifest.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["id", "chunk", "character", "voice", "status", "take", "duration", "file", "performed"])
        for l in lines:
            w.writerow([l["id"], l.get("chunk", ""), l["character"], l.get("voice_name", ""),
                        l["status"], l.get("selected_take") or "", l.get("duration") or "",
                        l.get("file") or "", l["performed"]])

    with open(root / "scenes.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["scene_file", "id", "character", "start_in_scene", "end_in_scene", "text"])
        for l in lines:
            sel = next((t for t in l["takes"] if t["take"] == l.get("selected_take")), None)
            if sel and sel.get("scene_file"):
                w.writerow([sel["scene_file"], l["id"], l["character"], sel["scene_start"],
                            sel["scene_end"], l["text"]])

    counts = {}
    for l in lines:
        counts[l["status"]] = counts.get(l["status"], 0) + 1
    print(f"[{mode}] {len(lines)} lines | generated {made} | " +
          ", ".join(f"{k}: {v}" for k, v in sorted(counts.items())))


if __name__ == "__main__":
    main()
