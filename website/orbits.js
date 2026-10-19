(() => {
  const scene = document.querySelector(".orbit-scene");
  const pause = document.querySelector("#pause-orbits");
  const tv = scene.querySelector(".orbit-tv");
  const status = scene.querySelector(".orbit-status");
  const tracks = [...scene.querySelectorAll(".orbit-track")];
  const families = Object.fromEntries(Object.entries(
    JSON.parse(document.querySelector("#emote-catalog").textContent),
  ).map(([family, entries]) => [family, entries.map((entry) => ({ ...entry, family }))]));
  const catalog = new Map(Object.values(families).flat().map((art) => [art.name, art]));
  const loaded = new Map();
  const reserved = new Set();
  const retiring = new Set();
  const populationLimit = 120;
  const childrenPerCatch = 6;
  const loadingMessage = "More emotes are loading. Try again in a moment.";
  let nextOrder = 0;
  const emotes = [...scene.querySelectorAll(".orbit-emote")].map((anchor) =>
    record(anchor, catalog.get(anchor.dataset.emote)));
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  const finePointer = window.matchMedia("(any-hover: hover) and (any-pointer: fine)");
  pause.disabled = reducedMotion.matches;
  let pointer = null;
  let frame = null;
  let held = null;

  const clamp = (value, minimum, maximum) => Math.max(minimum, Math.min(maximum, value));

  function record(anchor, art) {
    return {
      anchor, art, image: anchor.querySelector("img"), track: tracks.indexOf(anchor.parentElement),
      order: nextOrder++, active: true, busy: false, pixels: null, arrival: null, fade: null,
      restUntil: 0, nextHoldAt: 0,
    };
  }

  function loadArt(art, image) {
    if (loaded.has(art.src)) return loaded.get(art.src);
    if (!image) {
      image = new Image();
      image.crossOrigin = "anonymous";
      image.referrerPolicy = "no-referrer";
      image.src = art.src;
    }
    const ready = image.decode().then(() => {
      const canvas = document.createElement("canvas");
      canvas.width = image.naturalWidth;
      canvas.height = image.naturalHeight;
      const context = canvas.getContext("2d");
      context.drawImage(image, 0, 0);
      return { image, pixels: context.getImageData(0, 0, canvas.width, canvas.height) };
    }).catch((error) => {
      loaded.delete(art.src);
      throw error;
    });
    loaded.set(art.src, ready);
    return ready;
  }

  for (const emote of emotes) {
    loadArt(emote.art, emote.image).then(({ pixels }) => {
      emote.pixels = pixels;
      emote.anchor.disabled = false;
      emote.anchor.parentElement.removeAttribute("aria-hidden");
    }).catch((error) => {
      emote.anchor.setAttribute("aria-hidden", "true");
      console.warn(`Emote catching unavailable for ${emote.anchor.dataset.emote}:`, error);
    });
  }

  function hitTest(x, y) {
    const screen = tv.getBoundingClientRect();
    if (x >= screen.left && x < screen.right && y >= screen.top && y < screen.bottom) return null;
    if (document.elementFromPoint(x, y)?.closest(".orbit-tv")) return null;
    // Later tracks paint above earlier ones. Transparent pixels let clicks through.
    for (const emote of [...emotes].reverse()) {
      const { image, anchor, pixels } = emote;
      if (!pixels) continue;
      const rect = image.getBoundingClientRect();
      if (x < rect.left || x >= rect.right || y < rect.top || y >= rect.bottom) continue;
      const style = getComputedStyle(image);
      const width = Number.parseFloat(style.width);
      const height = Number.parseFloat(style.height);
      const matrix = new DOMMatrix(getComputedStyle(anchor.parentElement).transform)
        .multiply(new DOMMatrix(style.transform));
      const determinant = matrix.a * matrix.d - matrix.b * matrix.c;
      const dx = x - rect.left - rect.width / 2;
      const dy = y - rect.top - rect.height / 2;
      // Use the currently rendered transform, including in-flight nudge transitions.
      const localX = (matrix.d * dx - matrix.c * dy) / determinant + width / 2;
      const localY = (matrix.a * dy - matrix.b * dx) / determinant + height / 2;
      const scale = Math.min(width / pixels.width, height / pixels.height);
      const pixelX = Math.floor((localX - (width - pixels.width * scale) / 2) / scale);
      const pixelY = Math.floor((localY - (height - pixels.height * scale) / 2) / scale);
      if (pixelX < 0 || pixelX >= pixels.width || pixelY < 0 || pixelY >= pixels.height) continue;
      if (pixels.data[(pixelY * pixels.width + pixelX) * 4 + 3] > 0) return emote.busy ? null : emote;
    }
    return null;
  }

  function resetNudge({ image }) {
    for (const property of ["--nudge-x", "--nudge-y", "--nudge-rotate"]) {
      image.style.removeProperty(property);
    }
  }

  function releaseHold() {
    if (!held) return;
    held.emote.anchor.removeAttribute("data-catch-rest");
    held.emote.image.style.removeProperty("transform");
    held = null;
  }

  function discard(emote) {
    if (held?.emote === emote) releaseHold();
    const index = emotes.indexOf(emote);
    if (index !== -1) emotes.splice(index, 1);
    emote.active = false;
    emote.arrival?.cancel();
    emote.fade?.cancel();
    retiring.delete(emote);
    emote.anchor.remove();
  }

  function canAnimate() {
    return !reducedMotion.matches && !pause.checked && !document.hidden;
  }

  function recycleOldest() {
    while (emotes.length > populationLimit) {
      const oldest = emotes.filter((emote) => emote.anchor !== document.activeElement)
        .reduce((a, b) => a.order < b.order ? a : b);
      if (!canAnimate()) {
        discard(oldest);
        continue;
      }
      // Bound fading nodes too, even when catches arrive faster than fades finish.
      if (retiring.size >= childrenPerCatch) discard(retiring.values().next().value);
      emotes.splice(emotes.indexOf(oldest), 1);
      oldest.active = false;
      oldest.anchor.disabled = true;
      oldest.anchor.setAttribute("aria-hidden", "true");
      oldest.anchor.setAttribute("data-retiring", "");
      retiring.add(oldest);
      oldest.fade = oldest.anchor.animate([{ opacity: 1 }, { opacity: 0 }], {
        duration: 220, easing: "ease-out",
      });
      oldest.fade.onfinish = () => discard(oldest);
    }
  }

  function relatedArt(art) {
    const unavailable = new Set([...emotes, ...retiring].map((emote) => emote.art.src));
    for (const src of reserved) unavailable.add(src);
    const related = [];
    const other = [];
    for (const candidate of catalog.values()) {
      if (!unavailable.has(candidate.src)) {
        (candidate.family === art.family ? related : other).push(candidate);
      }
    }
    for (const pool of [related, other]) {
      for (let index = pool.length - 1; index > 0; index--) {
        const next = Math.floor(Math.random() * (index + 1));
        [pool[index], pool[next]] = [pool[next], pool[index]];
      }
    }
    return [...related, ...other].slice(0, childrenPerCatch);
  }

  function addChild(art, asset, trackIndex, phase) {
    const anchor = document.createElement("button");
    anchor.className = "orbit-emote";
    anchor.type = "button";
    anchor.dataset.emote = art.name;
    anchor.setAttribute("aria-label", `Pop ${art.name}`);
    anchor.setAttribute("data-offspring", "");
    const duration = Number.parseFloat(getComputedStyle(tracks[trackIndex]).getPropertyValue("--duration"));
    anchor.style.setProperty("animation-delay", `${-duration * phase}s`);
    const image = asset.image.cloneNode();
    image.removeAttribute("style");
    image.alt = "";
    image.width = image.height = 48;
    anchor.append(image);
    tracks[trackIndex].append(anchor);
    tracks[trackIndex].removeAttribute("aria-hidden");
    const child = record(anchor, art);
    child.pixels = asset.pixels;
    child.restUntil = performance.now() + 1000;
    emotes.push(child);
    return child;
  }

  async function pop(emote) {
    const choices = relatedArt(emote.art);
    if (choices.length < childrenPerCatch) {
      status.textContent = loadingMessage;
      return;
    }
    emote.busy = true;
    emote.anchor.setAttribute("data-caught", "");
    emote.anchor.setAttribute("aria-busy", "true");
    status.textContent = "";
    // Reserve before awaiting images so simultaneous catches cannot pick duplicates.
    for (const art of choices) reserved.add(art.src);
    let assets;
    try {
      assets = await Promise.all(choices.map((art) => loadArt(art)));
    } catch (error) {
      console.warn(`Could not multiply ${emote.art.name}:`, error);
      if (emote.active) {
        emote.busy = false;
        emote.anchor.removeAttribute("data-caught");
        emote.anchor.removeAttribute("aria-busy");
        status.textContent = "Emotes couldn't load. Try again.";
      }
      return;
    } finally {
      for (const art of choices) reserved.delete(art.src);
      if (reserved.size === 0 && status.textContent === loadingMessage) status.textContent = "";
    }
    if (!emote.active) return;
    const origin = emote.image.getBoundingClientRect();
    const transferFocus = document.activeElement === emote.anchor;
    const phase = Math.random();
    const children = choices.map((art, index) =>
      addChild(art, assets[index], (emote.track + index) % tracks.length, (phase + index / choices.length) % 1));
    // Read destinations together before animating; their orbit clocks keep running.
    const destinations = children.map(({ image }) => image.getBoundingClientRect());
    if (canAnimate()) {
      children.forEach((child, index) => {
        const destination = destinations[index];
        const x = origin.left + origin.width / 2 - destination.left - destination.width / 2;
        const y = origin.top + origin.height / 2 - destination.top - destination.height / 2;
        const base = getComputedStyle(child.image).transform;
        child.arrival = child.image.animate([
          { transform: `${base} translate(${x}px, ${y}px) scale(0.65)` },
          { transform: base },
        ], { duration: 650, easing: "cubic-bezier(0.16, 1, 0.3, 1)" });
        child.arrival.onfinish = () => { child.arrival = null; };
      });
    }
    discard(emote);
    emotes.sort((a, b) => a.track - b.track || a.order - b.order);
    if (transferFocus) children[0].anchor.focus({ preventScroll: true });
    recycleOldest();
    scene.removeAttribute("data-catchable");
  }

  function reset() {
    releaseHold();
    pointer = null;
    if (frame !== null) cancelAnimationFrame(frame);
    frame = null;
    scene.removeAttribute("data-interacting");
    scene.removeAttribute("data-catchable");
    emotes.forEach(resetNudge);
  }

  function stop() {
    reset();
    for (const emote of emotes) {
      emote.arrival?.cancel();
      emote.arrival = null;
    }
    for (const emote of retiring) discard(emote);
  }

  function update() {
    frame = null;
    if (!pointer) return;

    const bounds = scene.getBoundingClientRect();
    const radius = Math.min(120, bounds.width * 0.24);
    const strength = Math.min(24, bounds.width * 0.055);
    const now = performance.now();
    const target = hitTest(pointer.x, pointer.y);
    if (held && (held.emote !== target || now >= held.until)) releaseHold();
    if (!held && target && !target.arrival && now >= target.nextHoldAt) {
      // Preserve the rendered pose, not the destination of an unfinished nudge.
      const transform = getComputedStyle(target.image).transform;
      target.anchor.setAttribute("data-catch-rest", "");
      target.image.style.setProperty("transform", transform);
      target.nextHoldAt = now + 1600;
      held = { emote: target, until: now + 500 };
    }
    // Read the unnudged anchors together, before writing any image transforms.
    const offsets = emotes.map((emote) => {
      if (emote.busy || held?.emote === emote) return null;
      if (now < emote.restUntil) return { x: 0, y: 0 };
      const { anchor } = emote;
      const rect = anchor.getBoundingClientRect();
      const x = rect.left + rect.width / 2;
      const y = rect.top + rect.height / 2;
      const dx = x - pointer.x;
      const dy = y - pointer.y;
      const distance = Math.hypot(dx, dy);
      const sizeFactor = anchor.hasAttribute("data-offspring") ? 0.75 : 1;
      const proximity = Math.max(0, 1 - distance / radius);
      const force = strength * sizeFactor * proximity ** 2;
      if (force === 0) return { x: 0, y: 0 };

      const wave = Math.sin(now / 180 + emote.order * 1.8) * sizeFactor * proximity;
      const sidestep = wave * 7;
      const directionX = distance > 0 ? dx / distance : emote.order % 2 === 0 ? 1 : -1;
      const directionY = distance > 0 ? dy / distance : 0;
      const half = Math.max(rect.width, rect.height) / 2 + 8;
      return {
        x: clamp(
          directionX * force - directionY * sidestep,
          Math.max(bounds.left, 0) + half - x,
          Math.min(bounds.right, window.innerWidth) - half - x,
        ),
        y: clamp(
          directionY * force + directionX * sidestep,
          bounds.top + half - y,
          bounds.bottom - half - y,
        ),
        tilt: wave * 8,
      };
    });
    scene.toggleAttribute("data-catchable", target !== null);
    offsets.forEach((offset, index) => {
      if (!offset) return;
      const { x, y, tilt = 0 } = offset;
      const { style } = emotes[index].image;
      style.setProperty("--nudge-x", `${x.toFixed(2)}px`);
      style.setProperty("--nudge-y", `${y.toFixed(2)}px`);
      style.setProperty("--nudge-rotate", `${(x * 0.18 + tilt).toFixed(2)}deg`);
    });
    frame = requestAnimationFrame(update);
  }

  scene.addEventListener("pointermove", (event) => {
    if (event.pointerType !== "mouse" || reducedMotion.matches || !finePointer.matches || pause.checked || document.hidden) return;
    pointer = { x: event.clientX, y: event.clientY };
    scene.setAttribute("data-interacting", "");
    if (frame === null) frame = requestAnimationFrame(update);
  }, { passive: true });
  scene.addEventListener("pointerleave", reset);
  scene.addEventListener("pointercancel", reset);
  scene.addEventListener("click", (event) => {
    if (event.button !== 0 || document.hidden) return;
    const emote = event.detail === 0
      ? emotes.find(({ anchor }) => anchor === event.target.closest(".orbit-emote"))
      : hitTest(event.clientX, event.clientY);
    if (emote?.pixels && !emote.busy) void pop(emote);
  });
  scene.addEventListener("focusin", (event) => {
    if (event.target.closest(".orbit-emote")) reset();
  });
  pause.addEventListener("change", stop);
  reducedMotion.addEventListener("change", () => {
    pause.disabled = reducedMotion.matches;
    stop();
  });
  finePointer.addEventListener("change", stop);
  window.addEventListener("blur", stop);
  window.addEventListener("resize", stop);
  window.addEventListener("scroll", stop, { passive: true });
  document.addEventListener("visibilitychange", stop);
})();
