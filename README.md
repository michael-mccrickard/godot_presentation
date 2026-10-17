# Presentation Player

A Godot 4 tool for building and playing back still-image presentations with camera
moves (zoom and pan), transitions, and audio sync. The picture is drawn in real time
from the original image pixels, so there is no video compression or rescaling of your
stills. Everything you author is stored in one file, `presentation.json`, and the
player is generic: the presentation is data.

Developed and tested with Godot 4.7 using the Compatibility renderer (set in
`project.godot`).

## Project layout

| Path | What it is |
| --- | --- |
| `images/` | Your still images (png, jpg, jpeg, webp, bmp, tga). Shots are created in file-name order, with numbers compared as numbers (see "Naming and order"). |
| `audio/track.wav` | Optional soundtrack, used when a new presentation is first created. |
| `presentation.json` | The saved presentation: shot order, timings, camera framing, transitions. |
| `scripts/` | The code. `shot.gd` is the data for one shot; `presentation_player.gd` plays it back. |
| `shaders/transition.gdshader` | The transition shader. |

## The window

The window is 1280 x 1032:

- **Top bar (196 px):**
  - **Status line:** play/pause, time, the next shot `M` will mark, save status, and
	notices. The **Rewind**, **End** and **Trash** buttons sit to its right.
  - **Shot info box:** the shot on screen at the playhead: its number, file name and
	marker time, whether it has a camera move (`Full frame`, `Framed, no move`, or
	`Move`), and the **transition into it**, which you can change here (see
	"Transitions").
  - **Key hints:** the main shortcuts.
- **Presentation view (1280 x 720):** exactly what the audience sees. Letterbox bars
  inside it are black.
- **Timeline strip (bottom, 116 px):** the audio waveform (when available), a time
  ruler, your shot markers (yellow, numbered), and the red playhead.

`Tab` hides everything except the presentation view.

## Starting a new presentation

When the project starts and there is **no `presentation.json`** (or it is empty, or
cannot be read) and `images/` has images, a dialog offers to **scaffold** one:

- **Scaffold (Enter):** every image becomes a shot, in name order, **2 seconds each**,
  joined by **cuts** (no transitions), each framed Full. For 76 images that is a
  152-second presentation with a marker every 2 seconds. It is saved immediately.
  From there you adjust: drag markers to retime, press `C` to frame moves, and edit
  `transition` in the JSON where you want something other than a cut.
- **Start empty (Esc):** the old behaviour. Shot 1 is placed at 0:00 and the other
  shots wait for you to tap `M`. Nothing is saved until you make an edit, so the dialog
  appears again next time until you do.

The length and transition of a scaffold are set in `scripts/presentation_data.gd`
(`SCAFFOLD_SECONDS`, and `make_scaffold`).

If a `presentation.json` exists but is not valid JSON (for example a typo from editing
it by hand), a copy is saved next to it as `presentation.json.broken` before anything
can overwrite it, and the status line says so.

## Authoring workflow

1. **Add images.** Put them in `images/`. On first run, one shot is created per image,
   in file-name order. Shot 1 starts at 0:00; the rest are waiting to be marked.
   Images you add later are picked up the next time the project starts and placed by
   name (see "Naming and order" and "Adding or replacing images").
2. **Add audio (optional).** Put a WAV at `audio/track.wav` *before the first run*
   (see "Audio" below). With no audio you can still author against a free-running clock.
3. **Mark the cuts.** Press `Space` to start playback and press `M` at the moment each
   next image should appear. Each tap assigns the next unmarked shot. The status line
   shows which shot is next.
4. **Fine-tune.** Drag a marker on the timeline to retime it. Drag it as far as you
   like; it stops just short of its neighbours so shots stay in order.
