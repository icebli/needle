const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

const repo = path.resolve(__dirname, "../..");
const installer = path.join(repo, "browser-extension", "Install Needle Companion.command");

test("companion installer registers hosts against an installed app without touching Spotify", () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "needle-companion-home-"));
  const quotedHome = path.join(home, 'home "quote" $dollar `tick`');
  const appBin = path.join(quotedHome, "Applications/Needle.app/Contents/Resources/bin");
  fs.mkdirSync(appBin, { recursive: true });
  const host = path.join(appBin, "needle-browser-host");
  fs.writeFileSync(host, "#!/bin/sh\nexit 0\n");
  fs.chmodSync(host, 0o755);
  fs.symlinkSync(process.execPath, path.join(appBin, "node"));

  execFileSync("bash", [installer], {
    cwd: repo,
    env: { ...process.env, HOME: quotedHome, NEEDLE_COMPANION_NO_OPEN: "1" },
    input: "\n",
    stdio: ["pipe", "pipe", "pipe"],
  });

  const support = path.join(quotedHome, "Library/Application Support");
  const chromeManifest = JSON.parse(fs.readFileSync(path.join(support, "Google/Chrome/NativeMessagingHosts/dev.tege.needle.browser.json"), "utf8"));
  const firefoxManifest = JSON.parse(fs.readFileSync(path.join(support, "Mozilla/NativeMessagingHosts/dev.tege.needle.browser.json"), "utf8"));
  assert.equal(chromeManifest.allowed_origins[0], "chrome-extension://oljnldpeaookagcidchhjmlkocoglhia/");
  assert.deepEqual(firefoxManifest.allowed_extensions, ["needle@tege.dev"]);
  assert.equal(fs.readFileSync(path.join(support, "Google/Chrome/NativeMessagingHosts/dev.tege.needle.browser.json"), "utf8").includes("needle-local-playlist"), false);
  const wrapper = path.join(support, "Needle/bin/needle-browser-host");
  assert.match(fs.readFileSync(wrapper, "utf8"), /Contents\/Resources\/bin/);
  execFileSync(wrapper, ["quote-safe"], { env: { ...process.env, HOME: quotedHome } });
});

test("companion package builds Firefox and Chrome payloads from source", () => {
  const output = fs.mkdtempSync(path.join(os.tmpdir(), "needle-companion-package-"));
  execFileSync("bash", [path.join(repo, "scripts/package-browser-companion.sh"), output], { cwd: repo, stdio: "pipe" });
  const listing = execFileSync("unzip", ["-Z1", path.join(output, "needle-companion.zip")], { encoding: "utf8" });
  for (const resource of [
    "Install Needle Companion.command",
    "chrome-extension/manifest.json",
    "chrome-extension/background.js",
    "chrome-extension/track-detection.js",
    "chrome-extension/icons/needle-48.png",
    "chrome-extension/icons/needle-96.png",
    "needle-firefox.xpi",
    "spicetify/needle-local-playlist.js",
  ]) {
    assert.match(listing, new RegExp(`^${resource.replace(/[.]/g, "\\.")}$`, "m"), resource);
  }
});
