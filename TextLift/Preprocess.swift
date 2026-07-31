import AppKit
import CoreGraphics

/// Prepares a screen grab for OCR.
///
/// Vision's text recognizer is trained on document-sized glyphs. A screen grab of
/// 11pt UI text sits well below that even on a Retina display, and that gap is the
/// single biggest reason on-screen OCR drops characters. Upscaling closes it.
///
/// Contrast stretching and sharpening were measured and removed: Vision already
/// normalises contrast internally, and forcing it ahead of time made faint
/// dark-mode text *worse* (see harness/gen_extreme.py — the high-contrast variant
/// scored 82.9% character error on dimmed text that the plain upscale read
/// perfectly).
///
/// The resize is deliberately plain CoreGraphics rather than CoreImage's Lanczos
/// filter. The CoreImage version rendered a **blank white image** inside the app
/// bundle while working fine in the test harness — the screen grab carries a
/// Display P3 profile and an alpha channel, and `CIContext.createCGImage` silently
/// produced empty RGB from it. Drawing into an explicit sRGB, no-alpha bitmap has
/// no such failure mode, and measured accuracy is unchanged.
enum Preprocess {

    /// Long side to upscale toward, and the ceiling on the scale factor.
    /// Swept in `harness/sweep.py`: above ~1800 the target makes no measurable
    /// difference (the cap binds first on typical selections), but a 3x ceiling
    /// consistently beat 4x and 6x — past that, interpolation is inventing detail
    /// that Vision then has to see through. Overridable via env for the sweep.
    static var targetLongSide: CGFloat = {
        if let s = ProcessInfo.processInfo.environment["TEXTLIFT_TARGET"], let v = Double(s) {
            return CGFloat(v)
        }
        return 2200
    }()

    static var maxScale: CGFloat = {
        if let s = ProcessInfo.processInfo.environment["TEXTLIFT_MAXSCALE"], let v = Double(s) {
            return CGFloat(v)
        }
        return 3.0
    }()

    static func scale(for image: CGImage) -> CGFloat {
        let longSide = CGFloat(max(image.width, image.height))
        guard longSide > 0 else { return 1 }
        return min(max(targetLongSide / longSide, 1.0), maxScale)
    }

    /// The image OCR actually runs on: upscaled, flattened onto white, sRGB.
    /// Returns the original untouched if anything about the redraw fails.
    static func prepared(from image: CGImage) -> CGImage {
        let factor = scale(for: image)
        let w = Int((CGFloat(image.width) * factor).rounded())
        let h = Int((CGFloat(image.height) * factor).rounded())
        guard w > 0, h > 0 else { return image }

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil,
                                  width: w, height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }

        // Screen grabs can carry alpha (rounded window corners, shadows). Vision
        // reads the RGB, so flatten onto white first rather than leaving it
        // undefined.
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        return ctx.makeImage() ?? image
    }
}
