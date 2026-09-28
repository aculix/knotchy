# Chrome Web Store listing

Everything the developer dashboard asks for, in the order it asks.

## Package

`scripts/package-extension.sh` at the repository root builds `build/open-in-knotchy-<version>.zip`. It holds only
`manifest.json`, `background.js` and `icons/`. Upload that zip.

## Store listing

**Title** (from the manifest): Open in Knotchy

**Summary** (from the manifest): Adds "Open in Knotchy" to the right-click menu of links: opens them in Knotchy's
disposable, isolated browser.

**Description:**

> Right-click any link and choose Open in Knotchy to open it in Knotchy's disposable browser instead of Chrome.
>
> Knotchy is a free, open-source Mac app. Each link opens in its own throwaway Linux virtual machine, shown in a
> panel under your MacBook's notch. The page can reach the internet but not your Mac or your local network, and the
> whole machine is destroyed when you're done. It's meant for links you don't trust: unexpected email links,
> shortened URLs, and sites you'd rather not open in your own browser.
>
> This extension does one thing: it passes the address of the link you right-click to the Knotchy app on your Mac.
> It passes only http and https links, can't see the pages you visit, and sends nothing anywhere else.
>
> Requires the Knotchy app, on a Mac with Apple silicon and macOS 26 or later. The first time, Chrome asks whether to
> open Knotchy; allow it.

**Category:** Privacy & Security. **Language:** English.

**Graphics:**

| Asset | File |
|---|---|
| Store icon, 128 × 128 | `icons/icon-128.png` |
| Screenshots, 1280 × 800 (at least one) | `store/screenshot-*.png`, made as below |
| Small promo tile, 440 × 280 | `store/promo-440x280.png` |
| Marquee, 1400 × 560 (optional) | `store/marquee-1400x560.png` |

`scripts/make-icons.sh` regenerates the promo images with the icons.

**Screenshots** must be real captures:

1. With the extension loaded in Chrome, press ⌘⇧5, set a 5-second timer and capture the screen. During the countdown,
   right-click a link so the menu shows **Open in Knotchy**.
2. Open a link that way and capture the Knotchy panel under the notch with ⌘⇧4.
3. Fit each capture to the store's frame:
   `swift scripts/icons/frame.swift ~/Desktop/capture.png extensions/chrome/store/screenshot-1.png`

**Homepage and support URLs:** the GitHub repository and its issues page, once the repository is public.

## Privacy practices

**Single purpose:** Open a link in the Knotchy Mac app from Chrome's right-click menu.

**Permission justification, `contextMenus`:** Adds the Open in Knotchy item to the right-click menu of links, and
nothing else.

**Host permissions:** none requested.

**Remote code:** No. All code ships in the package.

**Data usage:** tick none of the data types. The extension collects nothing: the clicked link goes only to the
Knotchy app on the same Mac, through its `knotchy://` URL scheme, and never to a server. Tick the three
certifications (no selling or transferring data, no use unrelated to the single purpose, no use for creditworthiness).

**Privacy policy:** not required, since no user data is collected. If the dashboard asks anyway, link a page that
says: "Open in Knotchy collects no data. It passes the link you choose to the Knotchy app on your Mac and sends
nothing to any server."

## Distribution

Public, free, all regions.
