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

## Own tunnels: FortiGate SSL VPN and AnyConnect without their apps

FortiClient's extension can only be started by FortiClient's own window, which
does the SAML sign-in, and the AnyConnect on Apple silicon is the iPhone app,
which wants its window for the password. For those two the widget can run the
tunnel itself, with the same CLI tools the Linux version uses:

- **openfortivpn** for FortiGate SSL VPN, with SAML: the sign-in page opens in
  your default browser, nothing else to click;
- **openconnect** for the AnyConnect protocol, with the password stored once.

It can also run [AmneziaWG and WireGuard](#amneziawg-and-wireguard) tunnels
from their `.conf` files, described below.

Install the tools (`brew install openfortivpn openconnect`), then in Settings →
Tunnels click **Set Up Tunnels…** once. It asks for an administrator password
and:

- copies a small helper, `vpn-tunnel`, and root-owned copies of the tools to
  `/usr/local/libexec/vpn-widget` (the passwordless start below must never run a
  file you can edit);
- writes `/etc/sudoers.d/vpn-widget`, which lets your user run exactly
  `launchctl kickstart`, `kill TERM` and `print` on jobs named
  `com.ya-makariy.vpn-widget.*`, and nothing else.

**Add Tunnel** asks for the gateway, the sign-in details and the split-DNS
domains, then installs a launchd daemon for it (administrator password again,
once per tunnel). From then on Connect and Disconnect in the panel start and
stop that daemon without a password. The daemon:

1. waits until the gateway's port answers, so that a sign-in page never opens
   just to show an error;
2. runs the tool and follows its output into a state file the widget reads:
   waiting for sign-in (with the page), connected (with the interface), failed;
3. while the link is up, writes `/etc/resolver/<domain>` for the tunnel's
   domains with the DNS servers the gateway sent, and removes them when it goes
   down. With no domains configured, the gateway's DNS takes over everything
   while the tunnel is up, as the vendor clients do;
4. after a drop, starts again with a backoff from 5 seconds to 5 minutes. A
   SAML sign-in nobody answers is retried quietly without opening another page.

Configs live root-only in `/usr/local/etc/vpn-widget`, logs in
`/var/log/vpn-widget/<name>.log`, state in `/var/run/vpn-widget`. Tunnels
outlive the widget: quitting it leaves them up.

The daemon rotates its log every day at midnight (local time): the day's file
becomes `<name>.<date>.log.gz`, and archives older than the tunnel's retention,
7 days unless changed, are deleted. A tunnel that was not running at midnight
rotates at its next start. The tunnel's form has both settings under **Log**:
the retention, and the level — `ERROR` (failures only), `INFO` (the default),
`DEBUG` (the tool's debug output too) or `TRACE` (with packet traces).

To see why a tunnel does not come up, open its log: **Show Log** in the row's
`…` menu in the panel, or **Log** next to the tunnel in Settings → Tunnels. The
window shows the end of the file (the daemon's own lines and everything the
tool printed) and keeps up with it while **Follow** is on. From the command
line, `vpnw log <tunnel> -f` does the same.

### AmneziaWG and WireGuard

The AmneziaWG and WireGuard apps from the App Store register their tunnels with
macOS, and those show up as profiles like any other. The AmneziaVPN desktop
client does not, and keeps one tunnel up at a time. For `.conf` files from
several servers, each as its own row, the widget runs the tunnel itself:
**Add Tunnel → AmneziaWG / WireGuard**, then **Import .conf…**.

It uses two tools, **amneziawg-go** (the userspace tunnel) and **awg** (from
amneziawg-tools, which configures it). A plain WireGuard config goes through
the same two: without the obfuscation parameters (`Jc`, `Jmin`, `Jmax`, `S1`,
`S2`, `H1`–`H4`, …) amneziawg-go is expected to speak the plain WireGuard
protocol. That backward compatibility is AmneziaWG's design, and an assumption
here: the widget has no separate wireguard-go path.

Homebrew has no formulae for them and the release does not bundle them, so
build them once. amneziawg-go needs Go (`brew install go`), awg only the
Command Line Tools:

```sh
git clone https://github.com/amnezia-vpn/amneziawg-go
make -C amneziawg-go
sudo make -C amneziawg-go install PREFIX=/usr/local

git clone https://github.com/amnezia-vpn/amneziawg-tools
make -C amneziawg-tools/src
sudo make -C amneziawg-tools/src install PREFIX=/usr/local WITH_WGQUICK=no WITH_BASHCOMPLETION=no
```

That puts `amneziawg-go` and `awg` in `/usr/local/bin`. Setup looks for them
there and in Homebrew's `bin`, and copies them root-owned next to the other
tools: click **Set Up Again…** after installing them. The form says so while
either is missing.

What happens to the `.conf`:

- It is stored whole, keys included, in a root-only file under
  `/usr/local/etc/vpn-widget`, where the openconnect password goes. The
  widget's own settings and the files under `/var/run/vpn-widget` keep only
  what the form shows: endpoint, addresses, allowed IPs, DNS, MTU. Keys are
  kept out of the log.
- The daemon runs `amneziawg-go -f utun` and, once it has its interface, does
  what `wg-quick` would: `awg setconf` with the file minus wg-quick's own keys
  (`Address`, `DNS`, `MTU`, `Table`, the hooks, `SaveConfig`), `ifconfig` for
  each `Address` and the `MTU`, and a route per `AllowedIPs` entry. Everything
  else in the file reaches awg as written, so parameters of a newer AmneziaWG
  work without a new widget. When the tunnel stops, amneziawg-go exits, its
  interface goes, and the routes with it.
- **`PreUp`, `PostUp`, `PreDown` and `PostDown` are never run.** The daemon is
  root and the file came from somewhere else. The form lists the ones it found
  and ignores them; so with `SaveConfig`. `Table` may be `auto`, `main` or
  `off` (no routes), as in wg-quick on macOS.
- **`DNS =` is never made the system resolver.** Its servers become the DNS
  servers for the tunnel's split-DNS domains (the form fills them in), and with
  no domains the tunnel changes no DNS at all.
- `AllowedIPs = 0.0.0.0/0` or `::/0` (or the two `/1` halves) takes the default
  route, as two `/1` routes over the system's own, with a host route to the
  peer by the current gateway so that the tunnel's packets stay outside it.
  The form and the profile warn about it, as for any tunnel that carries
  everything. There is no kill switch: when the tunnel stops, traffic goes
  out the usual way.

"Connected" means a handshake in the last three minutes
(`awg show <interface> latest-handshakes`); before the first one the row says
connecting, and it goes back to connecting if handshakes stop. WireGuard only
handshakes when there is traffic, so a peer without `PersistentKeepalive` on an
idle tunnel reads as connecting until something is sent. A service check URL
keeps such a tunnel busy only while it is connected;
`PersistentKeepalive = 25` in the `[Peer]` section is the fix, and the form
says when it is missing. The peer's name is resolved when the tunnel starts;
Reconnect picks up a changed address.

Do not run the same config here and in the AmneziaWG or WireGuard app at once:
the server sees one peer, and the two take turns breaking each other.

Known gap: the root-owned copies of openfortivpn and openconnect still load
Homebrew's dylibs, which your user can write. Someone already running code as
you could use that to become root. Static builds would close it. (amneziawg-go
is a static Go binary and awg links only the system's libraries.)

## Several VPNs at once

macOS runs several VPN tunnels at the same time. Each brings its own routes, and
traffic goes to whichever tunnel claims the destination, so split-tunnel VPNs
coexist with no help. Two things get in the way, and the widget shows a warning
on the profile when it sees them:

- a tunnel that **takes the default route** carries everything, including the
  other tunnels' traffic;
- a tunnel whose DNS servers **answer every query**. FortiClient does this; so do
  the WireGuard and AmneziaWG apps whenever the config has a `DNS =` line (the
  widget's own AmneziaWG tunnels never do). The last tunnel up wins, and names
  of the other tunnels stop resolving.

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
| Own tunnels | launchd daemons running `vpn-tunnel`, controlled with `sudo -n launchctl` under a sudoers rule; state from `/var/run/vpn-widget/<name>.json`, traffic from `sysctl NET_RT_IFLIST2` |
| Whether a tunnel owns DNS | its `State:/Network/Service/<id>/DNS` has no match domains and the global resolver points at its servers |

Checks run every 30 seconds (configurable), every second while a service has
just stopped answering, and right after an action. A new tunnel has 30 seconds
to settle before a failed check counts; after that a check has to fail for more
than 10 seconds in a row before the icon turns red or a notification goes out.
The first check after launch only records the state, so a restart notifies
about nothing.

Settings live in `~/Library/Application Support/VPN Widget/profiles.json`.

## Development

Needs macOS 26 and Xcode 26 or newer; own tunnels also need Homebrew's
openfortivpn and openconnect, or amneziawg-go and awg built as described
above. The Command Line Tools alone cannot
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
swift run vpnw log <tunnel> -f   # the end of an own tunnel's log, following it
swift run vpnw check <url>       # the reachability check
```

Layout: `Sources/VPNWidgetCore` is the engine (models, the poll loop, the
notification diff, resolver files) and the system adapters behind protocols;
`Sources/VPNWidget` is the SwiftUI app; `Tests/VPNWidgetCoreTests` test the
core with fakes and no system access.

Releases: pushing a tag `vX.Y.Z` runs the Release workflow, which tests,
builds, zips, publishes the GitHub release and bumps the cask in
[homebrew-tap](https://github.com/ya-makariy/homebrew-tap) (the tap job needs
the `TAP_REPO` variable and a `TAP_GITHUB_TOKEN` secret with write access to the
tap). `make release` and `make cask` do the same by hand.

## License

MIT.
