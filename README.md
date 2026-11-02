# VPN Widget

A menu bar widget for macOS 26 that shows the VPNs you use for work, all in one
place, and connects or disconnects them. It works with the VPN apps you already
have: **FortiClient**, **Cisco AnyConnect**, **AmneziaWG** and **WireGuard**
(profiles of other VPN apps show up too, under "Other").

For each VPN it shows:

- whether it is connected, with Connect, Disconnect and Reconnect, and Connect All;
- while it is up, whether the service behind it answers: HTTP status, latency
  and total time of one request to a URL you choose;
- bytes received and sent over the tunnel, and how long it has been up.

Every change of state is a notification. The menu bar icon sums everything up:
a ring with one arc per VPN, green when all are connected and answering, grey
when all are off, pulsing blue while one is on its way, blinking red when one
needs you.

VPN Widget runs no tunnels of its own. It reads the VPN profiles that your VPN
apps registered with macOS and starts or stops them the way the system does, so
no password, no root helper and no kernel or network extension of its own.

## Install

```sh
brew tap ya-makariy/tap
brew install --cask vpn-widget
```

The app is signed ad hoc and not notarized. If macOS refuses to open it, remove
the quarantine flag or install with `--no-quarantine`:

```sh
xattr -dr com.apple.quarantine "/Applications/VPN Widget.app"
```

Or build it yourself: see [Development](#development).

## Adding a VPN

Create or import the VPN in its own app first: FortiClient, AnyConnect,
AmneziaWG or WireGuard. Then open the widget's Settings (⌘, from the panel), find
the profile in the list and turn it on. Per profile you can set:

- the name shown in the panel;
- a **service check URL**: something only reachable through the tunnel, such as
  an internal wiki or Grafana. One GET without redirects or proxy every check
  interval; any answer below HTTP 500 counts as reachable. Turn off certificate
  verification for services behind a private CA: the check asks about reach,
  not trust;
- **connect when VPN Widget starts**;
- **split DNS**: domains and the DNS servers that should answer for them (below).

FortiClient and AnyConnect ask for a sign-in in their own window when they
connect; the row says "waiting for sign-in" while that is pending.

## Several VPNs at once

macOS runs several VPN tunnels at the same time. Each brings its own routes, and
traffic goes to whichever tunnel claims the destination, so split-tunnel VPNs
coexist with no help. Two things get in the way, and the widget shows a warning
on the profile when it sees them:

- a tunnel that **takes the default route** carries everything, including the
  other tunnels' traffic;
- a tunnel whose DNS servers **answer every query**. FortiClient does this; so do
  WireGuard and AmneziaWG whenever the config has a `DNS =` line. The last tunnel
  up wins, and names of the other tunnels stop resolving.

### Split DNS

The fix for the DNS case is a file per domain in `/etc/resolver`: macOS sends
queries for that domain to the servers in its file, whichever VPN is primary.
In a profile's settings, add the domains and DNS servers (or use "Fill from
Current Connection" while the tunnel is up), then click **Install Resolver
Files…**. The widget asks for an administrator password once and writes the
files for every shown profile; nothing runs as root afterwards. "Remove All"
takes them away again. Files the widget did not write are never touched.

Check the result with `scutil --dns`, which lists a resolver per domain. For
WireGuard and AmneziaWG profiles, also remove the `DNS =` line from the config
so that they stop taking over the system resolver.

## How it works

Everything goes through the public SystemConfiguration framework:

| What | How |
| --- | --- |
| Which VPNs exist | `SCNetworkServiceCopyAll`, interface type `VPN`; the owning app from the `NEProviderBundleIdentifier` in the interface configuration |
| State | `SCNetworkConnectionGetStatus` on an unscheduled connection (a scheduled one answers from a cache until its first callback) |
| Changes | a second, scheduled connection per service, plus dynamic store notifications on `State:/Network/Service/*/IPv4` and `/DNS` |
| Uptime, DNS pushed by the tunnel, default route | `SCNetworkConnectionCopyExtendedStatus`: `LastStatusChangeTime`, `DNSServers`, `DNSSearchDomains`, `IsPrimaryInterface` |
| Traffic | `SCNetworkConnectionCopyStatistics` |
| Interface (`utunN`) | `State:/Network/Service/<id>/IPv4` in the dynamic store |
| Connect, disconnect | `SCNetworkConnectionStart` / `Stop`, what `scutil --nc start` does; `scutil` and the client's own app as fallbacks |
| Whether a tunnel owns DNS | its `State:/Network/Service/<id>/DNS` has no match domains and the global resolver points at its servers |

Checks run every 30 seconds (configurable), every second while a service has
just stopped answering, and right after an action. A new tunnel has 30 seconds
to settle before a failed check counts; after that a check has to fail for more
than 10 seconds in a row before the icon turns red or a notification goes out.
The first check after launch only records the state, so a restart notifies
about nothing.

Settings live in `~/Library/Application Support/VPN Widget/profiles.json`.

## Development

Needs macOS 26 and Xcode 26 or newer. The Command Line Tools alone cannot
build it: the SwiftUI macros and the Swift Testing plugin ship with Xcode. The
Makefile sets `DEVELOPER_DIR` to `/Applications/Xcode.app` when `xcode-select`
points elsewhere.

```sh
make test          # unit tests of the core: state, timing, notifications, resolver files
make app           # dist/VPN Widget.app, signed ad hoc
make run           # build and open it
make install       # copy to /Applications
VPNWIDGET_FAKE=1 VPNWIDGET_PREVIEW=1 "dist/VPN Widget.app/Contents/MacOS/VPNWidget"
                   # pretend VPNs and the panel in a window, for UI work
```

`vpnw` is the engine from the command line, without the app:

```sh
swift run vpnw list              # VPN profiles the system knows, with status
swift run vpnw once --all        # one poll of every profile
swift run vpnw watch 60          # print status changes as the system reports them
swift run vpnw start <name>      # what the Connect button does
swift run vpnw dns <name>        # DNS and routing facts about a profile
swift run vpnw check <url>       # the reachability check
```

Layout: `Sources/VPNWidgetCore` is the engine (models, the poll loop, the
notification diff, resolver files) and the system adapters behind protocols;
`Sources/VPNWidget` is the SwiftUI app; `Tests/VPNWidgetCoreTests` test the
core with fakes and no system access.

Releases: `make release` zips the app and creates a GitHub release;
`make cask` renders the cask into a checkout of
[homebrew-tap](https://github.com/ya-makariy/homebrew-tap).

## License

MIT.
