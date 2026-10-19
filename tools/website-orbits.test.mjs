import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { runInNewContext } from "node:vm";

const source = await readFile(new URL("../website/orbits.js", import.meta.url), "utf8");
const catalog = JSON.parse(await readFile(new URL("../website/emote-catalog.json", import.meta.url), "utf8"));
const families = Object.fromEntries(Object.entries(catalog).map(([family, entries]) => [
  family, entries.map(({ name, id, src }) => ({ name, src: id ? `https://cdn.frankerfacez.com/emote/${id}/4` : src })),
]));
const artByName = new Map(Object.values(families).flat().map((art) => [art.name, art]));
const initialNames = ["Party Parrot", "peepoHappy", "OMEGALUL", "monkaS", "KEKW", "PepeHands"];

function assertUnique(f) {
  const sources = f.all().map((button) => button.querySelector("img").src);
  assert.equal(new Set(sources).size, sources.length, "active and fading artwork must all be unique");
  const names = f.all().map((button) => button.dataset.emote);
  assert.equal(new Set(names).size, names.length);
}

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
    attributes, children: [], dataset: {}, computed: { transform: "none" },
    style: {
      values,
      setProperty: (key, value) => values.set(key, value),
      getPropertyValue: (key) => values.get(key) ?? "",
      removeProperty: (key) => values.delete(key),
    },
    setAttribute: (key, value) => attributes.set(key, value),
    hasAttribute: (key) => attributes.has(key),
    removeAttribute(key) { attributes.delete(key); if (key === "style") this.style.values.clear(); },
    toggleAttribute: (key, force) => force ? attributes.set(key, "") : attributes.delete(key),
    closest: () => null,
    append(child) { this.children.push(child); child.parentElement = this; },
    remove() { this.parentElement.children = this.parentElement.children.filter((child) => child !== this); },
    ...properties,
  });
}

