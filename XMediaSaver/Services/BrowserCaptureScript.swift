import Foundation

enum BrowserCaptureScript {
    static let source = #"""
    (() => {
      if (window.__xMediaSaverCaptureInstalled) return;
      window.__xMediaSaverCaptureInstalled = true;

      const shouldCapture = (url) => {
        if (!url) return false;
        try {
          const parsed = new URL(url, window.location.href);
          const host = parsed.hostname.toLowerCase();
          const isXHost = host === 'x.com' || host.endsWith('.x.com') ||
            host === 'twitter.com' || host.endsWith('.twitter.com');
          return isXHost && parsed.pathname.includes('/graphql/') &&
            (url.includes('Bookmarks') ||
             url.includes('BookmarkFolderTimeline') ||
             url.includes('TweetDetail') ||
             url.includes('TweetResultByRestId') ||
             url.includes('TweetResultsByRestIds'));
        } catch (_) {
          return false;
        }
      };

      const send = (url, body) => {
        if (!shouldCapture(url) || typeof body !== 'string' || body.length === 0) return;
        try {
          window.webkit.messageHandlers.xMediaCapture.postMessage({ url, body });
        } catch (_) {}
      };

      const originalFetch = window.fetch;
      window.fetch = async function(...args) {
        const response = await originalFetch.apply(this, args);
        try {
          const url = response.url || String(args[0] || '');
          if (shouldCapture(url)) {
            response.clone().text().then(body => send(url, body)).catch(() => {});
          }
        } catch (_) {}
        return response;
      };

      const originalOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url, ...rest) {
        this.__xMediaSaverURL = String(url || '');
        return originalOpen.call(this, method, url, ...rest);
      };

      const originalSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function(...args) {
        if (shouldCapture(this.__xMediaSaverURL)) {
          this.addEventListener('load', () => {
            try { send(this.responseURL || this.__xMediaSaverURL, this.responseText); }
            catch (_) {}
          }, { once: true });
        }
        return originalSend.apply(this, args);
      };
    })();
    """#
}
