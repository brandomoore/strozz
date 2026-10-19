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
});

test("unknown availability fails instead of claiming a successful rollout", async (t) => {
  const root = await fixture(t, "unknown");
  await assert.rejects(execute(process.execPath, [join(root, "tools/build-website.mjs")]), /Unknown public beta availability/);
});

test("download URLs must be actual HTTPS TestFlight invitations", async (t) => {
  const root = await fixture(t, "available", "https://example.com/not-testflight");
  await assert.rejects(execute(process.execPath, [join(root, "tools/build-website.mjs")]), /AssertionError/);
});
