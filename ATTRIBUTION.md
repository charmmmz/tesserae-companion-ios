# Attribution and project identity

Tesserae Companion is the official native iOS app for
[Tesserae](https://github.com/dmellok/tesserae). The iOS source, signing, and
App Store operations remain maintained in this separate public repository and
the current iOS maintainer's Apple Developer account.

Tesserae server source is copyright its contributors and distributed under
the GNU Affero General Public License v3.0 or later. This repository does not
redistribute or link Tesserae server source; it communicates with a separately
running server through the proposed Companion HTTP API.

Tesserae's maintainer initially granted permission on 2026-07-28 to use the
Tesserae name and mark for **Tesserae Companion** in this repository and on
the App Store. The original permission and its terms are recorded publicly in
[Discussion #147](https://github.com/dmellok/tesserae/discussions/147#discussioncomment-17810183).

On 2026-07-31, Tesserae's maintainer invited the project to become the
official iOS app, and the iOS maintainer accepted. That designation supersedes
only the original requirement to describe the app as community-built and
never official. The remaining name-and-mark terms continue unchanged.

The app must therefore:

- include no third-party advertising SDKs;
- send no analytics or telemetry off the device without explicit opt-in;
- never sell or share user data; and
- never paywall functionality that the Tesserae web UI provides for free.

The maintainer expressed a preference for a free app but separately permitted
a paid app, one-time unlock, tip jar, or sponsorship, provided the companion
maintainer gives notice before choosing a monetization model. If the binding
brand terms above are broken, permission to use the Tesserae name and mark
lapses and the app must be renamed. Official status does not transfer the iOS
repository, Apple account, signing credentials, or publishing access to the
server maintainer; those operational responsibilities require a separate
documented handover.

If maintenance stops, the iOS app maintainer will give advance public
notice and first seek to transfer the repository and App Store listing to a
mutually acceptable successor. If no responsible successor is available, new
distribution will stop rather than leave an unmaintained listing in place;
the final source and release will remain available where practical.

Tesserae Companion is distributed under the Apache License 2.0. See
[`LICENSE`](LICENSE) and [`NOTICE`](NOTICE). That licence covers this
repository's original code and documentation; it does not grant rights to
Tesserae names, logos, or other marks.

The App Icon and Onboarding cover use Tesserae's official Paper-era
tessellated mark, introduced in
[Tesserae 0.448.0](https://github.com/dmellok/tesserae/commit/719a7604b44279fc8d31b9b090ccd115a3d3c42d).
The source snapshot for this update is
[`e52177f3`](https://github.com/dmellok/tesserae/tree/e52177f335bd47b8e77080d7af06e43a2a482ef2):

- `static/brand/icon.svg` supplies the Onboarding asset, with its geometry
  and ink/red/paper colours preserved. A thin edge is added by the
  native view in dark appearance for visibility.
- `static/brand/square.svg` supplies `Design/AppIconSource.svg`, with only
  the intrinsic export size increased to 1024 px. The opaque PNG export
  allows iOS to apply its platform mask without transparent pixels.
- `static/style/paper-tokens.css` supplies the light/dark brand and semantic
  palette documented in `DESIGN.md`. Native typography and interactions
  remain supplied by iOS.

## Phosphor Icons

Dashboard icons are rendered with
[Phosphor Icons for Web](https://github.com/phosphor-icons/web), version 2.1.2.
Phosphor is copyright Phosphor Icons and contributors and is distributed
under the MIT License. The app vendors only the regular TTF and a compact
identifier-to-glyph map, rather than all six Swift asset-catalog weights. The
font is used only for Dashboard imagery selected by the Tesserae server;
native app controls continue to use Apple SF Symbols. The complete licence
text is in `ThirdPartyNotices/Phosphor.txt`.

## Compatible-hardware marks

The app bundles manufacturer marks sourced from official artwork or the
documented icon collection below solely to
identify compatible hardware in the user's own Tesserae device list. Each name
and mark remains the property of its respective owner and is not covered by
this repository's Apache-2.0 licence. Their presence does not imply sponsorship
or endorsement of Tesserae Companion.

The first five bundled source files below were retrieved from the owners'
current official sites on 2026-07-29; later additions include their retrieval
date:

- Seeed Studio colour and white wordmarks; the white wordmark is rendered with
  the official Seeed Green sampled from the colour asset in dark appearance:
  [official branding-kit archive](https://files.seeedstudio.com/wiki/Seeed_Studio_LOGO.zip)
- Pimoroni charcoal wordmark, retrieved 2026-08-15 from the inline SVG in the
  official shop header and rendered as an adaptive monochrome template:
  [official shop](https://shop.pimoroni.com/)
- TRMNL black glyph:
  [official Framework asset](https://trmnl.com/assets/trmnl--glyph-black-4ca602fd.svg)
- Waveshare colour wordmark source; Displays isolates its leading glyph and
  preserves its official green treatment:
  [official store header asset](https://www.waveshare.com/media/eternal/venedor/default/logo.png)
- PicPak red wordmark:
  [official shop header asset](https://cdn.shopify.com/s/files/1/0674/8569/6246/files/Vector.svg?v=1774110422)
- Xteink black-and-orange wordmark, retrieved 2026-08-01:
  [official shop header asset](https://www.xteink.com/cdn/shop/files/logo_pc.png?v=1784536352&width=760)
- M5Stack horizontal colour and white wordmarks, retrieved 2026-10-04 from
  `Horizontal Version/SVG/Color logo.svg` and `White logo.svg` in the
  [official logo archive](https://static-cdn.m5stack.com/resource/public/assets/M5Stack%20Logo.zip),
  linked by the [brand guidelines](https://m5stack.com/brand-guidelines).
  The colour artwork is used in light appearance and the supplied white artwork
  in dark appearance. The official paths and colours are preserved. CSS fills
  are inlined, exporter metadata is removed, and intrinsic dimensions match the
  original `1200 × 240.34` view box for static asset-catalog rendering.
- Soldered purple and white wordmarks, retrieved 2026-10-04 from the
  [official documentation site](https://docs.soldered.com/):
  [purple SVG](https://docs.soldered.com/img/soldered_logo_purple.svg) and
  [white SVG](https://docs.soldered.com/img/soldered_logo_white.svg).
  These supplied variants are used for light and dark appearance respectively.
  Paths and colours are preserved; CSS fills are inlined and redundant masks
  and rectangular clips covering the view box are removed for static rendering.
  The original view boxes are `288 × 58.9` and `1144 × 234`.
- paperlesspaper stacked wordmark, retrieved 2026-10-04 from the inline logo
  SVG in the [official site](https://paperlesspaper.de/en/).
  The `503.804 × 150.005` view box and paths are preserved. The site's
  `currentColor` fill is resolved to black in the SVG, and the asset renders as
  an adaptive monochrome template.
- Amazon two-colour wordmark, retrieved 2026-10-04 from the header and footer
  of the [official Trustworthy Shopping site](https://trustworthyshopping.aboutamazon.com/2024-brand-protection-report):
  [Squid Ink and orange SVG](https://cdn-trustworthyshopping.aboutamazon.com/4f/7c/f30570434070aab77383519e9ee1/style-2-color-squid-smile.svg)
  and [white and orange SVG](https://cdn-trustworthyshopping.aboutamazon.com/95/a6/63f5f61c459180dd621f50abb5ea/style-2-color-white-smile.svg).
  These supplied variants are used for light and dark appearance respectively.
  Paths, colours, and the `239 × 80` view box are preserved; only XML formatting
  is normalized. Amazon and the Amazon logo are trademarks of Amazon.com, Inc.
  or its affiliates.
- Rakuten Kobo red wordmark, retrieved 2026-10-04 from the embedded SVG data
  URL of the `kobo-logo` image served by the [official Kobo site](https://www.kobo.com/).
  The original red and all paths are preserved in both appearances. CSS fills
  are inlined and a `418.36 × 80` view box is added to match the original SVG's
  intrinsic dimensions.
- reMarkable wordmark, retrieved 2026-10-04 from the inline logo SVG in the
  [official site](https://remarkable.com/).
  The `131 × 17` view box and paths are preserved. The site's `currentColor`
  fill is resolved to black in the SVG, and the asset renders as an adaptive
  monochrome template.
- Elecrow orange-and-blue wordmark, retrieved 2026-10-27 from the
  [official branding kit](https://www.elecrow.com/download/partner/elecrow_logo_branding_kit.zip),
  linked by the [official brochure page](https://www.elecrow.com/brochure.html).
  The source is `elecrow_logo_branding kit/RGB/elecrow_logo_01.svg`. Paths and
  colours are preserved; the square canvas is cropped to a `48 328 704 144`
  view box around the horizontal mark, with exporter metadata removed.
- Good Display blue wordmark, retrieved 2026-10-27 from the
  [official site](https://www.good-display.com/):
  [header artwork](https://img202.yun300.cn/repository/image/08db4c90-c2b2-49f8-9474-e9070bdf7387.png?tenantId=160096&viewType=1&k=1791776976000).
  Only the wordmark to the right of the emblem is used. The blue silhouette in
  the `411 × 68` source is separated from its white background and converted
  to smooth SVG paths with Potrace 1.16, using the source's sampled navy colour.
  The view box is `97 13 304 51`. This is a contour conversion of official
  raster artwork, not an official vector original. It has no background, and
  the same silhouette renders as an adaptive white template in dark appearance.
- ZecTrix glyph, retrieved 2026-10-27 via the
  [Dashboard Icons entry](https://dashboardicons.com/icons/external/simpleicons/zectrix)
  from [Simple Icons 16.36.0](https://cdn.jsdelivr.net/npm/simple-icons@16.36.0/icons/zectrix.svg).
  The supplied SVG paths and `0 0 24 24` view box are unchanged and render as
  an adaptive monochrome template. Simple Icons documents the
  [official cloud logo](https://cloud.zectrix.com/logo.svg) as its source and
  distributes its collection under [CC0 1.0](https://cdn.jsdelivr.net/npm/simple-icons@16.36.0/LICENSE.md);
  brand rights remain with the owner.
- Bloomin8 black floral glyph, retrieved 2026-10-27 from the header of the
  [official site](https://bloomin8.com/):
  [original transparent PNG](https://bloomin8.com/cdn/shop/files/black_4c61cfe3-b387-405e-a453-567277be6612.png?v=1765963165).
  The bundled PNG is unchanged and renders as an adaptive monochrome template.

These source links document provenance and rendering adaptations. Availability
on an official site does not itself grant a general trademark licence or imply
manufacturer approval of this app.
