import "./style.css";
import "./wallpaper.css";
import { ArchiveScene } from "./scene";
import { records } from "./data";
import { logo } from "./brand";

const stage = document.querySelector<HTMLElement>("#stage")!;
stage.innerHTML = `
  <div id="three-scene" class="three-scene"></div>
  <div class="wallpaper-grid"></div>
  <div class="wallpaper-vignette"></div>
  <header class="wallpaper-brand"><div class="eyebrow">RHINE LAB / INTERNAL DATABASE</div><h1>ANALYSIS <b>OS</b></h1><p>SYNTHESIZE INFORMATION</p></header>
  <div class="wallpaper-mark">${logo}</div>
  <div class="wallpaper-caption"><span id="wallpaper-state">ARCHIVE SELECT / AUTOMATIC SEQUENCE</span><b id="wallpaper-file">FILE X-001</b></div>
  <div class="wallpaper-meta"><span>SESSION AUTHORIZED</span><i></i><span>NO INTERACTION REQUIRED</span></div>
  <div class="wallpaper-progress"><i></i></div>
`;

const scene = new ArchiveScene(document.querySelector("#three-scene")!);
scene.setWallpaperMode(true);
scene.setMode("archive");
scene.setQuality(true);

const fit = () => {
  const scale = Math.min(innerWidth / 1920, innerHeight / 1080);
  stage.style.transform = `translate(-50%, -50%) scale(${scale})`;
  scene.resize();
};
addEventListener("resize", fit);

let started = false;
let raf = 0;
const loop = (ms: number) => {
  const t = ms / 1000;
  // One selected slice rises every 5.6 seconds. The scene itself supplies the
  // wave field and spring motion, so selection remains purely visual.
  const cycle = 5.6;
  const index = Math.floor(t / cycle) % records.length;
  if (!started) {
    scene.select(index);
    started = true;
  } else if (Math.floor(t / cycle) !== Math.floor((t - 1 / 60) / cycle)) {
    scene.select(index);
  }
  scene.update(t);
  const phase = (t % cycle) / cycle;
  const title = document.querySelector<HTMLElement>("#wallpaper-file")!;
  title.textContent = `FILE ${records[index]?.id ?? "X-001"}`;
  document.querySelector<HTMLElement>(".wallpaper-progress i")!.style.transform =
    `scaleX(${phase})`;
  document.querySelector<HTMLElement>("#wallpaper-state")!.textContent =
    phase > 0.12 && phase < 0.78
      ? "ARCHIVE SELECT / FOCUS LOCKED"
      : "ARCHIVE SELECT / AUTOMATIC SEQUENCE";
  raf = requestAnimationFrame(loop);
};

void scene.load().then(() => {
  fit();
  scene.select(0);
  requestAnimationFrame(loop);
});

window.addEventListener("beforeunload", () => cancelAnimationFrame(raf));
