#!/usr/bin/env node
import assert from "node:assert/strict";
import { copyFile, cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";

const root = new URL("../", import.meta.url);
const output = new URL("build/website/", root);
const files = ["404.html", "styles.css", "orbits.js", "_headers", "robots.txt"];
const beta = JSON.parse(await readFile(new URL("website/beta.json", root), "utf8"));
const catalog = JSON.parse(await readFile(new URL("website/emote-catalog.json", root), "utf8"));
const names = new Set();
for (const [family, entries] of Object.entries(catalog)) {
  assert.match(family, /^[a-z]+$/);
  assert.ok(Array.isArray(entries) && entries.length >= 7, `Emote family ${family} needs at least seven reactions`);
  for (const entry of entries) {
    assert.match(entry.name, /^[A-Za-z0-9 ]+$/);
    assert.ok(!names.has(entry.name), `Duplicate emote: ${entry.name}`);
    names.add(entry.name);
    if (entry.id !== undefined) {
      assert.ok(Number.isSafeInteger(entry.id) && entry.id > 0);
      assert.ok(typeof entry.submitter === "string" && entry.submitter.length > 0);
      assert.equal(entry.src, undefined);
    } else {
      assert.equal(entry.name, "Party Parrot");
      assert.equal(entry.src, "/emotes/party-parrot.svg");
    }
  }
}
const escapeHTML = (text) => text.replace(/[&<>"']/g, (character) => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
})[character]);
const runtimeCatalog = Object.fromEntries(Object.entries(catalog).map(([family, entries]) => [
  family, entries.map(({ name, id, src }) => ({
    name, src: id ? `https://cdn.frankerfacez.com/emote/${id}/4` : src,
  })),
]));
assert.match(beta.testFlightUrl, /^https:\/\/testflight\.apple\.com\/join\/[A-Za-z0-9]+$/);
assert.ok(["review", "available"].includes(beta.availability), "Unknown public beta availability");
const available = beta.availability === "available";
const replacements = {
  EMOTE_CATALOG: JSON.stringify(runtimeCatalog).replaceAll("<", "\\u003c"),
  EMOTE_CREDITS: Object.entries(catalog).map(([family, entries]) =>
    `<h3>${escapeHTML(family[0].toUpperCase() + family.slice(1))}</h3><p>${entries.filter((entry) => entry.id).map((entry) =>
      `<a href="https://www.frankerfacez.com/emoticon/${entry.id}-${encodeURIComponent(entry.name)}">${escapeHTML(entry.name)} — ${escapeHTML(entry.submitter)}</a>`,
    ).join(", ")}.</p>`,
  ).join("\n"),
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
for (const [, name] of html.matchAll(/class="orbit-emote" data-emote="([^"]+)"/g)) {
  assert.ok(names.has(name), `Initial emote missing from catalog: ${name}`);
}

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
