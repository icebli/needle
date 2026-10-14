// Firefox exposes the WebExtension API as `browser`; Chrome exposes the same
// promise-based API as `chrome`. Keeping this alias in the shared UI/content
// scripts lets the two companion packages use the same implementation.
globalThis.browser ||= globalThis.chrome;
