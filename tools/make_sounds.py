"""Generates the physical-sounding sound effects into res://audio/ (44.1 kHz, mono, 16-bit WAV).

Every sound is built from filtered noise bursts plus a damped resonant body (wood: modes between about 120 and 600 Hz
decaying in 30 to 120 ms; stone: higher, shorter, sharper click with a little ring; soil, grass and flour: soft
low-passed noise with a gentle attack; water: a band of noise plus random plips). No sine or square beeps, no pitch
sweeps, no chimes. Each sound is made in 3 variants (<name>_1.wav, <name>_2.wav, <name>_3.wav); the game picks one at
random (AudioManager). A file with the plain name (<name>.wav / .ogg / .mp3) overrides the variants.

    python tools/make_sounds.py            (needs numpy)

NEVER OVERWRITES A FILE YOU SUPPLIED. audio/generated_manifest.json records every file this script wrote, with a hash:
 - a file that is not in the manifest, or whose hash no longer matches (you replaced it), is left alone;
 - a plain <name>.wav / .ogg / .mp3 that is not in the manifest means "this sound is supplied": its variants are not
   regenerated;
 - the old placeholder files (from tools/make_placeholder_audio.py, still in use for sounds not listed here) are in the
   manifest under "placeholders" and are never touched by this script.
"""
import hashlib
import json
import os
import sys
import wave
import zlib

import numpy as np

RATE = 44100
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "audio")
MANIFEST = os.path.join(OUT, "generated_manifest.json")
PEAK_DB = -12.0
VARIANTS = 3


# --- primitives ---------------------------------------------------------------------------------------------------

def T(seconds):
    return int(RATE * seconds)


def times(n):
    return np.arange(n) / RATE


def noise(rng, n):
    return rng.standard_normal(n)


def band(x, lo=None, hi=None, order=4):
    """Zero-phase Butterworth-shaped band limit done in the frequency domain (lo / hi in Hz, either may be None)."""
    n = len(x)
    spectrum = np.fft.rfft(x)
    f = np.fft.rfftfreq(n, 1.0 / RATE)
    f[0] = 1e-9
    gain = np.ones_like(f)
    if lo:
        gain = gain / np.sqrt(1.0 + (lo / f) ** (2 * order))
    if hi:
        gain = gain / np.sqrt(1.0 + (f / hi) ** (2 * order))
    return np.fft.irfft(spectrum * gain, n)


def env(n, attack=0.001, tau=0.05):
    """A short attack and a natural exponential decay."""
    e = np.exp(-times(n) / tau)
    a = max(1, T(attack))
    e[:a] *= np.linspace(0.0, 1.0, a)
    return e


def burst(rng, n, lo, hi, attack, tau, order=3):
    return band(noise(rng, n), lo, hi, order) * env(n, attack, tau)


def modes(rng, n, freqs, taus, amps, jitter=0.03):
    """Damped resonances: a body. Each partial gets a little random detune, phase and level."""
    t = times(n)
    out = np.zeros(n)
    for f, tau, a in zip(freqs, taus, amps):
        f = f * (1.0 + rng.uniform(-jitter, jitter))
        out += a * rng.uniform(0.8, 1.2) * np.sin(2 * np.pi * f * t + rng.uniform(0, 2 * np.pi)) * np.exp(-t / (tau * rng.uniform(0.85, 1.15)))
    out *= np.minimum(1.0, t / 0.0004)  # (no click at sample 0)
    return out


def put(dst, src, at, gain=1.0):
    """Mix src into dst starting at `at` seconds (grows nothing: anything past the end is dropped)."""
    start = T(at)
    if start >= len(dst):
        return
    end = min(len(dst), start + len(src))
    dst[start:end] += src[: end - start] * gain


def grains(rng, n, count, lo, hi, tau_lo, tau_hi, span, start=0.0, level=(0.3, 1.0), bandlo=500, bandhi=4000):
    """Many tiny filtered noise grains at random times (crumbling, rustling, patter)."""
    out = np.zeros(n)
    for _ in range(count):
        at = rng.uniform(start, start + span)
        g_n = T(rng.uniform(tau_lo, tau_hi) * 5)
        g = band(noise(rng, g_n), rng.uniform(bandlo, bandlo * 1.6), rng.uniform(bandhi * 0.7, bandhi), 2) * env(g_n, 0.0006, rng.uniform(tau_lo, tau_hi))
        put(out, g, at, rng.uniform(*level))
    return out


