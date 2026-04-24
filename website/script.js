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

    /* --- HERO STAGE: pinned scroll transition --------------------------
       The fullscreen hero video morphs via clip-path down to the phone's
       screen area. Simultaneously the hero intro fades out, the phone
       bezel + screenshot fade in, and the Section 01 outro copy fades
       in beside the phone. The whole thing is one continuous opening. */
    const heroStage = document.querySelector(".hero--stage");
    const heroBackdrop = document.querySelector(".hero__backdrop");
    const heroVideoWrap = document.querySelector(".hero--stage .hero__video-wrap");
    const heroIntro = document.querySelector(".hero--stage .hero__content");
    const heroPhoneStage = document.querySelector(".hero__phone-stage");
    const heroPhoneBezel = document.querySelector(".hero__phone-bezel");
    const heroScreens = document.querySelectorAll(".hero__screen");
    const heroChapters = document.querySelectorAll(".hero__chapter");
    const heroProps = document.querySelectorAll(".hero__prop");
    const heroScrollHint = document.querySelector(".hero--stage .hero__scroll");

    // Only run pinned transition on viewports where the phone stage fits
    // (wide enough for two columns). Mobile gets a plain hero.
    const canPin = heroStage && heroPhoneStage &&
      window.matchMedia("(min-aspect-ratio: 1/1) and (min-width: 901px)").matches;

    if (canPin) {
      // 7 chapters stacked on top of each other. Phase 0 = the hero-to-phone
      // transition AND the first chapter (Listening) ramping in. Phase N =
      // crossfade from chapter N-1 to chapter N.
      const TOTAL_CHAPTERS = 7;
      const PIN_SPAN = 8400; // px of scroll (~9.3vh) — 1200px per chapter

      // Initial state
      gsap.set(heroPhoneBezel, { opacity: 0 });
      gsap.set(heroScreens, { opacity: 0 });
      gsap.set(heroChapters, { opacity: 0, y: 20 });
      gsap.set(heroProps, { opacity: 0 });

      // Compute the clip-path inset that matches the phone-stage rect.
      // Recomputed on resize so the morph always lands accurately.
      const computeTargets = () => {
        const rect = heroPhoneStage.getBoundingClientRect();
        const hostRect = heroStage.getBoundingClientRect();
        return {
          clip: {
            top: rect.top - hostRect.top,
            right: hostRect.right - rect.right,
            bottom: hostRect.bottom - rect.bottom,
            left: rect.left - hostRect.left,
            radius: Math.max(24, Math.min(48, rect.width * 0.15)),
          },
        };
      };

      let target = computeTargets();
      window.addEventListener("resize", () => {
        target = computeTargets();
      });

      // Reset clip-path to "no clip" initially
      heroVideoWrap.style.clipPath = "inset(0px 0px 0px 0px round 0px)";

      // Tent weight function — returns 0..1 based on how close `cp` is to
      // `peak`. Used for cross-fading chapters, screens, and props.
      const tentWeight = (cp, peak) => Math.max(0, 1 - Math.abs(cp - peak));

      ScrollTrigger.create({
        trigger: heroStage,
        start: "top top",
        end: `+=${PIN_SPAN}`,
        pin: true,
        pinSpacing: true,
        scrub: 1,
        // Snap to each chapter peak + the initial hero state. 8 snap
        // points total (p = 0, 1/7, 2/7, ..., 1). After the user stops
        // scrolling, the stage gently lands on the nearest peak so each
        // chapter is held fully visible, not floated past.
        snap: {
          snapTo: 1 / TOTAL_CHAPTERS,
          duration: { min: 0.25, max: 0.6 },
          ease: "power2.inOut",
          delay: 0.05,
        },
        onUpdate: (self) => {
          const p = self.progress;
          // chapterPosition ranges 0..TOTAL_CHAPTERS. Phase 0 = 0..1 (hero
          // transition). Chapter i peaks at cp = i + 1.
          const cp = p * TOTAL_CHAPTERS;
          const phase0 = Math.min(1, cp); // 0..1 during the hero transition

          const tc = target.clip;

          // 1) Clip-path: morph video from full-bleed to phone screen
          //    during phase 0. After phase 0, holds at phone shape.
          heroVideoWrap.style.clipPath =
            `inset(${tc.top * phase0}px ${tc.right * phase0}px ${tc.bottom * phase0}px ${tc.left * phase0}px round ${tc.radius * phase0}px)`;

          // 2) Backdrop: darkens/de-saturates slightly across the pin so
          //    each chapter feels like a different "room" in the same mood.
          if (heroBackdrop) {
            const bd = Math.max(0.35, 1 - p * 0.5);
            heroBackdrop.style.filter =
              `brightness(${0.9 * bd}) saturate(${1.08 * bd})`;
            heroBackdrop.style.opacity = String(0.45 + bd * 0.55);
          }

          // 3) Hero intro: fades out as phase 0 progresses
          const introOut = Math.min(1, phase0 * 2);
          heroIntro.style.opacity = String(1 - introOut);
          heroIntro.style.transform = `translateY(${-40 * introOut}px)`;

          if (heroScrollHint) {
            heroScrollHint.style.opacity = String(Math.max(0, 1 - phase0 * 3));
          }

          // 4) Phone bezel: fades in as the video arrives
          const bezelIn = Math.max(0, Math.min(1, (phase0 - 0.35) / 0.5));
          heroPhoneBezel.style.opacity = String(bezelIn);

          // 5) Screens: each screen peaks at cp = (i + 1). Screen 0 has a
          //    special early delay so the video-to-phone transition reads
          //    as "video → empty screen" cleanly, not a half-visible cross-fade.
          heroScreens.forEach((screen, i) => {
            const peak = i + 1;
            let w = tentWeight(cp, peak);
            if (i === 0 && phase0 < 0.8) {
              w = 0; // hidden during the morph
            } else if (i === 0 && phase0 < 1) {
              w = Math.min(w, (phase0 - 0.8) / 0.2);
            }
            screen.style.opacity = String(w);
          });

          // 6) Chapter text: peaks at cp = (i + 1), cross-fades across
          heroChapters.forEach((chapter, i) => {
            const peak = i + 1;
            const w = tentWeight(cp, peak);
            chapter.style.opacity = String(w);
            // Subtle vertical drift so inactive chapters don't feel frozen
            const drift = (cp - peak) * 16; // px
            chapter.style.transform = `translateY(calc(-50% + ${drift}px))`;
          });

          // 7) Props: stacked identically. Each prop's data-chapter maps
          //    to the chapter it supports (chapter 1 = offline pill, etc.).
          //    Chapter 0 (Listening) has no prop by design.
          heroProps.forEach((prop) => {
            const chapterIdx = Number(prop.dataset.chapter);
            const peak = chapterIdx + 1;
            const w = tentWeight(cp, peak);
            prop.style.opacity = String(w);
          });
        },
      });
    } else if (heroStage) {
      // Mobile / short viewport: skip the pin transition entirely.
      // The mobile layout is driven by CSS — each chapter renders
      // as a regular stacked section with its own inline phone image.
      heroVideoWrap.style.clipPath = "inset(0px 0px 0px 0px round 0px)";
      heroStage.classList.add("hero--mobile");
    }

    /* --- Post-stage data-reveal sections (proof, source, download,
       footer): stagger their container children in on enter. The
       pinned stage handles its own reveal; everything below uses this
       simpler pattern. */
    document.querySelectorAll("[data-reveal]").forEach((section) => {
      const kids = section.querySelectorAll(
        ".container > *, .container > .container > *, .proof__container > *"
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
