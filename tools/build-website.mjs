#!/usr/bin/env node
import { copyFile, mkdir } from "node:fs/promises";

const root = new URL("../", import.meta.url);
const output = new URL("build/website/", root);
const files = ["index.html", "404.html", "styles.css", "_headers", "robots.txt"];

await mkdir(output, { recursive: true });
await Promise.all([
  ...files.map((file) => copyFile(new URL(`website/${file}`, root), new URL(file, output))),
  copyFile(new URL("Branding/strozz_logo.svg", root), new URL("strozz.svg", output)),
]);
console.log("Built the static website in build/website/");