def finish(x, peak_db=PEAK_DB, tail=0.004):
    """Normalise to peak_db dBFS; a one-shot also gets its silent tail trimmed and a few ms of fade (tail > 0)."""
    x = np.asarray(x, dtype=np.float64)
    x = x - np.mean(x)
    if tail > 0:
        m = np.max(np.abs(x))
        keep = np.nonzero(np.abs(x) > m * 0.003)[0]
        if len(keep):
            x = x[: min(len(x), keep[-1] + T(0.01))]
        k = min(len(x), T(tail))
        x[-k:] *= np.linspace(1.0, 0.0, k)
    return x / max(1e-9, np.max(np.abs(x))) * (10 ** (peak_db / 20.0))


# --- the materials ------------------------------------------------------------------------------------------------

def wood(rng, f0, t0, crack=1.0, thump=0.8, dur=0.35):
    """A strike on wood: a sharp transient, a low thump, and a body of 4 resonances (about 120 to 600 Hz)."""
    n = T(dur)
    ratios = [1.0, 1.58, 2.21, 3.07]
    amps = [1.0, 0.55, 0.38, 0.2]
    freqs = [min(600.0, max(120.0, f0 * r)) for r in ratios]
    taus = [t0 * (1.0 - 0.2 * i) for i in range(4)]
    x = modes(rng, n, freqs, taus, amps)
    x += crack * 0.9 * burst(rng, n, 1800, 6500, 0.0002, 0.0025)
    x += thump * 1.1 * burst(rng, n, 70, 320, 0.0005, 0.018)
    return x


def stone(rng, f0, dur=0.25, ring=0.2, heavy=0.4):
    """Stone on stone: a high, short, sharp click with a little ring."""
    n = T(dur)
    freqs = [f0, f0 * 1.47, f0 * 2.05, f0 * 2.8]
    taus = [0.018, 0.012, 0.009, 0.006]
    x = modes(rng, n, freqs, taus, [1.0, 0.7, 0.45, 0.3], 0.04)
    x += ring * modes(rng, n, [f0 * 1.22], [0.07], [1.0], 0.02)
    x += 1.0 * burst(rng, n, 3000, 9000, 0.0001, 0.0015)
    x += heavy * burst(rng, n, 120, 380, 0.0004, 0.014)
    return x


def soil(rng, dur=0.3, hi=1100.0, attack=0.010, tau=0.08, body=100.0, grit=6):
    """Earth, grass and flour: soft low-passed noise with a gentle attack, a dull body and a few crumbles."""
    n = T(dur)
    x = burst(rng, n, 60, hi, attack, tau, 2) * 1.0
    if body:
        x += 0.8 * modes(rng, n, [body, body * 1.6], [0.05, 0.03], [1.0, 0.5], 0.06) * np.minimum(1.0, times(n) / 0.004)
    x += 0.5 * grains(rng, n, grit, 0, 0, 0.004, 0.012, dur * 0.6, 0.0, (0.2, 0.7), 300, 2600)
    return x


def squeak(rng, n, lo, hi, pulses, rate=(14, 38)):
    """Wood creak at a constant pitch band: stick-slip pulses of noise, irregular in time and level."""
    x = np.zeros(n)
    t = 0.0
    dur = n / RATE
    while t < dur - 0.02:
        g_n = T(rng.uniform(0.008, 0.022))
        g = band(noise(rng, g_n), lo, hi, 2) * np.hanning(g_n)
        put(x, g, t, rng.uniform(0.4, 1.0))
        t += 1.0 / rng.uniform(*rate)
    return x * np.sin(np.pi * np.linspace(0, 1, n)) ** 0.7


def plip(rng, f, tau):
    """A water bubble: a short damped tone that rises a little as it forms (like a real bubble)."""
    n = T(tau * 6)
    t = times(n)
    rise = 1.0 + 0.22 * (1.0 - np.exp(-t / (tau * 0.5)))
    return np.sin(2 * np.pi * f * np.cumsum(rise) / RATE + rng.uniform(0, 6.28)) * np.exp(-t / tau) * np.minimum(1.0, t / 0.0008)


def plips(rng, n, count, span, start=0.0, fmin=600.0, fmax=3200.0, level=(0.2, 1.0), tau=(0.008, 0.028)):
    x = np.zeros(n)
    for _ in range(count):
        f = float(np.exp(rng.uniform(np.log(fmin), np.log(fmax))))
        put(x, plip(rng, f, rng.uniform(*tau)), rng.uniform(start, start + span), rng.uniform(*level))
    return x


# --- the sounds (name -> function(rng) returning a float array) ---------------------------------------------------

def blueprint_place(rng):
    n = T(0.22)
    x = wood(rng, rng.uniform(300, 360), 0.03, 0.7, 0.3, 0.22)
    x += 0.6 * soil(rng, 0.22, 700, 0.003, 0.04, 90, 2)
    return x


