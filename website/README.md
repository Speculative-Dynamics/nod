# Nod — website (usenod.app)

Marketing and landing page for the Nod iOS app. Domain: [usenod.app](https://usenod.app).

## Status

Live static site in this directory. It is intentionally plain HTML, CSS, and a
small amount of vanilla JavaScript so it can be deployed without a build step.

## Shape

The homepage is a single-page marketing site, with separate static legal pages:

- `index.html`
- `privacy/index.html`
- `terms/index.html`

Hosting can be any static host. The current domain target is
[usenod.app](https://usenod.app).

## Assets

Everything is served from this directory, with no third-party requests:

- `assets/fonts/`: Fraunces, Inter and JetBrains Mono (latin and latin-ext
  subsets, woff2) with their OFL licences. The `@font-face` rules are at the
  top of `styles.css`.
- `assets/vendor/`: GSAP and ScrollTrigger 3.12.5.
- Images ship as AVIF with the original PNG/JPEG as fallback. After changing
  a screenshot or the hero painting, regenerate its AVIF with macOS's `sips`:

  ```bash
  sips -s format avif -s formatOptions 70 assets/screens/chat.jpg --out assets/screens/chat.avif
  ```

## Deployment checklist

- Keep `sitemap.xml`, canonical links, Open Graph image URLs, and `CNAME`
  aligned to `https://usenod.app`.
- Validate `manifest.webmanifest` and `script.js` before publishing.
- App Store listing: <https://apps.apple.com/app/just-nod/id6762388689>
  (update the link in `index.html` if the storefront URL ever changes).

## License

The website code shares the repo's MIT license.
