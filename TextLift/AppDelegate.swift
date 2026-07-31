import AppKit
import Combine
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    private var statusItem: NSStatusItem!
    private let settings = Settings.shared
    private var settingsWindow: SettingsWindowController?
    private var resultWindow: ResultWindowController?
    private var cancellables = Set<AnyCancellable>()

    // Last scan, kept so the format can be switched without re-running OCR.
    private var lastOutcome: ScanOutcome?
    private var lastImage: CGImage?
    private var isScanning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "document.viewfinder",
                                           accessibilityDescription: "TextLift")

        settings.onShortcutChange = { [weak self] _ in self?.registerHotKey() }
        settings.onFormatChange = { [weak self] f in self?.reRender(format: f) }
        // Keep the menu's checkmarks in step with the Settings panel.
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.rebuildMenu() }
            .store(in: &cancellables)

        rebuildMenu()
        registerHotKey()

        Notify.setDelegate(self)
        Notify.requestAuthorization()

        if ProcessInfo.processInfo.environment["TEXTLIFT_TEST_NOTIFY"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Notify.test() }
        }

        Log.capture.info("screen recording authorized = \(Capture.isAuthorized)")
        if !Capture.isAuthorized { Capture.requestAuthorization() }
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()

        let capture = NSMenuItem(title: "Capture Text",
                                 action: #selector(startCapture),
                                 keyEquivalent: "")
        capture.target = self
        menu.addItem(capture)

        let hint = NSMenuItem(title: "    \(settings.shortcut.displayString)",
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit TextLift",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc private func openSettings() {
        let c = settingsWindow ?? SettingsWindowController()
        settingsWindow = c
        c.showCentered()
    }

    // MARK: - Hot key

    private func registerHotKey() {
        let s = settings.shortcut
        let ok = HotKeyManager.shared.setPrimary(keyCode: s.keyCode,
                                                 modifiers: s.carbonModifiers) { [weak self] in
            self?.startCapture()
        }
        if !ok {
            NSSound.beep()
            alert("That shortcut is taken",
                  "\(s.displayString) is already claimed by macOS or another app. Pick a different combination in Settings.")
        }
    }

    // MARK: - Capture

    @objc private func startCapture() {
        guard !isScanning else { return }

        guard Capture.isAuthorized else {
            Capture.requestAuthorization()
            permissionAlert()
            return
        }

        // The crosshair selection is swallowed if our windows stay key.
        resultWindow?.window?.orderOut(nil)
        settingsWindow?.window?.orderOut(nil)

        guard let image = Capture.selectRegion() else { return }  // Esc
        lastImage = image
        isScanning = true

        Task { @MainActor in
            let outcome = await OCREngine.scan(image, readCodes: self.settings.readCodes)
            self.isScanning = false

            guard let outcome, outcome.charCount > 0 else {
                NSSound.beep()
                // A revoked grant looks exactly like an empty selection, so
                // re-check before blaming the user's aim.
                if !Capture.isAuthorized {
                    self.permissionAlert()
                    return
                }
                // Don't force a window open just to report failure — say it
                // wherever the user is already looking.
                if self.settings.showsWindow {
                    self.present(text: "", status: "No text found in that selection.")
                } else if self.settings.notify {
                    Notify.nothingFound()
                }
                return
            }

            self.lastOutcome = outcome
            let text = DocumentRenderer.render(outcome, format: self.settings.format)
            if self.settings.autoCopy { Clipboard.set(text) }
            if self.settings.notify { Notify.copied(text) }
            self.present(text: text, status: self.statusLine(for: outcome))
            self.handleQRLink(in: outcome)
        }
    }

    // MARK: - QR codes

    /// Acts on a link found in a scanned code, according to the chosen policy.
    private func handleQRLink(in outcome: ScanOutcome) {
        guard settings.readCodes, settings.linkPolicy != .never,
              let url = QRLink.firstWebLink(in: outcome.codes) else { return }

        if settings.linkPolicy == .always {
            NSWorkspace.shared.open(url)
            return
        }

        // Show the host prominently — the whole risk with a scanned link is that
        // it goes somewhere other than where it appeared to.
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Open this link?"
        a.informativeText = "\(url.host ?? "")\n\n\(url.absoluteString)"
        a.addButton(withTitle: "Open")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Notifications

    /// Banners are suppressed by default while the app is frontmost; we want it
    /// shown either way, since the capture is the only thing happening.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
    -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    /// Clicking the banner brings the full result up for editing.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        await MainActor.run { self.showLast() }
    }

    private func statusLine(for o: ScanOutcome) -> String {
        let pct = Int((o.confidence * 100).rounded())
        let prefix = settings.autoCopy ? "Copied" : "Ready"
        return "\(prefix) · \(o.charCount) chars · \(pct)% confidence · \(o.engine)"
    }

    private func present(text: String, status: String) {
        guard settings.showsWindow else { return }
        let w = resultWindow ?? ResultWindowController()
        resultWindow = w
        w.onFormatChange = { [weak self] f in self?.settings.format = f }
        w.onRescan = { [weak self] in self?.startCapture() }
        w.show(text: text, image: lastImage, status: status, format: settings.format)
    }

    /// Re-render the last scan in a new format. No OCR re-run — the document
    /// observations are kept for exactly this.
    private func reRender(format: OutputFormat) {
        guard let o = lastOutcome else { return }
        let text = DocumentRenderer.render(o, format: format)
        resultWindow?.updateText(text)
        if settings.autoCopy { Clipboard.set(text) }
    }

    /// Used by the notification click-through.
    private func showLast() {
        guard let o = lastOutcome else { return }
        present(text: DocumentRenderer.render(o, format: settings.format),
                status: statusLine(for: o))
    }

    private func alert(_ title: String, _ body: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.runModal()
    }

    /// Without Screen Recording, `screencapture` doesn't fail — it quietly returns
    /// a wallpaper-only image with every window missing, which reads as "no text
    /// found". So say what's actually wrong and offer the exact settings pane.
    private func permissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "TextLift needs Screen Recording permission"
        a.informativeText = """
            Without it macOS hands back a blank picture instead of your screen, \
            so nothing can be read.

            Turn on TextLift under Privacy & Security → Screen & System Audio \
            Recording, then try again.
            """
        a.addButton(withTitle: "Open Settings")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