def hammer_hit(rng):
    x = wood(rng, rng.uniform(260, 330), 0.035, 1.4, 0.4, 0.24)
    tick = 0.18 * modes(rng, T(0.24), [2300], [0.004], [1.0], 0.05)
    return x + np.concatenate([tick, np.zeros(max(0, len(x) - len(tick)))])[: len(x)]


def chop_hit(rng):
    return wood(rng, rng.uniform(135, 175), 0.095, 1.0, 1.1, 0.4)


def delimb_hit(rng):
    x = wood(rng, rng.uniform(290, 340), 0.04, 1.3, 0.3, 0.26)
    put(x, burst(rng, T(0.05), 1500, 5000, 0.0003, 0.006), 0.035, 0.5)
    put(x, burst(rng, T(0.05), 1500, 5000, 0.0003, 0.005), 0.07, 0.3)
    return x


def dismantle_hit(rng):
    x = wood(rng, rng.uniform(200, 240), 0.055, 1.2, 0.5, 0.32)
    for at in sorted(rng.uniform(0.012, 0.11, 3)):
        put(x, burst(rng, T(0.04), 1200, 4500, 0.0002, 0.004), at, rng.uniform(0.4, 0.8))
    return x


def plank_drop(rng):
    x = wood(rng, rng.uniform(235, 270), 0.06, 1.0, 0.7, 0.42)
    put(x, wood(rng, rng.uniform(320, 380), 0.04, 0.8, 0.2, 0.3), rng.uniform(0.07, 0.095), 0.42)
    put(x, wood(rng, rng.uniform(380, 450), 0.03, 0.8, 0.1, 0.2), rng.uniform(0.15, 0.18), 0.2)
    return x


def drop(rng):
    n = T(0.24)
    x = modes(rng, n, [rng.uniform(100, 125), rng.uniform(170, 200)], [0.04, 0.03], [1.0, 0.6])
    x += burst(rng, n, 100, 900, 0.0008, 0.025) * 0.9
    x += 0.3 * burst(rng, n, 600, 2600, 0.006, 0.05)
    return x


def pickup(rng):
    n = T(0.18)
    x = burst(rng, n, 500, 3800, 0.022, 0.05, 2)
    x += 0.5 * grains(rng, n, 5, 0, 0, 0.004, 0.01, 0.1, 0.0, (0.3, 0.8), 500, 3000)
    x += 0.35 * modes(rng, n, [rng.uniform(180, 230)], [0.025], [1.0]) * np.minimum(1.0, times(n) / 0.02)
    return x


def stone_place(rng):
    return stone(rng, rng.uniform(1500, 1900), 0.25, 0.22, 0.45)


def crate_open(rng):
    n = T(0.3)
    x = 0.7 * squeak(rng, n, 250, 1200, 0)
    put(x, wood(rng, rng.uniform(160, 190), 0.05, 0.8, 0.8, 0.2), 0.0, 0.9)
    return x


def crate_close(rng):
    x = wood(rng, rng.uniform(135, 155), 0.085, 0.8, 1.2, 0.36)
    put(x, wood(rng, rng.uniform(300, 360), 0.03, 0.7, 0.1, 0.18), 0.065, 0.3)
    return x


def table_set(rng):
    return wood(rng, rng.uniform(175, 200), 0.07, 0.6, 0.9, 0.3)


def board_set(rng):
    return wood(rng, rng.uniform(380, 460), 0.028, 1.0, 0.25, 0.2)


def door(rng):
    n = T(0.7)
    x = 0.6 * np.concatenate([squeak(rng, T(0.26), 180, 800, 0, (9, 22)), np.zeros(n - T(0.26))])
    put(x, 0.35 * modes(rng, T(0.05), [420, 1900], [0.012, 0.005], [1.0, 0.5]) + burst(rng, T(0.05), 1500, 5000, 0.0002, 0.003) * 0.6, 0.27, 1.0)
    put(x, wood(rng, rng.uniform(115, 135), 0.1, 0.4, 1.3, 0.38), 0.31, 1.0)
    return x


def till(rng):
    x = soil(rng, 0.32, 1100, 0.009, 0.09, rng.uniform(70, 90), 8)
    put(x, 0.2 * burst(rng, T(0.05), 2000, 6000, 0.001, 0.006), 0.0, 1.0)
    return x


def dig_hit(rng):
    x = soil(rng, 0.34, 1400, 0.006, 0.09, rng.uniform(75, 100), 10)
    put(x, 0.3 * grains(rng, T(0.3), 5, 0, 0, 0.003, 0.008, 0.2, 0.02, (0.4, 0.9), 1500, 4000), 0.0, 1.0)
    return x


