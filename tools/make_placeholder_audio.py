"""Generates the placeholder sound effects into res://audio/ (22.05 kHz, mono, 16-bit WAV).

(Most of these are now made by tools/make_sounds.py instead, as <name>_1/_2/_3.wav; see audio/generated_manifest.json.
This older script only still supplies the sounds listed under "placeholders" in that manifest.)

Overwrite any of these files with real sounds (same names, .wav / .ogg / .mp3) and nothing in the code needs to
change. This script NEVER overwrites a file that already exists, so running it again only fills in what is missing.

    python tools/make_placeholder_audio.py
"""
import os
import wave

import numpy as np

RATE = 22050
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "audio")
rng = np.random.default_rng(7)


def t(seconds):
    return np.arange(int(RATE * seconds)) / RATE


def noise(seconds):
    return rng.uniform(-1.0, 1.0, int(RATE * seconds))


def lowpass(x, cutoff):
    a = np.exp(-2.0 * np.pi * cutoff / RATE)
    y = np.zeros_like(x)
    prev = 0.0
    for i, v in enumerate(x):
        prev = (1.0 - a) * v + a * prev
        y[i] = prev
    return y


def highpass(x, cutoff):
    return x - lowpass(x, cutoff)


def env(n, attack=0.005, decay=0.1):
    """Fast attack, exponential decay."""
    e = np.exp(-np.arange(n) / (RATE * decay))
    a = max(1, int(RATE * attack))
    e[:a] *= np.linspace(0.0, 1.0, a)
    return e


def sine(freq, seconds):
    return np.sin(2.0 * np.pi * freq * t(seconds))


def sweep(f0, f1, seconds):
    tt = t(seconds)
    freq = np.linspace(f0, f1, len(tt))
    return np.sin(2.0 * np.pi * np.cumsum(freq) / RATE)


def mix(*parts):
    n = max(len(p) for p in parts)
    out = np.zeros(n)
    for p in parts:
        out[: len(p)] += p
    return out


def delay(x, seconds):
    return np.concatenate([np.zeros(int(RATE * seconds)), x])


def save(name, x, peak=0.6):
    path = os.path.join(OUT, name)
    if os.path.exists(path):
        print("exists, kept:", name)
        return
    # Sounds that tools/make_sounds.py makes (<name>_1.wav ...) are not made here: a plain <name>.wav would override them.
    if os.path.exists(os.path.join(OUT, name[:-4] + "_1.wav")):
        print("replaced by variants (tools/make_sounds.py), skipped:", name)
        return
    x = np.asarray(x, dtype=np.float64)
    x = x / max(1e-9, np.max(np.abs(x))) * peak
    data = (x * 32767).astype("<i2").tobytes()
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(data)
    print("wrote:", name)


os.makedirs(OUT, exist_ok=True)

# woody thud
n = int(RATE * 0.2)
save("chop_hit.wav", mix(lowpass(noise(0.2), 900) * env(n, 0.002, 0.04) * 1.2, sine(150, 0.2) * env(n, 0.002, 0.06), sine(310, 0.2) * env(n, 0.001, 0.025) * 0.5))

# slow creak: a wobbling low tone with a stuttering rasp
n = int(RATE * 0.8)
tt = t(0.8)
wob = 1.0 + 0.5 * np.sin(2 * np.pi * 11 * tt)
creak = sweep(110, 70, 0.8) * wob + 0.4 * highpass(noise(0.8), 600) * (0.5 + 0.5 * np.sin(2 * np.pi * 17 * tt))
save("tree_creak.wav", lowpass(creak, 1800) * np.sin(np.pi * np.linspace(0, 1, n)) ** 0.6)

# heavy thump with a rumble
n = int(RATE * 0.9)
save("tree_fall.wav", mix(sine(55, 0.9) * env(n, 0.004, 0.22), lowpass(noise(0.9), 300) * env(n, 0.01, 0.3) * 1.5, sine(95, 0.9) * env(n, 0.002, 0.08) * 0.6))

# a crisp snap
n = int(RATE * 0.12)
save("delimb_hit.wav", mix(highpass(noise(0.12), 1500) * env(n, 0.001, 0.02), sine(520, 0.12) * env(n, 0.001, 0.03) * 0.6))

# earthy crunch: gritty noise in short grains
n = int(RATE * 0.22)
grit = lowpass(noise(0.22), 2200) * (rng.uniform(0.3, 1.0, n) ** 2)
save("dig_hit.wav", mix(grit * env(n, 0.003, 0.07) * 1.5, sine(95, 0.22) * env(n, 0.002, 0.05) * 0.6))

