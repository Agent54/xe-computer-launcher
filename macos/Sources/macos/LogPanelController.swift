import AppKit

@MainActor
final class LogPanelController: NSWindowController, NSWindowDelegate {
    private let textView = NSTextView()
    private let logStore: SystemLogStore
    private let earlierButton = NSButton()
    private var refreshTimer: Timer?
    private var currentSources: Set<String>?
    private var lastRevision: UInt64?
    private var displayed: [SystemLogStore.Entry] = []
    private var historyTask: Task<Void, Never>?
    private var historyGeneration = 0
    private var displayLimit = 10_000
    private var segmentedControl: NSSegmentedControl!
    private let tabSources: [Set<String>?] = [nil, ["launcher"], ["runtime", "smolvm", "docker", "maintenance", "routing", "workerd"], ["browser"], ["app_shim"], ["compose"]]
    private let tabLabels = ["All", "Xe Launcher", "Runtime", "Browser", "App Shim", "Compose"]

    private static let sourceColors: [String: NSColor] = [
        "launcher": .systemPurple,
        "browser": .systemGreen,
        "app_shim": .systemOrange,
        "compose": .systemBlue,
        "runtime": .systemTeal,
        "docker": .systemBlue,
        "smolvm": .systemTeal,
        "maintenance": .systemTeal
    ]

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    init(logStore: SystemLogStore = ExternalState.shared.logStore) {
        self.logStore = logStore
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.title = "System Logs"
        window.minSize = NSSize(width: 640, height: 320)
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
        loadHistory(reset: true)
    }

    func windowWillClose(_ notification: Notification) {
        stopRefreshing()
        historyTask?.cancel()
        historyGeneration += 1
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

        earlierButton.title = "Load earlier"
        earlierButton.bezelStyle = .rounded
        earlierButton.target = self
        earlierButton.action = #selector(loadEarlier)
        earlierButton.translatesAutoresizingMaskIntoConstraints = false
        earlierButton.isEnabled = false
        contentView.addSubview(earlierButton)

        NSLayoutConstraint.activate([
            segmentedControl.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            segmentedControl.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),

            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: earlierButton.topAnchor, constant: -8),
            earlierButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            earlierButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
        ])
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        let idx = sender.selectedSegment
        guard tabSources.indices.contains(idx) else { return }
        currentSources = tabSources[idx]
        loadHistory(reset: true)
    }

    @objc private func loadEarlier() { loadHistory(reset: false) }

    private func loadHistory(reset: Bool) {
        historyTask?.cancel()
        historyGeneration += 1
        let generation = historyGeneration
        let before = reset ? nil : displayed.first?.id
        let sources = currentSources
        earlierButton.isEnabled = false
        if reset {
            displayLimit = 10_000
            displayed = []
            lastRevision = nil
            textView.string = ""
        }
        historyTask = Task { [weak self, logStore] in
            let page = await logStore.history(before: before, sources: sources)
            guard let self, !Task.isCancelled, self.historyGeneration == generation else { return }
            if !reset { self.displayLimit += page.entries.count }
            self.displayed = page.entries + self.displayed
            self.earlierButton.isEnabled = page.hasEarlier
            self.historyTask = nil
            self.render(self.displayed, replacing: true, keepBottom: reset)
            self.lastRevision = nil
            self.refreshLogs()
        }
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
        guard historyTask == nil else { return }
        let snapshot = logStore.snapshot(sources: currentSources)
        guard snapshot.revision != lastRevision else { return }
        lastRevision = snapshot.revision
        let latestID = displayed.last?.id ?? 0
        let added = snapshot.entries.filter { $0.id > latestID }
        guard !added.isEmpty else { return }
        let keepBottom = isScrolledNearBottom()
        displayed += added
        if keepBottom && displayed.count > displayLimit + 2_500 {
            displayed.removeFirst(displayed.count - displayLimit)
            earlierButton.isEnabled = true
            render(displayed, replacing: true, keepBottom: true)
        } else {
            render(added, replacing: false, keepBottom: keepBottom)
        }
    }

    private func render(_ entries: [SystemLogStore.Entry], replacing: Bool, keepBottom: Bool) {
        guard let textContainer = textView.textContainer else { return }
        let attributed = NSMutableAttributedString()
        let defaultFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let defaultColor = NSColor.labelColor

        for entry in entries {
            let sourceColor = Self.sourceColors[entry.source] ?? .systemGray

            let timestamp = NSAttributedString(
                string: "[\(Self.timestampFormatter.string(from: entry.timestamp))] ",
                attributes: [
                    .font: defaultFont,
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )

            let prefix = NSAttributedString(string: "[\(entry.source)] ", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
                .foregroundColor: sourceColor
            ])

            let line = NSAttributedString(string: "\(entry.line)\n", attributes: [
                .font: defaultFont,
                .foregroundColor: defaultColor
            ])

            attributed.append(timestamp)
            attributed.append(prefix)
            attributed.append(line)
        }

        let scrollView = textView.enclosingScrollView
        let origin = scrollView?.contentView.bounds.origin ?? .zero
        let oldHeight = textView.layoutManager?.usedRect(for: textContainer).height ?? 0
        if replacing { textView.textStorage?.setAttributedString(attributed) }
        else { textView.textStorage?.append(attributed) }
        textView.layoutManager?.ensureLayout(for: textContainer)
        if keepBottom { textView.scrollToEndOfDocument(nil) }
        else if replacing, let scrollView {
            let height = textView.layoutManager?.usedRect(for: textContainer).height ?? oldHeight
            scrollView.contentView.scroll(to: NSPoint(x: origin.x, y: max(0, origin.y + height - oldHeight)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func isScrolledNearBottom() -> Bool {
        guard let scrollView = textView.enclosingScrollView else { return true }
        let visibleMaxY = scrollView.contentView.bounds.maxY
        let contentHeight = textView.bounds.height
        return contentHeight - visibleMaxY < 40
    }
}
