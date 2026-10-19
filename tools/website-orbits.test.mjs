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

class Matrix {
  constructor(value) {
    [this.a, this.b, this.c, this.d] = Array.isArray(value) ? value
      : value === "none" ? [1, 0, 0, 1] : value.slice(7, -1).split(",").map(Number);
  }
  multiply(other) {
    return new Matrix([
      this.a * other.a + this.c * other.b, this.b * other.a + this.d * other.b,
      this.a * other.c + this.c * other.d, this.b * other.c + this.d * other.d,
    ]);
  }
}

function element(properties = {}) {
  const attributes = new Map();
  const values = new Map();
  return target({
    attributes, children: [], computed: { transform: "none" },
    style: {
      setProperty: (key, value) => values.set(key, value),
      removeProperty: (key) => values.delete(key),
    },
    setAttribute: (key, value) => attributes.set(key, value),
    removeAttribute: (key) => attributes.delete(key),
    toggleAttribute: (key, force) => force ? attributes.set(key, "") : attributes.delete(key),
    closest: () => null,
    append(child) { this.children.push(child); child.parentElement = this; },
    remove() { this.parentElement.children = this.parentElement.children.filter((child) => child !== this); },
    ...properties,
  });
}

function fixture({ reduced = false, fine = true, paused = false, decodeFailure = false, canvasFailure = false } = {}) {
  const frames = new Map();
  const timers = new Map();
  const warnings = [];
  const styles = Array.from({ length: 6 }, () => new Map());
  const images = [];
  const anchors = styles.map((properties, index) => {
    const anchor = element({
      dataset: { emote: `Emote ${index}` }, disabled: true,
      parentElement: element(),
      rect: rect(350 + index * 45, 250 + index * 15, 40, 40),
      getBoundingClientRect() { return this.rect; },
      closest: (selector) => selector === ".orbit-emote" ? anchor : null,
    });
    const image = element({
      naturalWidth: 4, naturalHeight: 4,
      computed: { width: "40px", height: "40px", transform: "none" },
      pixels: { width: 4, height: 4, data: new Uint8ClampedArray(64) },
      decode: () => decodeFailure && index === 0 ? Promise.reject(new Error("Image failed")) : Promise.resolve(),
      getBoundingClientRect() { return this.rect ?? anchor.rect; },
      cloneNode: () => element({ src: `emote-${index}.png` }),
      style: {
        setProperty: (key, value) => properties.set(key, value),
        removeProperty: (key) => properties.delete(key),
      },
    });
    for (const pixel of [5, 6, 9, 10]) image.pixels.data[pixel * 4 + 3] = 255;
    images.push(image);
    anchor.querySelector = () => image;
    return anchor;
  });
  const tv = { rect: rect(1000, 1000, 100, 100), getBoundingClientRect() { return this.rect; } };
  const scene = element({
    rect: rect(200, 100, 500, 400),
    querySelectorAll: () => anchors,
    querySelector: () => tv,
    getBoundingClientRect() { return this.rect; },
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
    elementFromPoint() { return this.hitTarget ?? scene; },
    createElement(tag) {
      if (tag !== "canvas") return element();
      let image;
      return {
        getContext: () => ({
          drawImage: (value) => { image = value; },
          getImageData: () => {
            if (canvasFailure && image === images[0]) throw new Error("Pixel access blocked");
            return image.pixels;
          },
        }),
      };
    },
  });
  let nextFrame = 0;
  let nextTimer = 0;
  runInNewContext(source, {
    window, document, DOMMatrix: Matrix,
    console: { warn: (...args) => warnings.push(args) },
    getComputedStyle: (node) => node.computed,
    setTimeout: (callback) => { timers.set(++nextTimer, callback); return nextTimer; },
    clearTimeout: (id) => timers.delete(id),
    requestAnimationFrame: (callback) => {
      frames.set(++nextFrame, callback);
      return nextFrame;
    },
    cancelAnimationFrame: (id) => frames.delete(id),
  });
  return {
    frames, timers, warnings, attributes: scene.attributes, styles, images, anchors, scene, tv, pause, reducedMotion, finePointer, window, document,
    ready: () => new Promise(setImmediate),
    move: (clientX = 330, clientY = 270, pointerType = "mouse") => scene.emit("pointermove", { clientX, clientY, pointerType }),
    click: (clientX = 370, clientY = 270, extra = {}) => scene.emit("click", {
      button: 0, detail: 1, clientX, clientY, target: scene, ...extra,
    }),
    expire: () => [...timers.values()].forEach((callback) => callback()),
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

test("only visible image pixels produce a bounded burst of matching emotes", async () => {
  const f = fixture();
  await f.ready();
  assert.ok(f.anchors.every((anchor) => !anchor.disabled));
  f.click(351, 251);
  assert.equal(f.scene.children.length, 0, "transparent padding must not catch");
  f.click();
  assert.equal(f.scene.children.length, 1);
  assert.equal(f.scene.children[0].children.length, 8);
  assert.ok(f.scene.children[0].children.every((particle) => particle.src === "emote-0.png"));
  assert.equal(f.anchors[0].attributes.has("data-caught"), true);
  for (let index = 0; index < 30; index++) f.click();
  assert.equal(f.scene.children.length, 1, "rapid clicks replace rather than accumulate bursts");
  assert.equal(f.timers.size, 1);
  f.expire();
  assert.equal(f.scene.children.length, 0);
  assert.equal(f.timers.size, 0);
  assert.equal(f.anchors[0].attributes.has("data-caught"), false);
});

test("hit testing combines current image and track transforms at the nudged position", async () => {
  const f = fixture();
  f.images[0].pixels.data.fill(0);
  f.images[0].pixels.data[(1 * 4 + 0) * 4 + 3] = 255;
  f.anchors[0].parentElement.computed.transform = "matrix(0,-1,1,0,20,30)";
  f.images[0].computed.transform = "matrix(-1,0,0,-1,40,10)";
  f.images[0].rect = rect(380, 250, 40, 40);
  await f.ready();
  f.click(385, 265);
  assert.equal(f.scene.children.length, 0, "untransformed coordinates must miss");
  f.click(405, 255);
  assert.equal(f.scene.children.length, 1, "a visible pixel rotated 90 degrees must hit");
});

test("object-fit letterboxing and rotated square corners are not artwork", async () => {
  const f = fixture();
  f.images[0].pixels = { width: 4, height: 2, data: new Uint8ClampedArray(32).fill(255) };
  await f.ready();
  f.click(370, 255);
  assert.equal(f.scene.children.length, 0, "space above a wide image must miss");
  f.click(370, 265);
  assert.equal(f.scene.children.length, 1);
  f.expire();
  f.images[0].computed.transform = "matrix(0.7071,0.7071,-0.7071,0.7071,0,0)";
  f.images[0].rect = rect(341.716, 241.716, 56.568, 56.568);
  f.click(342, 242);
  assert.equal(f.scene.children.length, 0, "the rotated bounding rectangle is not the image");
});

test("transparent foreground emotes let visible underlying pixels be caught, but the TV does not", async () => {
  const f = fixture();
  f.images[1].rect = f.anchors[0].rect;
  f.images[1].pixels.data.fill(0);
  await f.ready();
  f.click();
  assert.equal(f.anchors[0].attributes.has("data-caught"), true);
  f.expire();
  f.images[1].pixels.data[10 * 4 + 3] = 255;
  f.click();
  assert.equal(f.anchors[1].attributes.has("data-caught"), true);
  f.expire();
  f.document.hitTarget = { closest: () => ({}) };
  f.click();
  assert.equal(f.scene.children.length, 0, "the TV occludes emotes behind it");
  f.document.hitTarget = f.scene;
  f.tv.rect = f.anchors[0].rect;
  f.click();
  assert.equal(f.scene.children.length, 0, "a pointer-transparent TV still visually occludes emotes");
});

test("keyboard catches work without pointer coordinates; pause and reduced motion only highlight", async () => {
  for (const options of [{}, { paused: true }, { reduced: true }]) {
    const f = fixture(options);
    await f.ready();
    assert.equal(f.pause.disabled, !!options.reduced);
    f.click(0, 0, { detail: 0, target: f.anchors[0] });
    assert.equal(f.anchors[0].attributes.has("data-caught"), true);
    assert.equal(f.scene.children.length, options.paused || options.reduced ? 0 : 1);
    f.expire();
    assert.equal(f.anchors[0].attributes.has("data-caught"), false);
    f.reducedMotion.matches = !options.reduced;
    f.reducedMotion.emit("change");
    assert.equal(f.pause.disabled, !options.reduced);
  }
});

test("unreadable or failed images log a warning and never gain a rectangular fallback", async () => {
  for (const options of [{ decodeFailure: true }, { canvasFailure: true }]) {
    const f = fixture(options);
    await f.ready();
    assert.equal(f.anchors[0].disabled, true);
    assert.equal(f.anchors[0].attributes.get("aria-hidden"), "true");
    assert.equal(f.anchors[1].disabled, false);
    assert.equal(f.warnings.length, 1);
    f.click();
    assert.equal(f.scene.children.length, 0);
    assert.equal(f.timers.size, 0);
  }
});

test("lifecycle changes clear catches; pointer leave lets an already-earned burst finish", async () => {
  for (const [name, event] of [
    ["pause", "change"], ["reducedMotion", "change"], ["finePointer", "change"],
    ["window", "blur"], ["window", "resize"], ["window", "scroll"], ["document", "visibilitychange"],
  ]) {
    const f = fixture();
    await f.ready();
    f.click();
    f.scene.emit("pointerleave");
    assert.equal(f.scene.children.length, 1);
    f[name].emit(event);
    assert.equal(f.scene.children.length, 0);
    assert.equal(f.timers.size, 0);
    assert.equal(f.anchors[0].attributes.has("data-caught"), false);
  }
});

test("right clicks and hidden pages cannot catch emotes", async () => {
  const f = fixture();
  await f.ready();
  f.click(370, 270, { button: 2 });
  assert.equal(f.scene.children.length, 0);
  f.document.hidden = true;
  f.click();
  assert.equal(f.scene.children.length, 0);
});