# sharp tap
n = int(RATE * 0.09)
save("hammer_hit.wav", mix(sine(1900, 0.09) * env(n, 0.0005, 0.012), highpass(noise(0.09), 2500) * env(n, 0.0005, 0.008) * 0.8, sine(700, 0.09) * env(n, 0.0005, 0.02) * 0.5))

# rhythmic rasp, loopable (0.5 s = exactly 4 strokes at 8 Hz)
n = int(RATE * 0.5)
stroke = 0.5 + 0.5 * np.sin(2 * np.pi * 8 * t(0.5) - np.pi / 2)
rasp = highpass(noise(0.5), 1200) * stroke ** 1.5 + 0.25 * sine(180, 0.5) * stroke
rasp[0] = 0.0
save("saw_loop.wav", rasp, peak=0.45)

# rustle
n = int(RATE * 0.28)
swell = np.sin(np.pi * np.linspace(0, 1, n)) ** 1.5
save("grass_pull.wav", highpass(lowpass(noise(0.28), 5000), 1500) * swell * (rng.uniform(0.4, 1.0, n)))

# short blips
save("pickup.wav", sweep(520, 880, 0.1) * env(int(RATE * 0.1), 0.004, 0.05))
n = int(RATE * 0.12)
save("drop.wav", mix(sine(140, 0.12) * env(n, 0.002, 0.04), lowpass(noise(0.12), 700) * env(n, 0.002, 0.03)))
n = int(RATE * 0.1)
clack = mix(sine(850, 0.1) * env(n, 0.0005, 0.015), highpass(noise(0.1), 1800) * env(n, 0.0005, 0.01) * 0.6)
save("plank_drop.wav", mix(clack, delay(clack * 0.7, 0.07)))

# bed made: rustle then two soft notes
n = int(RATE * 0.2)
rus = lowpass(noise(0.2), 3500) * np.sin(np.pi * np.linspace(0, 1, n)) * 0.6
note1 = sine(392, 0.25) * env(int(RATE * 0.25), 0.01, 0.12)
note2 = sine(523, 0.3) * env(int(RATE * 0.3), 0.01, 0.15)
save("bed_make.wav", mix(rus, delay(note1, 0.12) * 0.7, delay(note2, 0.24) * 0.7))

# bed broken: a falling rustle
n = int(RATE * 0.35)
save("bed_break.wav", mix(lowpass(noise(0.35), 3000) * env(n, 0.004, 0.1), sweep(300, 130, 0.35) * env(n, 0.004, 0.08) * 0.5))

# rising chime
parts = []
for i, f in enumerate([523.25, 659.25, 783.99, 1046.5]):
    nn = int(RATE * 0.35)
    parts.append(delay((sine(f, 0.35) + 0.3 * sine(f * 2, 0.35)) * env(nn, 0.005, 0.12), 0.09 * i))
save("build_complete.wav", mix(*parts))

# lower, cracking tap
n = int(RATE * 0.13)
save("dismantle_hit.wav", mix(sine(260, 0.13) * env(n, 0.001, 0.03), lowpass(noise(0.13), 2500) * env(n, 0.001, 0.025) * 0.9, sine(90, 0.13) * env(n, 0.002, 0.05) * 0.5))

# sleep: a soft falling tone; wake: a soft rising one
n = int(RATE * 0.5)
save("sleep_on.wav", sweep(440, 300, 0.5) * np.sin(np.pi * np.linspace(0, 1, n)) ** 1.2, peak=0.35)
n = int(RATE * 0.4)
save("wake.wav", sweep(300, 520, 0.4) * np.sin(np.pi * np.linspace(0, 1, n)) ** 1.2, peak=0.35)

# very quiet footstep
n = int(RATE * 0.06)
save("footstep.wav", lowpass(noise(0.06), 1100) * env(n, 0.002, 0.015), peak=0.25)

# --- Hunger and berries ---

# a soft pluck
n = int(RATE * 0.14)
save("berry_pick.wav", mix(sweep(620, 380, 0.14) * env(n, 0.002, 0.04), lowpass(noise(0.14), 2500) * env(n, 0.001, 0.015) * 0.5))