5. **Frame the camera.** Move the playhead onto a shot and press `C` (see "Camera and
   fit modes").
6. **Choose transitions.** Park the playhead on a shot and pick its transition and duration in the shot info box (see "Transitions").
7. **Preview.** Press `Home` (or the Rewind button), then `Space`.

Every edit is saved automatically (see "Saving").

## Controls

### Keyboard

| Key | Action |
| --- | --- |
| `Space` | Play / pause |
| `M` | Mark: start the first unmarked shot at the playhead (the status line names it) |
| `C` | Open the camera editor for the shot under the playhead |
| `Home` | Rewind to the beginning |
| `End` | Jump to the end |
| `Left` / `Right` | Seek 1 second (hold `Shift` for 5 seconds) |
| `R`, `R` | Clear all marks. Press `R` twice within 3 seconds; the status line asks you to confirm. |
| `S` | Save immediately (not normally needed) |
| `Tab` | Show / hide everything except the presentation view |

### Buttons (top right)

- **|< Rewind** – back to 0:00 (same as `Home`).
- **End >|** – jump to the end of the content (same as `End`). With audio this is the
  end of the audio; without audio it is the end of the last marked shot, which is
  assumed to last as long as the shot before it (4 seconds if there is only one).

### Timeline strip

| Mouse | Action |
| --- | --- |
| Click / drag on empty space | Move the playhead (scrub) |
| Drag a yellow marker | Retime that shot |
| Mouse wheel | Zoom in / out around the cursor |
| `Shift` + wheel | Pan left / right |

## Timing model

- A shot begins at its **marker time** (`start`) and stays on screen until the next
  marked shot begins.
- A shot's **camera move** runs from its start framing to its end framing over the
  shot's whole duration (until the next marker), with the easing you chose.
  Set `move_duration` in the JSON to make the move shorter; the camera then holds its
  end framing for the rest of the shot.
- The master clock is the audio. Every frame is computed from the audio playback
  position (corrected for output latency), so scrubbing and seeking are exact and
  video and sound cannot drift apart.
- If you are late or early when tapping `M`, change `TAP_OFFSET` in `scripts/main.gd`
  (seconds; negative means earlier), or just drag the marker afterwards.

## Starting over (Trash)

The **Trash** button (top right) deletes the whole presentation: every marker, camera
framing and transition. It asks for confirmation first. The current
`presentation.json` is copied to `presentation.json.bak`, the file is emptied, and the
first-run sequence starts again (the scaffold question, if `images/` has images). To
get the old presentation back, close the player and rename the `.bak` file to
`presentation.json`.

## Naming and order

Shots are ordered by image file name, and **numbers inside names are compared as
numbers**, so `p1_f2` comes before `p1_f10`, and `p2_f1` before `p10_f1`. You do **not**
need zero-padded names (`p1_f02`). Zero-padded names also work, so use whichever you
prefer. Capital letters are ignored; the folder name and extension do not affect order.

Two things decide where a shot sits in the list:

- **Marked shots are the timeline.** A shot that has a marker keeps its place in the
  list; its time is what matters, and the program never reorders it. Using the same
  image more than once (a repeat later in the show) is fine, because those shots are
  marked in place.
- **Unmarked shots follow name order.** They are the ones still waiting for `M`. New
  images are slotted in by name when the program starts (see below), so a file such as
  `p2_f3a.png` lands between `p2_f3` and `p2_f4`.

## Adding or replacing images

- **New images.** Drop them into `images/`, let Godot import them (it does this when
  the editor window regains focus), and start the project. Any image that no shot uses
  yet becomes a new, unmarked shot **placed by name**: right after the last shot whose
  name sorts at or before it. For example, a new `p3_f10` lands after `p3_f9`, and a new
  `p1_f05` lands between `p1_f4` and `p1_f6`. The status line says how many were added,
  and the change is saved automatically. A new shot between two marked shots is
  marked by moving the playhead to a time between them and pressing `M`; `M` always
  marks the first unmarked shot in the list, so it never overwrites a marked one.
- **Replaced images.** If you overwrite an existing file (same name), the shot keeps its
  timing and transition and shows the new picture. A shot that was framed in the camera
  editor keeps its old framing, which may not suit a different shape; press `C` on it
  and `0` (or `F`) to reset it to Full.
- **Renamed images.** If you rename a file only in its zero padding or extension
  (`p1_f1.png` to `p1_f01.png`, or `.png` to `.jpg`), the shot is relinked to the new
  name and keeps its marker, framing, and transition. The status line reports it. Any
  other rename looks like a new image, and the shot with the old name stays behind.
- **Removed images.** A shot whose file is gone stays in the list and shows
  `Could not load image: ...` in the status line. Edit that shot's `image_path` in
  `presentation.json`.
- **Changing the order by hand.** Shot order is the order in the JSON. There is no
  on-screen way to move a marked shot.

## Camera and fit modes

Each shot has a **start** and an **end** framing. If they are the same, the shot is
static; if they differ, the camera glides between them (a Ken Burns move). Zoom is
interpolated evenly in log space so zooms feel smooth at any scale.

A shot you have not framed is set to **Full**: the whole image is visible. Press `C`
to change that.

### Camera editor

`C` pauses playback and shows the whole image with two rectangles: **START** (green)
and **END** (red). The rectangle is exactly the part of the image the audience will see.

| Key / mouse | Action |
| --- | --- |
| `1` / `2` | Choose the START or END rectangle to edit |
| Drag | Move the rectangle (click anywhere to jump it there) |
| Mouse wheel | Zoom the rectangle (`Shift` for fine steps) |
| `Up` / `Down` | Crop in / out in 0.5% steps (`Shift` = 2%); hold to repeat |
| `F` | **Full** – the whole image is visible (bars on whichever sides are short) |
| `V` | **Full vertical** – the image height fills the frame (bars at the sides, or the sides are clipped) |
| `W` | **Full horizontal** – the image width fills the frame (bars top and bottom, or the top and bottom are clipped) |
| `H` | Hold – make END equal START (no move) |
| `0` | Reset both rectangles to Full |
| `[` / `]` | Previous / next shot |
| `Enter` | Apply and preview: replays the shot from its start |
| `Esc` | Cancel the changes made to the shot you are editing |

The timeline is hidden while the camera editor is open.

**Cropping a still image:** to trim a little off an image (a scanned border, say),
press `Up` a few times on the START frame, drag it into place, then press `H` so END
matches. The header shows how much is trimmed from each side (`trim L … R … T … B …`).
The frame is always 16:9, so both axes scale together; on an image that is not 16:9
only the axis that fills the frame is actually trimmed, and the other just loses some
of its black bars.

**Very wide or very tall images:** the frame is always 16:9. On an image much wider
than that (a 2.4:1 panel, say), a frame showing most of the width is taller than the
image, so it stays centered vertically and you can only drag it left and right. The
header shows how far to zoom in before up/down movement unlocks (for example
`[up/down locked until zoomed past 1.37x]`). Very tall images lock left/right the same
way.

`F`, `V`, and `W` set the rectangle you are editing, so a move can travel from one fit
to another (for example, from Full to Full vertical). The zoom labels (`1.00x`,
`2.32x`) are relative to the image width filling the frame.

## Transitions

A transition controls how the **previous shot changes into this one**. It is stored on
the *incoming* shot. It starts at that shot's marker time and lasts
`transition_duration` seconds. The first shot has nothing to transition from, so its
setting does nothing.

| `transition` value | Name | What it looks like |
| --- | --- | --- |
| `0` | `CUT` | Instant cut. |
| `1` | `CROSSFADE` | The old image fades into the new one. |
| `2` | `WIPE` | A soft-edged wipe from left to right. |
| `3` | `IRIS` | The new image opens outward from the center of the frame. |
| `4` | `MASK_DISSOLVE` | A dissolve through a cloud-like noise pattern. |

Every shot starts as a cut: scaffolded presentations, empty ones, and images added
later. (Only the generated demo, used when `images/` is empty, cycles through the
styles.)

**Changing a transition:** move the playhead onto the shot (click the timeline, or
seek with the arrow keys), then use the shot info box:

- Click **Cut**, **Crossfade**, **Wipe**, **Iris**, or **Mask Dissolve**. The selected
  one is highlighted.
- Use **-** and **+** next to **Duration** to change the length in 0.25 s steps
  (0.25 to 10 s). Duration does not apply to a cut.
- The change is saved automatically and shows immediately in the view.
- The box warns you if the transition is longer than the time until the next marker.
- The first shot has nothing to transition from, so its controls are disabled.

You can also edit `transition` and `transition_duration` in `presentation.json`
(close the player first, since it rewrites the file on every edit).

Things to know:

- `CUT` or a duration of `0` both give a hard cut.
- While a transition runs, both images are on screen. The outgoing shot holds its end
  framing; the incoming shot's camera move is already underway.
- Keep markers at least as far apart as the transition lasts. If the next marker
  arrives before a transition finishes, the transition is cut short.
- The shader is `shaders/transition.gdshader`; adding a new style means adding a mode
  there and a matching entry in the `Transition` enum in `scripts/shot.gd`.

## Easing

`easing` controls how a camera move accelerates:

| Value | Name | Feel |
| --- | --- | --- |
| `0` | `LINEAR` | Constant speed |
| `1` | `SMOOTH` | Eases in and out (the default) |
| `2` | `EASE_IN` | Starts slowly, speeds up |
| `3` | `EASE_OUT` | Starts quickly, slows down |

Like transitions, easing is set in `presentation.json` for now.

## Saving

Every edit is written to `presentation.json` automatically about 0.4 seconds after you
make it: marking a shot, dragging a marker, any change in the camera editor, and clearing
marks. The status line shows `unsaved` while a save is pending and `saved HH:MM:SS`
afterwards. A pending save is also written when you close the window.

- Running from the Godot editor, the file is `res://presentation.json` (the project
  folder), so it can be committed to git.
- In an exported build the player reads and writes `user://presentation.json`. On macOS
  that is `~/Library/Application Support/Godot/app_userdata/PresentationPlayer/`. If
  that file does not exist, it falls back to a `presentation.json` packed into the
  export (add `*.json` to the export's resource filters to include it).
- Because saving is automatic, `R` (clear all marks) cannot be undone from the app. It
  asks for a second press for that reason. Committing `presentation.json` to git gives
  you an undo.

## `presentation.json` reference

```json
{
  "audio_path": "res://audio/track.wav",
  "shots": [
	{
	  "image_path": "res://images/p1_f1.png",
	  "auto_fit": true,
	  "start": 0.0,
	  "move_duration": 0.0,
	  "cam_start": [0.0, 0.0, 1.0, 1.0],
	  "cam_end": [0.0, 0.0, 1.0, 1.0],
	  "easing": 1,
	  "transition": 0,
	  "transition_duration": 1.0
	}
  ]
}
```

| Field | Meaning |
| --- | --- |
| `audio_path` | Soundtrack. Empty for none. |
| `image_path` | The image. `res://...` paths use Godot's import; other paths are loaded directly. |
| `auto_fit` | `true`: the shot is simply Full and the two rectangles are ignored. Becomes `false` as soon as you change the framing in the camera editor. |
| `start` | Marker time in seconds. `-1` means not marked yet. |
| `move_duration` | Camera move length in seconds. `0` means "until the next marker". |
| `cam_start`, `cam_end` | Framing as `[x, y, width, height]`, fractions of the image. Only the center and the width are used: `width` is the fraction of the image width that is visible (`1.0` = the whole width, `0.5` = 2x zoom). |
| `easing` | See "Easing". |
| `transition`, `transition_duration` | See "Transitions". |

## Audio

- **Waveform:** shown only for uncompressed WAV files. In Godot's Import tab, leave the
  WAV's compress mode set to Disabled. MP3 and Ogg files still play but show no
  waveform; convert them to WAV for authoring.
- **Choosing the file:** a new presentation uses `audio/track.wav` if it exists. Once
  `presentation.json` exists, edit its `audio_path` to change the soundtrack (with the
  player closed).
- **No audio:** the timeline runs on a free-running clock and keeps extending as you
  play, so you can keep tapping marks. Timings are plain seconds, so they remain valid
  when you add audio later (they will only line up if the audio is timed the same way).
- **Markers from another tool:** `start` values are seconds, so cut times exported from
  a DAW or Audacity can be pasted into the JSON.

## Known limitations

- Easing and `move_duration` have no on-screen controls yet; edit the JSON.
- There is no on-screen way to move a marked shot or to drag shots into a custom order;
  edit the order in `presentation.json` if you need that.
- The waveform needs an uncompressed WAV.

## Image quality

For the sharpest result, keep the image imports on Lossless (not VRAM-compressed) with
mipmaps enabled, and keep each image under the GPU texture size limit (about 16384 px
per side). The picture is rendered at 1920 x 1080 internally and shown in the
1280 x 720 view.