function fixture({ reduced = false, fine = true, paused = false, decodeFailure = false, canvasFailure = false, seed = 1 } = {}) {
  const frames = new Map();
  const animations = new Set();
  const decodes = new Map();
  const pendingLoads = [];
  const loading = { fail: false, holdFamily: null, holdAll: false };
  const warnings = [];
  const images = [];
  let buttonCount = 0;
  let document;
  function animate(keyframes, options) {
    const animation = {
      keyframes, options, onfinish: null,
      cancel: () => animations.delete(animation),
      finish: () => { animations.delete(animation); animation.onfinish?.(); },
    };
    animations.add(animation);
    return animation;
  }
  function makeButton() {
    const index = buttonCount++;
    const anchor = element({
      className: "orbit-emote", disabled: false, animate,
      rect: rect(350 + index % 8 * 30, 250 + index % 3 * 20, 40, 40),
      getBoundingClientRect() { return this.rect; },
      closest: (selector) => selector === ".orbit-emote" ? anchor : null,
      querySelector() { return this.children[0]; },
      focus: () => { document.activeElement = anchor; },
    });
    return anchor;
  }
  function makeImage(initialIndex) {
    const image = element({
      naturalWidth: 4, naturalHeight: 4, animate,
      computed: { width: "40px", height: "40px", transform: "none" },
      pixels: { width: 4, height: 4, data: new Uint8ClampedArray(64) },
      decode() {
        decodes.set(this.src, (decodes.get(this.src) ?? 0) + 1);
        if ((decodeFailure && initialIndex === 0) || (loading.fail && initialIndex === undefined)) {
          return Promise.reject(new Error("Image failed"));
        }
        if (initialIndex === undefined && (loading.holdAll || families[loading.holdFamily]?.some((art) => art.src === this.src))) {
          return new Promise((resolve) => pendingLoads.push(resolve));
        }
        return Promise.resolve();
      },
      getBoundingClientRect() { return this.rect ?? this.parentElement.rect; },
      cloneNode() {
        return Object.assign(makeImage(), {
          src: this.src, crossOrigin: this.crossOrigin, referrerPolicy: this.referrerPolicy, pixels: this.pixels,
        });
      },
    });
    for (const pixel of [5, 6, 9, 10]) image.pixels.data[pixel * 4 + 3] = 255;
    return image;
  }
  const tracks = [42, 58, 76].map((duration) => element({
    computed: { transform: "none", getPropertyValue: () => `${duration}s` },
  }));
  const anchors = initialNames.map((name, index) => {
    const anchor = makeButton();
    anchor.rect = rect(350 + index * 45, 250 + index * 15, 40, 40);
    anchor.dataset.emote = name;
    anchor.disabled = true;
    const image = makeImage(index);
    image.src = artByName.get(name).src;
    images.push(image);
    anchor.append(image);
    tracks[Math.floor(index / 2)].append(anchor);
    return anchor;
  });
  const styles = images.map((image) => image.style.values);
  const all = () => tracks.flatMap((track) => track.children);
  const active = () => all().filter((anchor) => !anchor.hasAttribute("data-retiring"));
  const status = { textContent: "" };
  const tv = { rect: rect(1000, 1000, 100, 100), getBoundingClientRect() { return this.rect; } };
  const scene = element({
    rect: rect(200, 100, 500, 400),
    querySelectorAll: (selector) => selector === ".orbit-track" ? tracks : all(),
    querySelector: (selector) => selector === ".orbit-tv" ? tv : status,
    getBoundingClientRect() { return this.rect; },
  });
  const pause = target({ checked: paused });
  const reducedMotion = target({ matches: reduced });
  const finePointer = target({ matches: fine });
  const window = target({
    innerWidth: 900,
    matchMedia: (query) => query.includes("reduced-motion") ? reducedMotion : finePointer,
  });
  document = target({
    hidden: false, activeElement: null,
    querySelector: (selector) => selector === ".orbit-scene" ? scene
      : selector === "#emote-catalog" ? { textContent: JSON.stringify(families) } : pause,
    elementFromPoint() { return this.hitTarget ?? scene; },
    createElement(tag) {
      if (tag === "button") return makeButton();
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
  let now = 1000;
  const math = Object.create(Math);
  math.random = () => { seed = (seed * 1664525 + 1013904223) >>> 0; return seed / 4294967296; };
  runInNewContext(source, {
    window, document, DOMMatrix: Matrix, Math: math, Image: function () { return makeImage(); },
    performance: { now: () => now },
    console: { warn: (...args) => warnings.push(args) },
    getComputedStyle: (node) => node.computed,
    requestAnimationFrame: (callback) => {
      frames.set(++nextFrame, callback);
      return nextFrame;
    },
    cancelAnimationFrame: (id) => frames.delete(id),
  });
  return {
    frames, animations, decodes, loading, warnings, all, active, status, tracks,
    attributes: scene.attributes, styles, images, anchors, scene, tv, pause, reducedMotion, finePointer, window, document,
    ready: () => new Promise(setImmediate),
    advance: (milliseconds) => { now += milliseconds; },
    move: (clientX = 330, clientY = 270, pointerType = "mouse") => scene.emit("pointermove", { clientX, clientY, pointerType }),
    click: (clientX = 370, clientY = 270, extra = {}) => scene.emit("click", {
      button: 0, detail: 1, clientX, clientY, target: scene, ...extra,
    }),
    finishAnimations: () => [...animations].forEach((animation) => animation.finish()),
    releaseLoads: () => { loading.holdFamily = null; loading.holdAll = false; pendingLoads.splice(0).forEach((resolve) => resolve()); },
    pop: (anchor) => scene.emit("click", { button: 0, detail: 0, target: anchor }),
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
  assert.equal(Number.parseFloat(f.styles[0].get("--nudge-x")), 10.67);
  const sidestep = Number.parseFloat(f.styles[0].get("--nudge-y"));
  assert.ok(Math.abs(sidestep) > 0 && Math.abs(sidestep) <= 7);
  assert.equal(f.styles[5].get("--nudge-x"), "0.00px");
  assert.equal(f.styles[5].get("--nudge-y"), "0.00px");
  assert.equal(f.frames.size, 1, "a stationary cursor still influences moving orbits");
  assert.equal(f.attributes.has("data-interacting"), true);
  f.advance(300);
  f.tick();
  assert.notEqual(Number.parseFloat(f.styles[0].get("--nudge-y")), sidestep, "nearby artwork keeps playfully sidestepping");
  assert.equal(f.styles[5].get("--nudge-rotate"), "0.00deg");
});

test("a cursor at an emote's exact center produces a finite bounded nudge", () => {
  const f = fixture();
  f.move(370, 270);
  f.tick();
  const x = Number.parseFloat(f.styles[0].get("--nudge-x"));
  const y = Number.parseFloat(f.styles[0].get("--nudge-y"));
  assert.equal(x, 24);
  assert.ok(Math.hypot(x, y) <= 25);
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

test("pause, lifecycle changes, and input preferences clear active interaction and catch holds", async () => {
  for (const [name, event] of [
    ["pause", "change"], ["reducedMotion", "change"], ["finePointer", "change"],
    ["window", "blur"], ["window", "resize"], ["window", "scroll"],
    ["document", "visibilitychange"], ["scene", "pointercancel"],
  ]) {
    const f = fixture();
    await f.ready();
    assertUnique(f);
    f.move(370, 270);
    f.tick();
    assert.equal(f.anchors[0].hasAttribute("data-catch-rest"), true);
    f[name].emit(event);
    assert.equal(f.frames.size, 0, `${name}:${event} cancels the frame loop`);
    assert.ok(f.styles.every((style) => style.size === 0));
    assert.equal(f.attributes.has("data-interacting"), false);
    assert.equal(f.anchors[0].hasAttribute("data-catch-rest"), false);
  }
});

test("landing on artwork holds its rendered pose for 500ms, then allows teasing before another hold", async () => {
  const f = fixture();
  await f.ready();
  const transform = "matrix(1,0,0,1,5,-2)";
  f.images[0].computed.transform = transform;
  f.move(370, 270);
  f.tick();
  assert.equal(f.anchors[0].hasAttribute("data-catch-rest"), true);
  assert.equal(f.styles[0].get("transform"), transform);
  f.advance(499);
  f.tick();
  assert.equal(f.anchors[0].hasAttribute("data-catch-rest"), true);
  f.advance(1);
  f.tick();
  assert.equal(f.anchors[0].hasAttribute("data-catch-rest"), false);
  assert.equal(f.styles[0].has("transform"), false);
  f.advance(1099);
  f.tick();
  assert.equal(f.anchors[0].hasAttribute("data-catch-rest"), false, "a stationary pointer must not freeze it permanently");
  f.advance(1);
  f.tick();
  assert.equal(f.anchors[0].hasAttribute("data-catch-rest"), true);
  f.click();
  await f.ready();
  assert.equal(f.active().length, 11, "the resting artwork is still clickable");
  assert.equal(f.anchors[0].hasAttribute("data-catch-rest"), false);
  assert.equal(f.styles[0].has("transform"), false);
});

test("transparent padding never holds an emote, and leaving visible pixels releases the hold", async () => {
  const f = fixture();
  await f.ready();
  f.move(351, 251);
  f.tick();
  assert.equal(f.anchors[0].hasAttribute("data-catch-rest"), false);
  f.move(370, 270);
  f.tick();
  assert.equal(f.anchors[0].hasAttribute("data-catch-rest"), true);
  f.move(351, 251);
  f.tick();
  assert.equal(f.anchors[0].hasAttribute("data-catch-rest"), false);
  assert.equal(f.styles[0].has("transform"), false);
});

test("catch holds wait until offspring finish their arrival flight", async () => {
  const f = fixture();
  await f.ready();
  f.pop(f.anchors[0]);
  await f.ready();
  const child = f.active().find((a) => a.hasAttribute("data-offspring"));
  f.move(child.rect.left + 20, child.rect.top + 20);
  f.tick();
  assert.equal(child.hasAttribute("data-catch-rest"), false);
  f.finishAnimations();
  f.tick();
  assert.equal(child.hasAttribute("data-catch-rest"), true);
  f.scene.emit("pointerleave");
  assert.equal(child.hasAttribute("data-catch-rest"), false);
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

test("a visible-pixel catch becomes six persistent, distinct related emotes", async () => {
  const f = fixture();
  await f.ready();
  assert.ok(f.anchors.every((anchor) => !anchor.disabled));
  f.click(351, 251);
  assert.equal(f.active().length, 6, "transparent padding must not catch");
  f.click();
  for (let index = 0; index < 30; index++) f.click();
  await f.ready();
  assert.equal(f.active().length, 11, "busy input must not multiply the same parent twice");
  assert.ok(!f.active().includes(f.anchors[0]));
  const children = f.active().filter((anchor) => anchor.hasAttribute("data-offspring"));
  const names = children.map((anchor) => anchor.dataset.emote);
  assert.equal(new Set(names).size, 6);
  assert.ok(names.every((name) => families.party.some((art) => art.name === name) && name !== "Party Parrot"));
  assert.deepEqual(f.tracks.map((track) => children.filter((child) => child.parentElement === track).length), [2, 2, 2]);
  assert.equal(f.animations.size, 6);
  f.finishAnimations();
  f.advance(10000);
  assert.equal(f.active().length, 11, "the scattered copies must not expire");
  f.pop(children[0]);
  await f.ready();
  assert.equal(f.active().length, 16, "offspring must themselves multiply");
});

test("related choices vary randomly, while decoded artwork is shared between generations", async () => {
  const selections = [];
  for (const seed of [1, 10000, 123456]) {
    const f = fixture({ seed });
    await f.ready();
    f.pop(f.anchors[2]);
    await f.ready();
    selections.push(f.active().filter((a) => a.hasAttribute("data-offspring")).map((a) => a.dataset.emote).sort().join(","));
    for (let index = 0; index < 15; index++) {
      f.pop(f.active().find((a) => a.hasAttribute("data-offspring")));
      await f.ready();
    }
    assert.ok([...f.decodes.values()].every((count) => count === 1));
    assert.ok(f.decodes.size <= artByName.size, "shared decoding stays bounded by the catalog");
  }
  assert.ok(new Set(selections).size > 1);
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
  assert.equal(f.anchors[0].hasAttribute("data-caught"), false);
  f.click(405, 255);
  assert.equal(f.anchors[0].hasAttribute("data-caught"), true);
  await f.ready();
  assert.equal(f.active().length, 11, "a visible pixel rotated 90 degrees must hit");
});

test("object-fit letterboxing and rotated square corners are not artwork", async () => {
  const f = fixture();
  f.images[0].pixels = { width: 4, height: 2, data: new Uint8ClampedArray(32).fill(255) };
  await f.ready();
  f.click(370, 255);
  assert.equal(f.anchors[0].hasAttribute("data-caught"), false, "space above a wide image must miss");
  f.images[0].computed.transform = "matrix(0.7071,0.7071,-0.7071,0.7071,0,0)";
  f.images[0].rect = rect(341.716, 241.716, 56.568, 56.568);
  f.click(342, 242);
  assert.equal(f.anchors[0].hasAttribute("data-caught"), false, "the rotated bounding rectangle is not the image");
});

test("transparent pixels let clicks through, but opaque busy art and the TV occlude them", async () => {
  const f = fixture();
  f.images[1].rect = f.anchors[0].rect;
  f.images[1].pixels.data.fill(0);
  await f.ready();
  f.images[1].pixels.data[10 * 4 + 3] = 255;
  f.loading.holdFamily = "happy";
  f.click();
  assert.equal(f.anchors[1].attributes.has("data-caught"), true);
  f.click();
  assert.equal(f.anchors[0].hasAttribute("data-caught"), false, "do not click through a visible busy emote");
  f.images[1].pixels.data.fill(0);
  f.document.hitTarget = { closest: () => ({}) };
  f.click();
  assert.equal(f.anchors[0].hasAttribute("data-caught"), false);
  f.document.hitTarget = f.scene;
  f.tv.rect = f.anchors[0].rect;
  f.click();
  assert.equal(f.anchors[0].hasAttribute("data-caught"), false);
  f.tv.rect = rect(1000, 1000, 100, 100);
  f.click();
  assert.equal(f.anchors[0].hasAttribute("data-caught"), true);
  f.releaseLoads();
  await f.ready();
});

test("keyboard focus transfers to offspring; paused and reduced-motion growth stays still", async () => {
  for (const options of [{}, { paused: true }, { reduced: true }]) {
    const f = fixture(options);
    await f.ready();
    assert.equal(f.pause.disabled, !!options.reduced);
    f.anchors[0].focus();
    f.pop(f.anchors[0]);
    await f.ready();
    assert.equal(f.active().length, 11);
    assert.equal(f.animations.size, options.paused || options.reduced ? 0 : 6);
    assert.ok(f.active().includes(f.document.activeElement));
    assert.ok(f.document.activeElement.hasAttribute("data-offspring"));
    f.reducedMotion.matches = !options.reduced;
    f.reducedMotion.emit("change");
    assert.equal(f.pause.disabled, !options.reduced);
    assert.equal(f.animations.size, 0);
    assert.equal(f.active().length, 11);
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
    await f.ready();
    assert.equal(f.active().length, 6);
  }
});

test("lifecycle changes finish travel without removing the multiplied population", async () => {
  for (const [name, event] of [
    ["pause", "change"], ["reducedMotion", "change"], ["finePointer", "change"],
    ["window", "blur"], ["window", "resize"], ["window", "scroll"], ["document", "visibilitychange"],
  ]) {
    const f = fixture();
    await f.ready();
    f.click();
    await f.ready();
    f.scene.emit("pointerleave");
    assert.equal(f.animations.size, 6);
    f[name].emit(event);
    assert.equal(f.animations.size, 0);
    assert.equal(f.active().length, 11);
  }
});

test("offspring get a settling interval and gentler pixel-accurate dodging", async () => {
  const f = fixture();
  await f.ready();
  f.pop(f.anchors[0]);
  await f.ready();
  const child = f.active().find((a) => a.hasAttribute("data-offspring"));
  const image = child.querySelector("img");
  f.move(child.rect.left + 20, child.rect.top + 20);
  f.tick();
  assert.equal(image.style.getPropertyValue("--nudge-x"), "0.00px");
  f.advance(999);
  f.tick();
  assert.equal(image.style.getPropertyValue("--nudge-x"), "0.00px");
  f.advance(1);
  f.tick();
  assert.equal(Math.abs(parseFloat(image.style.getPropertyValue("--nudge-x"))), 18);
});

test("growth recycles the oldest at 120 and also bounds fading nodes and animations", async () => {
  const f = fixture();
  await f.ready();
  f.anchors[1].focus();
  for (let index = 0; index < 70; index++) {
    const parent = f.active().find((a) => a.hasAttribute("data-offspring")) ?? f.anchors[2];
    f.pop(parent);
    await f.ready();
    assert.ok(f.active().length <= 120);
    assert.ok(f.all().length <= 126);
    assertUnique(f);
    assert.ok(f.animations.size <= 132);
  }
  assert.equal(f.active().length, 120);
  assert.ok(!f.active().includes(f.anchors[0]), "the oldest art is recycled");
  assert.ok(f.active().includes(f.anchors[1]), "do not recycle the currently keyboard-focused control");
  f.finishAnimations();
  assert.equal(f.all().length, 120);
  assert.equal(f.animations.size, 0);
});

test("failed offspring loads keep the parent, report the failure, and can be retried", async () => {
  const f = fixture();
  await f.ready();
  f.loading.fail = true;
  f.pop(f.anchors[0]);
  await f.ready();
  assert.equal(f.active().length, 6);
  assert.equal(f.anchors[0].hasAttribute("aria-busy"), false);
  assert.match(f.status.textContent, /couldn't load/);
  assert.equal(f.warnings.length, 1);
  f.loading.fail = false;
  f.pop(f.anchors[0]);
  await f.ready();
  assert.equal(f.active().length, 11);
  assert.equal(f.status.textContent, "");
});

test("late image completions cannot resurrect a parent already recycled at capacity", async () => {
  const f = fixture();
  await f.ready();
  f.loading.holdFamily = "party";
  f.pop(f.anchors[0]);
  f.loading.holdFamily = null;
  for (let index = 0; index < 26; index++) {
    f.pop(f.active().find((a) => a.hasAttribute("data-offspring")) ?? f.anchors[2]);
    await f.ready();
  }
  assert.equal(f.active().length, 120);
  assert.ok(!f.active().includes(f.anchors[0]));
  const survivors = f.active().slice();
  f.releaseLoads();
  await f.ready();
  assert.deepEqual(f.active(), survivors);
});

test("simultaneous catches reserve distinct artwork before any images finish loading", async () => {
  const f = fixture();
  await f.ready();
  f.loading.holdAll = true;
  f.pop(f.anchors[2]);
  f.pop(f.anchors[4]);
  assert.equal(f.decodes.size, 18, "the two laughing parents must reserve twelve different new images");
  assert.equal(f.active().length, 6);
  assertUnique(f);
  f.releaseLoads();
  await f.ready();
  assert.equal(f.active().length, 16);
  assertUnique(f);
});

test("available related reactions are preferred, then unused reactions from other families fill the burst", async () => {
  const f = fixture();
  await f.ready();
  const family = new Set(families.party.map((art) => art.name));
  let usedFallback = false;
  for (let index = 0; index < families.party.length; index++) {
    const before = f.all().slice();
    const names = new Set(before.map((button) => button.dataset.emote));
    const available = [...family].filter((name) => !names.has(name)).length;
    f.pop(f.active().find((button) => family.has(button.dataset.emote)));
    await f.ready();
    const children = f.active().filter((button) => !before.includes(button));
    assert.equal(children.length, 6);
    assert.equal(children.filter((button) => family.has(button.dataset.emote)).length, Math.min(6, available));
    assertUnique(f);
    if (available < 6) { usedFallback = true; break; }
  }
  assert.equal(usedFallback, true);
});

test("failed image batches release their artwork reservations so retries cannot drain the pool", async () => {
  const f = fixture();
  await f.ready();
  f.loading.fail = true;
  for (let index = 0; index < Math.ceil(artByName.size / 6) + 2; index++) {
    f.pop(f.anchors[0]);
    await f.ready();
    assert.match(f.status.textContent, /couldn't load/);
    assert.equal(f.anchors[0].hasAttribute("aria-busy"), false);
    assert.equal(f.active().length, 6);
  }
  f.loading.fail = false;
  f.pop(f.anchors[0]);
  await f.ready();
  assert.equal(f.active().length, 11);
  assertUnique(f);
});

test("a temporarily reserved pool preserves unserved parents, explains the wait, and recovers without duplicates", async () => {
  const f = fixture();
  await f.ready();
  while (f.active().length < 120) {
    f.pop(f.active().at(-1));
    await f.ready();
  }
  f.finishAnimations();
  const parents = f.active().slice();
  for (const parent of parents) f.pop(parent);
  assert.match(f.status.textContent, /More emotes are loading/);
  assert.ok(parents.some((parent) => !parent.hasAttribute("aria-busy")));
  await f.ready();
  assert.equal(f.status.textContent, "");
  assert.equal(f.active().length, 120);
  assert.ok(f.all().length <= 126);
  assertUnique(f);
  const parent = f.active().at(-1);
  f.pop(parent);
  await f.ready();
  assert.ok(!f.active().includes(parent), "released reservations must allow the next catch");
  assertUnique(f);
});

test("new inner-track art never steals pixel hits from an older outer-track emote", async () => {
  const f = fixture();
  await f.ready();
  f.pop(f.anchors[0]);
  await f.ready();
  const inner = f.tracks[0].children.find((a) => a.hasAttribute("data-offspring"));
  inner.rect = rect(250, 150, 40, 40);
  f.anchors[4].rect = inner.rect;
  f.click(270, 170);
  assert.equal(f.anchors[4].hasAttribute("aria-busy"), true);
  assert.equal(inner.hasAttribute("aria-busy"), false);
  await f.ready();
});

test("right clicks and hidden pages cannot catch emotes", async () => {
  const f = fixture();
  await f.ready();
  f.click(370, 270, { button: 2 });
  assert.equal(f.anchors[0].hasAttribute("aria-busy"), false);
  f.document.hidden = true;
  f.click();
  assert.equal(f.anchors[0].hasAttribute("aria-busy"), false);
});