# a crunch
n = int(RATE * 0.22)
crunch = highpass(lowpass(noise(0.22), 3500), 500) * (rng.uniform(0.2, 1.0, n) ** 2)
save("eat.wav", mix(crunch * env(n, 0.002, 0.05) * 1.6, delay(crunch[: int(RATE * 0.12)] * env(int(RATE * 0.12), 0.002, 0.03), 0.09)))

# a woven thump with a small rustle
n = int(RATE * 0.16)
save("basket_pickup.wav", mix(lowpass(noise(0.16), 1800) * np.sin(np.pi * np.linspace(0, 1, n)) * 0.8, sine(210, 0.16) * env(n, 0.003, 0.05) * 0.6))

# a soft rumble
n = int(RATE * 0.9)
save("hunger_low.wav", mix(lowpass(noise(0.9), 220) * np.sin(np.pi * np.linspace(0, 1, n)) ** 1.5 * 1.2, sine(70, 0.9) * np.sin(np.pi * np.linspace(0, 1, n)) ** 2 * (0.6 + 0.4 * np.sin(2 * np.pi * 6 * t(0.9)))), peak=0.4)

# --- Houses ---

# a wooden door: a creak, then a soft thud
creak = lowpass(sweep(160, 110, 0.25) * (0.6 + 0.4 * np.sin(2 * np.pi * 30 * t(0.25))), 1500) * np.sin(np.pi * np.linspace(0, 1, int(RATE * 0.25)))
thud = mix(sine(95, 0.25) * env(int(RATE * 0.25), 0.002, 0.07), lowpass(noise(0.25), 500) * env(int(RATE * 0.25), 0.002, 0.05))
save("door.wav", mix(creak * 0.7, delay(thud, 0.2)))

# --- Crates ---

# a lid lifting: a short wooden creak and a soft knock
n = int(RATE * 0.3)
lid = lowpass(sweep(240, 330, 0.3) * (0.6 + 0.4 * np.sin(2 * np.pi * 38 * t(0.3))), 1800) * np.sin(np.pi * np.linspace(0, 1, n)) ** 0.8
knock = mix(sine(120, 0.12) * env(int(RATE * 0.12), 0.001, 0.035), lowpass(noise(0.12), 900) * env(int(RATE * 0.12), 0.001, 0.025) * 0.6)
save("crate_open.wav", mix(lid * 0.6, delay(knock, 0.02)))

# berries dropping in: a few soft little plops
plop = mix(sweep(520, 300, 0.07) * env(int(RATE * 0.07), 0.001, 0.02), lowpass(noise(0.07), 2000) * env(int(RATE * 0.07), 0.001, 0.012) * 0.4)
save("berry_drop.wav", mix(plop, delay(plop * 0.7, 0.05), delay(plop * 0.5, 0.1)))

# --- The food chain ---

# tilling: a dull scrape and thud
n = int(RATE * 0.22)
save("till.wav", mix(lowpass(noise(0.22), 900) * env(n, 0.004, 0.07) * 1.2, sine(110, 0.22) * env(n, 0.003, 0.05) * 0.6))

# sowing: a soft patter of seeds
n = int(RATE * 0.2)
pat = highpass(lowpass(noise(0.2), 4500), 1500) * (rng.uniform(0.2, 1.0, n) ** 3)
save("sow.wav", pat * env(n, 0.002, 0.08) * 1.5)

# harvest: a swish and a snip
n = int(RATE * 0.2)
save("harvest.wav", mix(highpass(lowpass(noise(0.2), 6000), 2500) * np.sin(np.pi * np.linspace(0, 1, n)) * 0.7, delay(sine(1500, 0.04) * env(int(RATE * 0.04), 0.0005, 0.01), 0.1)))

# grinding: a low gritty scrape (constant pitch) and a finishing clack
n = int(RATE * 0.3)
save("grind.wav", mix(lowpass(noise(0.3), 1400) * np.sin(np.pi * np.linspace(0, 1, n)) ** 0.5, sine(95, 0.3) * np.sin(np.pi * np.linspace(0, 1, n)) * 0.4), peak=0.5)
n = int(RATE * 0.25)
save("grind_done.wav", mix(sine(330, 0.25) * env(n, 0.001, 0.07), sine(495, 0.25) * env(n, 0.001, 0.05) * 0.6, lowpass(noise(0.25), 2500) * env(n, 0.001, 0.02) * 0.4))

# the ferro rod: a bright scrape with a spark
n = int(RATE * 0.25)
save("spark.wav", mix(highpass(noise(0.25), 3500) * env(n, 0.002, 0.06) * 1.2, sweep(2800, 4200, 0.25) * env(n, 0.002, 0.04) * 0.3), peak=0.5)

