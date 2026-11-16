"""Render the level1 chase music (audio/jam/music/canavar_escape.wav) from the team's original.

    python3 tools/audio/make_chase.py [out.wav] [--previews DIR]

Base: audio/jam/music/canavar_escape_original.wav (Bosca Ceol, canavar_escape.ceol):
120 bpm, 16th grid, every Bosca pattern is exactly 1.0 s (8 steps). Motif E3 F3 D#4 . E4 . G#3 D4, key centre E.
  bars 0-2  pattern 0 + 8th-note drums           -> slow source  (we take bar 1: pattern 0 after pattern 0)
  bars 3-5  pattern 1 + heavier drums            -> mid source   (bar 4)
  bars 6-13 pattern 2 + drums + pad B/B/B/B/B/C/B/C -> fast source (bars 12,7..13: every slice has the
            right predecessor, so the original's own note tails line up at every join and at the loop seam)

Each section is now a 16-pattern (16 s = 8 bars of 4/4) circular loop: the original audio is the foundation,
synthesized layers go on top:
  slow: original pattern 0 + heartbeat (60 bpm lub-dub), E bass drone, dark pulse pad (E/B - C - B roots,
        the original's B<->C pad swing), noise swells into each 8-pattern phrase
  mid : original pattern 1 + triangle bass (8ths, E-F neighbour), 16th arpeggio with echo, offbeat hats, pad
  fast: original pattern 2 + driving kick/snare/16th hats, 16th octave bass, the motif an octave up (from 2 s
        into each 8-pattern half), tension riser + snare roll into the loop, crash on the downbeat
Loudness per section (integrated, looped): slow -13.2, mid -12.5, fast -11.8 LUFS, peak <= -1 dBFS
(original file: -12.4 LUFS whole; audio_manager.gd / audio_mapping_test.gd assume ~-12.4).

File layout: each section = 16 s loop + POSTROLL seconds of its own continuation (the start of the loop again),
so the per-frame loop check in Manager_Darkness (seek when pos >= end - 0.05) can fire a few ms late without
ever running into the next section. Section starts are printed; Manager_Darkness.MUZIK_* must match:
  Vector2(start, start + LOOP_S + SEEK_LEAD)
"""
import os
import sys
import wave

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from synth import (Song, circular_delay, circular_reverb, colored_noise, drum_hit, fft_filter,  # noqa: E402
                   measure_lufs, note_to_midi, osc, exp_decay, repo_root, write_wav, SR)

SRC = os.path.join(repo_root(), "audio", "jam", "music", "canavar_escape_original.wav")
OUT = os.path.join(repo_root(), "audio", "jam", "music", "canavar_escape.wav")

BPM = 120
PAT = SR  # one Bosca pattern = 8 sixteenths = 1.0 s = 44100 samples
PATTERNS = 16
LOOP_S = PATTERNS * PAT / SR  # 16.0
POSTROLL = 0.30
# Manager_Darkness seeks when position >= end - 0.05, checked once per frame. With end = loop end + SEEK_LEAD the
# check fires ~8 ms (half a 60 fps frame) before the seam on average, so the jump lands on the seam +-8 ms.
SEEK_LEAD = 0.042
TARGET_LUFS = {"slow": -13.2, "mid": -12.5, "fast": -11.8}
PEAK_DB = -1.2

RNG = np.random.default_rng(77)


def load_wav(path):
    with wave.open(path) as w:
        n, ch = w.getnframes(), w.getnchannels()
        x = np.frombuffer(w.readframes(n), "<i2").astype(np.float64).reshape(-1, ch).T / 32768.0
    return x if ch == 2 else np.vstack([x, x])


def m(name):
    return note_to_midi(name)


# ------------------------------------------------------------------ instruments

PAD = dict(wave="pulse", duty=0.25, a=0.6, d=0.6, s=0.7, r=0.9, vol=0.050, trem=(0.25, 2.0))
PAD_LO = dict(wave="tri", a=0.8, d=0.5, s=0.9, r=1.0, vol=0.10, trem=(0.2, 0.5))
DRONE = dict(wave="tri", a=0.05, d=0.4, s=0.85, r=0.4, vol=0.16)
BASS = dict(wave="tri", a=0.002, d=0.06, s=0.8, r=0.03, vol=0.30)
BASS_GRIT = dict(wave="pulse", duty=0.25, a=0.002, d=0.05, s=0.45, r=0.02, vol=0.045)
ARP = dict(wave="pulse", duty=0.125, a=0.002, d=0.07, s=0.25, r=0.03, vol=0.17)
LEAD_HI = dict(wave="pulse", duty=0.25, a=0.003, d=0.08, s=0.55, r=0.06, vol=0.17, vib=(0.12, 6.0, 0.08))

