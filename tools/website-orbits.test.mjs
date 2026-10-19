import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { runInNewContext } from "node:vm";

const source = await readFile(new URL("../website/orbits.js", import.meta.url), "utf8");

function target(properties = {}) {
  const listeners = new Map();
  return {
    ...properties,
    addEventListener(type, listener) {
      if (!listeners.has(type)) listeners.set(type, []);
      listeners.get(type).push(listener);
    },
    emit(type, event = {}) {
      for (const listener of listeners.get(type) ?? []) listener(event);
    },
  };
}

function rect(left, top, width, height) {
  return { left, top, width, height, right: left + width, bottom: top + height };
}

function fixture({ reduced = false, fine = true, paused = false } = {}) {
  const frames = new Map();
  const attributes = new Map();
  const styles = Array.from({ length: 6 }, () => new Map());
  const anchors = styles.map((properties, index) => ({
    rect: rect(350 + index * 45, 250 + index * 15, 40, 40),
    getBoundingClientRect() { return this.rect; },
    querySelector: () => ({
      style: {
        setProperty: (key, value) => properties.set(key, value),
        removeProperty: (key) => properties.delete(key),
      },
    }),
  }));
  const scene = target({
    rect: rect(200, 100, 500, 400),
    querySelectorAll: () => anchors,
    getBoundingClientRect() { return this.rect; },
    setAttribute: (key, value) => attributes.set(key, value),
    removeAttribute: (key) => attributes.delete(key),
  });
  const pause = target({ checked: paused });
  const reducedMotion = target({ matches: reduced });
  const finePointer = target({ matches: fine });
  const window = target({
    innerWidth: 900,
    matchMedia: (query) => query.includes("reduced-motion") ? reducedMotion : finePointer,
  });
  const document = target({
    hidden: false,
    querySelector: (selector) => selector === ".orbit-scene" ? scene : pause,
  });
  let nextFrame = 0;
  runInNewContext(source, {
    window,
    document,
    requestAnimationFrame: (callback) => {
      frames.set(++nextFrame, callback);
      return nextFrame;
    },
    cancelAnimationFrame: (id) => frames.delete(id),
  });
  return {
    frames, attributes, styles, anchors, scene, pause, reducedMotion, finePointer, window, document,
    move: (clientX = 330, clientY = 270, pointerType = "mouse") => scene.emit("pointermove", { clientX, clientY, pointerType }),
    tick: () => {
      const callbacks = [...frames.values()];
      frames.clear();
      callbacks.forEach((callback) => callback());
    },
  };
}

test("nearby emotes dodge the cursor while distant emotes stay on their paths", () => {
  const f = fixture();
  assert.equal(f.frames.size, 0);
  for (let i = 0; i < 20; i++) f.move();
  assert.equal(f.frames.size, 1, "pointer events share one frame loop");
  f.tick();
  assert.ok(Number.parseFloat(f.styles[0].get("--nudge-x")) > 20);
  assert.equal(Number.parseFloat(f.styles[0].get("--nudge-y")), 0);
  assert.equal(f.styles[5].get("--nudge-x"), "0.00px");
  assert.equal(f.styles[5].get("--nudge-y"), "0.00px");
  assert.equal(f.frames.size, 1, "a stationary cursor still influences moving orbits");
  assert.equal(f.attributes.has("data-interacting"), true);
});

test("a cursor at an emote's exact center produces a finite bounded nudge", () => {
  const f = fixture();
  f.move(370, 270);
  f.tick();
  const x = Number.parseFloat(f.styles[0].get("--nudge-x"));
  const y = Number.parseFloat(f.styles[0].get("--nudge-y"));
  assert.equal(x, 54);
  assert.equal(y, 0);
});

test("nudges keep artwork inside the scene and viewport", () => {
  const f = fixture();
  f.window.innerWidth = 320;
  f.scene.rect = rect(0, 0, 320, 280);
  f.anchors[0].rect = rect(285, 120, 32, 32);
  f.move(280, 136);
  f.tick();
  const x = 301 + Number.parseFloat(f.styles[0].get("--nudge-x"));
  const y = 136 + Number.parseFloat(f.styles[0].get("--nudge-y"));
  assert.ok(x >= 24 && x <= 296);
  assert.ok(y >= 24 && y <= 256);
});

test("leaving the scene cancels the loop and lets CSS return the emotes to orbit", () => {
  const f = fixture();
  f.move();
  f.tick();
  f.scene.emit("pointerleave");
  assert.equal(f.frames.size, 0);
  assert.equal(f.attributes.has("data-interacting"), false);
  assert.ok(f.styles.every((style) => style.size === 0));
});

test("pause, lifecycle changes, and input preferences clear active interaction", () => {
  for (const [name, event] of [
    ["pause", "change"], ["reducedMotion", "change"], ["finePointer", "change"],
    ["window", "blur"], ["window", "resize"], ["window", "scroll"],
    ["document", "visibilitychange"], ["scene", "pointercancel"],
  ]) {
    const f = fixture();
    f.move();
    f.tick();
    f[name].emit(event);
    assert.equal(f.frames.size, 0, `${name}:${event} cancels the frame loop`);
    assert.ok(f.styles.every((style) => style.size === 0));
    assert.equal(f.attributes.has("data-interacting"), false);
  }
});

test("touch, reduced motion, coarse input, pause, and hidden pages never start nudging", () => {
  for (const options of [{ reduced: true }, { fine: false }, { paused: true }]) {
    const f = fixture(options);
    f.move();
    assert.equal(f.frames.size, 0);
  }
  const f = fixture();
  f.move(330, 270, "touch");
  assert.equal(f.frames.size, 0);
  f.document.hidden = true;
  f.move();
  assert.equal(f.frames.size, 0);
});