# the fire catches: a whoosh
n = int(RATE * 0.6)
save("fire_light.wav", mix(lowpass(noise(0.6), 1800) * np.sin(np.pi * np.linspace(0, 1, n)) ** 1.5, sweep(120, 300, 0.6) * np.sin(np.pi * np.linspace(0, 1, n)) * 0.3), peak=0.5)

# the fire burning: a quiet crackle (loops)
n = int(RATE * 1.6)
crackle = np.zeros(n)
for _ in range(26):
    at = int(rng.uniform(0, n - 400))
    pop = highpass(noise(0.015), 1500) * env(int(RATE * 0.015), 0.0005, 0.003) * rng.uniform(0.3, 1.0)
    crackle[at: at + len(pop)] += pop
crackle += lowpass(noise(1.6), 500) * 0.15
save("fire_loop.wav", crackle, peak=0.35)

# a stone set down
n = int(RATE * 0.15)
save("stone_place.wav", mix(sine(220, 0.15) * env(n, 0.001, 0.03), lowpass(noise(0.15), 1500) * env(n, 0.001, 0.02) * 0.8, sine(540, 0.15) * env(n, 0.0005, 0.012) * 0.4))

# baking: a sizzle (constant pitch) and a done ding
n = int(RATE * 0.35)
save("bake.wav", highpass(noise(0.35), 3000) * (0.5 + 0.5 * rng.uniform(0, 1, n)) * np.sin(np.pi * np.linspace(0, 1, n)) ** 0.6, peak=0.4)
n = int(RATE * 0.5)
save("bake_done.wav", mix(sine(880, 0.5) * env(n, 0.002, 0.18), sine(1320, 0.5) * env(n, 0.002, 0.12) * 0.5, delay(sine(1175, 0.4) * env(int(RATE * 0.4), 0.002, 0.15) * 0.5, 0.08)))

# eating bread: a soft chew
n = int(RATE * 0.3)
chew = lowpass(noise(0.3), 2200) * (rng.uniform(0.2, 1.0, n) ** 2)
save("eat_bread.wav", mix(chew * env(n, 0.003, 0.09), delay(chew[: int(RATE * 0.15)] * env(int(RATE * 0.15), 0.002, 0.04), 0.12)))

# --- Water ---

# a splash
n = int(RATE * 0.25)
save("splash.wav", mix(highpass(lowpass(noise(0.25), 5000), 600) * env(n, 0.003, 0.09) * 1.4, sweep(500, 260, 0.25) * env(n, 0.002, 0.05) * 0.3), peak=0.5)

# a scoop: a dip and a gulp
n = int(RATE * 0.5)
save("scoop.wav", mix(highpass(lowpass(noise(0.5), 3500), 400) * np.sin(np.pi * np.linspace(0, 1, n)) ** 1.2 * 0.7, delay(sweep(300, 520, 0.12) * env(int(RATE * 0.12), 0.002, 0.04) * 0.6, 0.18)), peak=0.5)

# pouring: a gentle running trickle
n = int(RATE * 0.6)
trickle = highpass(lowpass(noise(0.6), 4200), 800) * (0.5 + 0.5 * np.sin(2 * np.pi * 14 * t(0.6))) * np.sin(np.pi * np.linspace(0, 1, n)) ** 0.7
save("pour.wav", trickle, peak=0.45)

# the brook: a quiet loop of running water
n = int(RATE * 2.0)
brook = highpass(lowpass(noise(2.0), 2600), 300) * (0.6 + 0.4 * np.sin(2 * np.pi * 3 * t(2.0)) * np.sin(2 * np.pi * 5 * t(2.0)))
save("water_loop.wav", brook, peak=0.3)

# kneading: a soft constant-pitch thud, and a done chime
n = int(RATE * 0.18)
save("knead.wav", mix(sine(90, 0.18) * env(n, 0.003, 0.06), lowpass(noise(0.18), 600) * env(n, 0.003, 0.04) * 0.6), peak=0.5)
n = int(RATE * 0.4)
save("knead_done.wav", mix(sine(392, 0.4) * env(n, 0.002, 0.12), sine(523, 0.4) * env(n, 0.002, 0.1) * 0.6, delay(sine(659, 0.3) * env(int(RATE * 0.3), 0.002, 0.1) * 0.5, 0.07)))
