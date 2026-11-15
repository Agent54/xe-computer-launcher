import AppKit
import Testing
@testable import macos

@MainActor
struct LogPanelControllerTests {
    @Test func firstPaintContainsTheFilteredTailWithoutWaitingForTheJournal() throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/log-panel-tests/\(UUID().uuidString)")
        let store = SystemLogStore(directoryURL: directory, configuration: .init(flushDelay: 60))
        for index in 1...2_000 {
            store.append("runtime", "Info: completed work \(index)")
            store.append("runtime", "Warning: retry needed \(index)")
        }

        let panel = LogPanelController(logStore: store)
        let window = try #require(panel.window)
        window.contentView?.layoutSubtreeIfNeeded()
        defer { panel.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window)) }
        panel.prepareContents(showingIssues: true)

        let scrollView = try #require(window.contentView?.subviews.compactMap { $0 as? NSScrollView }.first)
        let textView = try #require(scrollView.documentView as? NSTextView)
        #expect(textView.string.contains("Warning: retry needed 2000"))
        #expect(!textView.string.contains("Info: completed work"))
        #expect(textView.string.split(separator: "\n").count == 160)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
