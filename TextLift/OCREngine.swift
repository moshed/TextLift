import AppKit
import Vision

enum OutputFormat: String, CaseIterable {
    case markdown          // tables as GitHub markdown
    case tsv               // tables as tab-separated (paste into Numbers/Excel/Sheets)
    case plain             // no table structure, just lines

    var label: String {
        switch self {
        case .markdown: return "Markdown"
        case .tsv:      return "Tabs (Sheets)"
        case .plain:    return "Plain"
        }
    }
}

struct ScanOutcome {
    /// Structured result. Empty when the fallback engine produced the text.
    let observations: [DocumentObservation]
    /// Plain lines, used when `observations` is empty.
    let fallbackText: String
    /// Per-line boxes from the line recognizer, kept for row reconstruction.
    let lineObservations: [RecognizedTextObservation]
    /// Decoded QR / barcode payloads, in reading order.
    let codes: [String]
    let engine: String
    let confidence: Float
    let charCount: Int
}

enum OCREngine {

    static func documentRequest(readCodes: Bool = false) -> RecognizeDocumentsRequest {
        var request = RecognizeDocumentsRequest()
        var opts = request.textRecognitionOptions
        opts.automaticallyDetectLanguage = true
        opts.useLanguageCorrection = true
        // Default is 1/32 of image height — that discards exactly the small text
        // we care about. 0 means "no floor".
        opts.minimumTextHeightFraction = 0
        opts.maximumCandidateCount = 1
        request.textRecognitionOptions = opts
        // Off by default: most screen grabs have no codes and the detector costs time.
        request.barcodeDetectionOptions.enabled = readCodes
        return request
    }

    /// Line-only recognizer. Kept as a safety net: the document request
    /// occasionally returns nothing on layouts it can't segment, and returning
    /// *some* text beats returning none.
    static func textRequest() -> RecognizeTextRequest {
        var r = RecognizeTextRequest()
        r.recognitionLevel = .accurate
        r.usesLanguageCorrection = true
        r.automaticallyDetectsLanguage = true
        r.minimumTextHeightFraction = 0
        return r
    }

    /// Upscale, then run the document recognizer. Falls back to the line
    /// recognizer only when the document pass clearly under-read.
    static func scan(_ image: CGImage, readCodes: Bool = false) async -> ScanOutcome? {
        let prepared = Preprocess.prepared(from: image)
        Log.ocr.info("in \(image.width)x\(image.height) -> prepared \(prepared.width)x\(prepared.height)")

        // `Result.init` can't wrap an async call, so capture success/failure by hand.
        @Sendable func attempt<T>(_ work: @escaping @Sendable () async throws -> T) async -> Result<T, Error> {
            do { return .success(try await work()) } catch { return .failure(error) }
        }
        async let docTask = attempt { try await documentRequest(readCodes: readCodes).perform(on: prepared) }
        async let lineTask = attempt { try await textRequest().perform(on: prepared) }
        let (docResult, lineResult) = await (docTask, lineTask)

        let doc = try? docResult.get()
        let lines = try? lineResult.get()

        let docOutcome = doc.map { score($0, lines: lines ?? []) }
        let lineChars = lines?.reduce(0) { $0 + $1.transcript.count } ?? 0

        func why<T>(_ r: Result<T, Error>) -> String {
            if case .failure(let e) = r { return "\(e)" }
            return "none"
        }
        Log.ocr.info("""
            doc=\(docOutcome?.charCount ?? -1) chars (err \(why(docResult), privacy: .public)) \
            lines=\(lineChars) chars (err \(why(lineResult), privacy: .public))
            """)

        // Only hand over when the structured pass genuinely lost text — a small
        // difference is normal (the document pass drops stray UI chrome) and
        // trading structure away for it would cost more than it gains.
        if let d = docOutcome, d.charCount > 0, Double(d.charCount) >= 0.8 * Double(lineChars) {
            return d
        }
        guard let lines, lineChars > 0 else { return docOutcome }
        return lineOutcome(lines)
    }

    /// Run the document recognizer on an already-preprocessed image (harness use).
    static func scanSingle(_ image: CGImage) async -> ScanOutcome? {
        guard let obs = try? await documentRequest().perform(on: image) else { return nil }
        let lines = (try? await textRequest().perform(on: image)) ?? []
        return score(obs, lines: lines)
    }

    private static func score(_ obs: [DocumentObservation],
                              lines: [RecognizedTextObservation]) -> ScanOutcome {
        var chars = 0
        var weighted: Float = 0

        for o in obs {
            for line in o.document.text.lines {
                let n = line.transcript.count
                chars += n
                weighted += line.confidence * Float(n)
            }
        }
        let confidence = chars > 0 ? weighted / Float(chars) : 0
        let codes = obs.flatMap { $0.document.barcodes.compactMap(\.payloadString) }
        return ScanOutcome(observations: obs, fallbackText: "", lineObservations: lines,
                           codes: codes, engine: "document",
                           confidence: confidence, charCount: chars)
    }