def sow(rng):
    n = T(0.32)
    x = grains(rng, n, 14, 0, 0, 0.004, 0.012, 0.22, 0.0, (0.25, 0.9), 500, 3000)
    x += 0.5 * burst(rng, n, 80, 1500, 0.03, 0.08, 2)
    return x


def harvest(rng):
    n = T(0.3)
    sw = band(noise(rng, n), 1400, 6000, 3) * np.sin(np.pi * np.clip(times(n) / 0.13, 0, 1)) ** 1.5 * (times(n) < 0.14)
    x = 0.7 * sw
    for at in sorted(rng.uniform(0.02, 0.14, 5)):
        put(x, burst(rng, T(0.03), 700, 4200, 0.0003, 0.004), at, rng.uniform(0.4, 0.9))
    x += 0.3 * burst(rng, n, 400, 3200, 0.05, 0.08, 2)
    return x


def grass_pull(rng):
    n = T(0.36)
    x = burst(rng, n, 450, 3500, 0.02, 0.1, 2)
    x += 0.7 * grains(rng, n, 9, 0, 0, 0.004, 0.012, 0.22, 0.0, (0.3, 0.9), 500, 3500)
    put(x, 0.9 * modes(rng, T(0.14), [rng.uniform(85, 110)], [0.04], [1.0]) + 0.4 * burst(rng, T(0.14), 80, 700, 0.001, 0.03), 0.17, 1.0)
    return x


def grind(rng):
    n = T(0.36)
    t = times(n)
    rough = np.abs(band(noise(rng, n), 20, 70, 2))
    rough = rough / np.max(rough)
    x = band(noise(rng, n), 400, 3500, 3) * (0.35 + 0.65 * rough) * np.sin(np.pi * np.clip(t / 0.34, 0, 1)) ** 0.8
    x += 0.5 * modes(rng, n, [rng.uniform(125, 140)], [0.12], [1.0]) * np.sin(np.pi * np.clip(t / 0.34, 0, 1))
    return x


def grind_done(rng):
    x = stone(rng, rng.uniform(900, 1100), 0.4, 0.15, 1.0)
    put(x, stone(rng, rng.uniform(800, 950), 0.25, 0.1, 0.8), 0.09, 0.45)
    return x


def knead(rng):
    n = T(0.32)
    x = burst(rng, n, 60, 650, 0.03, 0.07, 2)
    x += 0.6 * burst(rng, n, 300, 1300, 0.02, 0.05, 2) * (0.6 + 0.4 * np.sin(2 * np.pi * rng.uniform(9, 13) * times(n)))
    x += 0.8 * modes(rng, n, [rng.uniform(85, 110)], [0.05], [1.0]) * np.minimum(1.0, times(n) / 0.012)
    x += 0.18 * burst(rng, n, 2800, 6000, 0.03, 0.06)
    return x


def knead_done(rng):
    n = T(0.4)
    x = modes(rng, n, [rng.uniform(70, 82), rng.uniform(108, 125)], [0.085, 0.07], [1.0, 0.7]) * np.minimum(1.0, times(n) / 0.008)
    x += 0.6 * burst(rng, n, 80, 700, 0.004, 0.05, 2)
    x += 0.35 * burst(rng, n, 1000, 4000, 0.02, 0.09, 2)
    return x


def bake_done(rng):
    x = wood(rng, rng.uniform(160, 185), 0.1, 0.6, 1.0, 0.45)
    put(x, 0.25 * stone(rng, rng.uniform(1700, 2100), 0.18, 0.1, 0.1), 0.0, 1.0)
    put(x, burst(rng, T(0.12), 1500, 5000, 0.01, 0.04, 2), 0.05, 0.18)
    return x


def build_complete(rng):
    """Heavy and settled: a big low thunk, a smaller settle, a short wood creak. No chime."""
    x = wood(rng, rng.uniform(95, 115), 0.12, 0.7, 1.4, 0.5)
    put(x, wood(rng, rng.uniform(150, 180), 0.07, 0.5, 0.5, 0.3), 0.095, 0.5)
    put(x, 0.25 * squeak(rng, T(0.2), 220, 900, 0, (10, 24)), 0.14, 1.0)
    return x


def bed_make(rng):
    n = T(0.42)
    x = burst(rng, n, 400, 4200, 0.04, 0.14, 2)
    x += 0.6 * grains(rng, n, 10, 0, 0, 0.004, 0.012, 0.28, 0.0, (0.3, 0.9), 500, 3500)
    put(x, 0.9 * modes(rng, T(0.22), [rng.uniform(88, 100), rng.uniform(135, 150)], [0.06, 0.045], [1.0, 0.6]) + 0.5 * burst(rng, T(0.22), 80, 600, 0.002, 0.03), 0.12, 1.0)
    return x


