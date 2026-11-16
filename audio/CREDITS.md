# Audio credits & licensing

## Third-party sounds

| Files in this repo | Source | Author | License |
|---|---|---|---|
| `audio/footsteps/grass_0..4.wav` | `footstep_grass_000..004.ogg` from **Impact Sounds** (v1.0): https://kenney.nl/assets/impact-sounds | Kenney (www.kenney.nl) | CC0 1.0: http://creativecommons.org/publicdomain/zero/1.0/ |
| `audio/footsteps/stone_0..4.wav` | `footstep_concrete_000..004.ogg` from **Impact Sounds** (v1.0): https://kenney.nl/assets/impact-sounds | Kenney (www.kenney.nl) | CC0 1.0 |

The footsteps were edited with `tools/audio/process_footsteps.py`: trimmed to 0.12–0.20 s, band-limited,
stone pitched down about 12 %, held at 14.7 kHz and quantised to 8-bit (light bitcrush), then peak-normalised.
CC0 does not require attribution; we credit Kenney anyway.

## Original audio (made for this game)

Everything else under `audio/` is original. It was synthesised from scratch with the numpy scripts in
`tools/audio/`, with no samples involved:

| File | Generator | Notes |
|---|---|---|
| `music/menu_theme.ogg` | `make_music.py` (`menu`) | 80 bpm, E minor/Phrygian, 48 s loop |
| `music/forest_theme.ogg` | `make_music.py` (`forest`) | 120 bpm, E Phrygian/minor, 64 s loop (3_part + level2) |
| `music/lantern_cave.ogg` | `make_music.py` (`lantern_cave`) | 60 bpm, E pedal, 64 s loop (level1_2) |
| `music/ending_sting.ogg` | `make_music.py` (`ending`) | 9 s one-shot, F → E major resolution |
| `ambient/forest_ambient.ogg` | `make_ambient.py` | wind, crickets, owl, birds, distant growl (60 s loop) |
| `ambient/cave_ambient.ogg` | `make_ambient.py` | drone, rumble, drips, pebbles (60 s loop) |
| `sfx/*.wav` | `make_sfx.py` | jump, orb_jump, land, dash, orb_dash, hurt, death, heal, checkpoint, pickup, lantern_pickup, lantern_on/off/empty, ui_hover/click/start, whoosh |

### Tracks based on the team's chase music (canavar_escape)

The chase music `audio/jam/music/canavar_escape.wav` was made by the team in Bosca Ceol.
Its project file is kept at `tools/audio/reference/canavar_escape.ceol`, and
`tools/audio/parse_ceol.py` dumps its contents. The new tracks borrow its material:

- tempo 120 bpm: the forest theme uses the same tempo, the menu 2/3 of it (80) and the lantern cave half (60)
- lead motif `E F D# . E . G# D` (16th notes):
  - **forest_theme** plays it literally as its hook
  - **menu_theme** plays it augmented (stretched in time)
  - **lantern_cave** plays it 16× slower, in fragments
  - **ending_sting** opens with an F–E / D#–E variation
- half-step pad swing B ↔ C, and the E–F rub:
  - forest bass line (E→F neighbour note)
  - lantern-cave drone (E–F, C–B)
  - the death SFX (ends on a low E/F rub)

## Re-rendering

```
python3 tools/audio/make_music.py        # or: make_music.py forest
python3 tools/audio/make_ambient.py
python3 tools/audio/make_sfx.py
python3 tools/audio/process_footsteps.py /path/to/kenney_impact-sounds/Audio
```

`make_sfx.py` also takes names (`python3 tools/audio/make_sfx.py death pickup`) and renders deterministically,
so re-rendering one sound leaves the others byte-identical.

You need Python 3, numpy and ffmpeg (with libvorbis). Music is normalised to about -17 LUFS (lantern cave -18,
sting -16), ambience to -27 LUFS, and SFX are peak-normalised (-3 to -12 dBFS).

## Mix

Levels are set in `scripts/audio/audio_manager.gd`:

- `MASTER/MUSIC/SFX/AMBIENT_VOLUME_DB` at the top of the file are applied to the buses at startup.
  `default_bus_layout.tres` holds the same values for the editor.
- `MUSIC_DB`, `SCENE_MUSIC_NODE_DB` (the level1 chase music), `SFX_DB`, `FOOTSTEP_DB` and `SCENE_AUDIO.ambient_db` set
  per-sound levels.

Master has a HardLimiter (ceiling -1 dB). `play_sfx` has a per-sound retrigger cooldown (`SFX_MIN_INTERVAL`, default
0.05 s), and no sound plays more than `MAX_VOICES_PER_SOUND` (2) copies at once. The checkpoint chime plays only the
first time each heal zone is activated in a level, not again on respawn. The music, including the chase music, is
ducked by 10 dB while the death sound plays.

Effective level = file loudness + per-sound dB + bus dB. Music and ambience are integrated LUFS. SFX use max
momentary loudness (400 ms window; for sounds shorter than 0.4 s this reads low).

| Sound | Effective level before | Effective level after (Nov 2026 playtest) |
|---|---|---|
| chase music (canavar_escape, level1) | -20.4 | **-15.4** (loudest music) |
| lantern_cave music | -21 | -22 |
| forest / menu music | -20 | -23 |
| ending sting | -19 | -20 |
| forest ambient (levels / menu) | -29 / -41 | -32 / -42 |
| cave ambient (level1 / level1_2) | -33 / -29 | -34 / -32 |
| hurt | -12.5 | -15.5 |
| death | -12.7 (bright square, centroid 4.7 kHz) | -17.1 (re-rendered: soft, 1.5 kHz) |
| jump / dash | -14.4 / -15.6 | -17.9 / -18.1 |
| orb_jump / orb_dash | -17.5 / -17.4 | -19.0 / -18.9 |
| land | -30.2 | -28.2 |
| pickup | -11.7 (centroid 6.1 kHz) | -21.8 (re-rendered, low-passed: 2.2 kHz) |
| lantern_pickup | -12.8 | -20.8 |
| checkpoint | -15.9, on every respawn | -22.9, first activation only |
| heal tick | -29.6, every 0.3 s | -33.6, at most every 0.45 s |
| lantern on / off / empty | -19.8 / -28.7 / -22.9 | -21.8 / -26.7 / -22.9 |
| ui hover / click / start | -33.3 / -21.0 / -14.7 | -33.3 / -22.0 / -18.7 |
| whoosh (scene transition) | -21.2 | -23.2 |
| footsteps grass / stone | -41.5 / -43 | -39.5 / -41 |

## Not used

The older files in `audio/jam/sounds/` (`running_on_grass.mp3`, `running_on_stone ...mp3`,
`heavy-walking.mp3`) have no recorded source or license, so the new system does not use them.
