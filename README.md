<img src="assets/knotchy-icon.svg" width="96" alt="">

# Knotchy

Open suspicious links in a throwaway browser that lives in your Mac's notch.

> **Status:** 0.1.0, the first release. It works, but it's young. If something breaks, please open an issue.

Some links you'd rather not open. A shortened link in a text from a number you don't know. An "invoice" from a
company you've never dealt with. Knotchy opens them somewhere else: a small Linux virtual machine that exists for
that one link. The page appears in a panel under the notch, you look at it, and when you're done the whole machine
is deleted, along with anything the page did inside it.

The VM can reach the internet. It can't reach your Mac or anything else on your network.

## Requirements

- A Mac with Apple silicon
- macOS 26 or later
- About 3 GB of free space for the first setup
- An administrator password, once, for Apple's installer

## Install

1. Download `Knotchy-0.1.0.dmg` from [Releases](https://github.com/aculix/knotchy/releases/latest). It's signed
   and notarized, so macOS opens it without warnings.
2. Open the disk image and drag Knotchy to Applications.
3. Open Knotchy. A knot appears in the menu bar and the setup window opens.
4. Click **Set Up**, and Knotchy works through the list:
   - It checks that your Mac can run virtual machines and has enough space.
   - It downloads Apple's [`container`](https://github.com/apple/container) runtime (version 1.4.1, 118 MB),
     checks it against the SHA-256 built into Knotchy, and opens it in Apple's Installer. Click through Installer
     and enter your password there. Knotchy never asks for administrator rights itself.
   - It starts the runtime, which downloads a Linux kernel the first time.
   - It builds the browser VM image on your Mac. That takes about 3 minutes and downloads about 225 MB.
5. When every row has a green tick, click **Done**.

If `container` 1.4 or newer is already installed, Knotchy uses it and goes straight to the build. You can close the
window at any point and setup carries on; **Set Up Knotchy…** in the menu bar brings it back.

### The browser extension

Safari and Mail need nothing extra. Chrome, Edge, Brave and Arc do, because they pass the Services menu a link's
text instead of its address. Until the extension is on the Chrome Web Store, install it by hand:

1. Download `open-in-knotchy-1.0.0.zip` from [Releases](https://github.com/aculix/knotchy/releases/latest) and unzip
   it somewhere you'll keep it. (The same files are in [`extensions/chrome`](extensions/chrome).)
2. Open `chrome://extensions` and turn on **Developer mode** in the top-right corner.
3. Click **Load unpacked** and choose the unzipped folder.
4. Right-click any link and choose **Open in Knotchy**. The first time, the browser asks whether to open Knotchy.
   Allow it.

The extension has one permission, adding that menu item, and only passes `http` and `https` links to the app.
It won't update itself, and deleting the folder removes it from the browser.

## Opening links

- In Safari, Mail and most other apps, right-click a link and choose **Services → Open in Knotchy**. It also works
  on selected text that contains a link.
- In Chrome and other Chromium browsers, right-click a link and choose **Open in Knotchy**.
- Anywhere else, copy the link and press **⌃⌥⌘L**, or choose **Open Copied Link** from the menu bar.

Only web links open. Anything else gets a brief "No web link found" in the notch.

## Using the panel

The page opens in a panel that drops down from the notch. Scroll, click and type as you would in any browser. The
toolbar has back, forward and reload, an address field, and a button that makes the panel bigger.

Click anywhere outside the panel and it folds back into the notch, with a countdown beside it. Hover over the notch
to bring the page back. Leave it folded and the VM is destroyed when the countdown runs out, after 5 minutes unless
you change it. **Destroy** in the toolbar, or ⌘W, ends it right away.

Knotchy shows one page at a time. Opening a new link replaces the current VM with a fresh one.

## Settings

The knot in the menu bar opens a menu with the open page (show it or destroy it), **Open Copied Link**, the
connection picker and **Rebuild VM**. **Settings…** has three sections.

General sets how long a folded page lives, whether pages open in the small or large panel, the ⌃⌥⌘L shortcut, and
whether Knotchy opens at login.

Network sends pages through an HTTP or SOCKS5 proxy, with a username and password if it needs them, or through a
WireGuard VPN. For a VPN, import the `.conf` files or the `.zip` your provider gives you; Mullvad, Proton VPN and IVPN
all offer them. If the proxy or VPN is down, pages don't load. They never fall back to your normal connection.
Proxies on your Mac or your local network are refused, because a page could reach your network through them.
Passwords and VPN keys are kept in your keychain.

VM shows the runtime version and when the image was built, and has **Rebuild Now**. Rebuilding picks up WebKit
security fixes, and Knotchy suggests it once the image is two weeks old.

## How it works

There are two programs: the Mac app, and a small agent inside each VM.

When a link comes in, the app checks that it's `http` or `https` and asks Apple's `container` tool to start a new VM
from the `local/knotchy-vm` image. That's Debian with WPE WebKit and GStreamer, given 4 CPU cores and 2 GB of memory.
Each VM gets a random name (`knotchy-` and 8 hex digits) and is deleted when it stops.

The VM's first process is [`vm/knotchy-init`](vm/knotchy-init), a shell script. Before anything else runs, it sets up
an nftables firewall. On a direct connection the firewall allows the public internet and blocks private and
link-local addresses, carrier-grade NAT, IPv6, and the networks your Mac is on. With a proxy, the proxy is the only
thing the VM can reach. With WireGuard, it's the VPN server and the tunnel. If the firewall can't be put in place,
the VM stops instead of starting without it. Init then drops all its capabilities and starts the agent as an
unprivileged user, so nothing the browser runs can change the firewall.

The agent, [`vm/knotchy-agent.c`](vm/knotchy-agent.c), loads the page in WPE WebKit at 1024 × 640, encodes what it
draws as H.264 with x264, and writes the frames to a Unix socket. `container` exposes that socket to the Mac as a
file, so there's no network connection between the two. The app decodes the video with VideoToolbox and draws it
in the panel. Clicks, scrolls, keys and address changes go back over the same socket. The message format is at the
top of the agent's source.

Destroying a page stops and deletes its VM. If Knotchy quits with a VM running, it deletes it on the way out, and
any VM left behind by a crash is deleted at the next launch.

The image is built on your Mac from the [`vm`](vm) folder that ships inside the app, so what runs in the VM is what's
in this repository. Proxy passwords and VPN keys reach the VM through a shared folder that init reads, deletes and
unmounts before the browser starts. They're never passed as environment variables, which `container` saves to disk.

### What's where

| Path | Contents |
|---|---|
| `Sources/Knotchy` | The Mac app: menu bar, notch panel, setup window and Settings |
| `Sources/KnotchyCore` | The session state machine, the VM backend, the stream protocol and decoder, setup logic |
| `Sources/knotchyctl` | A command-line tool that opens a link in a VM and saves a screenshot, for testing without the UI |
| `Tests` | Unit tests for KnotchyCore; none of them need a VM |
| `vm` | The VM image: `Containerfile`, `knotchy-init` and `knotchy-agent.c` |
| `extensions/chrome` | The Open in Knotchy extension |
| `scripts` | Build, release, test and icon scripts |

## Known limitations

- The "Isolated" badge means isolated, not safe. A page can still try to trick you inside the VM.
- There's no sound. Clipboard, downloads, popups and links that open a new window stay inside the VM or don't work.
- The picture is streamed at 1×, so it's slightly soft on Retina screens.
- Proxy and VPN routes are IPv4 only, a WireGuard config can have only one peer, and OpenVPN isn't supported.
- The firewall runs in the VM's own kernel, so a kernel exploit inside the VM could get around it.
- A site can still reach your router through your network's public address (hairpin NAT), and routes that a VPN
  on your Mac adds for public addresses aren't blocked. Knotchy reads your Mac's networks when each page starts.
- Unprivileged user namespaces are on in the VM, because WebKit's sandbox needs them.

## Building from source

You need a Mac with Apple silicon, macOS 26 or later, Xcode 26 or later, and Apple's `container` installed.

```bash
git clone https://github.com/aculix/knotchy.git
cd knotchy
scripts/bundle-app.sh
```

`bundle-app.sh` builds Knotchy.app and installs it in `~/Applications`. It signs with your Developer ID certificate
if you have one and ad hoc if you don't, which is fine for your own Mac. The app builds its VM image the first time
it opens, the same as a downloaded copy.

The other scripts:

- `swift test` runs the unit tests.
- `scripts/build-vm.sh` builds the VM image from the command line.
- `scripts/test-egress.sh` starts a VM and checks what it can and can't reach. Run it after any change in `vm`.
- `scripts/test-routes.sh` checks the proxy and VPN routes, kill switch included. Build its test server first with
  `container build --dns 1.1.1.1 -t local/knotchy-route-server scripts/route-server`.
- `scripts/release.sh` builds a signed, notarized disk image. It needs a Developer ID certificate and notarization
  credentials saved with `xcrun notarytool store-credentials`.
- `scripts/package-extension.sh` zips the browser extension.
- `scripts/make-icons.sh` redraws every icon from the knot in `scripts/icons/knot.py`.

A VM image you build yourself is exactly as trustworthy as the checkout you built it from.

## Uninstalling

Quit Knotchy and move it to the Trash. Then remove its VM image in Terminal:

```bash
container image rm local/knotchy-vm
```

If nothing else on your Mac uses Apple's `container`, you can remove it as well. This deletes all of its data:

```bash
/usr/local/bin/uninstall-container.sh -d
```

## Security

To report a security problem, please use GitHub's private reporting. [SECURITY.md](SECURITY.md) has the details.

## License

MIT. See [LICENSE](LICENSE).
