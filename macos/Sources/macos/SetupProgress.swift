import AppKit
import os

/// Thread-safe cancellation token with active task management.
final class CancellationToken: @unchecked Sendable {
    private struct State {
        var cancelled = false
        var activeTask: URLSessionDownloadTask?
    }
    private let lock = os.OSAllocatedUnfairLock(initialState: State())

    var isCancelled: Bool { lock.withLock { $0.cancelled } }

    var activeTask: URLSessionDownloadTask? {
        get { lock.withLock { $0.activeTask } }
        set { lock.withLock { $0.activeTask = newValue } }
    }

    func cancel() {
        lock.withLock {
            $0.cancelled = true
            $0.activeTask?.cancel()
            $0.activeTask = nil
        }
    }
}

// MARK: - Module-level setup progress UI (all UI calls must happen on main thread)

nonisolated(unsafe) private var _setupWindow: NSPanel?
nonisolated(unsafe) private var _progressBar: NSProgressIndicator?
nonisolated(unsafe) private var _titleLabel: NSTextField?
nonisolated(unsafe) private var _statusLabel: NSTextField?
nonisolated(unsafe) private var _cancelButton: NSButton?
private let _cancellation = CancellationToken()

private var setupAppDisplayName: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Xe Launcher"
}

enum SetupProgressPlacement {
    case centered
    case topTrailing
}

@MainActor
private func positionSetupPanel(_ panel: NSPanel, placement: SetupProgressPlacement) {
    switch placement {
    case .centered:
        panel.level = .floating
        panel.center()
    case .topTrailing:
        // Keep system permission prompts above this companion window and leave
        // the center of the screen unobstructed.
        panel.level = .normal
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            panel.center()
            return
        }
        let margin: CGFloat = 24
        let visibleFrame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.maxX - panel.frame.width - margin,
            y: visibleFrame.maxY - panel.frame.height - margin
        ))
    }
}

/// The shared cancellation token for the current setup. Check `isCancelled` from any thread.
var setupCancellation: CancellationToken { _cancellation }

/// Load the app icon from the .app bundle's Resources directory.
/// Tries multiple strategies: Bundle.main.resourceURL, then navigating from the executable path.
private func loadAppIcon() -> NSImage? {
    let iconName = "app.icns"

    // Strategy 1: Bundle.main.resourceURL (works when launched as .app)
    if let resourceURL = Bundle.main.resourceURL {
        let iconURL = resourceURL.appendingPathComponent(iconName)
        if let icon = NSImage(contentsOf: iconURL) { return icon }
    }

    // Strategy 2: Navigate from executable: Contents/MacOS/bin -> Contents/Resources/
    let execURL = Bundle.main.executableURL ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
    let resourcesURL = execURL
        .deletingLastPathComponent()          // MacOS/
        .deletingLastPathComponent()          // Contents/
        .appendingPathComponent("Resources")  // Contents/Resources/
    let iconURL = resourcesURL.appendingPathComponent(iconName)
    if let icon = NSImage(contentsOf: iconURL) { return icon }

    return nil
}

