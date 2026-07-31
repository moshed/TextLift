import AppKit
import CoreGraphics

enum Capture {

    /// True once the user has granted Screen Recording. `screencapture` is spawned
    /// by us, so TCC attributes the permission to TextLift.
    static var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestAuthorization() -> Bool { CGRequestScreenCaptureAccess() }

    /// Interactive region selection. Returns the grabbed image at full Retina
    /// pixel resolution, or nil if the user pressed Esc.
    static func selectRegion() -> CGImage? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("textlift-\(UUID().uuidString).png")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i interactive, -x silent, -o no window shadow.
        p.arguments = ["-i", "-x", "-o", url.path]
        let err = Pipe()
        p.standardError = err

        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            Log.capture.error("screencapture failed to launch: \(error.localizedDescription)")
            return nil
        }

        let stderrText = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? ""
        let size = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil

        Log.capture.info("""
            screencapture exit=\(p.terminationStatus) \
            file=\(FileManager.default.fileExists(atPath: url.path)) \
            bytes=\(size ?? -1) stderr=\(stderrText, privacy: .public)
            """)

        // Read the bytes up front and decode from memory.
        //
        // A CGImage made from a *file* source is lazily decoded — it keeps reading
        // pixels from disk on demand. Deleting the temp file before Vision asks
        // for those pixels (which is what the obvious `defer { remove }` does)
        // hands OCR a blank white image and zero characters, with no error
        // anywhere. Decoding from Data has no such dependency.
        guard let data = try? Data(contentsOf: url) else {
            return nil   // Esc cancels and writes no file
        }
        try? FileManager.default.removeItem(at: url)

        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(
                src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }

        // Keep the last capture around so a bad result can be inspected.
        try? data.write(to: Log.lastCaptureURL)

        Log.capture.info("captured \(cg.width)x\(cg.height)")
        return cg
    }
}
