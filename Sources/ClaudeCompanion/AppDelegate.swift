import AppKit
import WebKit
import Carbon.HIToolbox
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: CompanionPanel!
    private var webView: WKWebView!
    private var statusItem: NSStatusItem!
    private var hotKey: GlobalHotKey!
    private var toggleMenuItem: NSMenuItem!
    /// Open sign-in popups, retained so they aren't deallocated while visible.
    private var popups: [PopupWindowController] = []
    /// URLs received before launch finished (see `application(_:open:)`).
    private var pendingURLs: [URL] = []

    // Tunables for the floating window.
    private let panelSize = NSSize(width: 440, height: 620)
    /// Gap between the bottom of the window and the top of the Dock. Measured off
    /// the Wispr Flow panel, which rests ~16pt above it.
    private let bottomMargin: CGFloat = 20
    private let cornerRadius: CGFloat = 22
    private let claudeURL = URL(string: "https://claude.ai/new")!
    private let savedFrameKey = "panelFrame"
    private let followKey = "followsActiveWindow"

    /// Current height of the panel. Starts compact-ish and is driven by the page:
    /// composer-only when there's no conversation, full height once there is.
    private var contentHeight: CGFloat = 620
    /// Compact mode is a single rounded bar: the window frame is the composer's
    /// frame, so there is no gutter between them.
    private let compactPadding: CGFloat = 0
    /// Deadband for panel resizing, to stop measure-resize-remeasure oscillation.
    private let heightTolerance: CGFloat = 5

    /// PID of the most recent app that wasn't us - i.e. what the user is working in.
    private var lastActiveAppPID: pid_t?
    private var followMenuItem: NSMenuItem!
    private var loginItemMenuItem: NSMenuItem!
    private var translucentChatMenuItem: NSMenuItem!
    private let translucentChatKey = "translucentChat"

    /// On by default, so a conversation looks like the compact bar it grew out of -
    /// same blur, same surface - rather than switching to a solid black window.
    ///
    /// The cost is that claude.ai's fade scrims are drawn to blend into its own
    /// opaque surface, so they have to be neutralised (see `WebChrome`). Turning
    /// this off restores that native surface, which is the guaranteed-clean
    /// fallback if a new artefact ever slips through.
    private var translucentChat: Bool {
        get { UserDefaults.standard.object(forKey: translucentChatKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: translucentChatKey) }
    }

    /// When on, the window appears at whatever window the user is working in.
    private var followsActiveWindow: Bool {
        get { UserDefaults.standard.object(forKey: followKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: followKey) }
    }

    /// Lets `./toggle.sh` (or any `notifyutil`/osascript caller) toggle the panel
    /// without a key press. Used for verification and as an escape hatch when
    /// every candidate hot key is already taken.
    static let toggleNotification = Notification.Name("co.rockflour.claudecompanion.toggle")

    // A desktop Safari UA. claude.ai gates some flows on a recognised browser;
    // presenting as Safari avoids "unsupported browser" states in the WKWebView.
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("launching Claude Companion")
        trackActiveApp()
        buildStatusItem()
        Log.info("status item built")
        buildPanel()
        Log.info("panel built")
        registerHotKey()
        Log.info("hot key setup done")

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(toggle),
            name: Self.toggleNotification,
            object: nil
        )
        // Start hidden; the user summons it with the hot key - unless a URL
        // launched us, which runs now that there is something to act on.
        let urls = pendingURLs
        pendingURLs = []
        if !urls.isEmpty { application(NSApp, open: urls) }
    }

    // MARK: - Tracking what the user is working in

    /// Remembers the frontmost application as it changes.
    ///
    /// This has to be observed continuously rather than read when the hot key
    /// fires: showing the panel activates *us*, so by then the app the user was
    /// working in is no longer frontmost.
    private func trackActiveApp() {
        let selfPID = ProcessInfo.processInfo.processIdentifier

        if let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           frontmost != selfPID {
            lastActiveAppPID = frontmost
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  app.processIdentifier != selfPID else { return }
            self?.lastActiveAppPID = app.processIdentifier
        }
    }

    // MARK: - Menu bar item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "bubble.left.and.bubble.right",
                accessibilityDescription: "Claude Companion"
            )
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        toggleMenuItem = NSMenuItem(
            title: "Show / Hide Claude",
            action: #selector(toggle),
            keyEquivalent: ""
        )
        menu.addItem(toggleMenuItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "New Chat  (⌘N)", action: #selector(newChat(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Reload", action: #selector(reload), keyEquivalent: "")
        followMenuItem = NSMenuItem(
            title: "Follow Active Window",
            action: #selector(toggleFollow),
            keyEquivalent: ""
        )
        followMenuItem.state = followsActiveWindow ? .on : .off
        menu.addItem(followMenuItem)
        loginItemMenuItem = NSMenuItem(
            title: "Start at Login",
            action: #selector(toggleLoginItem),
            keyEquivalent: ""
        )
        menu.addItem(loginItemMenuItem)
        translucentChatMenuItem = NSMenuItem(
            title: "Translucent Chat",
            action: #selector(toggleTranslucentChat),
            keyEquivalent: ""
        )
        translucentChatMenuItem.state = translucentChat ? .on : .off
        menu.addItem(translucentChatMenuItem)
        menu.addItem(
            withTitle: "Reset Position",
            action: #selector(resetPosition),
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: "Quit Claude Companion",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
        updateLoginItemState()
    }

    /// Reflects the hot key we actually got, so the shortcut is never a mystery.
    private func updateToggleTitle() {
        if let label = hotKey.activeCombo?.label {
            toggleMenuItem.title = "Show / Hide Claude  (\(label))"
        } else {
            toggleMenuItem.title = "Show / Hide Claude  (no shortcut available)"
        }
    }

    // MARK: - Floating panel + web view

    private func buildPanel() {
        panel = CompanionPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        // Show on every Space and over full-screen apps.
        // NB: .canJoinAllSpaces and .moveToActiveSpace are mutually exclusive -
        // setting both raises an AppKit exception.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Translucent backdrop, clipped to soft corners. The web content above it is
        // made transparent by injected CSS, so this blur is what you actually see.
        let container = NSVisualEffectView()
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = cornerRadius
        // Continuous ("squircle") curvature, as macOS uses for its own panels. A
        // circular radius meets the straight edge abruptly, which reads as a hard
        // corner against a light backdrop.
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        // The layer mask above rounds the *contents* only - the backdrop blur keeps
        // sampling the full square window bounds, which shows as a bright halo
        // around the panel over a light background. maskImage clips the effect.
        container.maskImage = .roundedMask(radius: cornerRadius)
        // Hairline edge, as in the ChatGPT companion - without it the translucent
        // panel has no definition against a light background.
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor

        let config = WKWebViewConfiguration()
        // .default() is the persistent store, so the login/session survives relaunches.
        config.websiteDataStore = .default()

        // Hide the non-functional WebAuthn API so sign-in falls back to a method
        // that works in a web view. All frames, not just the main one: identity
        // providers run their capability checks inside iframes.
        config.userContentController.addUserScript(
            WKUserScript(
                source: WebChrome.noWebAuthnJS,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )

        // Inject the chrome-hiding + transparency stylesheet on every page load.
        config.userContentController.addUserScript(
            WKUserScript(
                source: WebChrome.styleJS,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        // Collapse to composer-only when there's no conversation, and report the
        // height the window should take. Skippable, to get a baseline of the page's
        // untouched layout when diagnosing.
        if ProcessInfo.processInfo.environment["CLAUDE_COMPANION_NO_COMPACT"] == nil {
            config.userContentController.addUserScript(
                WKUserScript(
                    source: WebChrome.layoutJS,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true
                )
            )
        } else {
            Log.info("compact mode disabled for diagnosis")
        }
        config.userContentController.add(self, name: "layout")

        webView = WKWebView(frame: container.bounds, configuration: config)
        webView.customUserAgent = userAgent
        // Clear, so the vibrancy behind the web view is visible through the page.
        webView.underPageBackgroundColor = .clear

        // On macOS, a clear `underPageBackgroundColor` is not enough on its own -
        // WKWebView still paints an opaque backdrop, and `_setDrawsBackground:` is
        // the only switch that disables it. Private API, so it is probed for first:
        // if a future macOS drops it we log and stay opaque instead of crashing.
        let drawsBackground = NSSelectorFromString("_setDrawsBackground:")
        if webView.responds(to: drawsBackground) {
            webView.setValue(false, forKey: "drawsBackground")
            Log.info("web view background disabled - translucency active")
        } else {
            Log.warn("_setDrawsBackground: unavailable - panel will be opaque")
        }
        // Round the web view's own layer as well as the container's. WKWebView
        // renders out of process and composites its own layer, which the parent's
        // corner mask does not reliably clip - leaving its square backing visible
        // as light wedges in the four corners.

        // Round the web view's own layer as well as the container's. WKWebView
        // renders out of process and composites its own layer, which the parent's
        // corner mask does not reliably clip - leaving its square backing visible
        // as light wedges in the four corners.
        webView.wantsLayer = true
        webView.layer?.cornerRadius = cornerRadius
        webView.layer?.cornerCurve = .continuous
        webView.layer?.masksToBounds = true

        webView.uiDelegate = self
        webView.navigationDelegate = self
        container.addSubview(webView)

        // Auto Layout rather than autoresizing: `container` starts at zero size, so
        // an autoresizing mask has no sane ratio to scale the web view from.
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        panel.contentView = container

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelMoved),
            name: NSWindow.didMoveNotification,
            object: panel
        )

        // Overridable so a specific conversation can be reopened when diagnosing
        // chat-view rendering, which /new cannot show.
        let start = ProcessInfo.processInfo.environment["CLAUDE_COMPANION_URL"]
            .flatMap(URL.init(string:)) ?? claudeURL
        webView.load(URLRequest(url: start))
    }

    private func positionPanel() {
        // Following the active window is the whole point of the feature, so it takes
        // precedence over any position the user has dragged the window to.
        if followsActiveWindow {
            panel.setFrame(defaultFrame(), display: true)
            return
        }

        if let saved = UserDefaults.standard.string(forKey: savedFrameKey) {
            let frame = NSRectFromString(saved)
            // Only reuse it if that area still belongs to a connected screen -
            // otherwise unplugging a monitor would strand the window off-screen.
            if !frame.isEmpty,
               NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                panel.setFrame(frame, display: true)
                return
            }
        }
        panel.setFrame(defaultFrame(), display: true)
    }

    /// The screen to place the panel on.
    ///
    /// The window the user is working in decides *which display* - so the panel
    /// follows them across monitors - but not where on it. Placement is the same
    /// screen-centred spot regardless, which is what makes it predictable.
    private func targetScreen() -> NSScreen? {
        if followsActiveWindow,
           let pid = lastActiveAppPID,
           let (_, screen) = ActiveWindow.focusedWindow(ofPID: pid) {
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName
                ?? "pid \(pid)"
            Log.info("target screen: the one showing \(name)")
            return screen
        }
        // `NSScreen.main` follows the key window, which is unreliable for a
        // background app, so fall back to the screen under the pointer.
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    /// Horizontally centred on the screen and resting just above the Dock - where
    /// macOS companion utilities like Wispr Flow sit, close to hand without
    /// covering what you're reading.
    private func defaultFrame() -> NSRect {
        // `visibleFrame` already excludes the Dock and menu bar, so this stays just
        // above the Dock wherever the Dock happens to live.
        guard let visible = targetScreen()?.visibleFrame else {
            return NSRect(origin: .zero, size: panelSize)
        }

        let x = visible.midX - panelSize.width / 2
        let highestY = visible.maxY - contentHeight
        let y = min(visible.minY + bottomMargin, highestY)
        Log.info("frame on \(Int(visible.width))x\(Int(visible.height)) screen: "
            + "x=\(Int(x)) y=\(Int(y)) (gap above Dock: \(Int(y - visible.minY)))")
        return NSRect(x: x, y: y, width: panelSize.width, height: contentHeight)
    }

    /// Registers the app to launch at login.
    ///
    /// `SMAppService` needs no helper bundle or permission prompt, but it does
    /// require the app to be installed in /Applications and properly signed - so a
    /// failure is reported rather than swallowed, with the manual route as a
    /// fallback.
    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                Log.info("start at login: disabled")
            } else {
                try service.register()
                Log.info("start at login: enabled")
            }
        } catch {
            Log.error("start at login failed: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login item"
            alert.informativeText = error.localizedDescription
                + "\n\nYou can set this yourself in System Settings → General → "
                + "Login Items, under \"Open at Login\"."
            alert.runModal()
        }
        updateLoginItemState()
    }

    private func updateLoginItemState() {
        loginItemMenuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleTranslucentChat() {
        translucentChat.toggle()
        translucentChatMenuItem.state = translucentChat ? .on : .off
        applyChatOpacity()
        Log.info("translucent chat: \(translucentChat)")
    }

    /// Pushes the current setting into the page. Runs after every load too, since
    /// the class lives on <html> and a fresh document starts without it.
    private func applyChatOpacity() {
        let solid = !translucentChat
        webView.evaluateJavaScript(
            "document.documentElement.classList.toggle('cc-solid', \(solid))"
        ) { _, _ in }
    }

    @objc private func toggleFollow() {
        followsActiveWindow.toggle()
        followMenuItem.state = followsActiveWindow ? .on : .off
        Log.info("follow active window: \(followsActiveWindow)")
    }

    @objc private func resetPosition() {
        UserDefaults.standard.removeObject(forKey: savedFrameKey)
        panel.setFrame(defaultFrame(), display: true)
        Log.info("position reset to default")
    }

    /// Remembers a window the user has dragged, so it reappears where they left it.
    @objc private func panelMoved() {
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: savedFrameKey)
    }

    // MARK: - Hot key

    private func registerHotKey() {
        hotKey = GlobalHotKey()
        // ⌥Space is preferred, but the ChatGPT desktop app claims it system-wide.
        // Fall back through nearby combos so there is always a working shortcut.
        hotKey.registerFirstAvailable([
            .optionSpace,
            .commandOptionSpace,
            .controlOptionSpace,
            .optionC,
            .commandOptionC,
        ])
        hotKey.onPress = { [weak self] in self?.toggle() }
        updateToggleTitle()
    }

    // MARK: - Actions

    @objc private func toggle() {
        if panel.isVisible {
            Log.info("hiding panel")
            panel.orderOut(nil)
        } else {
            Log.info("showing panel")
            positionPanel()
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            // Focus the web content so typing goes straight into Claude.
            panel.makeFirstResponder(webView)
            nudgeRepaint()
        }
    }

    /// Handles `claudecompanion://toggle` (and `://show`, `://hide`), so the window
    /// can be summoned from Raycast, Shortcuts, or the CLI as well as the hot key.
    ///
    /// A URL that launches the app arrives *before* `applicationDidFinishLaunching`,
    /// when there is no panel or web view yet to act on, so it is held until then.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard panel != nil else {
            pendingURLs += urls
            return
        }
        for url in urls {
            switch url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
            case "show": if !panel.isVisible { toggle() }
            case "hide": if panel.isVisible { toggle() }
            case "check": runHealthCheck()
            case "test-paste": testPaste()
            case "test-newchat": testNewChat()
            case "test-newchat-button": testNewChatButton()
            case "test-enter": testEnterToSend()
            case "scroll":
                // Parks the transcript so text sits behind the sticky composer,
                // which is the only state where the backdrop blur is visible.
                webView.evaluateJavaScript("""
                    var sc = document.querySelector('div.overflow-y-auto');
                    if (sc) { sc.scrollTop = Math.max(0, sc.scrollHeight - sc.clientHeight - 220); }
                    var f = document.querySelector('div.sticky.bottom-0');
                    f ? getComputedStyle(f).webkitBackdropFilter || getComputedStyle(f).backdropFilter : 'no footer'
                """) { result, _ in
                    Log.info("scroll: footer backdrop-filter = \(result as? String ?? "?")")
                }
            case "snapshot": captureSnapshots()
            case "screengrab": captureOnScreen()
            case "login-item": toggleLoginItem()
            default: toggle()
            }
        }
    }

    @objc private func reload() {
        webView.reload()
    }

    /// Starts a fresh conversation. Reachable from the menu, the in-window button,
    /// and ⌘N - the panel dispatches that through the responder chain, which is why
    /// this takes a sender and is not private.
    @objc func newChat(_ sender: Any?) {
        Log.info("new conversation requested")
        goHome()
    }

    /// Writes what the app is actually drawing to `/tmp`, separating the two layers:
    /// what the *page* renders, and what the *window* composites. Geometry logs
    /// report correct rects whether or not anything was painted, so this is the only
    /// way to tell a layout bug from a rendering one.
    private func captureSnapshots() {
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        webView.takeSnapshot(with: config) { image, error in
            if let error {
                Log.error("web snapshot failed: \(error.localizedDescription)")
                return
            }
            guard let image, let png = Self.png(from: image) else {
                Log.error("web snapshot produced no image")
                return
            }
            try? png.write(to: URL(fileURLWithPath: "/tmp/cc-web.png"))
            Log.info("web snapshot: \(Int(image.size.width))x\(Int(image.size.height))")
        }

        guard let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "/tmp/cc-window.png"))
            Log.info("window snapshot: \(Int(view.bounds.width))x\(Int(view.bounds.height))")
        }
    }

    /// Captures the panel as the window server actually composites it, including
    /// the vibrancy and the out-of-process web content.
    ///
    /// `cacheDisplay` renders the view hierarchy offscreen and misses both, so it
    /// cannot show corner artefacts; this can.
    private func captureOnScreen() {
        let windowID = CGWindowID(panel.windowNumber)
        guard panel.isVisible, panel.windowNumber > 0 else {
            Log.warn("screengrab: panel is not on screen")
            return
        }
        // Two variants: without framing (the window's own pixels) and with it
        // (shadow and any backing the window server draws around them).
        let variants: [(String, CGWindowImageOption)] = [
            ("/tmp/cc-screen.png", [.boundsIgnoreFraming, .bestResolution]),
            ("/tmp/cc-screen-framed.png", [.bestResolution]),
        ]
        for (path, options) in variants {
            guard let image = CGWindowListCreateImage(
                .null, [.optionIncludingWindow], windowID, options
            ) else {
                Log.error("screengrab: capture returned nothing for \(path)")
                continue
            }
            let rep = NSBitmapImageRep(cgImage: image)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
                Log.info("screengrab: \(image.width)x\(image.height) -> \(path)")
            }
        }
    }

    private static func png(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Synthesises a real Cmd-V and reports whether it reached the page.
    ///
    /// Exercises the same path a keystroke takes - the window's key-equivalent
    /// handling - rather than calling `paste:` directly, which would bypass the part
    /// that was actually broken.
    private func testPaste() {
        // Focus the composer first: `paste:` only inserts into a focused editable, so
        // without focus the action dispatches successfully and still does nothing -
        // which looks like a pass while proving nothing. evaluateJavaScript is
        // asynchronous, so the keystroke has to wait for its completion.
        webView.evaluateJavaScript(
            "var i = document.querySelector('[data-testid=\"chat-input\"]'); if (i) i.focus(); !!i"
        ) { [weak self] focused, _ in
            Log.info("test paste: composer focused = \(focused as? Bool ?? false)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self?.sendPasteKeystroke()
            }
        }
    }

    /// Verifies Enter-to-send without posting anything.
    ///
    /// Types into the composer so the send button becomes enabled, dispatches a real
    /// Enter keydown with the handler in dry-run mode, reports whether it would have
    /// sent, then restores what was there. Testing with an empty composer proves
    /// nothing: the handler deliberately stands aside when there is nothing to send.
    ///
    /// The steps are separate evaluations because the button's enabled state is React
    /// state - it does not update within the same turn as the typing that caused it.
    private func testEnterToSend() {
        let type = """
        (() => {
          const input = document.querySelector('[data-testid="chat-input"]');
          if (!input) return 'composer not found';
          window.__ccDraft = input.textContent || '';
          window.__ccDryRun = true;
          window.__ccLastEnter = 'not intercepted';
          input.focus();
          document.execCommand('selectAll', false, null);
          document.execCommand('insertText', false, 'enter-key probe');
          return 'typed';
        })()
        """

        let fire = """
        (() => {
          const input = document.querySelector('[data-testid="chat-input"]');
          const button = document.querySelector('[data-testid="chat-input-send"]');
          const enabled = button ? !button.disabled : false;
          const plain = new KeyboardEvent('keydown', {
            key: 'Enter', code: 'Enter', keyCode: 13, which: 13,
            bubbles: true, cancelable: true
          });
          input.dispatchEvent(plain);
          const plainVerdict = window.__ccLastEnter
            + ' (defaultPrevented=' + plain.defaultPrevented + ')';

          window.__ccLastEnter = 'not intercepted';
          const shifted = new KeyboardEvent('keydown', {
            key: 'Enter', code: 'Enter', keyCode: 13, which: 13,
            shiftKey: true, bubbles: true, cancelable: true
          });
          input.dispatchEvent(shifted);
          const shiftVerdict = window.__ccLastEnter
            + ' (defaultPrevented=' + shifted.defaultPrevented + ')';

          const verdict = 'send enabled=' + enabled
            + ' | Enter: ' + plainVerdict
            + ' | Shift-Enter: ' + shiftVerdict;

          input.focus();
          document.execCommand('selectAll', false, null);
          document.execCommand('delete', false, null);
          if (window.__ccDraft) document.execCommand('insertText', false, window.__ccDraft);
          window.__ccDryRun = false;
          return verdict;
        })()
        """

        webView.evaluateJavaScript(type) { [weak self] result, _ in
            Log.info("test enter: \(result as? String ?? "?")")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self?.webView.evaluateJavaScript(fire) { result, error in
                    if let error {
                        Log.error("test enter: \(error.localizedDescription)")
                    } else {
                        Log.info("test enter: \(result as? String ?? "?")")
                    }
                }
            }
        }
    }

    /// Clicks the injected button, which reaches `newChat` over the message handler -
    /// a different route from ⌘N, so proving one says nothing about the other.
    private func testNewChatButton() {
        webView.evaluateJavaScript(
            "var b = document.getElementById('cc-new-chat'); if (b) b.click(); !!b"
        ) { clicked, _ in
            Log.info("test button: clicked = \(clicked as? Bool ?? false)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.webView.evaluateJavaScript("location.pathname") { result, _ in
                Log.info("test button: now at \(result as? String ?? "?")")
            }
        }
    }

    /// Synthesises ⌘N and reports where the web view ended up, exercising the same
    /// path a real keystroke takes rather than calling `newChat` directly.
    private func testNewChat() {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: "n",
            charactersIgnoringModifiers: "n",
            isARepeat: false,
            keyCode: 45
        ) else {
            Log.error("test new chat: could not synthesise the event")
            return
        }
        let handled = panel.performKeyEquivalent(with: event)
        Log.info("test new chat: key equivalent handled = \(handled)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.webView.evaluateJavaScript("location.pathname") { result, _ in
                Log.info("test new chat: now at \(result as? String ?? "?")")
            }
        }
    }

    private func sendPasteKeystroke() {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: "v",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: 9
        ) else {
            Log.error("test paste: could not synthesise the event")
            return
        }

        let handled = panel.performKeyEquivalent(with: event)
        Log.info("test paste: key equivalent handled = \(handled), "
            + "first responder = \(type(of: panel.firstResponder))")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.webView.evaluateJavaScript(
                "(document.querySelector('[data-testid=\"chat-input\"]') || {}).textContent || ''"
            ) { result, _ in
                Log.info("test paste: composer now contains '\(result as? String ?? "?")'")
            }
        }
    }

    /// Forces the web view to repaint when the panel is summoned.
    ///
    /// WebKit throttles rendering for windows that have been ordered out, and can
    /// come back with a blank frame even though the DOM is laid out correctly -
    /// a failure that geometry logging cannot detect, because the rects are fine.
    private func nudgeRepaint() {
        webView.needsDisplay = true
        // Reading offsetHeight forces a synchronous layout, prompting a fresh frame.
        webView.evaluateJavaScript("void document.body.offsetHeight") { _, _ in }
    }

    /// Inspects the live page right now, rather than only at load time - the state
    /// that matters when something has gone blank after a re-render.
    private func runHealthCheck() {
        webView.evaluateJavaScript(WebChrome.verifyJS) { result, error in
            if let error {
                Log.error("health check failed: \(error.localizedDescription)")
            } else if let text = result as? String {
                Log.info("health check: \(text)")
            }
        }
        webView.evaluateJavaScript(WebChrome.wrapProbeJS) { result, _ in
            if let text = result as? String { Log.info("wrapping:\n\(text)") }
        }
        webView.evaluateJavaScript(WebChrome.horizontalProbeJS) { result, _ in
            if let text = result as? String { Log.info("horizontal:\n\(text)") }
        }
        webView.evaluateJavaScript(WebChrome.inputRowProbeJS) { result, _ in
            if let text = result as? String { Log.info("input row:\n\(text)") }
        }
        webView.evaluateJavaScript(WebChrome.composerSpacingProbeJS) { result, _ in
            if let text = result as? String { Log.info("composer spacing:\n\(text)") }
        }
        webView.evaluateJavaScript(WebChrome.sendProbeJS) { result, _ in
            if let text = result as? String { Log.info("send behaviour:\n\(text)") }
        }
        webView.evaluateJavaScript(WebChrome.tokenChainProbeJS) { result, _ in
            if let text = result as? String { Log.info("token chain:\n\(text)") }
        }
        webView.evaluateJavaScript(WebChrome.tokenProbeJS) { result, _ in
            if let text = result as? String { Log.info("text tokens:\n\(text)") }
        }
        webView.evaluateJavaScript(WebChrome.mutedProbeJS) { result, _ in
            if let text = result as? String { Log.info("low-contrast text:\n\(text)") }
        }
        webView.evaluateJavaScript(WebChrome.gradientProbeJS) { result, _ in
            if let text = result as? String { Log.info("gradients:\n\(text)") }
        }
        webView.evaluateJavaScript(WebChrome.chatChromeProbeJS) { result, _ in
            if let text = result as? String { Log.info("chat chrome:\n\(text)") }
        }
        webView.evaluateJavaScript(WebChrome.strayProbeJS) { result, _ in
            if let text = result as? String { Log.info("stray elements:\n\(text)") }
        }
        webView.evaluateJavaScript(WebChrome.chainDiagJS) { result, _ in
            if let text = result as? String { Log.info("composer chain:\n\(text)") }
        }
        webView.evaluateJavaScript("location.pathname") { result, _ in
            Log.info("health check path: \(result as? String ?? "?") "
                + "panel=\(Int(self.panel.frame.height))pt visible=\(self.panel.isVisible)")
        }
    }

    /// Returns the main frame to Claude. Also the recovery path when a sign-in
    /// flow leaves the web view somewhere unhelpful.
    private func goHome() {
        webView.load(URLRequest(url: claudeURL))
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - WKScriptMessageHandler

extension AppDelegate: WKScriptMessageHandler {
    /// Receives the page's layout state and resizes the panel to match: composer
    /// height when there's no conversation, full height once there is - and also
    /// full height for `full`, which the page sends for anything that isn't a chat
    /// at all (login, cookie consent, an error page). Without that last case a
    /// panel that had already collapsed would stay collapsed on those pages.
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "layout",
              let body = message.body as? [String: Any],
              let mode = body["mode"] as? String else { return }
        let composerHeight = (body["height"] as? NSNumber)?.doubleValue ?? 0

        if mode == "newChat" {
            newChat(nil)
            return
        }

        if mode == "diag" {
            Log.warn("composer not visible: \(body["detail"] as? String ?? "?")")
            return
        }

        let target: CGFloat
        if mode == "compact" {
            guard composerHeight > 20 else {
                // A collapsed measurement is a bug, not a reason to jump to full
                // height - keep what we have and let the diagnostic explain it.
                Log.warn("ignoring compact height \(Int(composerHeight))pt")
                return
            }
            // Clamped: a mis-measured composer shouldn't produce a slit or a
            // full-screen panel.
            target = min(max(CGFloat(composerHeight) + compactPadding, 80), 320)
        } else {
            target = panelSize.height
        }

        Log.info("layout \(mode): composer \(Int(composerHeight))pt -> panel \(Int(target))pt")
        setPanelHeight(target)
    }

    /// Resizes the panel while keeping its bottom edge planted, so it grows upward
    /// from its resting position rather than drifting.
    ///
    /// Changes below `heightTolerance` are ignored. Resizing the window re-lays out
    /// the page, which can shift the composer's measured height by a point or two -
    /// enough to oscillate forever without a deadband. A wrapped line of text adds
    /// far more than this, so real growth still gets through.
    private func setPanelHeight(_ height: CGFloat) {
        guard abs(contentHeight - height) > heightTolerance else { return }
        contentHeight = height
        guard abs(panel.frame.height - height) > 1 else { return }

        var frame = panel.frame
        // In Cocoa, origin.y *is* the bottom edge - leaving it alone anchors the
        // bottom and lets the window extend upward.
        frame.size.height = height
        panel.setFrame(frame, display: true)
        // The shadow is cached from the old shape, so it has to be recomputed or it
        // outlines the previous size.
        panel.invalidateShadow()
    }
}