/// Show the setup progress window. Call from main thread.
@MainActor
func showSetupProgress(
    message: String,
    placement: SetupProgressPlacement = .centered,
    allowsCancellation: Bool = true
) {
    if let panel = _setupWindow {
        positionSetupPanel(panel, placement: placement)
        _cancelButton?.isHidden = !allowsCancellation
        panel.orderFrontRegardless()
        return
    }

    // Size window to fit the path
    let pathFont = NSFont.systemFont(ofSize: 11)
    let pathTextWidth = (message as NSString).size(withAttributes: [.font: pathFont]).width + 100
    let w = max(420, min(pathTextWidth, 700))
    let h: CGFloat = 320
    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: w, height: h),
        styleMask: [.titled, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    panel.titlebarAppearsTransparent = true
    panel.titleVisibility = .hidden
    panel.isMovableByWindowBackground = true
    panel.backgroundColor = .clear
    panel.isOpaque = false
    positionSetupPanel(panel, placement: placement)
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.hidesOnDeactivate = false
    panel.appearance = NSAppearance(named: .darkAqua)

    let vfx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
    vfx.appearance = NSAppearance(named: .darkAqua)
    vfx.material = .hudWindow
    vfx.blendingMode = .behindWindow
    vfx.state = .active
    vfx.wantsLayer = true
    vfx.layer?.cornerRadius = 16
    vfx.layer?.masksToBounds = true
    vfx.autoresizingMask = [.width, .height]
    panel.contentView = vfx

    // Add a dark overlay to make the background nearly black while keeping blur
    let overlay = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
    overlay.wantsLayer = true
    overlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor
    overlay.autoresizingMask = [.width, .height]
    vfx.addSubview(overlay)

    let pad: CGFloat = 40

    // Large centered app icon
    let iconSize: CGFloat = 80
    let iconView = NSImageView(frame: NSRect(x: (w - iconSize) / 2, y: h - iconSize - 50, width: iconSize, height: iconSize))
    if let icon = loadAppIcon() {
        iconView.image = icon
    } else {
        iconView.image = NSApp.applicationIconImage
    }
    iconView.imageScaling = .scaleProportionallyUpOrDown
    vfx.addSubview(iconView)

    // App setup title centered below icon
    let title = NSTextField(labelWithString: "Setting up \(setupAppDisplayName)")
    title.frame = NSRect(x: pad, y: h - iconSize - 80, width: w - pad * 2, height: 22)
    title.font = .systemFont(ofSize: 15, weight: .semibold)
    title.textColor = .white
    title.alignment = .center
    vfx.addSubview(title)
    _titleLabel = title

    // Path on its own line (clickable to open in Finder)
    let pathString = message.isEmpty ? "" : "App Dir: \(message)"
    let pathLabel = ClickablePathLabel(labelWithString: pathString)
    pathLabel.folderPath = message
    pathLabel.frame = NSRect(x: 20, y: h - iconSize - 103, width: w - 40, height: 16)
    pathLabel.font = .systemFont(ofSize: 11)
    pathLabel.textColor = NSColor.white.withAlphaComponent(0.45)
    pathLabel.alignment = .center
    pathLabel.lineBreakMode = .byTruncatingMiddle
    vfx.addSubview(pathLabel)

    // Status text (supports multi-line wrapping for longer messages)
    let status = NSTextField(labelWithString: "Preparing...")
    status.frame = NSRect(x: pad, y: 70, width: w - pad * 2, height: h - iconSize - 125 - 70)
    status.font = .systemFont(ofSize: 12)
    status.textColor = NSColor.white.withAlphaComponent(0.6)
    status.alignment = .center
    status.maximumNumberOfLines = 0
    status.lineBreakMode = .byWordWrapping
    status.cell?.wraps = true
    status.cell?.isScrollable = false
    vfx.addSubview(status)
    _statusLabel = status

    // Progress bar
    let bar = NSProgressIndicator(frame: NSRect(x: pad, y: 55, width: w - pad * 2, height: 6))
    bar.style = .bar
    bar.minValue = 0
    bar.maxValue = 100
    bar.doubleValue = 0
    bar.isIndeterminate = false
    bar.controlSize = .small
    vfx.addSubview(bar)
    _progressBar = bar

    // Cancel button centered at bottom
    let cancelButton = NSButton(title: "Cancel", target: SetupCancelHelper.shared, action: #selector(SetupCancelHelper.cancelSetup))
    cancelButton.frame = NSRect(x: (w - 80) / 2, y: 15, width: 80, height: 28)
    cancelButton.bezelStyle = .recessed
    cancelButton.isBordered = true
    cancelButton.contentTintColor = NSColor.white.withAlphaComponent(0.8)
    cancelButton.refusesFirstResponder = true
    cancelButton.isHidden = !allowsCancellation
    vfx.addSubview(cancelButton)
    _cancelButton = cancelButton

    // Dock visibility belongs to the running launcher, not to setup windows.
    // In particular, showing setup during the DMG installation flow must never
    // create a temporary Dock icon or override the user's launcher preference.
    panel.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    _setupWindow = panel
}

/// Update the setup progress status and/or bar. Call from main thread.
@MainActor
func updateSetupProgress(status: String? = nil, progress: Double? = nil) {
    if let status { _statusLabel?.stringValue = status }
    if let progress {
        _progressBar?.stopAnimation(nil)
        _progressBar?.isIndeterminate = false
        _progressBar?.doubleValue = progress
    }
}

/// Toggle the setup bar between determinate work and an open-ended wait.
@MainActor
func setSetupProgressIndeterminate(_ isIndeterminate: Bool) {
    _progressBar?.isIndeterminate = isIndeterminate
    if isIndeterminate {
        _progressBar?.startAnimation(nil)
    } else {
        _progressBar?.stopAnimation(nil)
    }
}

/// Possible user responses from the error dialog.
enum SetupErrorAction {
    case retry
    case cancel
}

/// Show an error in the setup progress window with Retry and Cancel buttons.
/// Blocks the calling thread until the user picks an action.
/// Must be called from a **background** thread (uses a semaphore internally).
func showSetupError(message: String) -> SetupErrorAction {
    final class Box: @unchecked Sendable { var value: SetupErrorAction = .cancel }
    let box = Box()
    let sem = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
        _statusLabel?.stringValue = message
        _statusLabel?.textColor = NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.45, alpha: 1.0)

        // Hide the progress bar while showing error
        _progressBar?.isHidden = true

        guard let cancelBtn = _cancelButton, let container = cancelBtn.superview else { sem.signal(); return }

        // Add a Retry button to the left of the existing Cancel button
        let retry = NSButton(title: "Retry", target: nil, action: nil)
        retry.bezelStyle = .rounded
        retry.tag = 1
        retry.frame = NSRect(x: 0, y: 0, width: 80, height: 28)
        container.addSubview(retry)

        // Reposition: center both buttons side by side
        let spacing: CGFloat = 12
        let totalWidth = retry.frame.width + spacing + cancelBtn.frame.width
        let containerWidth = container.frame.width
        let startX = (containerWidth - totalWidth) / 2
        let y = cancelBtn.frame.origin.y

        retry.frame = NSRect(x: startX, y: y, width: 80, height: 28)
        cancelBtn.frame = NSRect(x: startX + 80 + spacing, y: y, width: 80, height: 28)

        // Wire up the cancel button for error handling too
        cancelBtn.tag = 2
        cancelBtn.target = SetupErrorHelper.shared
        cancelBtn.action = #selector(SetupErrorHelper.buttonClicked(_:))

        retry.target = SetupErrorHelper.shared
        retry.action = #selector(SetupErrorHelper.buttonClicked(_:))

        SetupErrorHelper.shared.callback = { tag in
            box.value = tag == 1 ? .retry : .cancel
            // Remove retry button, restore cancel button
            retry.removeFromSuperview()
            cancelBtn.frame = NSRect(x: (containerWidth - 80) / 2, y: y, width: 80, height: 28)
            cancelBtn.target = SetupCancelHelper.shared
            cancelBtn.action = #selector(SetupCancelHelper.cancelSetup)
            cancelBtn.tag = 0
            _progressBar?.isHidden = false
            _statusLabel?.textColor = NSColor.white.withAlphaComponent(0.6)
            sem.signal()
        }
    }
    sem.wait()
    return box.value
}

