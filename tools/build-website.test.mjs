import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import test from "node:test";

const execute = promisify(execFile);
const repo = new URL("../", import.meta.url);
const publicInvite = "https://testflight.apple.com/join/36mzCevV";

async function fixture(t, availability, testFlightUrl = publicInvite) {
  const root = await mkdtemp(join(tmpdir(), "strozz-website-test-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  await mkdir(join(root, "tools"));
  await mkdir(join(root, "Branding"));
  await Promise.all([
    cp(new URL("website/", repo), join(root, "website"), { recursive: true }),
    cp(new URL("tools/build-website.mjs", repo), join(root, "tools/build-website.mjs")),
    cp(new URL("Branding/strozz_logo.svg", repo), join(root, "Branding/strozz_logo.svg")),
  ]);
  await writeFile(join(root, "website/beta.json"), JSON.stringify({ availability, testFlightUrl }));
  return root;
}

test("pending review never promises an available download", async (t) => {
  const root = await fixture(t, "review");
  await execute(process.execPath, [join(root, "tools/build-website.mjs")]);
  const html = await readFile(join(root, "build/website/index.html"), "utf8");
  assert.match(html, /Public beta · Apple review pending/);
  assert.match(html, /View on TestFlight/);
  assert.ok(html.includes(publicInvite));
  assert.doesNotMatch(html, /Download on TestFlight|Build instructions|Get Strozz on GitHub|\{\{/);
  assert.equal(
    await readFile(join(root, "build/website/strozz.svg"), "utf8"),
    await readFile(new URL("Branding/strozz_logo.svg", repo), "utf8"),
  );
  assert.match(await readFile(join(root, "build/website/privacy/index.html"), "utf8"), /Privacy — Strozz/);
});

test("approved availability leads to the actual public TestFlight invite", async (t) => {
  const root = await fixture(t, "available");
  await execute(process.execPath, [join(root, "tools/build-website.mjs")]);
  const html = await readFile(join(root, "build/website/index.html"), "utf8");
  assert.match(html, /Download on TestFlight/);
  assert.match(html, /The public beta is here/);
  assert.ok(html.includes(`href="${publicInvite}"`));
  assert.doesNotMatch(html, /Apple review pending|Once the beta is available|awaiting Apple's approval|\{\{/);
  const hero = html.match(/<section class="hero wrap"[\s\S]*?<\/section>/)?.[0];
  assert.ok(hero, "The homepage has a hero");
  assert.ok(
    hero.includes(`<a class="button" data-beta-link href="${publicInvite}">Download on TestFlight</a>`),
    "The hero must open TestFlight directly, not scroll to another download button",
  );
  assert.deepEqual(
    [...html.matchAll(/data-beta-link href="([^"]+)"/g)].map((match) => match[1]),
    [publicInvite, publicInvite, publicInvite],
  );
  assert.doesNotMatch(html, /href="#download"/);
  const privacy = await readFile(join(root, "build/website/privacy/index.html"), "utf8");
  assert.ok(privacy.includes(`data-beta-link href="${publicInvite}"`));
  assert.doesNotMatch(privacy, /href="\/#download"|\{\{/);
});

test("unknown availability fails instead of claiming a successful rollout", async (t) => {
  const root = await fixture(t, "unknown");
  await assert.rejects(execute(process.execPath, [join(root, "tools/build-website.mjs")]), /Unknown public beta availability/);
});

test("the orbital hero ships static local artwork, credits, and motion controls", async (t) => {
  const root = await fixture(t, "available");
  await execute(process.execPath, [join(root, "tools/build-website.mjs")]);
  const output = join(root, "build/website");
  const html = await readFile(join(output, "index.html"), "utf8");
  assert.equal([...html.matchAll(/class="orbit-track /g)].length, 3);
  assert.match(html, /<input class="orbit-pause" type="checkbox" id="pause-orbits">/);
  assert.match(html, /<label class="orbit-control" for="pause-orbits">Pause emote animation<\/label>/);
  assert.match(html, /class="orbit-art" aria-hidden="true"/);
  assert.doesNotMatch(html, /<script|<img[^>]+src="https?:/);
  const emotes = [...html.matchAll(/<img src="(\/emotes\/[^"]+\.svg)" width="48" height="48" alt="">/g)];
  assert.equal(emotes.length, 6);
  assert.equal(new Set(emotes.map((match) => match[1])).size, 6);
  for (const [, path] of emotes) {
    const svg = await readFile(join(output, path), "utf8");
    assert.match(svg, /<svg/);
    assert.doesNotMatch(svg, /<script|<animate|<set\b|<image|(?:xlink:)?href=["']https?:/i);
    assert.equal(svg, await readFile(join(root, "website", path), "utf8"));
  }
  const css = await readFile(join(output, "styles.css"), "utf8");
  assert.match(css, /\.orbit-emote\s*\{[^}]*animation-play-state: paused;/);
  assert.match(css, /@media \(prefers-reduced-motion: no-preference\)\s*\{\s*\.orbit-emote \{ animation-play-state: running; \}/);
  assert.match(css, /\.orbit-pause:checked ~ \.orbit-art \.orbit-emote \{ animation-play-state: paused; \}/);
  const credits = await readFile(join(output, "credits/index.html"), "utf8");
  assert.match(credits, /John Hobbs|Blobmoji/);
  assert.match(credits, /creativecommons\.org\/licenses\/by-sa\/4\.0/);
  assert.ok(credits.includes(`data-beta-link href="${publicInvite}"`));
  assert.doesNotMatch(credits, /\{\{/);
  for (const license of ["LICENSE-BlobEmoji.txt", "LICENSE-Blobmoji.txt"]) {
    assert.match(await readFile(join(output, "emotes", license), "utf8"), /Apache License/);
  }
});

test("download URLs must be actual HTTPS TestFlight invitations", async (t) => {
  const root = await fixture(t, "available", "https://example.com/not-testflight");
  await assert.rejects(execute(process.execPath, [join(root, "tools/build-website.mjs")]), /AssertionError/);
});
