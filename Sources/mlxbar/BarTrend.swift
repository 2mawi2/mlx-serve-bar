import AppKit

// Inline menu-bar readout: two rows, "110   ▰▰▰▫▫▫" (decode, green) over
// "0.0   ▫▫▫▫▫▫" (prefill, blue). Rendered into an NSImage so both axes are
// exact: numbers are padded to a fixed 5-char field in a monospaced font
// (status item never changes width while loading) and the block is centered
// from measured ink bounds (nothing clipped at the bar's top edge).
enum BarTrend {
    static let barCount = 6
    static let decodeFloor = 100.0    // floors keep idle blips from looking huge
    static let prefillFloor = 2000.0
    static let numWidth = 5           // "110", "0.0", "14.0K" all occupy 5 cols

    struct Row {
        let text: String
        let numberRange: NSRange
    }

    static func row(_ label: String, _ v: Double, _ hist: [Double], _ floor: Double) -> Row {
        var raw = v >= 1000 ? Formats.fmt(v, 1) : (v >= 100 ? String(format: "%.0f", v) : Formats.fmt(v, 1))
        if raw.count > numWidth { raw = Formats.fmt(v, 0) }
        if raw.count > numWidth { raw = String(raw.prefix(numWidth)) }
        let num = raw.padding(toLength: numWidth, withPad: " ", startingAt: 0)
        let maxV = max(floor, hist.max() ?? 0, v)
        let cells = filled(v, maxV)
        var bars = ""
        for i in 0..<barCount { bars += i < cells ? "▰" : "▫" }
        let prefix = label.isEmpty ? "" : "\(label) "
        let text = "\(prefix)\(num) \(bars)"
        let ns = text as NSString
        let numRange = ns.range(of: raw)
        return Row(text: text, numberRange: numRange.location != NSNotFound ? numRange : NSRange(location: prefix.count, length: raw.count))
    }

    // Filled cells for one series; a live (nonzero) series lights ≥1 cell.
    static func filled(_ v: Double, _ maxV: Double) -> Int {
        guard maxV > 0 else { return 0 }
        let f = Int((v / maxV * Double(barCount)).rounded())
        return v > 0.001 ? max(1, f) : f
    }

    static func paint(_ row: Row, font: NSFont, para: NSParagraphStyle,
                      label: NSColor, number: NSColor, bar: NSColor, empty: NSColor)
        -> NSAttributedString
    {
        let base: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para]
        let out = NSMutableAttributedString(string: row.text, attributes: base)
        if row.numberRange.location > 0 {
            out.addAttribute(.foregroundColor, value: label, range: NSRange(location: 0, length: 1))
        }
        out.addAttribute(.foregroundColor, value: number, range: row.numberRange)
        let barStart = NSMaxRange(row.numberRange)
        enumerate(row.text, from: barStart, "▰") { out.addAttribute(.foregroundColor, value: bar, range: $0) }
        enumerate(row.text, from: barStart, "▫") { out.addAttribute(.foregroundColor, value: empty, range: $0) }
        return out
    }

    private static func enumerate(_ s: String, from: Int, _ ch: String, _ f: (NSRange) -> Void) {
        let ns = s as NSString
        var r = ns.range(of: ch, options: [], range: NSRange(location: from, length: ns.length - from))
        while r.location != NSNotFound {
            f(r)
            if NSMaxRange(r) >= ns.length { break }
            r = ns.range(of: ch, options: [], range: NSRange(location: NSMaxRange(r), length: ns.length - NSMaxRange(r)))
        }
    }

    static func colors(dark: Bool) -> (decode: NSColor, prefill: NSColor) {
        if dark {
            return (NSColor(srgbRed: 0.30, green: 0.85, blue: 0.39, alpha: 1),
                    NSColor(srgbRed: 0.36, green: 0.60, blue: 1.00, alpha: 1))
        }
        return (NSColor(srgbRed: 0.00, green: 0.52, blue: 0.16, alpha: 1),
                NSColor(srgbRed: 0.08, green: 0.30, blue: 0.82, alpha: 1))
    }

    static let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .bold)
    private static let lineH: CGFloat = 11.0
    private static let padX: CGFloat = 3
    // Vertical nudge for the block draw (points, negative = up). Pixel-tuned:
    // draw(in:) top-aligns the block in its rect, canvas top lands ~screen y6.
    static var yAdjust: CGFloat = -1.5

    // Render both rows into a fixed-size image. Width = constant char count ×
    // mono advance ⇒ no jitter. Height = menu bar thickness, block centered
    // using the font's cap/descender metrics so the ink sits dead-center.
    static func image(dark: Bool, rows: [(Row, NSColor)], empty: NSColor) -> NSImage {
        let ink = dark ? NSColor.white : NSColor.black
        let para = NSMutableParagraphStyle()
        para.maximumLineHeight = lineH
        para.minimumLineHeight = lineH

        let attr = rows.map {
            paint($0.0, font: font, para: para, label: ink, number: ink, bar: $0.1, empty: empty)
        }

        let charW = ("▫" as NSString).size(withAttributes: [.font: font]).width
        let cols = CGFloat(rows.first?.0.text.count ?? 12)
        let w = ceil(cols * charW) + padX * 2
        let h = CGFloat(NSStatusBar.system.thickness)

        // SF Mono 9pt: ascender/descender → place the two baselines so the
        // combined ink (≈ascender above, descender below each baseline) is
        // symmetric about h/2.
        let asc = font.ascender          // ~+8.05
        let desc = -font.descender       // ~+2.1
        let block = 2 * lineH
        let topGap = (h - block) / 2 + yAdjust
        // Baselines in flipped coords: top of line i + leading + ascender.
        func baseline(_ i: Int) -> CGFloat { topGap + CGFloat(i) * lineH + (lineH - (asc + desc)) / 2 + asc }

        let img = NSImage(size: NSSize(width: w, height: h), flipped: true) { _ in
            // One block draw, top-aligned by draw(in:); yAdjust shifts it so
            // the ink sits centered in the bar. Both lines always full height.
            let block = NSMutableAttributedString()
            for (i, a) in attr.enumerated() {
                if i > 0 { block.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: para])) }
                block.append(a)
            }
            block.draw(in: NSRect(x: padX, y: yAdjust, width: w, height: h - yAdjust + 4))
            return true
        }
        img.isTemplate = false
        img.accessibilityDescription = "mlx-serve"
        return img
    }
}
