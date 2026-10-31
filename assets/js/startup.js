(() => {
        // Resolve the device here so iOS receives one unconditional launch image.
        const anchor = document.currentScript;
        const candidates = [...document.querySelectorAll('link[rel="apple-touch-startup-image"]')]
          .map(link => ({link, query: window.matchMedia(link.media)}));
        const select = () => {
          const selected = candidates.find(candidate => candidate.query.matches);
          if (!selected) return;
          for (const {link} of candidates) {
            if (link !== selected.link) link.remove();
          }
          selected.link.removeAttribute("media");
          anchor.before(selected.link);
        };
        select();
        for (const {query} of candidates) query.addEventListener("change", select);
      })();
