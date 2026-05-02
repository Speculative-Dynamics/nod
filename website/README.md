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

## Deployment checklist

- Keep `sitemap.xml`, canonical links, Open Graph image URLs, and `CNAME`
  aligned to `https://usenod.app`.
- Validate `manifest.webmanifest` and `script.js` before publishing.
- App Store listing: <https://apps.apple.com/in/app/just-nod/id6762388689>
  (update the link in `index.html` if the storefront URL ever changes).

## License

The website code shares the repo's MIT license.