# Roots per pattern (16): E home, C and B from the original's pad swing; B at the end leads back to E.
ROOTS_SLOW_MID = ["E2"] * 4 + ["C2"] * 2 + ["E2"] * 2 + ["E2"] * 4 + ["C2"] * 2 + ["B1"] * 2
# Fast keeps the original pad order (B B B B B C B C, twice); bass E under the B pad, C under the C pad.
FAST_PAD = list("BBBBBCBC") * 2
ROOTS_FAST = ["E2" if p == "B" else "C2" for p in FAST_PAD]
PAD_NOTES = {"E2": ["E3", "B3"], "C2": ["C3", "C4"], "B1": ["B2", "F#3"]}
ARP_IV = {"E2": [0, 7, 12, 13, 12, 7, 0, 7], "C2": [0, 7, 12, 16, 12, 7, 0, 7],
          "B1": [0, 4, 7, 12, 7, 4, 0, 4]}


def heartbeat(vel=1.0):
    n = int(0.30 * SR)
    t = np.arange(n) / SR
    f = 38 + 34 * np.exp(-t / 0.035)
    s = osc("sine", f, n) * exp_decay(n, 0.09)
    s[: int(0.003 * SR)] *= np.linspace(0, 1, int(0.003 * SR))
    return s * vel


def noise_swell(seconds, lo=300, hi=5000, seed=5):
    n = int(seconds * SR)
    nz = colored_noise(n, lo=lo, hi=hi, tilt=-0.5, seed=seed)
    env = np.linspace(0, 1, n) ** 2.2
    env[-int(0.02 * SR):] *= np.linspace(1, 0, int(0.02 * SR))
    return nz * env


def riser(seconds, seed=9):
    """Noise through a rising band-pass + a rising pulse tone (tension into the loop seam)."""
    n = int(seconds * SR)
    nz = RNG.standard_normal(n + 8192)
    out = np.zeros(n + 8192)
    seg = 4096
    win = np.hanning(2 * seg)
    for i in range(0, n, seg):
        centre = 400 * (16 ** (i / n))
        out[i:i + 2 * seg] += fft_filter(nz[i:i + 2 * seg] * win, lo=centre * 0.6, hi=centre * 1.6)
    out = out[:n]
    t = np.arange(n) / SR
    tone = osc("pulse", 82.4 * 2 ** (2 * t / seconds), n, 0.3) * 0.25
    env = (t / seconds) ** 2
    s = (out / (np.abs(out).max() + 1e-9) + tone) * env
    s[-int(0.01 * SR):] *= np.linspace(1, 0, int(0.01 * SR))
    return s


def crash():
    n = int(1.6 * SR)
    nz = np.diff(osc("noise", 22000, n, seed=11), prepend=0)
    nz = fft_filter(nz, lo=3000)
    return nz * exp_decay(n, 0.45) * 0.5


# ------------------------------------------------------------------ sections

def add_original(song, slices):
    for i, sl in enumerate(slices):
        song.raw(i * 1.0, sl[0], vol=1.0, pan=-1.0, bus="orig")  # pan -1/+1 with vol*sqrt(1) keeps L/R intact
        song.raw(i * 1.0, sl[1], vol=1.0, pan=1.0, bus="orig")


def add_pad(song, roots, vol=1.0):
    i = 0
    while i < len(roots):
        j = i
        while j < len(roots) and roots[j] == roots[i]:
            j += 1
        for k, nn in enumerate(PAD_NOTES[roots[i]]):
            song.tone(i * 8, (j - i) * 8, m(nn), dict(PAD, pan=-0.35 if k == 0 else 0.35), bus="pad", vel=vol)
        song.tone(i * 8, (j - i) * 8, m(roots[i]) + 12, PAD_LO, bus="pad", vel=vol)
        i = j