    private static func lineOutcome(_ obs: [RecognizedTextObservation]) -> ScanOutcome {
        func box(_ o: RecognizedTextObservation) -> CGRect {
            o.boundingRegion.normalizedPath.boundingBox
        }
        let sorted = obs.sorted { a, b in
            abs(box(a).maxY - box(b).maxY) > 0.008 ? box(a).maxY > box(b).maxY
                                                   : box(a).minX < box(b).minX
        }
        var chars = 0
        var weighted: Float = 0
        for o in obs { let n = o.transcript.count; chars += n; weighted += o.confidence * Float(n) }

        return ScanOutcome(observations: [],
                           fallbackText: sorted.map(\.transcript).joined(separator: "\n"),
                           lineObservations: obs,
                           codes: [],
                           engine: "lines",
                           confidence: chars > 0 ? weighted / Float(chars) : 0,
                           charCount: chars)
    }
}

// MARK: - Rendering

enum DocumentRenderer {

    static func render(_ outcome: ScanOutcome, format: OutputFormat) -> String {
        let body = renderText(outcome, format: format)
        guard !outcome.codes.isEmpty else { return body }
        // A QR code's payload is usually the whole point of the capture, so put it
        // first rather than burying it under whatever text shared the frame.
        let codes = outcome.codes.joined(separator: "\n")
        return body.isEmpty ? codes : codes + "\n\n" + body
    }

    private static func renderText(_ outcome: ScanOutcome, format: OutputFormat) -> String {
        if outcome.observations.isEmpty { return outcome.fallbackText }

        // Receipts and nutrition labels put the label and its number at opposite
        // edges of a wide gap. Vision reports those as two separate observations
        // and neither the document parser nor plain line ordering puts them back
        // together — you get every label, then every number, which is useless.
        // When the document pass found no table but the layout is plainly
        // columnar, rebuild the rows from the geometry instead.
        if format != .plain,
           outcome.observations.allSatisfy({ $0.document.tables.isEmpty }),
           let grid = columnarGrid(outcome.lineObservations) {
            return renderRows(grid, format: format)
        }

        return render(outcome.observations, format: format)
    }

    /// Groups line observations into visual rows, and returns them only if the
    /// result really looks like a two-or-more column layout.
    static func columnarGrid(_ obs: [RecognizedTextObservation]) -> [[String]]? {
        guard obs.count >= 6 else { return nil }

        struct Cell { let rect: CGRect; let text: String }
        let cells = obs.compactMap { o -> Cell? in
            let t = o.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : Cell(rect: bounds(o.boundingRegion), text: t)
        }
        guard !cells.isEmpty else { return nil }

        // Sort top-to-bottom (Vision's y grows upward), then group by vertical
        // overlap — two pieces of text share a row if they mostly line up.
        let sorted = cells.sorted { $0.rect.midY > $1.rect.midY }
        var rows: [[Cell]] = []
        for cell in sorted {
            if let i = rows.indices.last {
                let ref = rows[i][0].rect
                let overlap = min(ref.maxY, cell.rect.maxY) - max(ref.minY, cell.rect.minY)
                if overlap > 0.5 * min(ref.height, cell.rect.height) {
                    rows[i].append(cell)
                    continue
                }
            }
            rows.append([cell])
        }

        // Only worth doing if several rows genuinely have separated columns.
        let multi = rows.filter { row in
            guard row.count >= 2 else { return false }
            let byX = row.sorted { $0.rect.minX < $1.rect.minX }
            return zip(byX, byX.dropFirst()).contains { $1.rect.minX - $0.rect.maxX > 0.04 }
        }
        guard multi.count >= 3, Double(multi.count) >= 0.25 * Double(rows.count) else { return nil }

        return rows.map { row in
            row.sorted { $0.rect.minX < $1.rect.minX }.map(\.text)
        }
    }

    private static func renderRows(_ rows: [[String]], format: OutputFormat) -> String {
        let width = rows.map(\.count).max() ?? 0
        guard width > 0 else { return "" }
        func pad(_ r: [String]) -> [String] {
            r + Array(repeating: "", count: max(0, width - r.count))
        }
        if format == .tsv {
            return rows.map { pad($0).joined(separator: "\t") }.joined(separator: "\n")
        }
        var out = ["| " + pad(rows[0]).joined(separator: " | ") + " |"]
        out.append("| " + Array(repeating: "---", count: width).joined(separator: " | ") + " |")
        for r in rows.dropFirst() {
            out.append("| " + pad(r).joined(separator: " | ") + " |")
        }
        return out.joined(separator: "\n")
    }

