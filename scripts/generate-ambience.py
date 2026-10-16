#!/usr/bin/env python3
"""Rhine Lab 氛围背景音乐生成器（原创合成，无版权素材）。

风格参考《明日方舟》孤星 / 莱茵生命 OST 的「科技感 + 高级感」：
暗色电影感的合成弦乐垫、深潜次低频、机械脉冲低音、玻璃质感的琶音闪光，
D 小调，慢速呼吸感，54.4 秒无缝循环（含首尾交叉淡化，可直接 loop）。

用法：python3 generate-ambience.py <输出.wav>
之后用 afconvert 转 m4a：
  afconvert -f m4af -d aac -b 128000 out.wav out.m4a
"""
import sys
import wave

import numpy as np

SR = 44100
BEAT = 0.85          # ≈70.6 BPM
BAR = BEAT * 8       # 6.8 s
BARS_PER_LOOP = 8
LOOP = BAR * BARS_PER_LOOP            # 54.4 s
WINDOW_START = BARS_PER_LOOP * BAR    # 渲染 20 小节，取中间 8 小节作成品
RENDER_BARS = 20

# i - VI - III - VII：Dm / Bb / F / C
CHORDS = [
    [73.42, 146.83, 174.61, 220.00, 293.66],   # Dm: D2 A2? -> 低音 73.42 + 和弦音
    [58.27, 116.54, 146.83, 174.61, 233.08],   # Bb
    [43.65, 87.31, 174.61, 220.00, 261.63],    # F
    [65.41, 130.81, 164.81, 196.00, 261.63],   # C
]
# 每和弦的结构：sub 根音 / 三个垫音 / 琶音高音组
SUB_F = [c[0] for c in CHORDS]                       # 次低音（根音）
PAD_F = [c[1:4] for c in CHORDS]                     # 垫音三和弦
ARP_F = [c[2:5] for c in CHORDS]                     # 琶音组

N = int(RENDER_BARS * BAR * SR)
t = np.arange(N) / SR
L = np.zeros(N)
R = np.zeros(N)


def add(buf, idx, data):
    """把短事件写入左右声道（idx 为样本偏移）。"""
    i0, i1 = int(idx), int(idx) + len(data)
    if i0 >= N or i1 <= 0:
        return
    s0, s1 = max(i0, 0), min(i1, N)
    L[s0:s1] += data[s0 - i0:s1 - i0][:, 0]
    R[s0:s1] += data[s0 - i0:s1 - i0][:, 1]


def soft_saw(x):
    """三次谐波叠加的柔和锯齿波（近似低通滤波后的弦乐质感）。"""
    return np.sin(x) + 0.40 * np.sin(2 * x) + 0.20 * np.sin(3 * x)


def env_ar(tt, attack, decay):
    """指数型起落包络。"""
    e = np.zeros_like(tt)
    e[tt >= 0] = np.exp(-tt[tt >= 0] / decay)
    if attack > 0:
        mask = (tt >= 0) & (tt < attack)
        e[mask] = tt[mask] / attack
    return e


def raised_cosine_edges(tt, total, edge):
    """首尾均带 1.2s 升余弦边缘的条形包络（相邻和弦可无缝交叉）。"""
    e = np.ones_like(tt)
    up = np.clip(tt / edge, 0, 1)
    down = np.clip((total - tt) / edge, 0, 1)
    e = np.minimum(e, 0.5 - 0.5 * np.cos(np.pi * up))
    e = np.minimum(e, 0.5 - 0.5 * np.cos(np.pi * down))
    return e


# ---------- 1. 垫音（合成弦乐，每和弦一长条，首尾交叉） ----------
for bar in range(RENDER_BARS):
    chord = CHORDS[bar % len(CHORDS)]
    start = bar * BAR
    start_i = int(start * SR)
    seg_n = int(BAR * SR)
    tt = t[start_i:start_i + seg_n] - start
    edge = 1.2
    amp = raised_cosine_edges(tt, BAR, edge)
    for i, f in enumerate(PAD_F[bar % len(CHORDS)]):
        pan = 0.62 * (i - 1)  # -0.62 / 0 / 0.62
        lp, rp = np.cos(pan * np.pi / 4), np.sin(pan * np.pi / 4)
        norm = np.hypot(lp, rp) or 1.0
        lp, rp = lp / norm, rp / norm
        for det in (-0.0016, 0.0016):
            w = soft_saw(2 * np.pi * f * (1 + det) * tt)
            level = 0.0165 if i < 2 else 0.011
            add(None, start * SR,
                np.stack([w * amp * level * lp, w * amp * level * rp], axis=1))

# ---------- 2. 次低音（每和弦一根，慢呼吸） ----------
for bar in range(RENDER_BARS):
    f = SUB_F[bar % len(CHORDS)]
    start = bar * BAR
    start_i = int(start * SR)
    seg_n = int(BAR * SR)
    tt = t[start_i:start_i + seg_n] - start
    amp = raised_cosine_edges(tt, BAR, 1.6)
    breathe = 1 + 0.18 * np.sin(2 * np.pi * (t[start_i:start_i + seg_n]) / (2 * BAR) + 0.8)
    w = np.sin(2 * np.pi * f * tt) + 0.22 * np.sin(2 * np.pi * 2 * f * tt)
    w = w * amp * breathe * 0.085
    add(None, start * SR, np.stack([w, w], axis=1))

