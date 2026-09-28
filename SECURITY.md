# Security

Knotchy exists to keep untrusted pages away from your Mac, so a security bug here is the worst kind of bug. If you
find one, thank you.

## Reporting a vulnerability

Please report it privately: on this repository's **Security** tab, choose **Report a vulnerability**. Don't open a
public issue for it.

Tell us what you found, how to reproduce it, and which versions of Knotchy and macOS you used. We'll reply within a
few days, and we'll have a fix or a plan before anything is made public.

## What counts

- A page in the VM reaching your Mac, your local network, or anything else the firewall should block
- Getting around a proxy or VPN route's kill switch
- Knotchy running code on the Mac, or installing anything other than Apple's pinned `container` package
- Proxy passwords or VPN keys leaking from the keychain or from the VM's secrets share

A page taking over the browser inside the VM is expected; that's what the VM is for. Escaping the VM is what counts.

## Supported versions

Only the latest release gets fixes.
