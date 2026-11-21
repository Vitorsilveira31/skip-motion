#!/usr/bin/env bun
// SkipMotion's MotionView in a SwiftUIWeb app plays what Swift asks for, with lottie-web loaded on first use under the
// app's Content-Security-Policy. Run by `bash Web/demo/run.sh --test`, which builds the demo app first.
//
// The demo (Web/demo/App) shows one MotionView over a 100 by 100 Lottie animation of 60 frames at 30 fps whose square moves
// from x = 20 to x = 80, so where lottie-web stands is read from the square's transform in the SVG it draws (inside the
// DOM view's ShadowRoot). `onComplete` goes to the app's `log` text as `C|<finished>`. Each scenario runs with Swift in
// the Worker and on the main thread (`?render-in-worker=0`), on Chromium and WebKit (MOTION_ENGINES).
//
// usage: bun Web/demo/test-browser.mjs <bundle directory>
import { chromium, webkit } from "@playwright/test";
import { existsSync, statSync } from "node:fs";
import { extname, join, resolve } from "node:path";

const BUNDLE = resolve(process.argv[2] ?? "");
const ENGINES = (process.env.MOTION_ENGINES ?? "chromium,webkit").split(",").filter(Boolean);
const failures = [];

function check(condition, message) {
  if (!condition) {
    failures.push(message);
    console.log(`  FAIL ${message}`);
  }
  return Boolean(condition);
}

const TYPES = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css", ".wasm": "application/wasm", ".json": "application/json" };
/** The bundle as static files; `/` and every unknown path serve index.html (the app's routes). */
function serve(directory) {
  return Bun.serve({
    port: 0,
    fetch(request) {
      const path = decodeURIComponent(new URL(request.url).pathname);
      let file = join(directory, path);
      if (!file.startsWith(directory) || !existsSync(file) || statSync(file).isDirectory()) file = join(directory, "index.html");
      return new Response(Bun.file(file), { headers: { "content-type": TYPES[extname(file)] ?? "application/octet-stream" } });
    },
  });
}

// In the page: the DOM view's ShadowRoot, and the square's x in the SVG lottie-web draws there
// (its layer's transform is `matrix(1,0,0,1,x,50)`), or null.
const shadowSVG = () => document.querySelector('[data-dom-view="true"]')?.shadowRoot?.querySelector("svg") ?? null;
function squareX() {
  const svg = document.querySelector('[data-dom-view="true"]')?.shadowRoot?.querySelector("svg");
  if (!svg) return null;
  for (const group of svg.querySelectorAll("g[transform]")) {
    const match = /matrix\(([^)]+)\)/.exec(group.getAttribute("transform") || "");
    if (!match) continue;
    const values = match[1].split(",").map(Number);
    if (values.length === 6 && Math.abs(values[5] - 50) < 0.01) return values[4];
  }
  return null;
}

async function waitFor(page, predicate, timeout = 10000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (await page.evaluate(predicate)) return true;
    await page.waitForTimeout(50);
  }
  return false;
}

class Probe {
  constructor(page) { this.page = page; }
  async click(name) { await this.page.locator(`[data-testid="${name}"]`).first().dispatchEvent("click"); }
  async lines() {
    const text = (await this.page.locator('[data-testid="log"]').textContent()) || "";
    return text.split("\n").filter(Boolean);
  }
  async mark() { return (await this.lines()).length; }
  async since(mark) { return (await this.lines()).slice(mark); }
  async x() { return this.page.evaluate(squareX); }
  async waitLine(line, mark, timeout = 5000) {
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
      if ((await this.since(mark)).includes(line)) return true;
      await this.page.waitForTimeout(50);
    }
    return false;
  }
  async waitX(x, tolerance = 0.6, timeout = 5000) {
    const deadline = Date.now() + timeout;
    let last = null;
    while (Date.now() < deadline) {
      last = await this.x();
      if (last !== null && Math.abs(last - x) <= tolerance) return last;
      await this.page.waitForTimeout(50);
    }
    return last;
  }
}

