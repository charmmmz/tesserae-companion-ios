# Attribution and project identity

Tesserae Companion is an independent, community-built client for
[Tesserae](https://github.com/dmellok/tesserae). It is not the official
Tesserae application and is not published by Tesserae's maintainer.

Tesserae server source is copyright its contributors and distributed under
the GNU Affero General Public License v3.0 or later. This repository does not
redistribute or link Tesserae server source; it communicates with a separately
running server through the proposed Companion HTTP API.

Tesserae's maintainer granted permission on 2026-07-28 to use the Tesserae
name and mark for **Tesserae Companion** in this repository and on the App
Store. The permission and its terms are recorded publicly in
[Discussion #147](https://github.com/dmellok/tesserae/discussions/147#discussioncomment-17810183).

That permission requires the app to:

- always describe itself as community-built and never official;
- include no third-party advertising SDKs;
- send no analytics or telemetry off the device without explicit opt-in;
- never sell or share user data; and
- never paywall functionality that the Tesserae web UI provides for free.

The maintainer expressed a preference for a free app but separately permitted
a paid app, one-time unlock, tip jar, or sponsorship, provided the companion
maintainer gives notice before choosing a monetization model. If the binding
brand terms above are broken, permission to use the Tesserae name and mark
lapses and the app must be renamed.

If maintenance stops, the companion maintainer will give advance public
notice and first seek to transfer the repository and App Store listing to a
mutually acceptable successor. If no responsible successor is available, new
distribution will stop rather than leave an unmaintained listing in place;
the final source and release will remain available where practical.

Tesserae Companion is distributed under the Apache License 2.0. See
[`LICENSE`](LICENSE) and [`NOTICE`](NOTICE). That licence covers this
repository's original code and documentation; it does not grant rights to
Tesserae names, logos, or other marks.

The App Icon uses Tesserae's official tessellated mark from
`static/brand/icon.svg`. Its geometry and colours are preserved; only the
outer background is extended to the edge so iOS can apply its platform mask
without transparent pixels.

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

The app bundles unmodified manufacturer marks solely to identify compatible
hardware in the user's own Tesserae device list. Each name and mark remains
the property of its respective owner and is not covered by this repository's
Apache-2.0 licence. Their presence does not imply sponsorship or endorsement
of Tesserae Companion.

The bundled source files were retrieved from the owners' current official
sites on 2026-07-29:

- Seeed Studio colour and white wordmarks; the white wordmark is rendered with
  the official Seeed Green sampled from the colour asset in dark appearance:
  [official branding-kit archive](https://files.seeedstudio.com/wiki/Seeed_Studio_LOGO.zip)
- Pimoroni square mark:
  [official shop favicon](https://cdn.shopify.com/s/files/1/0174/1800/t/119/assets/favicon.png?v=46731808014570061601773155236)
- TRMNL black glyph:
  [official Framework asset](https://trmnl.com/assets/trmnl--glyph-black-4ca602fd.svg)
- Waveshare colour wordmark:
  [official store header asset](https://www.waveshare.com/media/eternal/venedor/default/logo.png)
- PicPak red wordmark:
  [official shop header asset](https://cdn.shopify.com/s/files/1/0674/8569/6246/files/Vector.svg?v=1774110422)