// MARK: - WKUIDelegate

extension AppDelegate: WKUIDelegate {
    /// Gives `window.open` requests (OAuth sign-in) a real window of their own.
    ///
    /// Returning a new web view built from `configuration` is what preserves the
    /// `window.opener` link. Loading the request into the main frame instead would
    /// destroy the claude.ai page that started the flow.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        Log.info("popup requested: \(navigationAction.request.url?.host ?? "?")")
        // The passkey prompt appears here, in the identity provider's own window,
        // so strip WebAuthn from the popup too. WebKit derives `configuration`
        // from the opener's, but re-adding is cheap and removes the doubt.
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: WebChrome.noWebAuthnJS,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        let popup = PopupWindowController(
            configuration: configuration,
            userAgent: userAgent,
            onClose: { [weak self] controller in self?.popupClosed(controller) }
        )
        popups.append(popup)
        popup.present()
        // WebKit loads the request into the returned web view itself.
        return popup.webView
    }

    private func popupClosed(_ controller: PopupWindowController) {
        popups.removeAll { $0 === controller }

        // Deliberately do NOT reload the main frame here.
        //
        // "Sign in with Google" (Google Identity Services) hands the credential to
        // the opener via postMessage, and claude.ai's own JavaScript then exchanges
        // it for a session and navigates itself. Reloading at popup-close time
        // destroys that page mid-exchange and bounces the user back to /login.
        if let host = webView.url?.host, !host.contains("claude.ai") {
            Log.info("popup done - main frame stranded on \(host), returning to claude.ai")
            goHome()
        } else {
            Log.info("popup done - letting claude.ai finish the sign-in itself")
        }
    }
}

