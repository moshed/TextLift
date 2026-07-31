import SwiftUI
import ServiceManagement
import Carbon.HIToolbox

/// Everything the app can be configured with, in one panel. Matches the house
/// pattern used by Mirror / Clipboard Manager: a grouped SwiftUI `Form` hosted
/// in a plain `NSWindow`.
struct SettingsView: View {
    @ObservedObject var settings: Settings

    var body: some View {
        Form {
            Section {
                LabeledContent("Capture text") {
                    ShortcutRecorderField(shortcut: $settings.shortcut)
                        .frame(width: 170, height: 26)
                }
            } header: {
                Text("Shortcut")
            } footer: {
                Text("Needs at least ⌘, ⌥, or ⌃ so it can't clash with typing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Tables become", selection: $settings.format) {
                    ForEach(OutputFormat.allCases, id: \.self) { f in
                        Text(f.label).tag(f)
                    }
                }
                Toggle("Copy to clipboard automatically", isOn: $settings.autoCopy)
                Toggle("Show the result window after a capture", isOn: $settings.showsWindow)
                Toggle("Show a notification with the copied text", isOn: $settings.notify)
                HStack {
                    Spacer()
                    Button("Send a Test Notification") { Notify.test() }
                        .disabled(!settings.notify)
                }
            } header: {
                Text("Output")
            } footer: {
                Text("“Tabs” pastes straight into Numbers, Excel or Sheets. "
                     + "Switch to “Plain” if a capture gets read as a table that isn't one.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Read QR codes and barcodes", isOn: $settings.readCodes)
                Picker("Links in QR codes", selection: $settings.linkPolicy) {
                    ForEach(LinkPolicy.allCases, id: \.self) { p in
                        Text(p.label).tag(p)
                    }
                }
                .disabled(!settings.readCodes)
            } header: {
                Text("QR Codes")
            } footer: {
                Text("A decoded code is put at the top of the result. "
                     + "Only http and https links can be opened — a QR code is "
                     + "untrusted, and other schemes can launch apps.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Shared settings object

/// Single source of truth for preferences, backed by `UserDefaults`. The app
/// delegate observes `onShortcutChange` to re-register the global hot key.
final class Settings: ObservableObject {
    static let shared = Settings()

    var onShortcutChange: ((Shortcut) -> Void)?
    var onFormatChange: ((OutputFormat) -> Void)?

    @Published var shortcut: Shortcut {
        didSet {
            guard shortcut != oldValue else { return }
            ShortcutStore.save(shortcut)
            onShortcutChange?(shortcut)
        }
    }

    @Published var format: OutputFormat {
        didSet {
            guard format != oldValue else { return }
            UserDefaults.standard.set(format.rawValue, forKey: "outputFormat")
            onFormatChange?(format)
        }
    }

    @Published var showsWindow: Bool {
        didSet { UserDefaults.standard.set(showsWindow, forKey: "showResultWindow") }
    }

    @Published var autoCopy: Bool {
        didSet { UserDefaults.standard.set(autoCopy, forKey: "autoCopy") }
    }

    @Published var notify: Bool {
        didSet { UserDefaults.standard.set(notify, forKey: "notify") }
    }

    @Published var readCodes: Bool {
        didSet { UserDefaults.standard.set(readCodes, forKey: "readCodes") }
    }

    @Published var linkPolicy: LinkPolicy {
        didSet { UserDefaults.standard.set(linkPolicy.rawValue, forKey: "linkPolicy") }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSSound.beep()
                // Put the toggle back where the system actually is.
                DispatchQueue.main.async {
                    self.launchAtLogin = (SMAppService.mainApp.status == .enabled)
                }
            }
        }
    }

    private init() {
        let d = UserDefaults.standard
        shortcut = ShortcutStore.load()
        format = OutputFormat(rawValue: d.string(forKey: "outputFormat") ?? "") ?? .markdown
        showsWindow = d.object(forKey: "showResultWindow") as? Bool ?? false
        autoCopy = d.object(forKey: "autoCopy") as? Bool ?? true
        notify = d.object(forKey: "notify") as? Bool ?? true
        readCodes = d.object(forKey: "readCodes") as? Bool ?? true
        // "Ask first" by default: opening a scanned link without a prompt hands
        // control of the browser to whatever happened to be on screen.
        linkPolicy = LinkPolicy(rawValue: d.string(forKey: "linkPolicy") ?? "") ?? .ask
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }
}

// MARK: - Shortcut field

struct ShortcutRecorderField: NSViewRepresentable {
    @Binding var shortcut: Shortcut

    func makeNSView(context: Context) -> ShortcutField {
        let f = ShortcutField()
        f.shortcut = shortcut
        f.onRecord = { shortcut = $0 }
        return f
    }

    func updateNSView(_ nsView: ShortcutField, context: Context) {
        guard !nsView.isRecording else { return }
        nsView.shortcut = shortcut
    }
}

/// Click to arm, then press a combination. Esc cancels, ⌫ is ignored.
final class ShortcutField: NSView {
    var onRecord: ((Shortcut) -> Void)?
    var shortcut: Shortcut = .default { didSet { refresh() } }
    private(set) var isRecording = false

    private let label = NSTextField(labelWithString: "")
    private var monitor: Any?

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setUp() }
    required init?(coder: NSCoder) { super.init(coder: coder); setUp() }

    private func setUp() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        label.alignment = .center
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refresh()
    }

    private func refresh() {
        label.stringValue = isRecording ? "Press keys…" : shortcut.displayString
        label.textColor = isRecording ? .secondaryLabelColor : .labelColor
        layer?.borderColor = isRecording ? NSColor.controlAccentColor.cgColor
                                         : NSColor.separatorColor.cgColor
        layer?.borderWidth = isRecording ? 2 : 1
    }

    override func mouseDown(with event: NSEvent) {
        isRecording ? stop() : start()
    }

    private func start() {
        isRecording = true
        refresh()
        // A local monitor is required: ⌘/⌥ combinations would otherwise be
        // swallowed as menu key-equivalents. Returning nil eats the event.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            self?.handle(e)
            return nil
        }
    }

    private func stop() {
        isRecording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        refresh()
    }

    private func handle(_ event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape { stop(); return }

        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard mods.contains(.command) || mods.contains(.option) || mods.contains(.control) else {
            NSSound.beep()
            return
        }
        let s = Shortcut(keyCode: UInt32(event.keyCode), modifierFlags: mods)
        stop()
        shortcut = s
        onRecord?(s)
    }

    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
}

// MARK: - Window

final class SettingsWindowController: NSWindowController {
    convenience init() {
        let host = NSHostingController(rootView: SettingsView(settings: .shared))
        let window = NSWindow(contentViewController: host)
        window.title = "TextLift Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }

    func showCentered() {
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
    }
}
