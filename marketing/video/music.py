"""Synthesizes the 47.5-second soundtrack for ad.html, locked to the Ava voiceover cues.

120 BPM. Pure Python (no samples, no dependencies): python music.py out.wav
"""
import array
import math
import random
import struct
import sys
import wave

SR = 44100
DUR = 47.5
N = int(SR * DUR)
L = array.array('f', bytes(4 * N))
R = array.array('f', bytes(4 * N))
REV = array.array('f', bytes(4 * N))  # reverb send (mono)
rnd = random.Random(7)
TAU = 2 * math.pi
BEAT = 0.5


def note(n):
    """MIDI note number to Hz."""
    return 440.0 * 2 ** ((n - 69) / 12)


def add(t0, samples, gain=1.0, pan=0.0, rev=0.0):
    """Mixes a mono buffer (a function of sample index) into the stereo bus."""
    i0 = int(t0 * SR)
    gl = gain * math.cos((pan + 1) * math.pi / 4)
    gr = gain * math.sin((pan + 1) * math.pi / 4)
    for k, s in enumerate(samples):
        i = i0 + k
        if i < 0:
            continue
        if i >= N:
            break
        L[i] += s * gl
        R[i] += s * gr
        if rev:
            REV[i] += s * rev * gain


def env(k, n, a=0.005, d=None):
    """Attack then exponential decay over n samples."""
    x = k / SR
    att = min(1.0, x / a) if a > 0 else 1.0
    dec = math.exp(-x / d) if d else 1.0
    tail = 1.0 if k < n - 400 else max(0.0, (n - k) / 400)
    return att * dec * tail


def kick(t, gain=1.0):
    n = int(0.45 * SR)
    out, ph = [], 0.0
    for k in range(n):
        x = k / SR
        f = 45 + 110 * math.exp(-x * 30)
        ph += TAU * f / SR
        out.append(math.sin(ph) * math.exp(-x * 7) + (rnd.random() - .5) * .3 * math.exp(-x * 300))
    add(t, out, gain * .9)


def boom(t, gain=1.0):
    """Cinematic hit: sub drop + noise snap + metallic ring, with reverb."""
    n = int(2.2 * SR)
    out, ph, ph2 = [], 0.0, 0.0
    lp = 0.0
    for k in range(n):
        x = k / SR
        ph += TAU * (32 + 90 * math.exp(-x * 9)) / SR
        ph2 += TAU * 1660 / SR
        noise = rnd.random() * 2 - 1
        lp += (noise - lp) * 0.18
        s = math.sin(ph) * math.exp(-x * 2.2) * 1.1
        s += lp * math.exp(-x * 16) * 1.4
        s += math.sin(ph2) * math.sin(ph2 * 1.41) * math.exp(-x * 5) * .08
        out.append(s)
    add(t, out, gain * .75, rev=.35)


def hat(t, gain=1.0, open_=False):
    n = int((0.22 if open_ else 0.06) * SR)
    out, prev = [], 0.0
    for k in range(n):
        noise = rnd.random() * 2 - 1
        hp = noise - prev
        prev = noise
        out.append(hp * math.exp(-(k / SR) * (14 if open_ else 70)))
    add(t, out, gain * .16, pan=rnd.uniform(-.3, .3))


def clap(t, gain=1.0):
    n = int(0.25 * SR)
    out, lp = [], 0.0
    for k in range(n):
        x = k / SR
        noise = rnd.random() * 2 - 1
        lp += (noise - lp) * 0.5
        burst = sum(math.exp(-max(0.0, x - d) * 60) for d in (0, .011, .022)) if x > 0 else 1
        out.append((noise - lp) * burst * math.exp(-x * 9) * .5)
    add(t, out, gain * .45, rev=.25)


def pluck(t, midi, dur=0.5, gain=1.0, pan=0.0, rev=.3, bright=1.0):
    f = note(midi)
    n = int(dur * SR)
    out = []
    for k in range(n):
        x = k / SR
        s = (math.sin(TAU * f * x) + .35 * bright * math.sin(TAU * 2 * f * x) * math.exp(-x * 9)
             + .15 * bright * math.sin(TAU * 3 * f * x) * math.exp(-x * 14))
        out.append(s * env(k, n, .003, dur * .35))
    add(t, out, gain * .22, pan, rev)