def slow(orig):
    s = Song(BPM, PATTERNS, steps_per_bar=8)
    add_original(s, [orig[:, 1 * PAT:2 * PAT]] * PATTERNS)
    for p in range(PATTERNS):
        t0 = p * 1.0
        s.raw(t0, heartbeat(1.0), vol=0.55, bus="low")
        s.raw(t0 + 3 * 0.125, heartbeat(0.6), vol=0.55, bus="low")
    # bass drone: long root notes, re-struck every 2 patterns
    for p in range(0, PATTERNS, 2):
        s.tone(p * 8, 16, m(ROOTS_SLOW_MID[p]), DRONE, bus="low")
    add_pad(s, ROOTS_SLOW_MID, vol=1.0)
    for end in (8, 16):  # swell into each phrase start
        s.raw(end - 1.5, noise_swell(1.5, seed=end), vol=0.16, pan=-0.3, bus="fx")
        s.raw(end - 1.5, noise_swell(1.5, seed=end + 1), vol=0.16, pan=0.3, bus="fx")
    return s.render({"pad": lambda x: circular_reverb(x, 2.4, 0.45, 2500),
                     "fx": lambda x: circular_reverb(x, 1.8, 0.4, 4000),
                     "low": lambda x: fft_filter(x, hi=900)})


def mid(orig):
    s = Song(BPM, PATTERNS, steps_per_bar=8)
    add_original(s, [orig[:, 4 * PAT:5 * PAT]] * PATTERNS)
    for p in range(PATTERNS):
        r = m(ROOTS_SLOW_MID[p])
        base = p * 8
        last = (p % 4) == 3
        for st, iv in [(0, 0), (2, 0), (4, 12), (6, 1 if last and ROOTS_SLOW_MID[p] == "E2" else 0)]:
            s.tone(base + st, 1.6, r + iv, BASS, bus="bass")
            s.tone(base + st, 1.0, r + iv + 12, BASS_GRIT, bus="bass")
        for st, iv in enumerate(ARP_IV[ROOTS_SLOW_MID[p]]):
            s.tone(base + st, 0.8, r + 24 + iv, dict(ARP, pan=-0.45 if st % 2 else 0.45), bus="arp",
                   vel=0.8 + 0.2 * (st == 0))
        for st in (1, 3, 5, 7):
            s.drum(base + st, "hat", vol=0.9, pan=0.25)
    add_pad(s, ROOTS_SLOW_MID, vol=1.0)
    return s.render({"pad": lambda x: circular_reverb(x, 2.2, 0.4, 2800),
                     "arp": lambda x: circular_reverb(circular_delay(x, 0.375, 0.35, 0.35, taps=4), 1.4, 0.25),
                     "bass": lambda x: fft_filter(x, hi=2500)})


def fast(orig):
    s = Song(BPM, PATTERNS, steps_per_bar=8)
    bars = [12, 7, 8, 9, 10, 11, 12, 13] * 2
    add_original(s, [orig[:, b * PAT:(b + 1) * PAT] for b in bars])
    for p in range(PATTERNS):
        r = m(ROOTS_FAST[p])
        base = p * 8
        s.drum(base + 0, "kick", vol=1.0)
        s.drum(base + 3, "kick", vol=0.6)
        s.drum(base + 4, "snare", vol=0.7)
        for st in range(8):
            s.drum(base + st, "hat", vol=0.45 if st % 2 else 0.25, pan=-0.2)
        if p % 2 == 1:
            s.drum(base + 6, "ohat", vol=0.4, pan=0.2)
        for st in range(8):
            iv = 12 if st % 2 else 0
            s.tone(base + st, 0.8, r + iv, BASS, bus="bass", vel=0.85)
            s.tone(base + st, 0.6, r + iv + 12, BASS_GRIT, bus="bass")
        # the motif one octave up (E4 F4 D#5 . E5 . G#4 D5) from 2 s into each 8-pattern half: in level1 the
        # trigger zones switch sections every ~3-7 s, so layers that only start late in the loop are rarely heard
        if p % 8 >= 2:
            for st, nn, ln in [(0, "E4", 1), (1, "F4", 1), (2, "D#5", 2), (4, "E5", 2), (6, "G#4", 1), (7, "D5", 1)]:
                s.tone(base + st, ln * 0.9, m(nn), dict(LEAD_HI, pan=0.3), bus="lead")
    # snare roll + riser over the last two patterns, crash on the downbeat (wraps to the loop start)
    for st in range(16):
        s.drum(14 * 8 + st, "snare", vol=0.15 + 0.4 * st / 15, pan=0.1)
    rs = riser(2.0)
    s.raw(14.0, rs, vol=0.10, pan=-0.25, bus="fx")
    s.raw(14.0, np.roll(rs, 300), vol=0.10, pan=0.25, bus="fx")
    s.raw(0.0, crash(), vol=0.35, pan=0.0, bus="fx")
    add_pad(s, ROOTS_FAST, vol=0.6)
    return s.render({"pad": lambda x: circular_reverb(x, 2.0, 0.35, 3000),
                     "lead": lambda x: circular_delay(x, 0.375, 0.3, 0.3, taps=3),
                     "fx": lambda x: circular_reverb(x, 1.2, 0.25, 6000),
                     "bass": lambda x: fft_filter(x, hi=3000)})