async function scenario(browser, base, engine, worker) {
  const label = `${engine} ${worker ? "worker" : "main thread"}`;
  const page = await browser.newPage();
  const errors = [];
  const loaderRequests = [];
  page.on("pageerror", (error) => errors.push(String(error)));
  page.on("console", (message) => { if (message.type() === "error") errors.push(message.text()); });
  page.on("request", (request) => { if (request.url().includes("skip-motion-lottie")) loaderRequests.push(request.url()); });
  await page.addInitScript(() => {
    window.__cspViolations = [];
    document.addEventListener("securitypolicyviolation", (event) => window.__cspViolations.push(`${event.violatedDirective} ${event.blockedURI}`));
  });
  try {
    await page.goto(`${base}/?render-in-worker=${worker ? 1 : 0}`, { waitUntil: "domcontentloaded" });
    await page.waitForSelector('html[data-embedded-mounted="true"]', { timeout: 30000 });
    check((await page.evaluate(() => window.__embeddedSession.worker)) === worker, `${label}: runs in the ${worker ? "worker" : "main thread"}`);
    const probe = new Probe(page);

    const header = await page.locator('[data-testid="header"]').textContent();
    check(header === "H|2.0|0.0|60.0|30.0|100.0|100.0", `${label}: LottieContainer reads the header (${header})`);

    check(await waitFor(page, shadowSVG, 15000), `${label}: lottie-web draws the animation`);
    check(loaderRequests.length === 1, `${label}: skip-motion-lottie.js is fetched once (${loaderRequests.length})`);
    const box = await page.evaluate(() => {
      const r = document.querySelector('[data-dom-view="true"]').shadowRoot.querySelector("svg").getBoundingClientRect();
      return [r.width, r.height];
    });
    check(Math.abs(box[0] - 200) < 1 && Math.abs(box[1] - 200) < 1, `${label}: a 200 by 200 frame holds the animation at 200 by 200 (${box})`);

    // The default playback loops: the square moves and no completion is reported.
    let mark = await probe.mark();
    const first = await probe.x();
    await page.waitForTimeout(400);
    const second = await probe.x();
    check(first !== null && second !== null && Math.abs(second - first) > 1, `${label}: a loop moves the square (${first} -> ${second})`);
    await page.waitForTimeout(2200);
    check((await probe.since(mark)).length === 0, `${label}: a loop never completes (${await probe.since(mark)})`);

    // Pausing cuts the loop short; the progress and the frame place the square.
    mark = await probe.mark();
    await probe.click("pause-half");
    const half = await probe.waitX(50);
    check(half !== null && Math.abs(half - 50) <= 0.6, `${label}: paused at progress 0.5 the square is at x 50 (${half})`);
    check(await probe.waitLine("C|false", mark), `${label}: pausing a loop reports it unfinished`);
    await page.waitForTimeout(300);
    check(Math.abs((await probe.x()) - half) < 0.01, `${label}: a paused animation stays`);
    await probe.click("frame-15");
    const fifteen = await probe.waitX(35);
    check(fifteen !== null && Math.abs(fifteen - 35) <= 0.6, `${label}: paused at frame 15 the square is at x 35 (${fifteen})`);

    // playOnce at 4x (0.4 s from frame 15) completes once, at lottie-web's last frame (op - 1: frame 59, x 79).
    mark = await probe.mark();
    await probe.click("once-fast");
    check(await probe.waitLine("C|true", mark, 4000), `${label}: playOnce completes`);
    await page.waitForTimeout(400);
    const end = await probe.x();
    check(end !== null && end > 78.9, `${label}: playOnce stops at the end (${end})`);
    check((await probe.since(mark)).join(",") === "C|true", `${label}: playOnce completes once (${await probe.since(mark)})`);

    // The same playback again changes nothing, as for lottie-ios: only its speed differs, and it has ended.
    mark = await probe.mark();
    await probe.click("once");
    await page.waitForTimeout(300);
    check((await probe.since(mark)).length === 0 && (await probe.x()) > 78.9, `${label}: the same playOnce again does not restart`);

    // A pause in the middle of playOnce at 1x reports it unfinished (from frame 15: 1.5 s to the end).
    await probe.click("frame-15");
    await probe.waitX(35);
    mark = await probe.mark();
    await probe.click("once");
    await page.waitForTimeout(300);
    await probe.click("pause");
    check(await probe.waitLine("C|false", mark), `${label}: a pause cuts playOnce short`);
    await page.waitForTimeout(2200);
    check(!(await probe.since(mark)).includes("C|true"), `${label}: an interrupted playOnce never completes`);

    // repeat(2) at 4x from frame 15: a pass to the end and a whole one (about 0.85 s), one completion.
    await probe.click("frame-15");
    await probe.waitX(35);
    mark = await probe.mark();
    const started = Date.now();
    await probe.click("repeat2");
    check(await probe.waitLine("C|true", mark, 5000), `${label}: repeat(2) completes`);
    const elapsed = Date.now() - started;
    check(elapsed > 650, `${label}: repeat(2) plays two passes (${elapsed} ms)`);
    await page.waitForTimeout(300);
    check((await probe.since(mark)).join(",") === "C|true", `${label}: repeat(2) completes once (${await probe.since(mark)})`);

    // A progress range: from 0.5 to 0.75 (frames 30 to 45), ending at x 65.
    mark = await probe.mark();
    await probe.click("range");
    check(await probe.waitLine("C|true", mark, 4000), `${label}: a range completes`);
    await page.waitForTimeout(200);
    const rangeEnd = await probe.x();
    check(rangeEnd !== null && Math.abs(rangeEnd - 65) <= 1, `${label}: a range from 0.5 to 0.75 ends at x 65 (${rangeEnd})`);

    // autoReverse at 4x: forward to the end, then back.
    await probe.click("autoreverse");
    const samples = [];
    for (let index = 0; index < 30; index += 1) { samples.push(await probe.x()); await page.waitForTimeout(40); }
    const top = Math.max(...samples);
    const peak = samples.indexOf(top);
    check(top > 70 && samples.slice(peak).some((x) => x < top - 10), `${label}: autoReverse turns back (${samples.map((x) => Math.round(x)).join(" ")})`);

    // The content mode.
    await probe.click("fill");
    check(await waitFor(page, () => document.querySelector('[data-dom-view="true"]')?.shadowRoot?.querySelector("svg")?.getAttribute("preserveAspectRatio") === "xMidYMid slice", 5000),
      `${label}: .fill draws with preserveAspectRatio slice`);

    // The view goes away and comes back: a new player, no new download.
    await probe.click("hide");
    check(await waitFor(page, () => document.querySelector('[data-dom-view="true"]') === null, 5000), `${label}: hiding removes the MotionView`);
    await probe.click("show");
    check(await waitFor(page, shadowSVG, 5000), `${label}: showing it again draws the animation`);
    check(loaderRequests.length === 1, `${label}: skip-motion-lottie.js is not fetched again (${loaderRequests.length})`);

    const violations = await page.evaluate(() => window.__cspViolations);
    check(violations.length === 0, `${label}: no CSP violation (${violations.join("; ")})`);
    check(errors.length === 0, `${label}: no page error (${errors.join("; ")})`);
    console.log(`  ${label}: done`);
  } finally {
    await page.close();
  }
}

if (!existsSync(join(BUNDLE, "index.html"))) {
  console.error(`usage: bun Web/demo/test-browser.mjs <bundle directory> (no index.html in ${BUNDLE})`);
  process.exit(2);
}
const server = serve(BUNDLE);
const base = `http://127.0.0.1:${server.port}`;
try {
  for (const engine of ENGINES) {
    const browser = await ({ chromium, webkit })[engine].launch({ headless: true });
    try {
      for (const worker of [true, false]) await scenario(browser, base, engine, worker);
    } finally {
      await browser.close();
    }
  }
} finally {
  server.stop(true);
}
if (failures.length > 0) {
  console.log(`${failures.length} FAILED`);
  process.exit(1);
}
console.log("PASS MotionView plays Lottie animations with lottie-web in SwiftUIWeb, in the Worker and on the main thread");
