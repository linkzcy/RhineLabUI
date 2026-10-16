export class TerminalAudio {
  enabled = false;
  private context?: AudioContext;
  private bgm?: HTMLAudioElement;
  private bgmOn = false;

  /** 背景氛围音乐（原创合成，54.4s 无缝循环）。 */
  setBgm(on: boolean) {
    this.bgmOn = on;
    if (!on) {
      this.bgm?.pause();
      return;
    }
    this.bgm ??= (() => {
      const audio = new Audio("/assets/rhine-ambience.m4a");
      audio.loop = true;
      audio.volume = 0.3;
      audio.preload = "auto";
      document.body.appendChild(audio);
      return audio;
    })();
    if (this.bgm.paused) void this.bgm.play().catch(() => {});
  }

  /** 首次交互兜底：自动播放被拦时，等用户任意点击/按键后启动。 */
  resumeBgmIfNeeded() {
    if (!this.bgmOn) return;
    this.bgm ??= new Audio("/assets/rhine-ambience.m4a");
    this.bgm.loop = true;
    this.bgm.volume = 0.3;
    if (this.bgm.paused) void this.bgm.play().catch(() => {});
  }

  play(type: "tick" | "open" | "confirm" | "back" = "tick") {
    if (!this.enabled) return;
    try {
      this.context ??= new AudioContext();
      const c = this.context;
      if (c.state === "suspended") void c.resume();
      const osc = c.createOscillator(),
        gain = c.createGain();
      osc.type = "sine";
      const frequency = { tick: 760, open: 420, confirm: 960, back: 320 }[type];
      osc.frequency.setValueAtTime(frequency, c.currentTime);
      osc.frequency.exponentialRampToValueAtTime(
        frequency * (type === "open" ? 1.8 : 0.7),
        c.currentTime + 0.13,
      );
      gain.gain.setValueAtTime(0.0001, c.currentTime);
      gain.gain.exponentialRampToValueAtTime(0.035, c.currentTime + 0.008);
      gain.gain.exponentialRampToValueAtTime(0.0001, c.currentTime + 0.18);
      osc.connect(gain);
      gain.connect(c.destination);
      osc.start();
      osc.stop(c.currentTime + 0.2);
    } catch {
      /* Audio is optional; the terminal remains fully interactive. */
    }
  }
}
