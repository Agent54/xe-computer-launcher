import Foundation

// Anti-detection patches for headless Chrome.
// Uses CDP (Chrome DevTools Protocol) over the debugging pipe to inject
// scripts that mask headless/automation signals in webview targets.
//
// Inspired by https://github.com/nicedoc/undetected-browser and
// https://github.com/Kaliiiiiiiiii-Vinyzu/patchright.
// Only executed when --headless=new is active.

extension ExternalState {

    // MARK: - Anti-Detection

    /// Comprehensive anti-detection JavaScript.
    /// Patches: navigator.webdriver, WebGL renderer, plugins, languages,
    /// permissions, chrome runtime object, and other headless signals.
    private static let antiDetectionScript = """
    (() => {
        // 1. navigator.webdriver
        Object.defineProperty(navigator, 'webdriver', {get: () => undefined});

        // 2. navigator.plugins — headless has 0 plugins, real Chrome has ≥1
        Object.defineProperty(navigator, 'plugins', {
            get: () => {
                const p = {
                    0: {type: 'application/x-google-chrome-pdf', suffixes: 'pdf', description: 'Portable Document Format', enabledPlugin: null},
                    description: 'Portable Document Format',
                    filename: 'internal-pdf-viewer',
                    length: 1,
                    name: 'Chrome PDF Plugin',
                    item: i => p[i],
                    namedItem: n => p[n],
                    [Symbol.iterator]: function*() { yield p[0]; }
                };
                p[0].enabledPlugin = p;
                return [p];
            }
        });

        // 3. navigator.mimeTypes
        Object.defineProperty(navigator, 'mimeTypes', {
            get: () => {
                const m = {
                    0: {type: 'application/pdf', suffixes: 'pdf', description: '', enabledPlugin: null},
                    length: 1,
                    item: i => m[i],
                    namedItem: n => n === 'application/pdf' ? m[0] : null,
                    [Symbol.iterator]: function*() { yield m[0]; }
                };
                return m;
            }
        });

        // 4. navigator.languages
        if (!navigator.languages || navigator.languages.length === 0) {
            Object.defineProperty(navigator, 'languages', {get: () => ['en-US', 'en']});
        }

        // 5. WebGL renderer — headless uses SwiftShader, real Chrome uses GPU
        const origGetParameter = WebGLRenderingContext.prototype.getParameter;
        WebGLRenderingContext.prototype.getParameter = function(param) {
            // UNMASKED_VENDOR_WEBGL
            if (param === 37445) return 'Google Inc. (Apple)';
            // UNMASKED_RENDERER_WEBGL
            if (param === 37446) return 'ANGLE (Apple, ANGLE Metal Renderer: Apple M1 Pro, Unspecified Version)';
            return origGetParameter.call(this, param);
        };
        if (typeof WebGL2RenderingContext !== 'undefined') {
            const origGetParameter2 = WebGL2RenderingContext.prototype.getParameter;
            WebGL2RenderingContext.prototype.getParameter = function(param) {
                if (param === 37445) return 'Google Inc. (Apple)';
                if (param === 37446) return 'ANGLE (Apple, ANGLE Metal Renderer: Apple M1 Pro, Unspecified Version)';
                return origGetParameter2.call(this, param);
            };
        }

        // 6. window.chrome — exists in real Chrome, may be incomplete in headless
        if (!window.chrome) {
            window.chrome = {};
        }
        if (!window.chrome.runtime) {
            window.chrome.runtime = {
                connect: () => {},
                sendMessage: () => {},
                onMessage: {addListener: () => {}, removeListener: () => {}, hasListener: () => false},
                id: undefined
            };
        }

        // 7. Permissions — headless denies notification permission
        const origQuery = Permissions.prototype.query;
        Permissions.prototype.query = function(params) {
            if (params.name === 'notifications') {
                return Promise.resolve({state: Notification.permission === 'denied' ? 'prompt' : Notification.permission, onchange: null});
            }
            return origQuery.call(this, params);
        };

        // 8. Connection rtt — headless may report 0
        if (navigator.connection && navigator.connection.rtt === 0) {
            Object.defineProperty(navigator.connection, 'rtt', {get: () => 50});
        }

        // 9. Screen dimensions — headless may have odd values
        if (screen.width === 0 || screen.height === 0) {
            Object.defineProperty(screen, 'width', {get: () => 1920});
            Object.defineProperty(screen, 'height', {get: () => 1080});
            Object.defineProperty(screen, 'availWidth', {get: () => 1920});
            Object.defineProperty(screen, 'availHeight', {get: () => 1080});
            Object.defineProperty(screen, 'colorDepth', {get: () => 24});
            Object.defineProperty(screen, 'pixelDepth', {get: () => 24});
        }

        // 10. Remove headless from User-Agent if present
        if (navigator.userAgent.includes('HeadlessChrome')) {
            Object.defineProperty(navigator, 'userAgent', {
                get: () => navigator.userAgent.replace('HeadlessChrome', 'Chrome')
            });
        }

        // 11. Prevent iframe contentWindow detection
        const origContentWindow = Object.getOwnPropertyDescriptor(HTMLIFrameElement.prototype, 'contentWindow');
        if (origContentWindow) {
            Object.defineProperty(HTMLIFrameElement.prototype, 'contentWindow', {
                get: function() {
                    const w = origContentWindow.get.call(this);
                    if (w) {
                        try { w.chrome = window.chrome; } catch {}
                    }
                    return w;
                }
            });
        }
    })();
    """

