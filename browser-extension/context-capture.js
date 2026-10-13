(function captureNeedleContext() {
  "use strict";

  document.addEventListener("contextmenu", (event) => {
    const target = event.target instanceof Element ? event.target : null;
    const anchor = target?.closest("a[href]");
    if (!anchor) return;
    const card = anchor.closest(
      "ytd-rich-item-renderer, ytd-video-renderer, ytd-compact-video-renderer, ytd-grid-video-renderer, .soundList__item, .sound__body",
    );
    const artistHint = card?.querySelector(
      "ytd-channel-name a, #channel-name a, .ytd-channel-name, .soundTitle__username",
    )?.textContent || "";
    const linkText =
      anchor.getAttribute("title") ||
      card?.querySelector("#video-title, .soundTitle__title")?.textContent ||
      anchor.textContent ||
      "";

    browser.runtime.sendMessage({
      type: "contextSnapshot",
      snapshot: {
        url: anchor.href,
        linkText: linkText.replace(/\s+/g, " ").trim(),
        artistHint: artistHint.replace(/\s+/g, " ").trim(),
      },
    }).catch(() => {});
  }, true);
})();