// MARK: - WKNavigationDelegate

extension AppDelegate: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        Log.info("loaded \(url.host ?? "?")\(url.path)")

        // Google's GSI helper pages render blank and are a dead end when they land
        // in the main frame. Recover instead of leaving the user staring at white.
        if url.host?.contains("accounts.google.") == true, url.path.contains("/gsi/") {
            Log.warn("main frame hit a blank Google GSI page - returning to claude.ai")
            goHome()
            return
        }

        guard url.host?.contains("claude.ai") == true else { return }
        applyChatOpacity()

        // Confirm the stylesheet landed. claude.ai's markup can change under us, so a
        // silently-failed injection should show up in the log rather than as a
        // mysteriously opaque window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.webView.evaluateJavaScript(WebChrome.verifyJS) { result, error in
                if let error {
                    Log.error("style check failed: \(error.localizedDescription)")
                } else if let text = result as? String {
                    Log.info("style check: \(text)")
                }
            }
        }

        guard ProcessInfo.processInfo.environment["CLAUDE_COMPANION_PROBE"] != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.webView.evaluateJavaScript(WebChrome.probeJS) { result, _ in
                if let text = result as? String { Log.info("DOM probe:\n\(text)") }
            }
            self?.webView.evaluateJavaScript(WebChrome.backgroundProbeJS) { result, _ in
                if let text = result as? String { Log.info("background probe:\n\(text)") }
            }
            self?.webView.evaluateJavaScript(WebChrome.opaqueProbeJS) { result, _ in
                if let text = result as? String { Log.info("opaque probe:\n\(text)") }
            }
            self?.webView.evaluateJavaScript(WebChrome.structureProbeJS) { result, _ in
                if let text = result as? String { Log.info("structure probe:\n\(text)") }
            }
            self?.webView.evaluateJavaScript(WebChrome.composerProbeJS) { result, _ in
                if let text = result as? String { Log.info("composer probe:\n\(text)") }
            }
            self?.webView.evaluateJavaScript(WebChrome.hooksProbeJS) { result, _ in
                if let text = result as? String { Log.info("hooks probe:\n\(text)") }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Log.error("navigation failed: \(error.localizedDescription)")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Log.error("navigation failed: \(error.localizedDescription)")
    }
}