    /// Apply anti-detection patches to webview targets via CDP.
    /// Discovers existing targets, attaches only to webview targets, injects
    /// the anti-detection script, then reloads them so the script runs before page JS.
    func preventDetection() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.chromeRunning else { return }

            let script = Self.antiDetectionScript

            // Discover existing targets
            guard let getTargetsResp = self.sendCDP(method: "Target.getTargets"),
                  let result = getTargetsResp["result"] as? [String: Any],
                  let targetInfos = result["targetInfos"] as? [[String: Any]] else {
                self.appendLog("launcher", "CDP preventDetection: failed to get targets")
                return
            }

            self.appendLog("launcher", "CDP preventDetection: found \(targetInfos.count) targets")

            for info in targetInfos {
                let type = info["type"] as? String ?? ""
                let targetId = info["targetId"] as? String ?? ""
                let url = info["url"] as? String ?? ""

                // Only patch webview targets (third-party pages loaded in controlled frames)
                guard type == "webview" else { continue }

                self.appendLog("launcher", "CDP preventDetection: patching webview id=\(targetId) url=\(url)")

                guard let attachResp = self.sendCDP(method: "Target.attachToTarget", params: [
                    "targetId": targetId,
                    "flatten": true
                ]),
                let attachResult = attachResp["result"] as? [String: Any],
                let sessionId = attachResult["sessionId"] as? String else {
                    // Attach failed — webview may be a child target that requires
                    // attaching through the parent (IWA app) session instead.
                    self.appendLog("launcher", "CDP preventDetection: direct attach failed for \(targetId), trying via parent")
                    self.patchWebviewViaParent(targetId: targetId, script: script, targetInfos: targetInfos)
                    continue
                }

                self.injectAntiDetection(sessionId: sessionId, targetId: targetId, type: type, script: script, reload: true)
            }
        }
    }

    /// Try to attach to a webview through its parent target's session.
    /// Webviews inside IWA controlled frames may only be attachable via the parent session.
    private func patchWebviewViaParent(targetId: String, script: String, targetInfos: [[String: Any]]) {
        // Find the parent (app) target
        for info in targetInfos {
            let type = info["type"] as? String ?? ""
            let parentId = info["targetId"] as? String ?? ""
            guard type == "app" else { continue }

            // Attach to the parent app target first
            guard let parentAttach = sendCDP(method: "Target.attachToTarget", params: [
                "targetId": parentId,
                "flatten": true
            ]),
            let parentResult = parentAttach["result"] as? [String: Any],
            let parentSession = parentResult["sessionId"] as? String else {
                appendLog("launcher", "CDP preventDetection: failed to attach to parent app \(parentId)")
                continue
            }

            // Now try to attach to the webview through the parent session
            guard let childAttach = sendCDP(method: "Target.attachToTarget", params: [
                "targetId": targetId,
                "flatten": true
            ], sessionId: parentSession),
            let childResult = childAttach["result"] as? [String: Any],
            let childSession = childResult["sessionId"] as? String else {
                appendLog("launcher", "CDP preventDetection: failed to attach to webview \(targetId) via parent \(parentId)")
                continue
            }

            injectAntiDetection(sessionId: childSession, targetId: targetId, type: "webview", script: script, reload: true)
            return
        }
        appendLog("launcher", "CDP preventDetection: no parent found for webview \(targetId)")
    }

    /// Inject the anti-detection script into a target session.
    private func injectAntiDetection(sessionId: String, targetId: String, type: String, script: String, reload: Bool) {
        // Override User-Agent at the network level (HTTP headers).
        // The JS patch only fixes navigator.userAgent; servers see the real header.
        // Get current UA and always strip "HeadlessChrome" → "Chrome".
        let browserVersionResp = sendCDP(method: "Browser.getVersion")
        let rawUA = (browserVersionResp?["result"] as? [String: Any])?["userAgent"] as? String ?? ""
        let fixedUA = rawUA.replacingOccurrences(of: "HeadlessChrome", with: "Chrome")
        appendLog("launcher", "CDP UA: \(rawUA.prefix(80))... → fixed: \(fixedUA.prefix(80))...")

        // Enable Network domain and override UA
        sendCDP(method: "Network.enable", sessionId: sessionId)
        let uaResp = sendCDP(method: "Emulation.setUserAgentOverride", params: [
            "userAgent": fixedUA,
            "acceptLanguage": "en-US,en;q=0.9",
            "platform": "macOS"
        ], sessionId: sessionId)
        appendLog("launcher", "CDP Emulation.setUserAgentOverride on \(type)/\(targetId): \(uaResp?["error"] ?? "ok")")

        // Enable Page domain
        let pageEnableResp = sendCDP(method: "Page.enable", sessionId: sessionId)
        let pageEnabled = (pageEnableResp?["error"] == nil)

        if pageEnabled {
            let addResp = sendCDP(method: "Page.addScriptToEvaluateOnNewDocument", params: [
                "source": script,
                "worldName": "",
                "runImmediately": true
            ], sessionId: sessionId)
            appendLog("launcher", "CDP Page.addScript on \(type)/\(targetId): \(addResp?["error"] ?? "ok")")

            if reload {
                sendCDP(method: "Page.reload", sessionId: sessionId)
                appendLog("launcher", "CDP Page.reload on \(type)/\(targetId)")
            }
        }

        // Also evaluate immediately
        let evalResp = sendCDP(method: "Runtime.evaluate", params: [
            "expression": script,
            "allowUnsafeEvalBlockedByCSP": true
        ], sessionId: sessionId)
        appendLog("launcher", "CDP Runtime.evaluate on \(type)/\(targetId): \(evalResp?["error"] ?? "ok")")
    }
}
