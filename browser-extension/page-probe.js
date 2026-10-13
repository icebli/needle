(function probeNeedleTrack() {
  "use strict";

  function meta(selector) {
    return document.querySelector(selector)?.content || "";
  }

  const jsonLd = [];
  for (const node of document.querySelectorAll('script[type="application/ld+json"]')) {
    try {
      jsonLd.push(JSON.parse(node.textContent));
    } catch (_) {}
  }

  const channel =
    document.querySelector("ytd-channel-name a, #channel-name a, .soundTitle__username")?.textContent ||
    meta('meta[name="author"]') ||
    "";

  return globalThis.NeedleTrackDetection.detectTrack({
    url: location.href,
    pageTitle: document.title,
    ogTitle: meta('meta[property="og:title"]') || meta('meta[name="twitter:title"]'),
    siteName: meta('meta[property="og:site_name"]'),
    channel,
    jsonLd,
  });
})();
