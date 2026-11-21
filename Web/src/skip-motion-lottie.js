// SkipMotion's "skip-motion" component for SwiftUIWeb: plays a MotionView's Lottie animation with lottie-web.
//
// Sources/SkipMotionWeb/SkipMotion.swift mounts it through DOMViewRepresentable. Its state is one line of JSON with what
// to play, a line break, and the Lottie JSON text:
//   {"mode":"play"|"pause","loop":"once"|"loop"|"autoreverse"|"repeat:<n>"|"repeat-backwards:<n>","speed":<n>,
//    "from":<n>|null,"to":<n>|null,"progress":<n>|null,"frame":<n>|null,"fill":<bool>}
// It posts "1" when a playback ends and "0" when a pause or a new playback cuts it short, as lottie-ios calls
// `animationDidFinish`; an infinite loop never ends by itself.
//
// `npm run build` (or `bun run build`) bundles this file with lottie-web's light SVG player into
// Resources/skip-motion-lottie.js, which Resources/skip-motion.js imports the first time a MotionView is on the page. The
// light player has no After Effects expressions, which lottie-web evaluates with `eval`: a page whose
// Content-Security-Policy has no 'unsafe-eval' (SwiftUIWeb's) refuses that.
import lottie from "lottie-web/build/player/esm/lottie_light.min.js";

/** `{kind, count}` from the state's `loop`; anything else loops forever, SkipMotion's default. */
export function parseLoop(value) {
  if (value === "once" || value === "autoreverse" || value === "loop") return { kind: value, count: 0 };
  const counted = /^(repeat|repeat-backwards):(\d+)$/.exec(value || "");
  if (counted) return { kind: counted[1], count: Number(counted[2]) };
  return { kind: "loop", count: 0 };
}

const finite = (value) => (typeof value === "number" && Number.isFinite(value) ? value : null);

/** The playback and the animation text of a state. */
export function parseState(state) {
  const text = String(state ?? "");
  const lineBreak = text.indexOf("\n");
  let raw = {};
  try { raw = JSON.parse(lineBreak < 0 ? text : text.slice(0, lineBreak)) || {}; } catch { raw = {}; }
  const speed = finite(raw.speed);
  return {
    config: {
      mode: raw.mode === "pause" ? "pause" : "play",
      loop: parseLoop(raw.loop),
      speed: speed === null ? 1 : speed,
      from: finite(raw.from),
      to: finite(raw.to),
      progress: finite(raw.progress),
      frame: finite(raw.frame),
      fill: raw.fill === true,
    },
    animation: lineBreak < 0 ? "" : text.slice(lineBreak + 1),
  };
}

const clamp = (value) => Math.min(1, Math.max(0, value));

class Player {
  constructor(root, emit) {
    this.emit = emit;
    this.container = root.ownerDocument.createElement("div");
    this.container.style.cssText = "display:block;width:100%;height:100%;overflow:hidden";
    root.append(this.container);
    this.text = null;
    this.animation = null;
    this.ready = false;
    this.config = null;
    this.applied = null;
    this.playback = null;
    this.segmented = false;
    this.running = false;
    this.plays = 0;
    this.direction = 1;
  }

  set(state) {
    const { config, animation } = parseState(state);
    this.config = config;
    if (animation !== this.text) this.load(animation);
    else if (this.ready) this.apply();
  }

  load(text) {
    this.destroyAnimation();
    this.text = text;
    let data;
    try { data = JSON.parse(text); } catch { return; }
    const animation = lottie.loadAnimation({
      container: this.container, renderer: "svg", loop: false, autoplay: false, animationData: data,
      rendererSettings: { preserveAspectRatio: "xMidYMid meet" },
    });
    this.animation = animation;
    this.firstFrame = Number(data.ip) || 0;
    this.lastFrame = Number(data.op) || 0;
    animation.addEventListener("complete", () => { if (this.animation === animation) this.completed(); });
    const ready = () => {
      if (this.animation !== animation) return;
      this.ready = true;
      this.applied = null;
      this.apply();
    };
    // An animation with images is ready once they load; one without is ready at once.
    if (animation.isLoaded) ready(); else animation.addEventListener("DOMLoaded", ready);
  }

  apply() {
    const config = this.config;
    const key = JSON.stringify(config);
    if (!config || key === this.applied) return;
    this.applied = key;
    const animation = this.animation;
    this.container.querySelector("svg")?.setAttribute("preserveAspectRatio", config.fill ? "xMidYMid slice" : "xMidYMid meet");
    animation.setSpeed(config.speed);
    const span = Math.max(0, this.lastFrame - this.firstFrame);
    if (config.mode === "pause") {
      this.interrupt();
      this.playback = null;
      // The last frame is `op - 1`: lottie-web wraps a frame at `op` back to the first.
      const last = Math.max(0, span - 0.001);
      if (config.progress !== null) animation.goToAndStop(Math.min(last, clamp(config.progress) * span), true);
      else if (config.frame !== null) animation.goToAndStop(Math.min(last, Math.max(0, config.frame - this.firstFrame)), true);
      else animation.pause();
      return;
    }
    // A change of speed or content mode leaves the playback as it is (running, or ended); a new loop mode or range, or
    // playing after a pause, starts a new one, as a new playback mode does for lottie-ios.
    const playback = `${config.loop.kind}:${config.loop.count}|${config.from}|${config.to}`;
    if (playback === this.playback) return;
    this.interrupt();
    this.playback = playback;
    this.running = true;
    this.plays = 0;
    this.direction = 1;
    animation.setLoop(config.loop.kind === "loop");
    animation.setDirection(1);
    const ranged = config.from !== null && config.to !== null;
    if (ranged) {
      animation.playSegments([this.firstFrame + clamp(config.from) * span, this.firstFrame + clamp(config.to) * span], true);
    } else {
      // Back to the whole animation from its start when a range played last, else from where it stands.
      if (this.segmented) animation.resetSegments(true);
      animation.play();
    }
    this.segmented = ranged;
  }

  /** lottie-web stopped at an end of the playback (its `loop` is off for every mode but `.loop`). */
  completed() {
    const config = this.config;
    if (!config || config.mode !== "play" || !this.running) return;
    const animation = this.animation;
    this.plays += 1;
    const reverse = () => {
      this.direction = -this.direction;
      animation.setDirection(this.direction);
      animation.play();
    };
    switch (config.loop.kind) {
      case "autoreverse":
        reverse();
        return;
      case "repeat":
        if (this.plays < Math.max(1, config.loop.count)) { animation.goToAndPlay(0, true); return; }
        break;
      case "repeat-backwards":
        // Each repetition is a pass forward and one back.
        if (this.plays < 2 * Math.max(1, config.loop.count)) { reverse(); return; }
        break;
      default:
        break;
    }
    this.running = false;
    this.emit("1");
  }

  /** A playback still running that a pause or a new playback ends: reported as not finished. */
  interrupt() {
    if (!this.running) return;
    this.running = false;
    this.emit("0");
  }

  destroyAnimation() {
    this.ready = false;
    this.running = false;
    this.playback = null;
    this.applied = null;
    this.segmented = false;
    if (this.animation) {
      try { this.animation.destroy(); } catch { /* an animation whose container is gone */ }
      this.animation = null;
    }
  }
}

export default {
  mount(host, root, emit, state) {
    const player = new Player(root, emit);
    player.set(state);
    return player;
  },
  update(player, state) {
    player.set(state);
  },
  dispose(player) {
    player.destroyAnimation();
    player.container.remove();
  },
};
