#!/bin/sh
# Renders the Homebrew cask for a release.
# usage: cask.sh <version> <sha256> <output path>
set -eu
VERSION=$1
SHA=$2
OUT=$3
mkdir -p "$(dirname "$OUT")"
cat > "$OUT" <<CASK
cask "vpn-widget" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/ya-makariy/vpn-widget/releases/download/v#{version}/VPN-Widget-#{version}.zip"
  name "VPN Widget"
  desc "Menu bar status and control for VPN profiles of FortiClient, AnyConnect, AmneziaWG and WireGuard"
  homepage "https://github.com/ya-makariy/vpn-widget"

  depends_on macos: ">= :tahoe"

  app "VPN Widget.app"

  zap trash: [
    "~/Library/Application Support/VPN Widget",
    "~/Library/Preferences/com.ya-makariy.vpn-widget.plist",
  ]

  caveats <<~EOS
    VPN Widget is signed ad hoc, not notarized. If macOS refuses to open it:
      xattr -dr com.apple.quarantine "/Applications/VPN Widget.app"
    or install with --no-quarantine.
  EOS
end
CASK
echo "Wrote $OUT"
