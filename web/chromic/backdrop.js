/* The Chromic app's living backdrop, for the web: the watercolor wash with its five paint layers
   swaying (iOS `LivingBackdrop`), and the squiggles, stars and dots drifting up through it
   (`SquiggleField`). Numbers are the app's, so the site moves the way the app does.
   Built entirely here: a page only needs <script src="backdrop.js" defer></script>. */
(() => {
  const base = document.currentScript?.src.replace(/[^/]*$/, "") || "";
  const url = (p) => base + p;

  // LivingBackdrop: each layer drifts on its own pair of sine periods (seconds, before `pace`).
  const LAYERS = [
    { img: "bg/wash1.webp", x: 9.7, y: 6.1, phase: 0.0 },
    { img: "bg/wash2.webp", x: 4.3, y: 8.9, phase: 1.3 },
    { img: "bg/wash3.webp", x: 7.4, y: 3.7, phase: 2.6 },
    { img: "bg/wash4.webp", x: 3.1, y: 9.9, phase: 3.9 },
    { img: "bg/wash5.webp", x: 6.6, y: 5.2, phase: 5.2 },
  ];
  const ZOOM = 1.12, TRAVEL = 0.05, PACE = 0.2;

  // SquiggleField: the mock's mix — more dots than stars, more stars than squiggles. Sizes are the
  // @3x art in points, which is also CSS pixels.
  const SPRITES = {
    squiggle1: [102, 48], squiggle2: [43, 94], squiggle3: [90, 68],
    star1: [62, 60], star2: [43, 42], star3: [64, 55],
    dot1: [21, 20], dot2: [21, 20], dot3: [19, 17],
  };
  const KINDS = ["squiggle1", "squiggle2", "squiggle3", "squiggle2",
                 "star1", "star2", "star3", "star1", "star3",
                 "dot1", "dot2", "dot3", "dot1", "dot2", "dot3", "dot2", "dot1", "dot3"];
  const MARGIN = 0.12;   // a sprite finishes leaving before it re-enters on the other side
  const rand = (a, b) => a + Math.random() * (b - a);

  const css = `
    .cx-backdrop{position:fixed;left:0;top:0;width:100vw;height:100vh;height:100lvh;overflow:hidden;
      z-index:-1;pointer-events:none;background:#f7e7d6}
    .cx-backdrop .cx-layer{position:absolute;left:-6%;top:-6%;width:112%;height:112%;
      background:center/cover no-repeat;will-change:transform}
    .cx-backdrop .cx-sprite{position:absolute;left:0;top:0;will-change:transform,opacity}`;
  const style = document.createElement("style");
  style.textContent = css;
  document.head.append(style);

  const root = document.createElement("div");
  root.className = "cx-backdrop";
  root.setAttribute("aria-hidden", "true");

  const still = document.createElement("div");
  still.className = "cx-layer";
  still.style.backgroundImage = `url("${url("backdrop.jpg")}")`;
  root.append(still);

  const washes = LAYERS.map((l) => {
    const el = document.createElement("div");
    el.className = "cx-layer";
    el.style.backgroundImage = `url("${url(l.img)}")`;
    root.append(el);
    return { ...l, el };
  });

  const sprites = KINDS.map((kind) => {
    // Mostly upward, a little sideways: the squiggles read as rising through the wash.
    const angle = rand(-Math.PI * 0.35, Math.PI * 0.35) - Math.PI / 2;
    const speed = rand(0.010, 0.022);                       // 60–120 s to cross the screen
    const [w, h] = SPRITES[kind];
    const el = document.createElement("img");
    el.className = "cx-sprite";
    el.src = url(`bg/${kind}.png`);
    el.alt = "";
    el.width = w; el.height = h;
    root.append(el);
    return {
      el, w, h,
      ox: Math.random(), oy: Math.random(),
      dx: Math.cos(angle) * speed, dy: Math.sin(angle) * speed,
      scale: kind.startsWith("dot") ? rand(0.8, 1.2) : rand(0.8, 1.3),
      spin: rand(-0.12, 0.12),
      swayPhase: rand(0, 2 * Math.PI), swayPeriod: rand(6, 11),
      opacity: rand(0.8, 1.0),
    };
  });
  sprites.forEach((s) => { s.el.style.opacity = s.opacity.toFixed(2); });

  const wrap = (v) => { const span = 1 + 2 * MARGIN; v = (v + MARGIN) % span; return (v < 0 ? v + span : v) - MARGIN; };

  function draw(seconds) {
    const W = root.clientWidth, H = root.clientHeight;
    const t = seconds * PACE;
    for (const l of washes) {
      const dx = Math.sin(t * 2 * Math.PI / l.x + l.phase) * TRAVEL * W;
      const dy = Math.sin(t * 2 * Math.PI / l.y + l.phase * 0.7) * TRAVEL * H;
      l.el.style.transform = `translate3d(${dx.toFixed(1)}px,${dy.toFixed(1)}px,0)`;
    }
    for (const s of sprites) {
      const sway = Math.sin(seconds * 2 * Math.PI / s.swayPeriod + s.swayPhase) * 10;
      const x = wrap(s.ox + s.dx * seconds) * W + sway - s.w / 2;
      const y = wrap(s.oy + s.dy * seconds) * H - s.h / 2;
      s.el.style.transform =
        `translate3d(${x.toFixed(1)}px,${y.toFixed(1)}px,0) rotate(${(s.spin * seconds).toFixed(3)}rad) scale(${s.scale.toFixed(2)})`;
    }
  }

  // Reduce Motion pauses the app's TimelineViews; here it holds the first frame.
  const reduce = matchMedia("(prefers-reduced-motion: reduce)");
  const start = performance.now();
  let frame = 0;
  function tick(now) { draw((now - start) / 1000); frame = requestAnimationFrame(tick); }
  function run() {
    cancelAnimationFrame(frame);
    if (reduce.matches) draw(0); else frame = requestAnimationFrame(tick);
  }
  reduce.addEventListener?.("change", run);
  addEventListener("resize", () => { if (reduce.matches) draw(0); });

  const mount = () => { document.body.prepend(root); run(); };
  if (document.body) mount(); else addEventListener("DOMContentLoaded", mount);
})();