# ---------- 3. 机械脉冲低音（八分音符，小节第 1/5 拍加重，第 8 拍留白） ----------
for bar in range(RENDER_BARS):
    f = SUB_F[bar % len(CHORDS)] * 2
    for step in range(16):  # 每小节 16 个八分音符
        beat_pos = (step % 8) / 8
        if beat_pos >= 0.875:  # 第 8 拍留白（呼吸）
            continue
        onset = bar * BAR + step * BEAT / 2
        if onset + 0.35 > RENDER_BARS * BAR:
            continue
        dur = 0.20
        tt = np.arange(int(dur * SR)) / SR
        w = np.sin(2 * np.pi * f * tt) * np.exp(-tt / 0.075)
        accent = 1.55 if (step % 8) == 0 or (step % 8) == 4 else 1.0
        level = 0.038 * accent
        add(None, onset * SR, np.stack([w * level, w * level], axis=1))

# ---------- 4. 琶音闪光（十六分音符 + 3/8 拍回声，第 3 小节起进入） ----------
arp_gain = 0.020
for bar in range(RENDER_BARS):
    if bar % BARS_PER_LOOP < 2:  # 循环内前两小节留白，后六小节有琶音
        continue
    chord_tones = ARP_F[bar % len(CHORDS)]
    for step in range(32):
        onset = bar * BAR + step * BEAT / 4
        if onset + 0.5 > RENDER_BARS * BAR:
            continue
        f = chord_tones[step % len(chord_tones)] * 4  # 升高两个八度
        dur = 0.32
        tt = np.arange(int(dur * SR)) / SR
        w = np.sin(2 * np.pi * f * tt) * np.exp(-tt / 0.10)
        pan = 0.7 if step % 2 == 0 else -0.7
        lp, rp = np.cos(pan * np.pi / 4), np.sin(pan * np.pi / 4)
        level = arp_gain * (0.7 + 0.3 * np.sin(np.pi * step / 32))
        add(None, onset * SR, np.stack([w * level * lp, w * level * rp], axis=1))
        # 回声（3/8 拍后）
        echo_onset = onset + BEAT * 3 / 8
        if echo_onset + 0.32 < RENDER_BARS * BAR:
            add(None, echo_onset * SR,
                np.stack([w * level * 0.45 * lp, w * level * 0.45 * rp], axis=1))

# ---------- 5. 空气噪声（周期化棕噪声 + 低通 + 双小节呼吸） ----------
rng = np.random.default_rng(20261016)
noise_period = int(LOOP * SR)
base = rng.standard_normal(noise_period)
brown = np.cumsum(base - base.mean())
brown -= np.linspace(brown[0], brown[-1], noise_period)  # 去趋势保证周期衔接
brown /= (np.abs(brown).max() + 1e-9)
noise = np.tile(brown, int(np.ceil(N / noise_period)))[:N]
# FFT 低通（约 800 Hz，四阶平滑）
spec = np.fft.rfft(noise)
freqs = np.fft.rfftfreq(len(noise), 1 / SR)
mask = 1.0 / (1.0 + (freqs / 800.0) ** 4)
noise = np.fft.irfft(spec * mask, len(noise))
noise /= (np.abs(noise).max() + 1e-9)
breathe = 1 + 0.3 * np.sin(2 * np.pi * t / (2 * BAR))
air = noise * breathe * 0.011
L += air
R += air * 0.96

# ---------- 6. 玻璃钟（循环内第 2/4/6 小节起音，长衰减） ----------
for bar in range(RENDER_BARS):
    if bar % BARS_PER_LOOP not in (1, 3, 5):  # 对应循环小节 2/4/6
        continue
    f = ARP_F[bar % len(CHORDS)][0] * 8  # 再高一个八度的泛音
    onset = bar * BAR + 0.15
    dur = 1.6
    if onset + dur > RENDER_BARS * BAR:
        continue
    tt = np.arange(int(dur * SR)) / SR
    w = (np.sin(2 * np.pi * f * tt) + 0.55 * np.sin(2 * np.pi * f * 2.001 * tt)) \
        * np.exp(-tt / 0.5)
    level = 0.0075
    add(None, onset * SR, np.stack([w * level * 0.6, w * level], axis=1))

# ---------- 成品窗口 + 首尾交叉淡化（保证无缝循环） ----------
i0 = int(WINDOW_START * SR)
i1 = i0 + int(LOOP * SR)
outL = L[i0:i1]
outR = R[i0:i1]
xfade = int(0.05 * SR)
ramp = np.linspace(0, 1, xfade)
outL[:xfade] = outL[:xfade] * ramp + L[i1:i1 + xfade] * (1 - ramp)
outR[:xfade] = outR[:xfade] * ramp + R[i1:i1 + xfade] * (1 - ramp)

peak = max(np.abs(outL).max(), np.abs(outR).max())
target = 0.42
outL *= target / peak
outR *= target / peak

# 轻柔的极高频收敛（避免 AAC 编码后的冷硬感）
specL = np.fft.rfft(outL)
freqs = np.fft.rfftfreq(len(outL), 1 / SR)
shelf = 1.0 / (1.0 + (freqs / 11000.0) ** 3)
outL = np.fft.irfft(specL * (0.92 + 0.08 * shelf), len(outL))
specR = np.fft.rfft(outR)
outR = np.fft.irfft(specR * (0.92 + 0.08 * shelf), len(outR))

stereo = np.stack([outL, outR], axis=1)
pcm = (np.clip(stereo, -1, 1) * 32767).astype(np.int16)

out_path = sys.argv[1] if len(sys.argv) > 1 else "rhine-ambience.wav"
with wave.open(out_path, "wb") as wf:
    wf.setnchannels(2)
    wf.setsampwidth(2)
    wf.setframerate(SR)
    wf.writeframes(pcm.tobytes())

print(f"OK {out_path}: {len(outL)/SR:.1f}s loop, peak {peak:.3f}, "
      f"seam diff {float(np.abs(outL[-1] - outL[0])):.5f}")