def bed_break(rng):
    n = T(0.44)
    x = burst(rng, n, 400, 4200, 0.02, 0.12, 2)
    x += 0.8 * grains(rng, n, 12, 0, 0, 0.004, 0.012, 0.3, 0.0, (0.3, 1.0), 500, 3500)
    put(x, wood(rng, rng.uniform(190, 230), 0.05, 1.1, 0.5, 0.25), 0.03, 0.7)
    return x


def eat(rng):
    n = T(0.3)
    x = grains(rng, n, 4, 0, 0, 0.012, 0.026, 0.05, 0.0, (0.8, 1.0), 800, 4500)
    put(x, grains(rng, T(0.2), 3, 0, 0, 0.01, 0.022, 0.04, 0.0, (0.6, 0.9), 800, 4500), 0.11, 0.8)
    x += 0.4 * burst(rng, n, 400, 1500, 0.01, 0.04, 2)
    return x


def eat_bread(rng):
    n = T(0.42)
    x = np.zeros(n)
    for at, g in [(0.0, 1.0), (0.12, 0.8), (0.24, 0.6)]:
        put(x, burst(rng, T(0.14), 250, 2000, 0.008, 0.045, 2) + 0.5 * grains(rng, T(0.14), 3, 0, 0, 0.008, 0.02, 0.07, 0.0, (0.4, 0.8), 400, 2400), at, g)
    return x


# water: nothing below 250 Hz, a band of noise, plips and gurgles

def scoop(rng):
    n = T(0.45)
    x = band(burst(rng, n, 500, 3500, 0.04, 0.09, 2), 250, None)
    x += 0.7 * plips(rng, n, 5, 0.25, 0.02, 500, 1900, (0.3, 0.9), (0.012, 0.03))
    return x


def pour(rng):
    n = T(0.55)
    t = times(n)
    lvl = 0.7 + 0.3 * np.sin(2 * np.pi * rng.uniform(5, 8) * t + rng.uniform(0, 6)) * np.sin(2 * np.pi * rng.uniform(3, 5) * t)
    shape = np.clip(t / 0.06, 0, 1) * np.exp(-np.clip(t - 0.3, 0, None) / 0.09)
    x = band(noise(rng, n), 900, 5000, 3) * lvl * shape
    x += 0.9 * plips(rng, n, 22, 0.4, 0.02, 700, 3200, (0.15, 0.7), (0.007, 0.018))
    return band(x, 250, None)


def splash(rng):
    n = T(0.3)
    x = band(burst(rng, n, 700, 6000, 0.004, 0.06, 2), 250, None)
    x += 0.8 * plips(rng, n, 8, 0.2, 0.0, 800, 3500, (0.2, 0.9), (0.008, 0.02))
    return x


# loops

def saw_loop(rng):
    """0.5 s = exactly 4 strokes at 8 Hz: a rasp of noise on a slightly resonant board."""
    n = T(0.5)
    t = times(n)
    stroke = 0.5 + 0.5 * np.sin(2 * np.pi * 8 * t - np.pi / 2)
    rasp = band(noise(rng, n), 1100, 5200, 3) * stroke ** 1.4
    body = modes(rng, n, [rng.uniform(190, 230), rng.uniform(330, 380)], [10.0, 10.0], [1.0, 0.5], 0.02) * stroke
    x = rasp + 0.22 * body
    x[0] = 0.0
    return x


