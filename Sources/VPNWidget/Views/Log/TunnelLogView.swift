import AppKit
import SwiftUI
import VPNWidgetCore

/// Opens the log window of one of the widget's own tunnels. Like Settings, it
/// would open behind the panel unless the app is made active first.
@MainActor
enum TunnelLogOpener {
    static let windowID = "tunnel-log"

    static func open(_ profileID: String, with action: OpenWindowAction) {
        NSApp.activate()
        action(id: windowID, value: profileID)
    }
}

/// The end of a tunnel's log, kept up to date while Follow is on.
struct TunnelLogView: View {
    @Environment(AppModel.self) private var model
    var profileID: String
    @State private var tail: TunnelLog.Tail?
    @State private var loaded = false
    @State private var follow = true

    private var name: String? { TunnelConfig.name(fromProfileID: profileID) }
    private var path: String? { name.map(TunnelFiles.logPath) }
    private var title: String { model.profile(profileID)?.displayName ?? name ?? profileID }

    var body: some View {
        VStack(spacing: 0) {
            if let tail, !tail.text.isEmpty {
                LogTextView(text: tail.text, follow: follow)
            } else {
                ContentUnavailableView {
                    Label(loaded ? "No log yet" : "Reading…", systemImage: "doc.text")
                } description: {
                    if loaded { Text("The tunnel writes its log once it has been started.") }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: path ?? "")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    if let tail, tail.truncated {
                        Text("Showing the last \(Format.bytes(UInt64(TunnelLog.defaultTailBytes))) of \(Format.bytes(tail.fileSize))")
                            .font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
                Spacer()
                Toggle("Follow", isOn: $follow)
                    .toggleStyle(.checkbox)
                    .help("Keep reading the log and stay at its end")
                Button("Show in Finder") {
                    if let path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
                .disabled(tail == nil)
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 560, minHeight: 320)
        .navigationTitle("Log: \(title)")
        .task(id: follow) {
            // Read once in any case; keep reading only while following.
            repeat {
                await reload()
                try? await Task.sleep(for: .seconds(1))
            } while follow && !Task.isCancelled
        }
    }

    /// Reads the end of the file again when its size has changed.
    private func reload() async {
        guard let path else {
            loaded = true
            return
        }
        let known = tail?.fileSize
        let fresh = await Task.detached(priority: .utility) { () -> TunnelLog.Tail?? in
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value
            if let size, size == known { return nil }
            return .some(TunnelLog.tail(path: path))
        }.value
        if let fresh { tail = fresh }
        loaded = true
    }
}

/// The log text: AppKit's text view, which stays quick with thousands of
/// lines and brings selection, copy and Find with it.
private struct LogTextView: NSViewRepresentable {
    var text: String
    var follow: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.drawsBackground = false
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 8, height: 8)
        // Long lines scroll sideways instead of wrapping.
        view.isHorizontallyResizable = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text {
            view.string = text
        }
        if follow {
            view.scrollToEndOfDocument(nil)
        }
    }
}
