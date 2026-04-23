/* =====================================================================
   Nod — marketing site motion
   GSAP + ScrollTrigger for hero line reveal, showcase entrances,
   staggered children, parallax. Respects prefers-reduced-motion.
   Falls back gracefully if GSAP fails to load.
   ===================================================================== */

(() => {
  const prefersReduced = window.matchMedia(
    "(prefers-reduced-motion: reduce)"
  ).matches;

  /* ------------------------------------------------------------------
   * 0. Hero video poster-swap (mobile vs desktop)
   *    Runs synchronously before video starts so the right still is
   *    showing from the first frame.
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
    (mql.addEventListener ? mql.addEventListener : mql.addListener).call(
      mql,
      "change",
      sync
    );
  })();

  /* ------------------------------------------------------------------
   * 1. Ensure hero video autoplays on iOS Safari quirks.
   * ------------------------------------------------------------------ */
  (() => {
    const video = document.querySelector(".hero__video");
    if (!video) return;
    const tryPlay = () => {
      const p = video.play();
      if (p && typeof p.catch === "function") p.catch(() => {});
    };
    if (video.readyState >= 2) tryPlay();
    else video.addEventListener("loadeddata", tryPlay, { once: true });
  })();

  /* ------------------------------------------------------------------
   * 2. Mark <html> as JS-ready so the reveal-hidden CSS engages.
   *    If JS fails to load, content stays visible (no-JS fallback).
   * ------------------------------------------------------------------ */
  document.documentElement.classList.add("js-ready");

  /* ------------------------------------------------------------------
   * 3. Split hero title into lines for GSAP stagger.
   *    Splits on <br> and wraps each line in a mask so we can slide
   *    each line up from below with overflow clipping.
   * ------------------------------------------------------------------ */
  (() => {
    const title = document.querySelector(".hero__title");
    if (!title) return;
    const html = title.innerHTML;
    const lines = html.split(/<br\s*\/?>/i).map((l) => l.trim());
    title.innerHTML = lines
      .map(
        (line) =>
          `<span class="line-mask"><span class="line-inner">${line}</span></span>`
      )
      .join("");
  })();

  /* ------------------------------------------------------------------
   * 4. Wait for GSAP, then wire up all animations.
   *    If GSAP is unavailable (CDN blocked, offline), fall back to the
   *    old IntersectionObserver reveal so the page still decorates.
   * ------------------------------------------------------------------ */
  const runWhenReady = () => {
    const hasGSAP = window.gsap && window.ScrollTrigger;
    if (!hasGSAP) {
      fallbackReveal();
      return;
    }

    const { gsap, ScrollTrigger } = window;
    gsap.registerPlugin(ScrollTrigger);

    if (prefersReduced) {
      // Respect user preference: snap everything to final state, no animation.
      gsap.set("[data-reveal] > .container > *", { opacity: 1, y: 0 });
      gsap.set(".hero__title .line-inner", { y: 0, opacity: 1 });
      gsap.set(".hero__sub, .hero__cta", { opacity: 1, y: 0 });
      return;
    }

    /* --- Hero line reveal on page load ----------------------------- */
    gsap.set(".hero__title .line-inner", { yPercent: 110, opacity: 0 });
    gsap.set(".hero__sub", { opacity: 0, y: 16 });
    gsap.set(".hero__cta", { opacity: 0, y: 16 });

    const heroTl = gsap.timeline({ defaults: { ease: "power3.out" } });
    heroTl
      .to(".hero__title .line-inner", {
        yPercent: 0,
        opacity: 1,
        duration: 1.1,
        stagger: 0.12,
        delay: 0.15,
      })
      .to(".hero__sub", { opacity: 1, y: 0, duration: 0.8 }, "-=0.6")
      .to(".hero__cta", { opacity: 1, y: 0, duration: 0.7 }, "-=0.5");

    /* --- Hero video parallax (smooth scroll-linked) ---------------- */
    const heroVideo = document.querySelector(".hero__video");
    const hero = document.querySelector(".hero");
    if (heroVideo && hero) {
      gsap.to(heroVideo, {
        yPercent: 18,
        ease: "none",
        scrollTrigger: {
          trigger: hero,
          start: "top top",
          end: "bottom top",
          scrub: 0.6,
        },
      });
    }

    /* --- Hero wash opacity increases as you scroll past ------------ */
    const wash = document.querySelector(".hero__wash");
    if (wash && hero) {
      gsap.to(wash, {
        opacity: 1.35,
        ease: "none",
        scrollTrigger: {
          trigger: hero,
          start: "top top",
          end: "bottom top",
          scrub: true,
        },
      });
    }

    /* --- Showcase sections: stagger children in on enter ----------- */
    const showcaseSections = document.querySelectorAll(
      "[data-reveal] > .container > .showcase, [data-reveal] > .container > .screen-pair"
    );
    showcaseSections.forEach((showcase) => {
      const section = showcase.closest("[data-reveal]");
      const text = showcase.querySelector(".showcase__text");
      const screen = showcase.querySelector(
        ".showcase__screen, .screen-pair__item"
      );
      const screenPairItems = showcase.classList.contains("screen-pair")
        ? showcase.querySelectorAll(".screen-pair__item")
        : null;

      // Set initial states
      if (text) gsap.set(text.children, { opacity: 0, y: 30 });
      if (screenPairItems) {
        gsap.set(screenPairItems, { opacity: 0, y: 40, scale: 0.94 });
      } else if (screen) {
        gsap.set(screen, { opacity: 0, y: 40, scale: 0.94 });
      }

      const tl = gsap.timeline({
        scrollTrigger: {
          trigger: section,
          start: "top 78%",
          toggleActions: "play none none none",
        },
        defaults: { ease: "power3.out" },
      });

      if (text) {
        tl.to(text.children, {
          opacity: 1,
          y: 0,
          duration: 0.9,
          stagger: 0.09,
        });
      }

      if (screenPairItems) {
        tl.to(
          screenPairItems,
          {
            opacity: 1,
            y: 0,
            scale: 1,
            duration: 1,
            stagger: 0.18,
          },
          "-=0.7"
        );
      } else if (screen) {
        tl.to(
          screen,
          { opacity: 1, y: 0, scale: 1, duration: 1 },
          "-=0.7"
        );
      }

      section.classList.add("is-in"); // compat marker
    });

    /* --- Non-showcase data-reveal sections (facts, source, download,
           footer): simple staggered children reveal --------------- */
    const plainReveals = document.querySelectorAll("[data-reveal]");
    plainReveals.forEach((section) => {
      if (section.querySelector(".showcase, .screen-pair")) return;
      const kids = section.querySelectorAll(
        ".container > *, .container > .container > *"
      );
      if (!kids.length) return;
      gsap.set(kids, { opacity: 0, y: 24 });
      gsap.to(kids, {
        opacity: 1,
        y: 0,
        duration: 0.8,
        stagger: 0.07,
        ease: "power3.out",
        scrollTrigger: {
          trigger: section,
          start: "top 78%",
          toggleActions: "play none none none",
          onEnter: () => section.classList.add("is-in"),
        },
      });
    });

    /* --- Phone subtle hover lift on pointer (desktop only) --------- */
    if (window.matchMedia("(hover: hover)").matches) {
      document.querySelectorAll(".screen-frame").forEach((frame) => {
        frame.addEventListener("mouseenter", () => {
          gsap.to(frame, {
            y: -6,
            duration: 0.5,
            ease: "power2.out",
          });
        });
        frame.addEventListener("mouseleave", () => {
          gsap.to(frame, { y: 0, duration: 0.5, ease: "power2.out" });
        });
      });
    }
  };

  /* ------------------------------------------------------------------
   * 5. Fallback (no GSAP): simple IntersectionObserver reveal.
   * ------------------------------------------------------------------ */
  const fallbackReveal = () => {
    const els = document.querySelectorAll("[data-reveal]");
    if (!("IntersectionObserver" in window)) {
      els.forEach((el) => el.classList.add("is-in"));
      return;
    }
    const io = new IntersectionObserver(
      (entries) => {
        for (const e of entries) {
          if (e.isIntersecting) {
            e.target.classList.add("is-in");
            io.unobserve(e.target);
          }
        }
      },
      { threshold: 0.12, rootMargin: "0px 0px -8% 0px" }
    );
    els.forEach((el) => io.observe(el));
    // Hero: just show the title/sub/cta
    const heroLines = document.querySelectorAll(
      ".hero__title .line-inner"
    );
    heroLines.forEach((l) => (l.style.transform = "none"));
    document
      .querySelectorAll(".hero__title, .hero__sub, .hero__cta")
      .forEach((el) => (el.style.opacity = "1"));
  };

  /* ------------------------------------------------------------------
   * 6. Script tags with defer load in DOM order; GSAP arrives before
   *    this runs. But be defensive: if GSAP hasn't initialized yet,
   *    wait one tick and retry.
   * ------------------------------------------------------------------ */
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () =>
      setTimeout(runWhenReady, 0)
    );
  } else {
    setTimeout(runWhenReady, 0);
  }
})();
