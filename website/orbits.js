(() => {
  const scene = document.querySelector(".orbit-scene");
  const pause = document.querySelector("#pause-orbits");
  const tv = scene.querySelector(".orbit-tv");
  const emotes = [...scene.querySelectorAll(".orbit-emote")].map((anchor) => ({
    anchor,
    image: anchor.querySelector("img"),
    restUntil: 0,
  }));
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  const finePointer = window.matchMedia("(any-hover: hover) and (any-pointer: fine)");
  pause.disabled = reducedMotion.matches;
  let pointer = null;
  let frame = null;
  let caught = null;
  let burst = null;
  let catchTimer = null;

  const clamp = (value, minimum, maximum) => Math.max(minimum, Math.min(maximum, value));

  for (const emote of emotes) {
    emote.image.decode().then(() => {
      const canvas = document.createElement("canvas");
      canvas.width = emote.image.naturalWidth;
      canvas.height = emote.image.naturalHeight;
      const context = canvas.getContext("2d");
      context.drawImage(emote.image, 0, 0);
      emote.pixels = context.getImageData(0, 0, canvas.width, canvas.height);
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
      if (!pixels || (emote === caught && burst)) continue;
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
      if (pixels.data[(pixelY * pixels.width + pixelX) * 4 + 3] > 0) return emote;
    }
    return null;
  }

  function resetNudge({ image }) {
    for (const property of ["--nudge-x", "--nudge-y", "--nudge-rotate"]) {
      image.style.removeProperty(property);
    }
  }

  function clearCatch() {
    if (catchTimer !== null) clearTimeout(catchTimer);
    catchTimer = null;
    if (caught) {
      caught.anchor.removeAttribute("data-caught");
      if (burst) {
        resetNudge(caught);
        caught.restUntil = performance.now() + 350;
        caught.anchor.removeAttribute("data-popped");
      }
    }
    caught = null;
    burst?.remove();
    burst = null;
  }

  function pop(emote) {
    clearCatch();
    caught = emote;
    emote.anchor.setAttribute("data-caught", "");
    if (!reducedMotion.matches && !pause.checked) {
      const bounds = scene.getBoundingClientRect();
      const rect = emote.image.getBoundingClientRect();
      burst = document.createElement("div");
      burst.className = "emote-burst";
      burst.setAttribute("aria-hidden", "true");
      for (let index = 0; index < 8; index++) {
        const particle = emote.image.cloneNode();
        particle.removeAttribute("style");
        particle.className = "emote-particle";
        const angle = (index + 0.5) * Math.PI / 4;
        const distance = Math.min(85, bounds.width * 0.17) * (index % 2 ? 1 : 0.7);
        particle.style.setProperty("left", `${rect.left + rect.width / 2 - bounds.left}px`);
        particle.style.setProperty("top", `${rect.top + rect.height / 2 - bounds.top}px`);
        particle.style.setProperty("--size", `${16 + index % 3 * 4}px`);
        particle.style.setProperty("--travel-x", `${Math.cos(angle) * distance}px`);
        particle.style.setProperty("--travel-y", `${Math.sin(angle) * distance}px`);
        particle.style.setProperty("--spin", `${index % 2 ? 35 : -35}deg`);
        burst.append(particle);
      }
      scene.append(burst);
      resetNudge(emote);
      emote.anchor.setAttribute("data-popped", "");
      scene.removeAttribute("data-catchable");
    }
    catchTimer = setTimeout(clearCatch, 700);
  }

  function reset() {
    pointer = null;
    if (frame !== null) cancelAnimationFrame(frame);
    frame = null;
    scene.removeAttribute("data-interacting");
    scene.removeAttribute("data-catchable");
    emotes.forEach(resetNudge);
  }

  function stop() {
    reset();
    clearCatch();
  }

  function update() {
    frame = null;
    if (!pointer) return;

    const bounds = scene.getBoundingClientRect();
    const radius = Math.min(120, bounds.width * 0.24);
    const strength = Math.min(36, bounds.width * 0.08);
    const now = performance.now();
    // Read the unnudged anchors together, before writing any image transforms.
    const offsets = emotes.map((emote, index) => {
      if ((emote === caught && burst) || now < emote.restUntil) return { x: 0, y: 0 };
      const { anchor } = emote;
      const rect = anchor.getBoundingClientRect();
      const x = rect.left + rect.width / 2;
      const y = rect.top + rect.height / 2;
      const dx = x - pointer.x;
      const dy = y - pointer.y;
      const distance = Math.hypot(dx, dy);
      const force = strength * Math.max(0, 1 - distance / radius) ** 2;
      if (force === 0) return { x: 0, y: 0 };

      const half = Math.max(rect.width, rect.height) / 2 + 8;
      return {
        x: clamp(
          (distance > 0 ? dx / distance : index % 2 === 0 ? 1 : -1) * force,
          Math.max(bounds.left, 0) + half - x,
          Math.min(bounds.right, window.innerWidth) - half - x,
        ),
        y: clamp(
          (distance > 0 ? dy / distance : 0) * force,
          bounds.top + half - y,
          bounds.bottom - half - y,
        ),
      };
    });
    scene.toggleAttribute("data-catchable", hitTest(pointer.x, pointer.y) !== null);
    offsets.forEach(({ x, y }, index) => {
      const { style } = emotes[index].image;
      style.setProperty("--nudge-x", `${x.toFixed(2)}px`);
      style.setProperty("--nudge-y", `${y.toFixed(2)}px`);
      style.setProperty("--nudge-rotate", `${(x * 0.18).toFixed(2)}deg`);
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
    if (emote?.pixels && !(emote === caught && burst)) pop(emote);
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
