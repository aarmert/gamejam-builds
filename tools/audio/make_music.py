"""Render the game's music tracks to res://audio/music/*.ogg.

    python3 tools/audio/make_music.py            # all tracks
    python3 tools/audio/make_music.py forest     # one track

Musical source material comes from the team's monster chase theme
(audio/jam/music/canavar_escape.wav, Bosca Ceol project canavar_escape.ceol):
  - tempo 120 bpm, 16th-note grid, key centre E with a Phrygian flat-2 (E-F) half-step
  - lead motif (pattern 0):  E4 F4 D#5 . E5 . G#4 D5   (16ths)
  - pad motif (patterns 6/7): sustained half-step swing B <-> C
Every track below reuses / varies these so the whole game sounds like one family.
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from synth import (Song, circular_delay, circular_reverb, colored_noise, fft_filter, linear_reverb,  # noqa: E402
                   normalize_lufs, note_to_midi, repo_root, save_ogg, SR)

OUT = os.path.join(repo_root(), "audio", "music")
MUSIC_LUFS = -17.0

# The canavar_escape lead motif, literal (16th steps).
CANAVAR_MOTIF = "E4:1 F4:1 D#5:2 E5:2 G#4:1 D5:1"

CHORDS = {
    "Em": ["E", "G", "B"], "F": ["F", "A", "C"], "C": ["C", "E", "G"], "D": ["D", "F#", "A"],
    "G": ["G", "B", "D"], "Am": ["A", "C", "E"], "B": ["B", "D#", "F#"], "B7": ["B", "D#", "A"],
}


def chord_midis(name, octave):
    out, last = [], -1
    for n in CHORDS[name]:
        m = note_to_midi(f"{n}{octave}")
        while m <= last:
            m += 12
        out.append(m)
        last = m
    return out


def root_midi(name, octave):
    return note_to_midi(f"{CHORDS[name][0]}{octave}")


# ---------------------------------------------------------------- instruments
LEAD50 = dict(wave="pulse", duty=0.5, a=0.004, d=0.08, s=0.55, r=0.06, vol=0.16, vib=(0.15, 5.5, 0.18))
LEAD25 = dict(wave="pulse", duty=0.25, a=0.004, d=0.1, s=0.6, r=0.08, vol=0.17, vib=(0.2, 5.0, 0.2))
LEAD12 = dict(wave="pulse", duty=0.125, a=0.01, d=0.2, s=0.5, r=0.2, vol=0.15, vib=(0.25, 4.5, 0.25))
ARP12 = dict(wave="pulse", duty=0.125, a=0.002, d=0.06, s=0.25, r=0.03, vol=0.07)
BASS = dict(wave="tri", a=0.002, d=0.05, s=0.9, r=0.03, vol=0.42)
BASS_PULSE = dict(wave="pulse", duty=0.5, a=0.002, d=0.06, s=0.5, r=0.02, vol=0.08)
PAD = dict(wave="pulse", duty=0.25, a=0.4, d=0.5, s=0.6, r=0.8, vol=0.05, trem=(0.3, 3.0))
DRONE = dict(wave="tri", a=1.0, d=0.5, s=1.0, r=1.5, vol=0.38, trem=(0.25, 0.25))
BELL = dict(wave="tri", a=0.002, d=0.4, s=0.0, r=0.4, vol=0.22)
MUSICBOX = dict(wave="pulse", duty=0.125, a=0.002, d=0.35, s=0.0, r=0.3, vol=0.11)


def arp_bar(song, bar, chord, octave, inst, pattern=(0, 1, 2, 3, 2, 1), steps=16, every=1, vel=1.0):
    notes = chord_midis(chord, octave)
    notes = notes + [notes[0] + 12]
    for i, s in enumerate(range(0, steps, every)):
        song.tone(bar * song.spb + s, every, notes[pattern[i % len(pattern)]], inst, bus="arp", vel=vel)


# ================================================================== MENU
def menu():
    """'Maya's Lullaby' - 80 bpm (2/3 of the chase tempo), music-box arps, motif augmented."""
    s = Song(bpm=80, bars=16)
    prog = ["Em", "F", "Em", "F", "Am", "C", "F", "B",
            "Em", "F", "G", "F", "Am", "F", "B", "B"]
    melody = [
        "E5:4 F5:2 E5:2 B4:8",
        "C5:4 A4:4 F4:8",
        "E5:4 F5:2 D#5:6 E5:4",          # canavar E-F-D#-E motif, augmented
        "A5:6 G5:2 F5:4 E5:4",
        "C5:4 E5:4 A5:8",
        "G5:4 E5:4 C5:4 E5:4",
        "F5:8 E5:4 D5:4",
        "D#5:8 F#5:4 B4:4",
        "B5:4 G5:4 E5:8",
        "F5:4 A5:4 C6:6 B5:2",
        "B5:4 D6:4 B5:4 G5:4",
        "A5:8 F5:4 E5:4",
        "E5:4 F5:2 D#5:2 E5:8",          # motif again
        "C5:4 F5:4 A5:8",
        "F#5:4 D#5:4 B4:8",
        "-:8 F5:4 D#5:4",                # half-step pickup back into E5 at loop start
    ]
    for bar, (ch, mel) in enumerate(zip(prog, melody)):
        # bass: root half notes, octave answer
        r = root_midi(ch, 2)
        s.tone(bar * 16, 7, r, BASS, vel=0.8)
        s.tone(bar * 16 + 8, 7, r + 12 if ch != "B" else r + 7, BASS, vel=0.7)
        # music box arpeggio, 8ths
        arp_bar(s, bar, ch, 4, MUSICBOX, pattern=(0, 1, 2, 3, 2, 1, 2, 1), every=2)
        # pad: canavar B<->C style half-step colour on top of the chord
        for m in chord_midis(ch, 3):
            s.tone(bar * 16, 16, m, PAD, bus="pad", vel=0.8)
        if bar >= 0:
            s.line(bar, mel, LEAD25, bus="lead")
        # soft tick on beats 2 and 4 in the second half
        if bar >= 8:
            for st in (4, 12):
                s.drum(bar * 16 + st, "tick", 0.5)
            s.drum(bar * 16, "softkick", 0.6)
    out = s.render(bus_fx={
        "lead": lambda x: circular_delay(x, s.step_s * 3, 0.35, 0.35),
        "arp": lambda x: circular_delay(x, s.step_s * 6, 0.3, 0.25),
    })
    out = np.stack([circular_reverb(c, 2.2, 0.35) for c in out])
    return s, out


