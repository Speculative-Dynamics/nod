/* =====================================================================
   Nod — marketing site
   Scroll reveal, hero parallax, small polish.
   No framework, no dependencies.
   ===================================================================== */

(() => {
  const prefersReduced = window.matchMedia(
    "(prefers-reduced-motion: reduce)",
  ).matches;

  /* ------------------------------------------------------------------ *
   * 0. Match poster to viewport
   *    — the <video poster> attribute only accepts one image. Swap it
   *      so mobile viewports get the mobile poster (same framing as
   *      the mobile video source), desktop gets the desktop poster.
   *      Runs before playback so the right fallback shows immediately.
   * ------------------------------------------------------------------ */
  (() => {
    const video = document.querySelector(".hero__video");
    if (!video) return;
    const mql = window.matchMedia("(max-aspect-ratio: 1/1)");
    const sync = () => {
      const poster = mql.matches
        ? "/assets/hero/mobile.png"
        : "/assets/hero/desktop.png";
      if (video.getAttribute("poster") !== poster) {
        video.setAttribute("poster", poster);
      }
    };
    sync();
    // listen for orientation / resize changes (iPad rotation, window resize)
    if (mql.addEventListener) mql.addEventListener("change", sync);
    else mql.addListener(sync); // Safari < 14
  })();

  /* ------------------------------------------------------------------ *
   * 1. Scroll reveal via IntersectionObserver
   *    — adds .is-in to any [data-reveal] element when 12% of it is
   *      in the viewport. Unobserves after reveal.
   * ------------------------------------------------------------------ */
  const reveal = (() => {
    const els = document.querySelectorAll("[data-reveal]");
    if (!els.length) return;

    if (prefersReduced || !("IntersectionObserver" in window)) {
      els.forEach((el) => el.classList.add("is-in"));
      return;
    }

    const io = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) {
            entry.target.classList.add("is-in");
            io.unobserve(entry.target);
          }
        }
      },
      {
        threshold: 0.12,
        rootMargin: "0px 0px -8% 0px",
      },
    );

    els.forEach((el) => io.observe(el));
  })();

  /* ------------------------------------------------------------------ *
   * 2. Hero parallax
   *    — subtle vertical drift of the hero video as you scroll past it.
   *      Uses transform (cheap), rAF-throttled, respects reduced motion.
   * ------------------------------------------------------------------ */
  const parallax = (() => {
    if (prefersReduced) return;

    const video = document.querySelector(".hero__video");
    const hero = document.querySelector(".hero");
    if (!video || !hero) return;

    let ticking = false;
    let heroHeight = hero.offsetHeight;

    const update = () => {
      ticking = false;
      const y = window.scrollY;
      if (y > heroHeight) return; // past hero, skip work
      // Video drifts at ~30% of scroll speed for a subtle depth effect.
      // Extra 1.08 scale in CSS isn't applied here — the video is cover,
      // so a small translate reads as parallax without gaps.
      const t = Math.min(y * 0.3, heroHeight * 0.35);
      video.style.transform = `translate3d(0, ${t}px, 0)`;
    };

    const onScroll = () => {
      if (ticking) return;
      ticking = true;
      requestAnimationFrame(update);
    };

    const onResize = () => {
      heroHeight = hero.offsetHeight;
      update();
    };

    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("resize", onResize, { passive: true });
    update();
  })();

  /* ------------------------------------------------------------------ *
   * 3. Scroll-linked hero brightness
   *    — tiny touch: as you scroll away from the hero, darken the wash
   *      slightly so the content below gets visual focus.
   * ------------------------------------------------------------------ */
  const heroFade = (() => {
    if (prefersReduced) return;
    const wash = document.querySelector(".hero__wash");
    const hero = document.querySelector(".hero");
    if (!wash || !hero) return;

    let ticking = false;
    const update = () => {
      ticking = false;
      const h = hero.offsetHeight;
      const y = Math.max(0, Math.min(window.scrollY / h, 1));
      wash.style.opacity = `${0.9 + y * 0.4}`;
    };
    const onScroll = () => {
      if (ticking) return;
      ticking = true;
      requestAnimationFrame(update);
    };
    window.addEventListener("scroll", onScroll, { passive: true });
    update();
  })();

  /* ------------------------------------------------------------------ *
   * 4. Ensure hero video plays on iOS
   *    — some iOS Safari versions need a poke after metadata is ready,
   *      especially with multiple <source> tags.
   * ------------------------------------------------------------------ */
  (() => {
    const video = document.querySelector(".hero__video");
    if (!video) return;

    const tryPlay = () => {
      const p = video.play();
      if (p && typeof p.catch === "function") {
        p.catch(() => {
          // Autoplay blocked — fall back gracefully. The poster image
          // is already visible from the `poster` attribute.
        });
      }
    };

    if (video.readyState >= 2) tryPlay();
    else video.addEventListener("loadeddata", tryPlay, { once: true });
  })();

  /* ------------------------------------------------------------------ *
   * 5. Tiny year stamp is omitted — this is a product page, not a blog.
   *    (Placeholder comment for future extension.)
   * ------------------------------------------------------------------ */
})();
