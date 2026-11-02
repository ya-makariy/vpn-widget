import AppKit
import SwiftUI

/// Draws the status item image: a shield in the menu bar's text colour, with a
/// ring around it split into one arc per shown profile. Filled arcs are the
/// connected ones; the ring's colour is the summary. Drawing happens when the
/// image is displayed, so the label colour follows the menu bar's appearance.
@MainActor
final class StatusIconRenderer {
    static let shared = StatusIconRenderer()

    private var cache: [String: NSImage] = [:]

    func image(for aggregate: AggregateState, segments: [Bool], blinkOn: Bool) -> NSImage {
        let dimmed = aggregate.animates && !blinkOn
        let key = "\(aggregate)|\(segments.map { $0 ? "1" : "0" }.joined())|\(dimmed)"
        if let cached = cache[key] { return cached }
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { rect in
            Self.draw(in: rect, aggregate: aggregate, segments: segments, dimmed: dimmed)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = Self.accessibilityLabel(aggregate, connected: segments.filter { $0 }.count, total: segments.count)
        cache[key] = image
        return image
    }

    static func accessibilityLabel(_ aggregate: AggregateState, connected: Int, total: Int) -> String {
        switch aggregate {
        case .empty: "VPN Widget, no VPNs configured"
        case .allStopped: "VPN Widget, all VPNs disconnected"
        case .allConnected: "VPN Widget, all \(total) VPNs connected"
        case .partial: "VPN Widget, \(connected) of \(total) VPNs connected"
        case .transitioning: "VPN Widget, a VPN is connecting or disconnecting"
        case .rechecking: "VPN Widget, rechecking a service"
        case .attention: "VPN Widget, a VPN needs attention"
        }
    }

    private static func draw(in rect: NSRect, aggregate: AggregateState, segments: [Bool], dimmed: Bool) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius: CGFloat = 7.6
        let lineWidth: CGFloat = 1.9
        let label = NSColor.labelColor

        // Ring.
        let ringColor: NSColor
        switch aggregate {
        case .allConnected, .partial: ringColor = .systemGreen
        case .transitioning: ringColor = .systemBlue
        case .rechecking: ringColor = NSColor(calibratedRed: 0.62, green: 0.78, blue: 0.16, alpha: 1)
        case .attention: ringColor = .systemRed
        case .allStopped, .empty: ringColor = label.withAlphaComponent(0.35)
        }
        let count = max(segments.count, 1)
        let gap: CGFloat = count > 1 ? .pi / 180 * 14 : 0
        let sweep = 2 * .pi / CGFloat(count)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(count > 1 ? .round : .butt)
        for i in 0..<count {
            let start = .pi / 2 - CGFloat(i) * sweep - gap / 2
            let end = start - sweep + gap
            let on = segments.isEmpty ? false : segments[i]
            var color = on || aggregate == .attention || aggregate == .transitioning ? ringColor : label.withAlphaComponent(0.3)
            if aggregate == .transitioning, !on { color = ringColor.withAlphaComponent(0.45) }
            if dimmed { color = color.withAlphaComponent(aggregate == .attention ? 0.25 : 0.4) }
            ctx.setStrokeColor(color.cgColor)
            ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
            ctx.strokePath()
        }

        // Shield, as a mask filled with the label colour.
        let config = NSImage.SymbolConfiguration(pointSize: 8.5, weight: .semibold)
        if let symbol = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let size = symbol.size
            let origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
            let target = CGRect(origin: origin, size: size)
            if let cg = symbol.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                ctx.saveGState()
                ctx.clip(to: target, mask: cg)
                let alpha: CGFloat = aggregate == .allStopped || aggregate == .empty ? 0.55 : 1
                ctx.setFillColor(label.withAlphaComponent(alpha).cgColor)
                ctx.fill(target)
                ctx.restoreGState()
            }
        }

        // Badge for attention and rechecking, bottom right.
        let badge: (String, NSColor)? = switch aggregate {
        case .attention: ("exclamationmark", .systemRed)
        case .rechecking: ("arrow.trianglehead.2.clockwise", NSColor(calibratedRed: 0.62, green: 0.78, blue: 0.16, alpha: 1))
        default: nil
        }
        if let (name, color) = badge, !dimmed {
            let badgeRect = CGRect(x: rect.maxX - 7.5, y: rect.minY + 0.5, width: 7, height: 7)
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: badgeRect)
            let bConfig = NSImage.SymbolConfiguration(pointSize: 5, weight: .black)
            if let s = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(bConfig),
               let cg = s.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let size = s.size
                let r = CGRect(x: badgeRect.midX - size.width / 2, y: badgeRect.midY - size.height / 2, width: size.width, height: size.height)
                ctx.saveGState()
                ctx.clip(to: r, mask: cg)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(r)
                ctx.restoreGState()
            }
        }
    }
}