def water_loop(rng, seconds=24.0, cross=2.0):
    """A shallow brook: nothing below ~250 Hz, a broad band of noise (about 1 to 5 kHz) that slowly varies in level,
    many random plips, short gurgles. 24 s, crossfaded so the loop point cannot be heard."""
    total = T(seconds + cross)
    t = times(total)

    def slow(period, depth):
        # a slowly wandering level between 1-depth and 1
        k = np.fft.rfft(noise(rng, total))
        f = np.fft.rfftfreq(total, 1.0 / RATE)
        k *= np.exp(-(f / (1.0 / period)) ** 2)
        s = np.fft.irfft(k, total)
        s = s / (np.max(np.abs(s)) + 1e-9)
        return 1.0 - depth * (0.5 - 0.5 * s)

    x = np.zeros(total)
    for lo, hi, period, gain in [(1000, 2200, 3.1, 1.0), (1800, 3600, 2.3, 0.9), (2800, 5200, 1.7, 0.7)]:
        x += gain * band(noise(rng, total), lo, hi, 3) * slow(period, 0.55)
    x *= slow(7.0, 0.3)
    # plips: random times (a slowly changing rate), random pitch
    rate = 5.0 + 6.0 * (1.0 - slow(9.0, 1.0))
    at = 0.0
    while at < seconds + cross - 0.1:
        f = float(np.exp(rng.uniform(np.log(550.0), np.log(3300.0))))
        put(x, plip(rng, f, rng.uniform(0.007, 0.03)), at, rng.uniform(0.15, 1.0) * 3.0)
        at += rng.exponential(1.0 / rate[min(total - 1, T(at))])
    # gurgles: short trains of bubbles
    at = rng.uniform(0.2, 1.0)
    while at < seconds + cross - 0.3:
        g_n = T(rng.uniform(0.07, 0.2))
        gt = times(g_n)
        am = 0.5 + 0.5 * np.sin(2 * np.pi * rng.uniform(22, 46) * gt + rng.uniform(0, 6))
        g = band(noise(rng, g_n), rng.uniform(450, 800), rng.uniform(1500, 2600), 2) * am * np.hanning(g_n)
        put(x, g, at, rng.uniform(1.0, 2.2))
        at += rng.uniform(0.5, 2.2)
    # seamless loop: the last `cross` seconds fade into the first
    c = T(cross)
    loop = x[: total - c].copy()
    fade = np.linspace(0.0, np.pi / 2, c)
    loop[:c] = loop[:c] * np.sin(fade) + x[total - c:] * np.cos(fade)
    # nothing below ~250 Hz (done circularly, so the loop stays seamless)
    loop = band(loop, 290, None, 4)
    loop = band(loop, None, 6500, 2)
    return loop


# --- the interface (paper and wood, very quiet) ---

def ui_hover(rng):
    n = T(0.07)
    return burst(rng, n, 1800, 5200, 0.003, 0.012, 2) + 0.4 * wood(rng, rng.uniform(520, 600), 0.012, 0.4, 0.0, 0.07)[:n]


def ui_click(rng):
    return wood(rng, rng.uniform(400, 470), 0.02, 0.7, 0.15, 0.12)


def ui_open(rng):
    n = T(0.3)
    x = burst(rng, n, 700, 4200, 0.05, 0.1, 2)
    x += 0.5 * grains(rng, n, 7, 0, 0, 0.004, 0.01, 0.2, 0.0, (0.3, 0.8), 600, 3500)
    put(x, wood(rng, rng.uniform(170, 200), 0.04, 0.4, 0.5, 0.15), 0.0, 0.45)
    return x


def ui_close(rng):
    n = T(0.26)
    x = burst(rng, n, 900, 4000, 0.03, 0.07, 2)
    x += 0.4 * grains(rng, n, 5, 0, 0, 0.004, 0.01, 0.12, 0.0, (0.3, 0.8), 700, 3500)
    put(x, wood(rng, rng.uniform(210, 250), 0.03, 0.5, 0.3, 0.12), 0.1, 0.5)
    return x


# --- footsteps (v1 = left foot, a little brighter; v2 = right foot, a little darker; v3 = a neutral spare) and the toolbox ---

def _foot(rng, v, lo, hi, tau, body_f, body_tau, grit=0.0, attack=0.004):
    n = T(0.16)
    bright = {1: 1.18, 2: 0.85, 3: 1.0}[v]
    x = burst(rng, n, lo * bright, hi * bright, attack, tau, 2)
    if body_f:
        x += 0.8 * modes(rng, n, [body_f * (1.05 if v == 1 else 0.95 if v == 2 else 1.0)], [body_tau], [1.0], 0.04) * np.minimum(1.0, times(n) / 0.003)
    if grit:
        x += grit * grains(rng, n, 4, 0, 0, 0.004, 0.01, 0.07, 0.0, (0.3, 0.8), lo, hi)
    return x


def step_grass(rng, v):
    return _foot(rng, v, 1500, 5500, 0.03, 130, 0.03, 0.4, 0.012)


def step_dirt(rng, v):
    return _foot(rng, v, 250, 1600, 0.035, 95, 0.05, 0.7, 0.004)


def step_wood(rng, v):
    n = T(0.18)
    f = rng.uniform(165, 200) * {1: 1.08, 2: 0.93, 3: 1.0}[v]
    x = modes(rng, n, [f, f * 1.7, f * 2.4], [0.05, 0.03, 0.02], [1.0, 0.5, 0.25])
    x += 0.5 * burst(rng, n, 900, 3500, 0.001, 0.008) + 0.5 * burst(rng, n, 80, 300, 0.001, 0.02)
    return x


def step_water(rng, v):
    n = T(0.22)
    x = band(burst(rng, n, 700 * {1: 1.15, 2: 0.88, 3: 1.0}[v], 4200, 0.004, 0.05, 2), 250, None)
    x += 0.8 * plips(rng, n, 4, 0.12, 0.0, 700, 2600, (0.3, 0.9), (0.008, 0.02))
    return x