# ================================================================== FOREST
def forest():
    """Eerie-but-adventurous forest - 120 bpm (same as chase), driving 8th bass with the E-F step."""
    s = Song(bpm=120, bars=32)
    A = ["Em", "Em", "C", "D", "Em", "Em", "F", "B"]
    B = ["Am", "Am", "Em", "Em", "F", "G", "B", "B"]
    C = ["C", "D", "Em", "Em", "F", "F", "B", "B"]
    prog = A + B + A + C
    lead_A = [
        CANAVAR_MOTIF + " E5:4 -:4",           # literal chase motif as the hook
        "B4:2 G4:2 E4:2 F4:2 G4:4 B4:4",
        "C5:4 E5:2 G5:2 E5:4 C5:4",
        "D5:4 F#5:2 A5:2 F#5:2 E5:2 D5:4",
        CANAVAR_MOTIF + " E5:4 G5:2 B5:2",
        "A5:2 G5:2 F#5:2 E5:2 B4:8",
        "C5:2 A4:2 F4:2 A4:2 C5:4 F5:4",
        "D#5:4 F#5:4 B5:6 A5:2",
    ]
    lead_B = [
        "E5:6 C5:2 A4:8",
        "B4:4 C5:4 E5:4 A5:4",
        "G5:6 F#5:2 E5:8",
        "B4:4 E5:4 F5:4 E5:4",
        "A5:6 G5:2 F5:4 E5:4",
        "D5:4 G5:4 B5:6 A5:2",
        "F#5:8 D#5:4 F#5:4",
        "B5:12 -:4",
    ]
    lead_C = [
        "E5:8 G5:8",
        "F#5:8 A5:8",
        "B5:12 A5:2 G5:2",
        "E5:16",
        "F5:8 E5:4 F5:4",
        "A5:8 C6:8",
        "B5:8 A5:4 F#5:4",
        "D#5:8 F#4:2 G#4:2 A4:2 D#5:2",
    ]
    for bar, ch in enumerate(prog):
        sec = bar // 8
        r2 = root_midi(ch, 2)
        # ---- bass
        if sec == 3:  # bridge: half-time, long notes
            s.tone(bar * 16, 8, r2, BASS, vel=0.9)
            s.tone(bar * 16 + 8, 6, r2 + 12, BASS, vel=0.7)
            s.tone(bar * 16 + 14, 2, r2 + 1 if ch in ("Em", "B") else r2, BASS, vel=0.6)
        else:
            pat = [0, 0, 12, 0, 0, 12, 0, 12]
            if ch == "Em":
                pat[6] = 1  # the canavar E->F half step
            for i, o in enumerate(pat):
                s.tone(bar * 16 + i * 2, 1.6, r2 + o, BASS, vel=0.85 if i % 2 == 0 else 0.7)
            if sec in (1, 2):
                for i, o in enumerate(pat):
                    s.tone(bar * 16 + i * 2, 1, r2 + 12 + o, BASS_PULSE, bus="bass2")
        # ---- lead
        if sec == 0:
            s.line(bar, lead_A[bar % 8], LEAD50, bus="lead")
        elif sec == 1:
            s.line(bar, lead_B[bar % 8], LEAD25, bus="lead")
        elif sec == 2:
            s.line(bar, lead_A[bar % 8], LEAD25, bus="lead")
            s.line(bar, lead_A[bar % 8], dict(LEAD12, vol=0.06, pan=0.4), bus="lead", octave=1)
        else:
            s.line(bar, lead_C[bar % 8], LEAD12, bus="lead")
            for m in chord_midis(ch, 3):
                s.tone(bar * 16, 16, m, PAD, bus="pad")
        # ---- arps (sections B, A', and bridge)
        if sec >= 1:
            arp_bar(s, bar, ch, 4 if sec != 3 else 5, dict(ARP12, pan=-0.35),
                    pattern=(0, 2, 1, 3), every=1, vel=0.8 if sec != 3 else 0.5)
        # ---- drums
        base = bar * 16
        if sec == 3:
            s.drum(base, "kick", 0.8)
            s.drum(base + 8, "snare", 0.6)
            for st in range(0, 16, 4):
                s.drum(base + st + 2, "hat", 0.6, pan=0.2)
            if bar == 31:
                for st in range(8, 16):
                    s.drum(base + st, "snare", 0.25 + 0.06 * (st - 8))
        else:
            for st in (0, 6, 8) if bar % 4 != 3 else (0, 6, 8, 10, 11):
                s.drum(base + st, "kick", 0.85)
            for st in (4, 12):
                s.drum(base + st, "snare", 0.7)
            for st in range(0, 16, 2):
                s.drum(base + st, "hat", 0.55 if st % 4 else 0.75, pan=0.25)
            if sec == 1 and bar % 2 == 1:
                s.drum(base + 14, "ohat", 0.5, pan=0.25)
    out = s.render(bus_fx={
        "lead": lambda x: circular_delay(x, s.step_s * 3, 0.3, 0.3),
        "arp": lambda x: circular_delay(x, s.step_s * 3, 0.25, 0.2),
    })
    out = np.stack([circular_reverb(c, 1.4, 0.22) for c in out])
    return s, out