    /// Turns document observations back into text, preserving reading order and
    /// (for markdown/tsv) table structure.
    static func render(_ obs: [DocumentObservation], format: OutputFormat) -> String {
        var blocks: [(y: CGFloat, bottom: CGFloat, x: CGFloat, text: String)] = []

        for o in obs {
            let c = o.document

            if format == .plain {
                // Structure-free: emit every line top-to-bottom.
                for line in c.text.lines {
                    let box = bounds(line.boundingRegion)
                    blocks.append((box.maxY, box.minY, box.minX, line.transcript))
                }
                continue
            }

            let tableBoxes = c.tables.map { bounds($0.boundingRegion) }
            let listBoxes  = c.lists.map  { bounds($0.boundingRegion) }

            for table in c.tables {
                let box = bounds(table.boundingRegion)
                blocks.append((box.maxY, box.minY, box.minX, renderTable(table, format: format)))
            }

            for list in c.lists {
                let box = bounds(list.boundingRegion)
                let body = list.items.map { item in
                    let marker = item.markerString.isEmpty ? "-" : item.markerString
                    return "\(marker) \(item.itemString)"
                }.joined(separator: "\n")
                blocks.append((box.maxY, box.minY, box.minX, body))
            }

            // Paragraph text is also reported inside tables/lists — skip the
            // duplicates so a receipt doesn't come out twice.
            for para in c.paragraphs {
                let box = bounds(para.boundingRegion)
                let mid = CGPoint(x: box.midX, y: box.midY)
                if tableBoxes.contains(where: { $0.contains(mid) }) { continue }
                if listBoxes.contains(where: { $0.contains(mid) }) { continue }
                blocks.append((box.maxY, box.minY, box.minX, para.transcript))
            }
        }

        // Vision's normalized origin is bottom-left, so larger y is higher up.
        blocks.sort { a, b in
            abs(a.y - b.y) > 0.008 ? a.y > b.y : a.x < b.x
        }

        let kept = blocks.compactMap { b -> (CGFloat, CGFloat, String)? in
            let t = deIcon(b.text.trimmingCharacters(in: .whitespacesAndNewlines))
            return t.isEmpty ? nil : (b.y, b.bottom, t)
        }
        guard !kept.isEmpty else { return "" }
        if format == .plain {
            return kept.map(\.2).joined(separator: "\n")
        }

        // Blank-line only where the page actually has one. Always double-spacing
        // turns a list of short UI labels into a wall of gaps; never doing it runs
        // real paragraphs together. The typical block height sets the scale, so
        // this works the same on a tall screenshot and a tiny one.
        let heights = kept.map { $0.0 - $0.1 }.sorted()
        let typical = heights[heights.count / 2]
        let breakGap = max(typical * 0.7, 0.004)

        var out = kept[0].2
        for i in 1..<kept.count {
            let gap = kept[i - 1].1 - kept[i].0     // previous bottom → this top
            out += gap > breakGap ? "\n\n" : "\n"
            out += kept[i].2
        }
        return out
    }

    private static func renderTable(_ table: DocumentObservation.Container.Table,
                                    format: OutputFormat) -> String {
        var rows: [[String]] = table.rows.map { row in
            row.map { cell in
                cell.content.text.transcript
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        guard !rows.isEmpty else { return "" }

        // Icons, checkboxes and toggles land in the grid as columns with no text
        // in any row. Keeping them just adds empty cells to paste around.
        let width = rows.map(\.count).max() ?? 0
        let keep = (0..<width).filter { c in
            rows.contains { c < $0.count && !$0[c].isEmpty }
        }
        guard !keep.isEmpty else { return "" }
        rows = rows.map { row in keep.map { c in c < row.count ? row[c] : "" } }

        if format == .tsv {
            return rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        }

        // Markdown: first row becomes the header, which is what receipts/forms
        // almost always are.
        let cols = keep.count
        func pad(_ r: [String]) -> [String] {
            r + Array(repeating: "", count: max(0, cols - r.count))
        }
        var out = ["| " + pad(rows[0]).joined(separator: " | ") + " |"]
        out.append("| " + Array(repeating: "---", count: cols).joined(separator: " | ") + " |")
        for r in rows.dropFirst() {
            out.append("| " + pad(r).joined(separator: " | ") + " |")
        }
        return out.joined(separator: "\n")
    }


    /// Strips a leading glyph that is really a UI icon.
    ///
    /// Screen captures put little pictograms next to section headers — a pencil
    /// beside "SPECIFICATIONS", a box beside "WHAT'S IN THE BOX". Vision has to
    /// return *something*, so they arrive as stray "@" / "<" characters.
    ///
    /// Deliberately narrow: it only fires when the rest of the line is **all
    /// upper-case**, i.e. a UI heading. A wider rule was tried and measurably
    /// hurt — dropping any lone non-alphanumeric line ate the `}` lines out of
    /// captured code, and stripping any leading glyph mangled `} else {`.
    /// Conventional bullets are always left alone.
    private static let bullets: Set<Character> = ["-", "*", "•", "◦", "‣"]

    static func deIcon(_ line: String) -> String {
        var chars = Array(line)
        guard chars.count > 2, let first = chars.first,
              !first.isLetter, !first.isNumber, !bullets.contains(first),
              chars[1] == " "
        else { return line }

        let rest = String(chars.dropFirst(2))
        let letters = rest.filter(\.isLetter)
        guard !letters.isEmpty, letters.allSatisfy(\.isUppercase) else { return line }

        chars.removeFirst(2)
        return String(chars)
    }

    /// NormalizedRegion is a contour; its path's bounding box is the rect we want.
    private static func bounds(_ region: NormalizedRegion) -> CGRect {
        region.normalizedPath.boundingBox
    }
}