def toolbox_open(rng):
    n = T(0.5)
    x = 0.6 * squeak(rng, T(0.34), 220, 900, 0, (12, 28))
    x = np.concatenate([x, np.zeros(n - len(x))])
    put(x, wood(rng, rng.uniform(150, 175), 0.05, 0.6, 0.7, 0.2), 0.0, 0.5)
    put(x, wood(rng, rng.uniform(280, 330), 0.025, 0.7, 0.1, 0.12), 0.33, 0.35)
    return x


def toolbox_close(rng):
    x = wood(rng, rng.uniform(140, 160), 0.07, 0.8, 1.0, 0.3)
    put(x, 0.4 * squeak(rng, T(0.14), 250, 900, 0, (14, 30)), 0.0, 0.5)
    put(x, wood(rng, rng.uniform(300, 360), 0.03, 0.6, 0.1, 0.15), 0.1, 0.3)
    return x


def toolbox_lift(rng):
    # two people taking the weight: a wood scrape on the ground, a short creak, then the knock of the handles
    n = T(0.5)
    x = 0.5 * grains(rng, n, 7, 0, 0, 0.004, 0.012, 0.1, 0.0, (0.3, 0.8), 500, 2600)
    x += 0.35 * squeak(rng, n, 180, 700, 0, (10, 22))
    put(x, wood(rng, rng.uniform(160, 190), 0.04, 0.5, 0.5, 0.15), 0.3, 0.4)
    return x


def toolbox_set(rng):
    # set down on the ground: a dull wooden thud and a little rattle of what is inside
    x = wood(rng, rng.uniform(120, 145), 0.08, 0.9, 1.0, 0.3)
    put(x, wood(rng, rng.uniform(260, 320), 0.03, 0.6, 0.1, 0.12), 0.07, 0.3)
    put(x, 0.3 * burst(rng, T(0.12), 900, 3200, 0.002, 0.03), 0.1, 0.4)
    return x


def thresh_rustle(rng):
    # beating the ear off a sheaf: a dry straw rustle and a few seeds rattling loose
    n = T(0.34)
    x = 0.5 * grains(rng, n, 9, 0, 0, 0.004, 0.012, 0.1, 0.0, (0.3, 0.8), 1800, 6000)
    x += 0.4 * plips(rng, n, 5, 0.1, 0.0, 2200, 5200, (0.3, 0.7), (0.004, 0.012))
    return x


def thresh_done(rng):
    # the last of the seeds pouring into the bag, and a soft pat on the empty straw
    n = T(0.5)
    x = 0.6 * plips(rng, n, 10, 0.4, 0.0, 1500, 4200, (0.3, 0.8), (0.006, 0.02))
    put(x, wood(rng, rng.uniform(190, 230), 0.03, 0.4, 0.2, 0.1), 0.0, 0.35)
    return x


# name -> (function, variants)   (loops and long ambience make 1 file)
SOUNDS = {
    "blueprint_place": (blueprint_place, VARIANTS), "hammer_hit": (hammer_hit, VARIANTS), "chop_hit": (chop_hit, VARIANTS),
    "delimb_hit": (delimb_hit, VARIANTS), "dismantle_hit": (dismantle_hit, VARIANTS), "plank_drop": (plank_drop, VARIANTS),
    "drop": (drop, VARIANTS), "pickup": (pickup, VARIANTS), "stone_place": (stone_place, VARIANTS),
    "crate_open": (crate_open, VARIANTS), "crate_close": (crate_close, VARIANTS), "table_set": (table_set, VARIANTS),
    "board_set": (board_set, VARIANTS), "door": (door, VARIANTS), "till": (till, VARIANTS), "dig_hit": (dig_hit, VARIANTS),
    "sow": (sow, VARIANTS), "harvest": (harvest, VARIANTS), "grass_pull": (grass_pull, VARIANTS), "grind": (grind, VARIANTS),
    "grind_done": (grind_done, VARIANTS), "knead": (knead, VARIANTS), "knead_done": (knead_done, VARIANTS),
    "bake_done": (bake_done, VARIANTS), "build_complete": (build_complete, VARIANTS), "bed_make": (bed_make, VARIANTS),
    "bed_break": (bed_break, VARIANTS), "eat": (eat, VARIANTS), "eat_bread": (eat_bread, VARIANTS), "scoop": (scoop, VARIANTS),
    "pour": (pour, VARIANTS), "splash": (splash, VARIANTS), "step_grass": (step_grass, VARIANTS), "step_dirt": (step_dirt, VARIANTS), "step_wood": (step_wood, VARIANTS), "step_water": (step_water, VARIANTS), "ui_hover": (ui_hover, VARIANTS), "toolbox_open": (toolbox_open, VARIANTS), "toolbox_close": (toolbox_close, VARIANTS), "toolbox_lift": (toolbox_lift, VARIANTS), "toolbox_set": (toolbox_set, VARIANTS), "thresh_rustle": (thresh_rustle, VARIANTS), "thresh_done": (thresh_done, VARIANTS), "ui_click": (ui_click, VARIANTS), "ui_open": (ui_open, VARIANTS), "ui_close": (ui_close, VARIANTS), "saw_loop": (saw_loop, VARIANTS), "water_loop": (water_loop, 1),
}
STEP_SOUNDS = ("step_grass", "step_dirt", "step_wood", "step_water")
LOOP_PEAK_DB = {"step_grass": -20.0, "step_dirt": -18.0, "step_wood": -18.0, "step_water": -18.0, "saw_loop": -14.0, "water_loop": -14.0, "ui_hover": -26.0, "ui_click": -22.0, "ui_open": -22.0, "ui_close": -22.0}


