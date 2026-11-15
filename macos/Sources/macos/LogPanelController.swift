import AppKit

@MainActor
final class LogPanelController: NSWindowController, NSWindowDelegate {
    private let textView = NSTextView()
    private let logStore: SystemLogStore
    private let earlierButton = NSButton()
    private let issuesFilter = NSButton(checkboxWithTitle: "Warnings & Errors Only", target: nil, action: nil)
    private static let pageSize = 160
    private static let liveLimit = 480
    private static let liveCharacterLimit = 256 * 1024
    private var liveTask: Task<Void, Never>?
    private var liveCursor: UInt64 = 0
    private var liveUpdateDeferred = false
    private var currentSources: Set<String>?
    private var displayed: [SystemLogStore.Entry] = []
    private var historyTask: Task<Void, Never>?
    private var historyGeneration = 0
    private var displayLimit = liveLimit
    private var characterLimit = liveCharacterLimit
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

    func present(showingIssues: Bool = false) {
        if let window, let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let winSize = window.frame.size
            let x = screenFrame.midX - winSize.width / 2
            let y = screenFrame.midY - winSize.height / 2
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        let updated = prepareContents(showingIssues: showingIssues)
        showWindow(nil)
        window?.orderFrontRegardless()
        if updated { textView.scrollToEndOfDocument(nil) }
    }

