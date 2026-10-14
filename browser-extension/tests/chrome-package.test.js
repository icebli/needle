const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const root = path.resolve(__dirname, "..");
const manifest = JSON.parse(fs.readFileSync(path.join(root, "chrome", "manifest.json"), "utf8"));

test("Chrome companion is an MV3 unpacked extension with a stable native host id", () => {
  assert.equal(manifest.manifest_version, 3);
  assert.equal(manifest.background.service_worker, "background.js");
  assert.ok(manifest.permissions.includes("scripting"));
  assert.match(manifest.key, /^[A-Za-z0-9+/]+=*$/);
  assert.deepEqual(manifest.content_scripts[0].js.slice(0, 2), ["browser-compat.js", "context-capture.js"]);
  assert.match(fs.readFileSync(path.join(root, "chrome", "background.js"), "utf8"), /importScripts\("track-detection\.js"\)/);
  for (const resource of ["background.js", "track-detection.js", "browser-compat.js", "popup.html"]) {
    assert.equal(fs.existsSync(path.join(root, "chrome", resource)) || fs.existsSync(path.join(root, resource)), true, resource);
  }
  for (const resource of ["needle-48.png", "needle-96.png"]) {
    assert.equal(fs.existsSync(path.join(root, "icons", resource)), true, resource);
  }
});

test("Chrome native host allows the extension id declared by the package", () => {
  const template = JSON.parse(fs.readFileSync(path.resolve(root, "../native-host/dev.tege.needle.browser.chrome.json.in"), "utf8"));
  assert.deepEqual(template.allowed_origins, ["chrome-extension://oljnldpeaookagcidchhjmlkocoglhia/"]);
  assert.equal(template.type, "stdio");
});

test("shared popup and content scripts load the Chrome compatibility alias", () => {
  assert.match(fs.readFileSync(path.join(root, "popup.html"), "utf8"), /browser-compat\.js/);
  assert.match(fs.readFileSync(path.join(root, "browser-compat.js"), "utf8"), /globalThis\.browser/);
});

test("Chrome service worker keeps the callback channel open for async messages", async () => {
  let listener;
  const chrome = {
    contextMenus: {
      removeAll: () => Promise.resolve(),
      create: () => {},
      onClicked: { addListener: () => {} },
    },
    runtime: {
      onInstalled: { addListener: () => {} },
      onStartup: { addListener: () => {} },
      onMessage: { addListener: (callback) => { listener = callback; } },
      getURL: (value) => `chrome-extension://test/${value}`,
      sendNativeMessage: () => {},
      lastError: undefined,
    },
    storage: { local: { get: () => Promise.resolve({}), set: () => Promise.resolve() } },
    notifications: { create: () => Promise.resolve() },
    scripting: { executeScript: () => Promise.resolve([{ result: {} }]) },
    tabs: { onRemoved: { addListener: () => {} } },
  };
  vm.runInNewContext(fs.readFileSync(path.join(root, "chrome", "background.js"), "utf8"), {
    chrome,
    console,
    globalThis,
    importScripts: () => {},
  });
  let response;
  const keepsChannelOpen = listener({ type: "download", track: {} }, {}, (value) => { response = value; });
  assert.equal(keepsChannelOpen, true);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(response.ok, false);
  assert.match(response.message, /artist and title/);
});
