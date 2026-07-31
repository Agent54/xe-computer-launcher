import AppKit

@MainActor
final class LogPanelController: NSWindowController, NSWindowDelegate {
    private let textView = NSTextView()
    private var refreshTimer: Timer?
    private var currentSource: String? = nil  // nil = all
    private var lastLogCount = 0
    private var segmentedControl: NSSegmentedControl!
    private let tabSources = ["all", "launcher", "colima", "browser", "app_shim"]
    private let tabLabels = ["All", "XE Launcher", "Colima", "Browser", "App Shim"]

    private static let sourceColors: [String: NSColor] = [
        "launcher": .systemPurple,
        "colima": .systemBlue,
        "browser": .systemGreen,
        "app_shim": .systemOrange
    ]

    init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.title = "System Logs"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false

        super.init(window: window)

        window.delegate = self
        setupContent()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func present() {
        showWindow(nil)
        if let window, let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let winSize = window.frame.size
            let x = screenFrame.midX - winSize.width / 2
            let y = screenFrame.midY - winSize.height / 2
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        window?.orderFrontRegardless()
        startRefreshing()
        refreshLogs()
    }

    func windowWillClose(_ notification: Notification) {
        stopRefreshing()
    }

    private func setupContent() {
        guard let contentView = window?.contentView else { return }

        // Segmented control tab bar
        segmentedControl = NSSegmentedControl(labels: tabLabels, trackingMode: .selectOne, target: self, action: #selector(tabChanged(_:)))
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        segmentedControl.segmentStyle = .automatic
        segmentedControl.selectedSegment = 0
        segmentedControl.focusRingType = .none

        contentView.addSubview(segmentedControl)

        // Scroll view + text
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.isRichText = true
        textView.usesFontPanel = false
        scrollView.documentView = textView

        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            segmentedControl.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            segmentedControl.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),

            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        let idx = sender.selectedSegment
        let source = tabSources[idx]
        currentSource = (source == "all") ? nil : source
        lastLogCount = -1  // force refresh
        refreshLogs()
    }

    private func startRefreshing() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshLogs()
            }
        }
    }

    private func stopRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refreshLogs() {
        let entries = Array(ExternalState.shared.getLogs(source: currentSource).suffix(1000))
        guard entries.count != lastLogCount else { return }
        lastLogCount = entries.count

        let attributed = NSMutableAttributedString()
        let defaultFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let defaultColor = NSColor.labelColor

        for entry in entries {
            let sourceColor = Self.sourceColors[entry.source] ?? .systemGray

            let prefix = NSAttributedString(string: "[\(entry.source)] ", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
                .foregroundColor: sourceColor
            ])

            let line = NSAttributedString(string: "\(entry.line)\n", attributes: [
                .font: defaultFont,
                .foregroundColor: defaultColor
            ])

            attributed.append(prefix)
            attributed.append(line)
        }

        let shouldStickToBottom = isScrolledNearBottom()
        textView.textStorage?.setAttributedString(attributed)

        if shouldStickToBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }

    private func isScrolledNearBottom() -> Bool {
        guard let scrollView = textView.enclosingScrollView else { return true }
        let visibleMaxY = scrollView.contentView.bounds.maxY
        let contentHeight = textView.bounds.height
        return contentHeight - visibleMaxY < 40
    }
}