# ------------------------------------------------------------------ mastering

def _run_min(x, w):
    """Circular running minimum over a centred window of 2*w+1 samples (doubling shifts)."""
    out = x.copy()
    covered = 0
    while covered < w:
        sh = min(covered + 1, w - covered)
        out = np.minimum(out, np.minimum(np.roll(out, sh), np.roll(out, -sh)))
        covered += sh
    return out


def limit(x, peak_db=PEAK_DB, look_s=0.004):
    """Zero-phase circular look-ahead peak limiter: gain = box-average of the running-min required gain."""
    lim = 10 ** (peak_db / 20)
    a = np.abs(x).max(0)
    need = np.minimum(1.0, lim / np.maximum(a, 1e-9))
    w = int(look_s * SR)
    g = _run_min(need, w)
    k = np.zeros(len(g))  # centred box of width w (< the 2w+1 min window) -> smoothed gain <= need everywhere
    k[np.arange(-(w // 2), w - w // 2) % len(g)] = 1.0 / w
    G = np.fft.irfft(np.fft.rfft(g) * np.fft.rfft(k), len(g))
    G = np.minimum(G, 1.0)
    y = x * G
    return np.clip(y, -lim, lim)


def master(x, target):
    x = x / (np.abs(x).max() + 1e-9) * 0.5
    for _ in range(4):
        cur = measure_lufs(np.tile(x, 2))
        x = x * 10 ** ((target - cur) / 20)
        x = limit(x)
    return x


def build(orig_path=SRC, out_path=OUT, preview_dir=None):
    orig = load_wav(orig_path)
    secs = {}
    for name, fn in [("slow", slow), ("mid", mid), ("fast", fast)]:
        loop = master(fn(orig), TARGET_LUFS[name])
        secs[name] = loop
        print("%-4s LUFS %.2f peak %.2f dBFS" % (name, measure_lufs(np.tile(loop, 2)),
                                                 20 * np.log10(np.abs(loop).max())))
    pr = int(POSTROLL * SR)
    parts, starts, t = [], {}, 0
    for name in ("slow", "mid", "fast"):
        starts[name] = t / SR
        blk = np.concatenate([secs[name], secs[name][:, :pr]], axis=1)
        parts.append(blk)
        t += blk.shape[1]
    full = np.concatenate(parts, axis=1)
    write_wav(out_path, full)
    for name in ("slow", "mid", "fast"):
        s0 = starts[name]
        print("const MUZIK_%s := Vector2(%.3f, %.3f)" % (name, s0, s0 + LOOP_S + SEEK_LEAD))
    print("wrote", out_path, "%.2f s" % (full.shape[1] / SR))
    if preview_dir:
        os.makedirs(preview_dir, exist_ok=True)
        for name in ("slow", "mid", "fast"):
            write_wav(os.path.join(preview_dir, "preview_%s.wav" % name), np.tile(secs[name], 2))
    return secs, starts


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    prev = None
    if "--previews" in sys.argv:
        prev = sys.argv[sys.argv.index("--previews") + 1]
        args = [a for a in args if a != prev]
    build(out_path=args[0] if args else OUT, preview_dir=prev)
