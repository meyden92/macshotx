import CoreGraphics

/// Immutable pixel copy of the frozen screenshot — the only thing that crosses
/// the isolation boundary into the background index build.
struct PixelSnapshot: Sendable {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    /// Nil when the image exceeds the pixel cap (snapping is skipped outright
    /// on enormous captures) or its pixels cannot be read.
    init?(image: CGImage, maxPixels: Int = EdgeIndex.maxPixels) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width * height <= maxPixels else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.rgba = pixels
    }
}

/// Colour edges of the frozen screenshot, indexed for snap queries. Built once
/// per screenshot off the main actor; a value type of plain arrays, so only
/// Sendable values cross back. Positions and spans are device pixels.
struct EdgeIndex: Sendable {
    /// One candidate line: the pixel position of the colour edge plus a prefix
    /// sum of qualifying samples, so span support is an O(1) query. Prefix
    /// sums exist only for candidate lines — memory stays proportional to
    /// candidates × dimension rather than width × height.
    struct Line: Sendable {
        let position: Int
        let prefix: [Int]

        func support(from lo: Int, to hi: Int) -> Int {
            let lo = max(0, min(lo, prefix.count - 1))
            let hi = max(0, min(hi, prefix.count - 1))
            return hi > lo ? prefix[hi] - prefix[lo] : 0
        }
    }

    /// Vertical candidate lines (x positions) — targets for left/right edges.
    let columns: [Line]
    /// Horizontal candidate lines (y positions) — targets for top/bottom edges.
    let rows: [Line]

    static let empty = EdgeIndex(columns: [], rows: [])
    static let maxPixels = 40_000_000
    /// A luminance step qualifies at ≥ 0.18 of full range.
    static let stepThreshold = 46
    /// A line becomes a candidate at ≥ 5% qualifying samples.
    static let candidateFraction = 0.05
    /// A candidate must support ≥ 60% of the Selection's perpendicular span.
    static let supportFraction = 0.6

    var isEmpty: Bool { columns.isEmpty && rows.isEmpty }

    /// Two passes: mark candidate lines from strong luminance steps, then
    /// build prefix sums along the candidates only.
    static func build(from snapshot: PixelSnapshot) -> EdgeIndex {
        let w = snapshot.width
        let h = snapshot.height
        guard w > 1, h > 1 else { return .empty }

        var luminance = [UInt8](repeating: 0, count: w * h)
        snapshot.rgba.withUnsafeBufferPointer { rgba in
            for i in 0..<(w * h) {
                let p = i * 4
                let lum = (Int(rgba[p]) * 299 + Int(rgba[p + 1]) * 587 + Int(rgba[p + 2]) * 114) / 1000
                luminance[i] = UInt8(lum)
            }
        }

        func qualifiesColumn(_ x: Int, _ y: Int) -> Bool {
            abs(Int(luminance[y * w + x]) - Int(luminance[y * w + x - 1])) >= stepThreshold
        }
        func qualifiesRow(_ y: Int, _ x: Int) -> Bool {
            abs(Int(luminance[y * w + x]) - Int(luminance[(y - 1) * w + x])) >= stepThreshold
        }

        var columnCounts = [Int](repeating: 0, count: w)
        var rowCounts = [Int](repeating: 0, count: h)
        for y in 0..<h {
            for x in 1..<w where qualifiesColumn(x, y) {
                columnCounts[x] += 1
            }
        }
        for y in 1..<h {
            for x in 0..<w where qualifiesRow(y, x) {
                rowCounts[y] += 1
            }
        }

        let columnMinimum = max(1, Int((candidateFraction * Double(h)).rounded(.up)))
        let rowMinimum = max(1, Int((candidateFraction * Double(w)).rounded(.up)))

        var columns: [Line] = []
        for x in 1..<w where columnCounts[x] >= columnMinimum {
            var prefix = [Int](repeating: 0, count: h + 1)
            for y in 0..<h {
                prefix[y + 1] = prefix[y] + (qualifiesColumn(x, y) ? 1 : 0)
            }
            columns.append(Line(position: x, prefix: prefix))
        }
        var rows: [Line] = []
        for y in 1..<h where rowCounts[y] >= rowMinimum {
            var prefix = [Int](repeating: 0, count: w + 1)
            for x in 0..<w {
                prefix[x + 1] = prefix[x] + (qualifiesRow(y, x) ? 1 : 0)
            }
            rows.append(Line(position: y, prefix: prefix))
        }
        return EdgeIndex(columns: columns, rows: rows)
    }

    /// Nearest candidate column within the radius that supports at least the
    /// majority of the span; ties break on higher support. Pixel units.
    func column(near x: CGFloat, spanning span: ClosedRange<CGFloat>, radius: CGFloat) -> Int? {
        best(in: columns, near: x, spanning: span, radius: radius)
    }

    func row(near y: CGFloat, spanning span: ClosedRange<CGFloat>, radius: CGFloat) -> Int? {
        best(in: rows, near: y, spanning: span, radius: radius)
    }

    private func best(
        in lines: [Line],
        near position: CGFloat,
        spanning span: ClosedRange<CGFloat>,
        radius: CGFloat
    ) -> Int? {
        let lo = Int(span.lowerBound.rounded(.down))
        let hi = Int(span.upperBound.rounded(.up))
        let required = Int((Self.supportFraction * Double(hi - lo)).rounded(.up))
        guard required > 0 else { return nil }

        var winner: (position: Int, distance: CGFloat, support: Int)?
        for line in lines {
            let distance = abs(CGFloat(line.position) - position)
            guard distance <= radius else { continue }
            let support = line.support(from: lo, to: hi)
            guard support >= required else { continue }
            if let current = winner {
                if distance < current.distance
                    || (distance == current.distance && support > current.support) {
                    winner = (line.position, distance, support)
                }
            } else {
                winner = (line.position, distance, support)
            }
        }
        return winner?.position
    }
}
