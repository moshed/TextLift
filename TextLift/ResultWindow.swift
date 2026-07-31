import AppKit

/// Shows what was recognised so it can be checked and fixed before use.
/// The text is already on the clipboard by the time this appears — the window is
/// for verification, not a required step.
final class ResultWindowController: NSWindowController, NSWindowDelegate {

    var onFormatChange: ((OutputFormat) -> Void)?
    var onRescan: (() -> Void)?

    private let textView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let formatPicker = NSPopUpButton()
    private let thumbnail = NSImageView()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "TextLift"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 380, height: 260)
        self.init(window: window)
        window.delegate = self
        build()
    }

    private func build() {
        guard let content = window?.contentView else { return }

        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.imageAlignment = .alignCenter
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 4
        thumbnail.layer?.borderWidth = 1
        thumbnail.layer?.borderColor = NSColor.separatorColor.cgColor
        thumbnail.setContentHuggingPriority(.defaultLow, for: .horizontal)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        formatPicker.addItems(withTitles: OutputFormat.allCases.map(\.label))
        formatPicker.target = self
        formatPicker.action = #selector(formatChanged)

        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyText))
        copyButton.keyEquivalent = "\r"
        let rescanButton = NSButton(title: "Capture Again", target: self, action: #selector(rescan))

        let bar = NSStackView(views: [formatPicker, statusLabel,
                                      NSView(), rescanButton, copyButton])
        bar.orientation = .horizontal
        bar.spacing = 10
        bar.distribution = .fill
        bar.setHuggingPriority(.defaultLow, for: .horizontal)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autohidesScrollers = true

        textView.isEditable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView

        let stack = NSStackView(views: [thumbnail, bar, scroll])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            thumbnail.heightAnchor.constraint(equalToConstant: 90),
            thumbnail.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    // MARK: - Content

    func show(text: String, image: CGImage?, status: String, format: OutputFormat) {
        textView.string = text
        statusLabel.stringValue = status
        formatPicker.selectItem(at: OutputFormat.allCases.firstIndex(of: format) ?? 0)
        if let image {
            thumbnail.image = NSImage(cgImage: image,
                                      size: NSSize(width: image.width, height: image.height))
        } else {
            thumbnail.image = nil
        }
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
        textView.window?.makeFirstResponder(textView)
    }

    func updateText(_ text: String) { textView.string = text }

    var currentText: String { textView.string }

    // MARK: - Actions

    @objc private func formatChanged() {
        let f = OutputFormat.allCases[formatPicker.indexOfSelectedItem]
        onFormatChange?(f)
    }

    @objc private func copyText() {
        Clipboard.set(textView.string)
        statusLabel.stringValue = "Copied"
    }

    @objc private func rescan() { onRescan?() }

    override func cancelOperation(_ sender: Any?) { window?.close() }
}

enum Clipboard {
    static func set(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }
}