# ================================================================== LANTERN CAVE
def lantern_cave():
    """Sparse, tense dark-cave piece - 60 bpm (half the chase tempo)."""
    s = Song(bpm=60, bars=16)
    # drone per bar (octave 1/2) - E pedal with the canavar half steps (E-F, B-C)
    drone = ["E2", "E2", "E2", "F2", "E2", "E2", "C2", "B1",
             "E2", "E2", "E2", "F2", "E2", "E2", "C2", "B1"]
    for bar, n in enumerate(drone):
        m = note_to_midi(n)
        s.tone(bar * 16, 16, m, DRONE)
        s.tone(bar * 16, 16, m + 7 if n.startswith("E") else m + 12,
               dict(DRONE, wave="pulse", duty=0.125, vol=0.025, trem=(0.6, 0.5)), bus="pad")
    # heartbeat from bar 4 on: lub-dub
    for bar in range(4, 16):
        s.drum(bar * 16, "softkick", 0.55)
        s.drum(bar * 16 + 1.2, "softkick", 0.35)
    # lantern glints: sparse pulse notes with long echoes; motif fragments slowed down
    frags = {
        1: "-:4 E5:2 F5:6 -:4",
        3: "-:8 B4:6 -:2",
        5: "D#5:4 E5:8 -:4",
        7: "-:6 G#4:2 D5:6 -:2",          # tail of the chase motif
        9: "-:4 E6:1 F6:3 -:8",
        11: "C5:6 B4:6 -:4",
        13: "E5:4 F5:4 D#5:4 E5:4",       # full motif, 16x slower than the chase
        14: "-:8 G#4:4 D5:4",
    }
    for bar, txt in frags.items():
        s.line(bar, txt, dict(LEAD12, vol=0.12, r=0.4, pan=-0.2), bus="lead")
    # distant bell (triangle) - very rare
    for bar, n in ((2, "B5"), (6, "C6"), (10, "B5"), (15, "F5")):
        s.tone(bar * 16 + 10, 2, note_to_midi(n), dict(BELL, vol=0.1, pan=0.4), bus="lead")
    # quiet ticking (like a lantern mechanism / dripping) every beat in 2nd half
    for bar in range(8, 16):
        for st in (6, 14):
            s.drum(bar * 16 + st, "tick", 0.25, pan=0.5)
    # filtered noise breath swelling every 4 bars
    n = s.n
    breath = colored_noise(n, lo=150, hi=900, tilt=-1, seed=11)
    t = np.arange(n) / SR
    env = (0.5 - 0.5 * np.cos(2 * np.pi * t / (s.length_s / 4))) ** 3
    s.raw(0, breath * env, vol=0.05, bus="pad")
    out = s.render(bus_fx={"lead": lambda x: circular_delay(x, 0.75, 0.5, 0.45, taps=10)})
    out = np.stack([circular_reverb(c, 3.5, 0.45, damp_hz=2500) for c in out])
    return s, out