    @discardableResult
    func prepareContents(showingIssues: Bool) -> Bool {
        let filterChanged = showingIssues && (currentSources != nil || issuesFilter.state != .on)
        if showingIssues {
            currentSources = nil
            segmentedControl.selectedSegment = 0
            issuesFilter.state = .on
        }
        if liveTask == nil {
            startRefreshing()
        } else if !filterChanged {
            return false
        }
        showRecentLogs()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        liveTask?.cancel()
        liveTask = nil
        historyTask?.cancel()
        historyTask = nil
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
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isRichText = true
        textView.usesFontPanel = false
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrollPositionChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        contentView.addSubview(scrollView)

        earlierButton.title = "Load earlier"
        earlierButton.bezelStyle = .rounded
        earlierButton.target = self
        earlierButton.action = #selector(loadEarlier)
        earlierButton.translatesAutoresizingMaskIntoConstraints = false
        earlierButton.isEnabled = false
        contentView.addSubview(earlierButton)

        issuesFilter.target = self
        issuesFilter.action = #selector(issuesFilterChanged)
        issuesFilter.sendAction(on: .leftMouseDown)
        issuesFilter.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(issuesFilter)

        NSLayoutConstraint.activate([
            segmentedControl.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            segmentedControl.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),

            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: earlierButton.topAnchor, constant: -8),
            earlierButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            earlierButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            issuesFilter.centerYAnchor.constraint(equalTo: earlierButton.centerYAnchor),
            issuesFilter.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8)
        ])
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        let idx = sender.selectedSegment
        guard tabSources.indices.contains(idx) else { return }
        currentSources = tabSources[idx]
        showRecentLogs()
    }

    @objc private func loadEarlier() { loadHistory() }

    @objc private func issuesFilterChanged() { showRecentLogs() }

    private var minimumSeverity: SystemLogSeverity { issuesFilter.state == .on ? .warning : .info }

    private func showRecentLogs() {
        historyTask?.cancel()
        historyTask = nil
        historyGeneration += 1
        let (page, cursor) = logStore.recentPage(limit: Self.pageSize, sources: currentSources, minimumSeverity: minimumSeverity)
        liveCursor = cursor
        liveUpdateDeferred = false
        displayLimit = Self.liveLimit
        characterLimit = Self.liveCharacterLimit
        displayed = page.entries
        render(page.entries, edit: .replace, keepBottom: true)
        earlierButton.isEnabled = page.hasEarlier || (displayed.first.map { $0.id > 1 } ?? (cursor > 0))
        // Only ask disk for the first page if there was nothing to paint from memory.
        if displayed.isEmpty && cursor > 0 { loadHistory(initial: true) }
    }

    private func loadHistory(initial: Bool = false) {
        guard historyTask == nil else { return }
        historyGeneration += 1
        let generation = historyGeneration
        let before = displayed.first?.id ?? (liveCursor + 1)
        let sources = currentSources
        let severity = minimumSeverity
        earlierButton.isEnabled = false
        historyTask = Task { [weak self, logStore] in
            let page = await logStore.history(before: before, limit: Self.pageSize, sources: sources, minimumSeverity: severity)
            guard let self, !Task.isCancelled, self.historyGeneration == generation else { return }
            self.historyTask = nil
            guard self.displayed.first.map({ $0.id >= before }) ?? true else { return }
            var size = 0
            let entries = page.entries.reversed().prefix { entry in
                size += entry.line.utf8.count + 100
                return size <= 64 * 1024
            }.reversed()
            let batch = Array(entries)
            self.earlierButton.isEnabled = page.hasEarlier || batch.count < page.entries.count
            guard !batch.isEmpty else { return }
            self.displayLimit += batch.count
            self.characterLimit += min(size, 64 * 1024)
            let keepBottom = initial && self.isScrolledNearBottom()
            self.displayed.insert(contentsOf: batch, at: 0)
            self.render(batch, edit: .prepend, keepBottom: keepBottom)
        }
    }

    private func startRefreshing() {
        let updates = logStore.updates()
        liveTask = Task { [weak self] in
            for await _ in updates {
                guard !Task.isCancelled else { return }
                self?.refreshLogs()
                // Coalesce bursts to keep the main thread free between paints.
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    @objc private func scrollPositionChanged() {
        if liveUpdateDeferred && isScrolledNearBottom() { refreshLogs() }
    }

    private func refreshLogs() {
        let (page, cursor) = logStore.recentPage(after: liveCursor, limit: Self.pageSize,
                                                sources: currentSources, minimumSeverity: minimumSeverity)
        guard !page.entries.isEmpty else {
            liveCursor = cursor
            liveUpdateDeferred = false
            return
        }
        let keepBottom = isScrolledNearBottom()
        let atLimit = displayed.count + page.entries.count > displayLimit + Self.pageSize
            || (textView.textStorage?.length ?? 0) > characterLimit
        if !keepBottom && (page.hasEarlier || atLimit) {
            liveUpdateDeferred = true
            return
        }
        liveUpdateDeferred = false
        liveCursor = cursor
        if page.hasEarlier || atLimit {
            historyTask?.cancel()
            historyTask = nil
            historyGeneration += 1
            displayLimit = Self.liveLimit
            characterLimit = Self.liveCharacterLimit
            let (tail, tailCursor) = logStore.recentPage(limit: Self.liveLimit, sources: currentSources, minimumSeverity: minimumSeverity)
            displayed = tail.entries
            liveCursor = tailCursor
            earlierButton.isEnabled = true
            render(displayed, edit: .replace, keepBottom: true)
        } else {
            displayed += page.entries
            render(page.entries, edit: .append, keepBottom: keepBottom)
        }
    }

    private enum Edit { case replace, append, prepend }

    private func render(_ entries: [SystemLogStore.Entry], edit: Edit, keepBottom: Bool) {
        guard let storage = textView.textStorage else { return }
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

            let severity = entry.severity
            let marker = severity == .info ? "" : severity == .error ? "⛔︎ " : "⚠︎ "
            let line = NSAttributedString(string: "\(marker)\(entry.line)\n", attributes: [
                .font: defaultFont,
                .foregroundColor: severity == .error ? NSColor.systemRed : severity == .warning ? NSColor.systemOrange : defaultColor
            ])

            attributed.append(timestamp)
            attributed.append(prefix)
            attributed.append(line)
        }

        let scrollView = textView.enclosingScrollView
        let origin = scrollView?.contentView.bounds.origin ?? .zero
        let oldHeight = textView.bounds.height
        switch edit {
        case .replace: storage.setAttributedString(attributed)
        case .append: storage.append(attributed)
        case .prepend: storage.insert(attributed, at: 0)
        }
        if keepBottom { textView.scrollToEndOfDocument(nil) }
        else if edit == .prepend, let scrollView {
            if let container = textView.textContainer { textView.layoutManager?.ensureLayout(for: container) }
            let height = textView.bounds.height
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
