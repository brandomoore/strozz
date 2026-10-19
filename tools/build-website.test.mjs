import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { cp, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
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

test("the orbital hero uses recognizable chat emotes with restricted delivery and motion controls", async (t) => {
  const root = await fixture(t, "available");
  await execute(process.execPath, [join(root, "tools/build-website.mjs")]);
  const output = join(root, "build/website");
  const html = await readFile(join(output, "index.html"), "utf8");
  assert.equal([...html.matchAll(/class="orbit-track /g)].length, 3);
  assert.match(html, /<input class="orbit-pause" type="checkbox" id="pause-orbits" aria-label="Pause emote animation">/);
  assert.match(html, /<label class="orbit-tv" for="pause-orbits"/);
  assert.doesNotMatch(html, /class="orbit-control"/);
  assert.doesNotMatch(html, /class="orbit-art" aria-hidden="true"/);
  assert.equal([...html.matchAll(/class="orbit-track [^"]+" aria-hidden="true"/g)].length, 3);
  assert.match(html, /class="tv-screen" aria-hidden="true"/);
  assert.doesNotMatch(html, /blob-(?:cool|laugh|think|owo|cry)/);
  assert.match(html, /<script src="\/orbits\.js" defer><\/script>/);
  assert.equal([...html.matchAll(/<script\b/g)].length, 2);
  const embeddedCatalog = html.match(/<script id="emote-catalog" type="application\/json">([^<]+)<\/script>/)?.[1];
  assert.ok(embeddedCatalog);
  const families = JSON.parse(embeddedCatalog);
  assert.equal(Object.keys(families).length, 5);
  assert.ok(Object.values(families).flat().length >= 132);
  const sources = Object.values(families).flat().map((art) => art.src);
  assert.equal(new Set(sources).size, sources.length);
  assert.equal(await readFile(join(output, "orbits.js"), "utf8"), await readFile(join(root, "website/orbits.js"), "utf8"));
  const emotes = [...html.matchAll(/<button class="orbit-emote" data-emote="([^"]+)" type="button" aria-label="Pop [^"]+" disabled(?: data-opposite)?><img src="([^"]+)"([^>]*)>/g)];
  assert.equal(emotes.length, 6);
  const expected = {
    "Party Parrot": "/emotes/party-parrot.svg",
    peepoHappy: "https://cdn.frankerfacez.com/emote/228449/4",
    OMEGALUL: "https://cdn.frankerfacez.com/emote/128054/4",
    monkaS: "https://cdn.frankerfacez.com/emote/130762/4",
    KEKW: "https://cdn.frankerfacez.com/emote/381875/4",
    PepeHands: "https://cdn.frankerfacez.com/emote/231552/4",
  };
  assert.deepEqual(Object.fromEntries(emotes.map(([, name, url]) => [name, url])), expected);
  for (const [, name, url, attributes] of emotes) {
    assert.match(attributes, /width="48" height="48" alt=""/);
    if (name !== "Party Parrot") {
      assert.match(attributes, /crossorigin="anonymous" referrerpolicy="no-referrer"/);
      assert.equal(new URL(url).hostname, "cdn.frankerfacez.com");
    }
  }
  const parrot = await readFile(join(output, expected["Party Parrot"]), "utf8");
  assert.doesNotMatch(parrot, /<script|<animate|<set\b|<image|(?:xlink:)?href=["']https?:/i);
  assert.equal(parrot, await readFile(join(root, "website", expected["Party Parrot"]), "utf8"));
  const headers = await readFile(join(output, "_headers"), "utf8");
  assert.match(headers, /default-src 'none'; style-src 'self'; img-src 'self' https:\/\/cdn\.frankerfacez\.com;/);
  assert.match(headers, /script-src 'self';/);
  assert.doesNotMatch(headers, /unsafe-inline|unsafe-eval/);
  const css = await readFile(join(output, "styles.css"), "utf8");
  assert.match(css, /transition: transform 320ms ease-out/);
  assert.match(css, /\.orbit-emote\[data-offspring\] \{ width: clamp\(28px, 3\.2vw, 38px\); height: clamp\(28px, 3\.2vw, 38px\);/);
  assert.match(css, /\.orbit-emote\[data-catch-rest\] \{ animation-play-state: paused; \}/);
  assert.match(css, /\.orbit-scene\[data-interacting\] \.orbit-emote\[data-catch-rest\] img \{ transition: none; \}/);
  assert.match(css, /\.orbit-emote\[data-opposite\] \{ animation-delay: var\(--opposite-delay\); \}/);
  assert.doesNotMatch(css, /\.orbit-emote:nth-child|emote-burst|data-popped/);
  assert.match(css, /\.orbit-emote\s*\{[^}]*animation-play-state: paused;/);
  assert.match(css, /@media \(prefers-reduced-motion: no-preference\)\s*\{\s*\.orbit-emote \{ animation-play-state: running; \}/);
  assert.match(css, /\.orbit-pause:checked ~ \.orbit-art \.orbit-emote \{ animation-play-state: paused; \}/);
  assert.match(css, /\.orbit-pause:focus-visible ~ \.orbit-art \.orbit-tv \{ outline:/);
  const credits = await readFile(join(output, "credits/index.html"), "utf8");
  assert.match(credits, /John Hobbs/);
  assert.match(credits, /creativecommons\.org\/licenses\/by-sa\/4\.0/);
  assert.ok(credits.includes(`data-beta-link href="${publicInvite}"`));
  assert.doesNotMatch(credits, /\{\{/);
  for (const [name, url] of Object.entries(expected)) {
    if (name === "Party Parrot") continue;
    const id = new URL(url).pathname.split("/")[2];
    assert.ok(credits.includes(`https://www.frankerfacez.com/emoticon/${id}-${name}`));
  }
  for (const family of Object.values(families)) {
    for (const art of family) {
      if (art.name === "Party Parrot") continue;
      assert.match(art.src, /^https:\/\/cdn\.frankerfacez\.com\/emote\/[0-9]+\/4$/);
      const id = new URL(art.src).pathname.split("/")[2];
      assert.ok(credits.includes(`https://www.frankerfacez.com/emoticon/${id}-${art.name}`));
    }
  }
  assert.doesNotMatch(credits, /Blobmoji|Blob OwO|No emote-provider requests/);
  const privacy = await readFile(join(output, "privacy/index.html"), "utf8");
  assert.match(privacy, /cdn\.frankerfacez\.com/);
  assert.match(privacy, /omit cookies and the referring page URL/);
});

test("rebuilding removes retired local emotes from the deployed assets", async (t) => {
  const root = await fixture(t, "available");
  const emotes = join(root, "build/website/emotes");
  await mkdir(emotes, { recursive: true });
  await writeFile(join(emotes, "blob-cool.svg"), "<svg/>");
  await writeFile(join(emotes, "LICENSE-Blobmoji.txt"), "Retired license");
  await execute(process.execPath, [join(root, "tools/build-website.mjs")]);
  assert.deepEqual(await readdir(emotes), ["party-parrot.svg"]);
});

test("download URLs must be actual HTTPS TestFlight invitations", async (t) => {
  const root = await fixture(t, "available", "https://example.com/not-testflight");
  await assert.rejects(execute(process.execPath, [join(root, "tools/build-website.mjs")]), /AssertionError/);
});

test("catalog validation rejects incomplete families and initial emotes missing from the pool", async (t) => {
  const root = await fixture(t, "available");
  const file = join(root, "website/emote-catalog.json");
  const catalog = JSON.parse(await readFile(file, "utf8"));
  catalog.party = catalog.party.slice(0, 2);
  await writeFile(file, JSON.stringify(catalog));
  await assert.rejects(execute(process.execPath, [join(root, "tools/build-website.mjs")]), /needs at least seven/);
  await writeFile(file, "{}");
  await assert.rejects(execute(process.execPath, [join(root, "tools/build-website.mjs")]), /Initial emote missing/);
});

test("catalog credits escape submitter text instead of inserting active HTML", async (t) => {
  const root = await fixture(t, "available");
  const file = join(root, "website/emote-catalog.json");
  const catalog = JSON.parse(await readFile(file, "utf8"));
  catalog.happy[0].submitter = "<script>alert('unsafe')</script>";
  await writeFile(file, JSON.stringify(catalog));
  await execute(process.execPath, [join(root, "tools/build-website.mjs")]);
  const credits = await readFile(join(root, "build/website/credits/index.html"), "utf8");
  assert.match(credits, /&lt;script&gt;alert\(&#39;unsafe&#39;\)&lt;\/script&gt;/);
  assert.doesNotMatch(credits, /<script>/);
});

test("catalogs cannot alias artwork or run out of unique reactions at capacity", async (t) => {
  const root = await fixture(t, "available");
  const file = join(root, "website/emote-catalog.json");
  const catalog = JSON.parse(await readFile(file, "utf8"));
  const duplicate = structuredClone(catalog);
  duplicate.happy[1].id = duplicate.happy[0].id;
  await writeFile(file, JSON.stringify(duplicate));
  await assert.rejects(execute(process.execPath, [join(root, "tools/build-website.mjs")]), /Duplicate emote artwork/);
  const small = Object.fromEntries(Object.entries(catalog).map(([family, entries]) => [family, entries.slice(0, 8)]));
  await writeFile(file, JSON.stringify(small));
  await assert.rejects(execute(process.execPath, [join(root, "tools/build-website.mjs")]), /120 active reactions/);
});
