#!/usr/bin/env node
import assert from "node:assert/strict";
import { copyFile, cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";

const root = new URL("../", import.meta.url);
const output = new URL("build/website/", root);
const files = ["404.html", "styles.css", "orbits.js", "_headers", "robots.txt"];
const beta = JSON.parse(await readFile(new URL("website/beta.json", root), "utf8"));
assert.match(beta.testFlightUrl, /^https:\/\/testflight\.apple\.com\/join\/[A-Za-z0-9]+$/);
assert.ok(["review", "available"].includes(beta.availability), "Unknown public beta availability");
const available = beta.availability === "available";
const replacements = {
  BETA_URL: beta.testFlightUrl,
  BETA_AVAILABILITY: beta.availability,
  BETA_STATUS: available ? "The public beta is here" : "Public beta · Apple review pending",
  BETA_MESSAGE: available
    ? "Install TestFlight, accept the invitation, and enjoy Strozz."
    : "The first public builds are awaiting Apple's approval. Downloads will open here once they're approved.",
  BETA_ACTION: available ? "Download on TestFlight" : "View on TestFlight",
};
async function renderPage(file) {
  const source = await readFile(new URL(`website/${file}`, root), "utf8");
  const html = source.replace(/\{\{(\w+)\}\}/g, (_, name) => {
    assert.ok(Object.hasOwn(replacements, name), `Unknown website placeholder: ${name}`);
    return replacements[name];
  });
  assert.ok(!html.includes("{{"), "Unresolved website placeholder");
  return html;
}

const [html, privacy, credits] = await Promise.all([
  renderPage("index.html"), renderPage("privacy.html"), renderPage("credits.html"),
]);

await Promise.all([
  mkdir(new URL("privacy/", output), { recursive: true }),
  mkdir(new URL("credits/", output), { recursive: true }),
]);
await rm(new URL("emotes/", output), { recursive: true, force: true });
await Promise.all([
  writeFile(new URL("index.html", output), html),
  ...files.map((file) => copyFile(new URL(`website/${file}`, root), new URL(file, output))),
  writeFile(new URL("privacy/index.html", output), privacy),
  writeFile(new URL("credits/index.html", output), credits),
  cp(new URL("website/emotes/", root), new URL("emotes/", output), { recursive: true }),
  copyFile(new URL("Branding/strozz_logo.svg", root), new URL("strozz.svg", output)),
]);
console.log("Built the static website in build/website/");