def bass(t, midi, dur, gain=1.0):
    f = note(midi)
    n = int(dur * SR)
    out, lp = [], 0.0
    for k in range(n):
        x = k / SR
        saw = 2 * ((f * x) % 1) - 1
        cutoff = .04 + .12 * math.exp(-x * 7)
        lp += (saw - lp) * cutoff
        out.append((lp * .9 + math.sin(TAU * f * x) * .6) * env(k, n, .004, dur * .7))
    add(t, out, gain * .5)


def pad(t, midis, dur, gain=1.0, attack=.8):
    n = int(dur * SR)
    out = []
    det = [rnd.uniform(-.004, .004) for _ in range(len(midis) * 2)]
    for k in range(n):
        x = k / SR
        s = 0.0
        for j, m in enumerate(midis):
            f = note(m)
            s += math.sin(TAU * f * (1 + det[2 * j]) * x) + .6 * math.sin(TAU * f * (1 + det[2 * j + 1]) * x + 1.3)
        a = min(1.0, x / attack)
        r = min(1.0, (dur - x) / .8)
        out.append(s / len(midis) * a * max(0.0, r) * (.8 + .2 * math.sin(TAU * .25 * x)))
    add(t, out, gain * .12, rev=.5)


def whoosh(t, dur, gain=1.0, rising=True, pan_sweep=True):
    n = int(dur * SR)
    out, lp, bp = [], 0.0, 0.0
    for k in range(n):
        p = k / n
        shape = p if rising else 1 - p
        noise = rnd.random() * 2 - 1
        c = .01 + .25 * shape * shape
        lp += (noise - lp) * c
        bp += (lp - bp) * .5
        out.append((lp - bp * .3) * (math.sin(math.pi * p) if not rising else p ** 2.2))
    add(t, out, gain * .6, rev=.3)


def riser(t, dur, gain=1.0, start=48, end=84):
    n = int(dur * SR)
    out, ph = [], 0.0
    for k in range(n):
        p = k / n
        f = note(start + (end - start) * p ** 1.6)
        ph += TAU * f / SR
        out.append((math.sin(ph) + .5 * math.sin(ph * 2.01)) * p ** 2 * .5)
    add(t, out, gain * .35, rev=.4)
    whoosh(t, dur, gain * .7, rising=True)


def click(t, gain=1.0, pitch=2400):
    n = int(0.03 * SR)
    out = [math.sin(TAU * pitch * k / SR) * math.exp(-(k / SR) * 180) + (rnd.random() - .5) * .4 * math.exp(-(k / SR) * 400) for k in range(n)]
    add(t, out, gain * .35, pan=rnd.uniform(-.2, .2))


def tick_run(t0, t1, start_rate=8, end_rate=28, gain=1.0, base=72):
    """Counter ticks that speed up and rise in pitch."""
    t, i = t0, 0
    while t < t1:
        p = (t - t0) / (t1 - t0)
        pluck(t, base + int(p * 14), dur=.05, gain=gain * .5, pan=(i % 2) * .3 - .15, rev=.1, bright=.4)
        rate = start_rate + (end_rate - start_rate) * p
        t += 1 / rate
        i += 1


# ------------------------------------------------------------------ score
# Cue times match ad.html (voiceover line start + word offset from voice/words.json).
PROG = [(57, [69, 72, 76]), (53, [69, 72, 77]), (48, [67, 72, 76]), (55, [67, 71, 74])]

# S1: the hook. Low drone, typing, a soft hit as the question lands, a pull into the burst.
pad(0.0, [45, 52, 57], 4.4, gain=1.0, attack=1.0)
for c in range(15):
    click(0.38 + c * (0.75 / 15), gain=.6, pitch=rnd.choice([2200, 2500, 2800]))
boom(1.62, gain=.5)
for i, at in enumerate([1.637, 1.875, 2.1, 2.762, 2.925, 3.287, 3.387, 3.5]):
    pluck(at, [64, 67, 72, 67, 63, 64, 67, 71][i], dur=.3, gain=.32, pan=-.4 + i * .1, rev=.5)