# ================================================================== ENDING STING
def ending():
    """~7 s one-shot: the E-F half step finally resolves to E major."""
    s = Song(bpm=120, bars=3, loop=False, tail_s=3.0)
    s.line(0, "F5:2 E5:2 F5:2 D#5:2 E5:8", LEAD25, bus="lead")
    for m in chord_midis("F", 3):
        s.tone(0, 6, m, PAD, bus="pad")
    for m in (note_to_midi("E3"), note_to_midi("G#3"), note_to_midi("B3"), note_to_midi("E4")):
        s.tone(8, 32, m, dict(PAD, vol=0.07), bus="pad")
    s.tone(0, 8, note_to_midi("F2"), BASS)
    s.tone(8, 32, note_to_midi("E2"), dict(BASS, r=1.5))
    arp = [note_to_midi(n) for n in ("E5", "G#5", "B5", "E6", "G#6", "B6", "E7")]
    for i, m in enumerate(arp):
        s.tone(16 + i, 8, m, MUSICBOX, bus="arp")
    s.drum(8, "softkick", 0.8)
    out = s.render()
    out = np.stack([linear_reverb(c, 2.5, 0.35)[: s.n] for c in out])
    fade = int(1.0 * SR)
    out[:, -fade:] *= np.linspace(1, 0, fade)
    return s, out


TRACKS = {
    "menu_theme": (menu, MUSIC_LUFS),
    "forest_theme": (forest, MUSIC_LUFS),
    "lantern_cave": (lantern_cave, MUSIC_LUFS - 1.0),
    "ending_sting": (ending, MUSIC_LUFS + 1.0),
}

if __name__ == "__main__":
    want = sys.argv[1:]
    for name, (fn, lufs) in TRACKS.items():
        if want and not any(w in name for w in want):
            continue
        song, audio = fn()
        audio = fft_filter(audio[0], lo=30, hi=14000), fft_filter(audio[1], lo=30, hi=14000)
        audio = normalize_lufs(np.stack(audio), lufs)
        path = os.path.join(OUT, name + ".ogg")
        save_ogg(path, audio)
        print(f"{name}: {song.bpm} bpm, {song.bars} bars, {audio.shape[1] / SR:.2f} s -> {path}")