# --- writing, with the manifest ------------------------------------------------------------------------------------

def sha(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def load_manifest():
    if os.path.exists(MANIFEST):
        with open(MANIFEST, encoding="utf-8") as f:
            return json.load(f)
    return {"rate": RATE, "generated": {}, "placeholders": {}}


def write_wav(path, x):
    data = (np.clip(x, -1, 1) * 32767).astype("<i2").tobytes()
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(data)


def supplied_plain(name, manifest):
    """A plain <name>.wav/.ogg/.mp3 that this script did not write: the sound is supplied by you."""
    for ext in (".wav", ".ogg", ".mp3"):
        p = os.path.join(OUT, name + ext)
        if os.path.exists(p) and (name + ext) not in manifest["generated"]:
            if ext == ".wav" and (name + ext) in manifest["placeholders"] and sha(p) == manifest["placeholders"][name + ext]:
                continue   # an old placeholder, replaced by the variants
            return True
    return False


def save_manifest(manifest):
    manifest["generated"] = dict(sorted(manifest["generated"].items()))
    # (an old placeholder that is gone from the folder - replaced by variants - is no longer listed)
    manifest["placeholders"] = {k: v for k, v in manifest["placeholders"].items() if os.path.exists(os.path.join(OUT, k))}
    with open(MANIFEST, "w", encoding="utf-8", newline="\n") as f:
        json.dump(manifest, f, indent=1)
        f.write("\n")


def main():
    os.makedirs(OUT, exist_ok=True)
    manifest = load_manifest()
    manifest["rate"] = RATE
    wrote, kept, replaced_old = [], [], []
    try:
        for name, (fn, count) in SOUNDS.items():
            if supplied_plain(name, manifest):
                kept.append(name + " (plain file supplied)")
                continue
            # the old placeholder with the plain name is replaced by the variants (only while it is still the untouched placeholder)
            plain = os.path.join(OUT, name + ".wav")
            if os.path.exists(plain) and manifest["placeholders"].get(name + ".wav") == sha(plain) and count > 1:
                os.remove(plain)
                if os.path.exists(plain + ".import"):
                    os.remove(plain + ".import")
                manifest["placeholders"].pop(name + ".wav")
                replaced_old.append(name + ".wav")
            for v in range(1, count + 1):
                fname = name + ("_%d.wav" % v if count > 1 else ".wav")
                path = os.path.join(OUT, fname)
                if os.path.exists(path):
                    rec = manifest["generated"].get(fname)
                    is_old_placeholder = manifest["placeholders"].get(fname) == sha(path)
                    if is_old_placeholder:
                        manifest["placeholders"].pop(fname)
                        replaced_old.append(fname)
                    elif rec is None or rec["sha256"] != sha(path):
                        kept.append(fname + " (yours, kept)")
                        continue
                rng = np.random.default_rng(zlib.crc32(("%s:%d" % (name, v)).encode()))
                result = fn(rng, v) if name in STEP_SOUNDS else fn(rng)
                x = finish(result, LOOP_PEAK_DB.get(name, PEAK_DB), 0.0 if name.endswith("_loop") else 0.004)
                write_wav(path, x)
                manifest["generated"][fname] = {"sha256": sha(path), "sound": name, "variant": v, "seconds": round(len(x) / RATE, 3)}
                wrote.append(fname)
    finally:
        save_manifest(manifest)
    print("wrote %d file(s), kept %d of yours, replaced %d old placeholder(s)" % (len(wrote), len(kept), len(replaced_old)))
    for k in kept:
        print("  kept:", k)


if __name__ == "__main__":
    main()