riser(3.45, 0.8, gain=.8, start=45, end=86)
whoosh(4.0, 0.4, gain=1.0, rising=True)

# S2: the counts. Chips burst, a heartbeat pulse, a slam per count, a sad little fall for the Java.
boom(4.25, gain=1.2)
for i in range(40):
    pluck(4.27 + i * .02 + rnd.random() * .02, rnd.choice([76, 79, 81, 84, 86, 88]), dur=.22, gain=.22, pan=rnd.uniform(-.8, .8), rev=.4)
t = 4.5
while t < 12.7:
    kick(t, gain=.55)
    t += BEAT
for i, at in enumerate([4.5, 6.2, 7.3, 9.212]):
    boom(at, gain=.95)
    pluck(at, [57, 60, 64, 67][i], dur=.6, gain=.8, rev=.4)
pad(4.5, [45, 52, 60], 6.2, gain=.6, attack=.3)
boom(10.712, gain=1.15)
pluck(10.712, 70, dur=.5, gain=.7, rev=.4)
for i, m in enumerate([67, 66, 65, 64]):
    pluck(11.2 + i * .28, m, dur=.45 if i < 3 else 1.0, gain=.45, rev=.5, bright=.5)
riser(12.2, 1.2, gain=.9, start=50, end=90)

# S3: logo.
whoosh(12.95, 0.8, gain=1.0, rising=False)
boom(13.45, gain=1.0)
for i, m in enumerate([81, 84, 88, 93, 88, 84]):
    pluck(13.42 + i * .08, m, dur=.6, gain=.5, pan=-.5 + i * .2, rev=.6)
for i in range(9):
    pluck(13.75 + i * .045, [69, 72, 76, 79, 81, 84, 88, 91, 93][i], dur=.35, gain=.35, pan=-.6 + i * .15, rev=.5)
pad(13.4, [57, 64, 69, 72], 2.3, gain=1.0, attack=.3)
whoosh(15.0, 0.45, gain=.8)

# S4–S6: the groove from 15.4, dropping out for "one calm window" (19.45–20.6).
G0 = 15.4
CALM = (19.4, 20.6)
for b in range(int((41.5 - G0) / BEAT)):
    t = G0 + b * BEAT
    if CALM[0] <= t < CALM[1]:
        continue
    kick(t, gain=.9 if b % 4 == 0 else .75)
    hat(t + BEAT / 2, gain=.85)
    if b % 2 == 1:
        clap(t, gain=.7)
    if b % 4 == 3:
        hat(t + BEAT * .75, gain=.6, open_=True)
bars = int((41.5 - G0) / 2.0)
for bar in range(bars):
    t = G0 + bar * 2.0
    root, chord = PROG[bar % 4]
    calm = CALM[0] - .1 <= t < CALM[1]
    for step in range(8):
        st = t + step * .25
        if CALM[0] <= st < CALM[1]:
            continue
        if (step in (0, 3, 4, 6)) or bar % 2:
            bass(st, root - 12 + (12 if step == 6 else 0), .24, gain=.8)
    pad(t, chord, 2.05, gain=1.0 if calm else .7, attack=.15)
boom(G0, gain=.8)
tick_run(16.5, 18.0, gain=.6, base=74)
for at in (16.063, 17.112, 17.875):
    pluck(at, 84, dur=.4, gain=.45, rev=.5)
pad(19.4, [57, 64, 69, 76], 1.4, gain=1.2, attack=.3)
whoosh(20.25, 0.4, gain=.8)

# Roll call: a rising note on every name, then a sparkle for "and more".
boom(20.6, gain=.6)
for i, at in enumerate([20.75, 21.725, 22.637, 23.713, 24.688, 25.713, 26.75, 27.762]):
    boom(at, gain=.35)
    pluck(at, [69, 71, 72, 74, 76, 77, 79, 81][i], dur=.5, gain=.55, rev=.45)
    pluck(at, [69, 71, 72, 74, 76, 77, 79, 81][i] + 12, dur=.3, gain=.2, rev=.5, bright=.4)
