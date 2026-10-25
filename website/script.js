/* =====================================================================
   Nod — marketing site motion
   GSAP + ScrollTrigger for the pinned hero stage, showcase entrances,
   staggered children, parallax. Respects prefers-reduced-motion.
   Falls back gracefully if GSAP fails to load.
   ===================================================================== */

(() => {
  const prefersReduced = window.matchMedia(
    "(prefers-reduced-motion: reduce)"
  ).matches;

  /* ------------------------------------------------------------------
   * 0. Hero asset selection (poster + source) is now done INLINE in <head>
   *    via window.__heroAssets, BEFORE the <video> element parses. See
   *    index.html. That's the only correct moment to decide which mp4 +
   *    still to use, because the previous deferred poster-swap pattern
   *    raced with the browser's <source media> selection and caused a
   *    visible mis-crop on cold mobile loads (desktop poster rendered
   *    inside a portrait container with object-fit:cover, cropping the
   *    boy + tree out of frame until the script swap landed).
   *
   *    Leaving this comment as a breadcrumb so future-us doesn't
   *    re-introduce a deferred swap here.
   * ------------------------------------------------------------------ */

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
   * 3. The hero intro (title lines, subline, App Store button) is plain
   *    CSS now, with the line masks in the markup, so it starts on first
   *    paint instead of waiting for GSAP. See "HERO INTRO" in extra.css.
   * ------------------------------------------------------------------ */

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
      return;
    }

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
      // Scroll distance per chapter, as a share of the viewport height.
      // Short enough that a couple of wheel notches or one trackpad swipe
      // moves to the next chapter.
      const STEP_VH = 0.75;
      const pinSpan = () =>
        Math.round(window.innerHeight * STEP_VH * TOTAL_CHAPTERS);

      // Initial state
      gsap.set(heroPhoneBezel, { opacity: 0 });
      gsap.set(heroScreens, { opacity: 0 });
      gsap.set(heroChapters, { opacity: 0, y: 20 });
      gsap.set(heroProps, { opacity: 0 });

      // Compute the clip-path inset that matches the phone-stage rect.
      // Recomputed on refresh so the morph always lands accurately.
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

      // Reset clip-path to "no clip" initially
      heroVideoWrap.style.clipPath = "inset(0px 0px 0px 0px round 0px)";

      // Plateau weight: 1 while `cp` is within `hold` of `peak`, then
      // fades to 0 over `fade`. The hold means each chapter sits still and
      // fully visible across a band of scroll, so landing a little early
      // or late still shows a clean state instead of a half cross-fade.
      // Text fades out completely before the next chapter fades in
      // (hold + fade = 0.5); screens and props overlap so the phone
      // never flashes empty.
      const plateau = (cp, peak, hold, fade) => {
        const d = Math.abs(cp - peak);
        if (d <= hold) return 1;
        return Math.max(0, 1 - (d - hold) / fade);
      };
      const textWeight = (cp, peak) => plateau(cp, peak, 0.22, 0.28);
      const screenWeight = (cp, peak) => plateau(cp, peak, 0.22, 0.56);

      // Chapter dots: show where you are and jump straight to any chapter.
      // Built here so they only exist where the pinned stage runs.
      const chapterNames = Array.from(heroChapters).map((chapter) => {
        const eyebrow = chapter.querySelector(".cinema__eyebrow");
        const text = eyebrow ? eyebrow.textContent : "";
        return text.split("·").pop().trim();
      });
      const dotsNav = document.createElement("nav");
      dotsNav.className = "hero__dots";
      dotsNav.setAttribute("aria-label", "Chapters");
      const dots = chapterNames.map((name, i) => {
        const dot = document.createElement("button");
        dot.type = "button";
        dot.className = "hero__dot";
        dot.setAttribute("aria-label", name || `Chapter ${i + 1}`);
        dot.title = name;
        dot.addEventListener("click", () => goToChapter(i));
        dotsNav.appendChild(dot);
        return dot;
      });
      heroStage.appendChild(dotsNav);

      let activeDot = -1;
      const setActiveDot = (i) => {
        if (i === activeDot) return;
        activeDot = i;
        dots.forEach((dot, j) => {
          dot.classList.toggle("is-active", j === i);
          if (j === i) dot.setAttribute("aria-current", "step");
          else dot.removeAttribute("aria-current");
        });
      };

      const stageTrigger = ScrollTrigger.create({
        trigger: heroStage,
        start: "top top",
        end: () => `+=${pinSpan()}`,
        pin: true,
        pinSpacing: true,
        invalidateOnRefresh: true,
        onRefresh: () => {
          target = computeTargets();
        },
        // Snap to the hero state and each chapter peak (p = 0, 1/7, ...,
        // 1). Directional, so a small nudge moves on to the next chapter
        // rather than sliding back to the one you were leaving.
        snap: {
          snapTo: Array.from(
            { length: TOTAL_CHAPTERS + 1 },
            (_, i) => i / TOTAL_CHAPTERS
          ),
          directional: true,
          duration: { min: 0.2, max: 0.45 },
          ease: "power2.out",
          delay: 0.12,
          inertia: false,
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
          // Keep the faded-out intro (and its App Store button) from
          // catching clicks meant for the chapters behind it.
          heroIntro.style.pointerEvents = introOut > 0.5 ? "none" : "";

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
            let w = screenWeight(cp, peak);
            if (i === 0 && phase0 < 0.8) {
              w = 0; // hidden during the morph
            } else if (i === 0 && phase0 < 1) {
              w = Math.min(w, (phase0 - 0.8) / 0.2);
            }
            screen.style.opacity = String(w);
          });

          // 6) Chapter text: holds around cp = (i + 1), hands off cleanly
          heroChapters.forEach((chapter, i) => {
            const peak = i + 1;
            const w = textWeight(cp, peak);
            chapter.style.opacity = String(w);
            // Subtle vertical drift while fading, still at the hold
            const d = cp - peak;
            const drift = Math.sign(d) * Math.max(0, Math.abs(d) - 0.22) * 40;
            chapter.style.transform = `translateY(calc(-50% + ${drift}px))`;
          });

          // 7) Props: stacked identically. Each prop's data-chapter maps
          //    to the chapter it supports (chapter 1 = offline pill, etc.).
          //    Chapter 0 (Listening) has no prop by design.
          heroProps.forEach((prop) => {
            const chapterIdx = Number(prop.dataset.chapter);
            const peak = chapterIdx + 1;
            const w = textWeight(cp, peak);
            prop.style.opacity = String(w);
          });

          // 8) Dots: appear once the phone has settled, track the chapter
          dotsNav.classList.toggle("is-visible", cp > 0.6 && p < 1);
          setActiveDot(
            Math.min(TOTAL_CHAPTERS - 1, Math.max(0, Math.round(cp) - 1))
          );
        },
      });

      // Scroll position where chapter i is fully shown.
      const chapterScrollY = (i) =>
        stageTrigger.start +
        ((i + 1) / TOTAL_CHAPTERS) * (stageTrigger.end - stageTrigger.start);

      function goToChapter(i, behavior = "smooth") {
        window.scrollTo({ top: chapterScrollY(i), behavior });
      }

      // Deep links (#memory, #voice, ...) land on that chapter's peak
      // instead of wherever its stacked element happens to sit.
      const chapterIndexForHash = () => {
        const id = decodeURIComponent(window.location.hash.slice(1));
        if (!id) return -1;
        return Array.from(heroChapters).findIndex((c) => c.id === id);
      };
      const jumpToHash = () => {
        const i = chapterIndexForHash();
        if (i >= 0) goToChapter(i, "auto");
      };
      window.addEventListener("hashchange", jumpToHash);
      const onLoaded = () => {
        ScrollTrigger.refresh();
        jumpToHash();
      };
      if (document.readyState === "complete") onLoaded();
      else window.addEventListener("load", onLoaded, { once: true });
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
