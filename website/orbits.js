(() => {
  const scene = document.querySelector(".orbit-scene");
  const pause = document.querySelector("#pause-orbits");
  const emotes = [...scene.querySelectorAll(".orbit-emote")].map((anchor) => ({
    anchor,
    image: anchor.querySelector("img"),
  }));
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  const finePointer = window.matchMedia("(any-hover: hover) and (any-pointer: fine)");
  let pointer = null;
  let frame = null;

  const clamp = (value, minimum, maximum) => Math.max(minimum, Math.min(maximum, value));

  function reset() {
    pointer = null;
    if (frame !== null) cancelAnimationFrame(frame);
    frame = null;
    scene.removeAttribute("data-interacting");
    for (const { image } of emotes) {
      for (const property of ["--nudge-x", "--nudge-y", "--nudge-rotate"]) {
        image.style.removeProperty(property);
      }
    }
  }

  function update() {
    frame = null;
    if (!pointer) return;

    const bounds = scene.getBoundingClientRect();
    const radius = Math.min(120, bounds.width * 0.24);
    const strength = Math.min(54, bounds.width * 0.12);
    // Read the unnudged anchors together, before writing any image transforms.
    const offsets = emotes.map(({ anchor }, index) => {
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
  pause.addEventListener("change", reset);
  reducedMotion.addEventListener("change", reset);
  finePointer.addEventListener("change", reset);
  window.addEventListener("blur", reset);
  window.addEventListener("resize", reset);
  window.addEventListener("scroll", reset, { passive: true });
  document.addEventListener("visibilitychange", reset);
})();