boom(28.787, gain=.7)
for i in range(10):
    pluck(29.03 + i * .05, [81, 84, 88, 91, 93, 96, 93, 91, 88, 84][i], dur=.35, gain=.3, pan=-.6 + i * .13, rev=.6)
whoosh(29.85, 0.45, gain=.8)

# Graph.
boom(30.25, gain=.7)
for i in range(6):
    pluck(31.125 + i * .16, 72 + i * 2, dur=.3, gain=.38, pan=-.4 + i * .16, rev=.4)
for i in range(4):
    pluck(33.775 + i * .12, 88, dur=.15, gain=.25, rev=.2, bright=.3)
pluck(34.5, 76, dur=.6, gain=.4, rev=.5)
whoosh(35.3, 0.5, gain=.8)

# Cleanup: checks, the click, the freed counter, items dropping into the bin.
boom(35.75, gain=.7)
for i in range(6):
    click(35.9 + i * .05, gain=.7, pitch=3000)
click(36.2, gain=1.5, pitch=1800)
boom(36.22, gain=.65)
tick_run(36.5, 38.0, start_rate=10, end_rate=30, gain=.85, base=76)
pluck(38.05, 93, dur=1.0, gain=.55, rev=.7)
whoosh(38.3, 0.5, gain=.7)
for i in range(6):
    land = 38.975 + i * .14
    kick(land, gain=.35)
    pluck(land, [79, 81, 84, 86, 88, 91][i], dur=.2, gain=.3, rev=.3)
for i, m in enumerate([76, 81, 84]):
    pluck(40.05 + i * .12, m, dur=1.0, gain=.35, rev=.7)
riser(41.0, 1.15, gain=.85, start=55, end=88)

# S7: end card. Final hit and a wide chord that rings out.
boom(42.15, gain=1.2)
pad(42.15, [57, 64, 69, 72, 76], 5.3, gain=1.4, attack=.05)
for i, m in enumerate([69, 76, 81, 84, 88]):
    pluck(42.3 + i * .045, m, dur=1.4, gain=.45, pan=-.6 + i * .3, rev=.7)
pluck(43.5, 88, dur=1.5, gain=.35, rev=.8)
pluck(44.725, 93, dur=2.5, gain=.4, rev=.8)

# ------------------------------------------------------------------ reverb
# Schroeder-style: four combs + two all-passes on the send, added back wide.
def comb(src, delay, fb):
    out = array.array('f', bytes(4 * N))
    for i in range(N):
        y = src[i] + (out[i - delay] * fb if i >= delay else 0.0)
        out[i] = y
    return out


wetL = array.array('f', bytes(4 * N))
wetR = array.array('f', bytes(4 * N))
for d, fb, side in ((1557, .80, 0), (1617, .80, 1), (1491, .80, 0), (1422, .80, 1)):
    c = comb(REV, d, fb)
    target = wetL if side == 0 else wetR
    for i in range(N):
        target[i] += c[i] * .25

for buf in (wetL, wetR):
    for d, g in ((225, .5), (556, .5)):
        out = array.array('f', bytes(4 * N))
        for i in range(N):
            x = buf[i]
            y = -g * x + (buf[i - d] if i >= d else 0.0) + g * (out[i - d] if i >= d else 0.0)
            out[i] = y
        for i in range(N):
            buf[i] = out[i]

for i in range(N):
    L[i] += wetL[i] * .45
    R[i] += wetR[i] * .45

# ------------------------------------------------------------------ master
# Gentle soft-clip limiter, fade-in/out, normalize to -1 dBFS.
peak = 1e-9
for i in range(N):
    for buf in (L, R):
        v = math.tanh(buf[i] * 1.2)
        buf[i] = v
        peak = max(peak, abs(v))
norm = 0.89 / peak
fade_in, fade_out = int(.02 * SR), int(.45 * SR)
frames = bytearray()
for i in range(N):
    g = norm * min(1.0, i / fade_in) * min(1.0, (N - i) / fade_out)
    frames += struct.pack('<hh', int(L[i] * g * 32767), int(R[i] * g * 32767))

with wave.open(sys.argv[1] if len(sys.argv) > 1 else 'music.wav', 'wb') as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes(bytes(frames))
print('wrote', sys.argv[1] if len(sys.argv) > 1 else 'music.wav')