@MainActor
private class SetupErrorHelper: NSObject {
    static let shared = SetupErrorHelper()
    var callback: ((Int) -> Void)?
    @objc func buttonClicked(_ sender: NSButton) {
        callback?(sender.tag)
        callback = nil
    }
}

/// Close the setup progress window. Call from main thread.
@MainActor
func closeSetupProgress() {
    _setupWindow?.close()
    _setupWindow = nil
    _progressBar = nil
    _titleLabel = nil
    _statusLabel = nil
    _cancelButton = nil
}

// Clickable label that opens the folder path in Finder on click
@MainActor
private class ClickablePathLabel: NSTextField {
    var folderPath: String = ""

    override func resetCursorRects() {
        if !folderPath.isEmpty {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !folderPath.isEmpty else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folderPath)
    }
}

// Helper to wire up the cancel button action
@MainActor
private class SetupCancelHelper: NSObject {
    static let shared = SetupCancelHelper()
    @objc func cancelSetup() {
        _cancellation.cancel()
        _statusLabel?.stringValue = "Cancelling..."
        _setupWindow?.close()
        _setupWindow = nil
    }
}

// MARK: - Download progress delegate

/// URLSession delegate that reports download progress and captures the downloaded file.
/// NOTE: Do NOT use a completion handler on the download task when using this delegate,
/// otherwise the delegate progress methods will not be called.
class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: (Double) -> Void
    private let completion: (URL?, Error?) -> Void

    init(onProgress: @escaping (Double) -> Void, completion: @escaping (URL?, Error?) -> Void) {
        self.onProgress = onProgress
        self.completion = completion
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Move to a stable temp location before the system deletes it
        let ext = downloadTask.response?.suggestedFilename.flatMap { URL(string: $0)?.pathExtension } ?? "tmp"
        let stableTemp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
        do {
            try FileManager.default.moveItem(at: location, to: stableTemp)
            completion(stableTemp, nil)
        } catch {
            completion(nil, error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            completion(nil, error)
        }
    }
}
