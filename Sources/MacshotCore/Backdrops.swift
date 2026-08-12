import AppKit
import SwiftUI

/// One entry in the curated backdrop list. Styles are code-defined, not
/// user-supplied: the point is to reach a good-looking result in one or two
/// clicks rather than to build one. The identifier is stable and is what
/// persists — renaming a style must never change what a saved config means.
struct BackdropStyle: Identifiable, Sendable {
    enum Kind: Sendable {
        case solid(NSColor)
        /// Top-left to bottom-right.
        case linear([NSColor])
        /// A 3×3 control-point mesh, row-major.
        case mesh([NSColor])
    }

    let id: String
    let name: String
    let kind: Kind

    /// The colour a swatch shows for this style.
    var swatchColor: NSColor {
        switch kind {
        case let .solid(color): return color
        case let .linear(colors), let .mesh(colors): return colors[colors.count / 2]
        }
    }
}

private func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
}

enum Backdrops {
    static let all: [BackdropStyle] = [
        BackdropStyle(id: "slate", name: "Slate", kind: .solid(rgb(38, 42, 51))),
        BackdropStyle(id: "paper", name: "Paper", kind: .solid(rgb(242, 240, 235))),
        BackdropStyle(
            id: "dusk", name: "Dusk",
            kind: .linear([rgb(65, 88, 208), rgb(200, 80, 192), rgb(255, 204, 112)])
        ),
        BackdropStyle(
            id: "mint", name: "Mint",
            kind: .linear([rgb(0, 201, 167), rgb(146, 254, 157)])
        ),
        BackdropStyle(
            id: "ember", name: "Ember",
            kind: .linear([rgb(255, 110, 127), rgb(191, 82, 158), rgb(83, 105, 194)])
        ),
        BackdropStyle(
            id: "aurora", name: "Aurora",
            kind: .mesh([
                rgb(28, 45, 92), rgb(52, 90, 176), rgb(34, 55, 110),
                rgb(96, 60, 178), rgb(46, 160, 190), rgb(28, 96, 150),
                rgb(20, 30, 70), rgb(58, 42, 130), rgb(18, 44, 88)
            ])
        ),
        BackdropStyle(
            id: "coral", name: "Coral",
            kind: .mesh([
                rgb(255, 150, 120), rgb(255, 96, 122), rgb(232, 70, 140),
                rgb(255, 190, 130), rgb(250, 120, 130), rgb(190, 70, 160),
                rgb(255, 220, 170), rgb(255, 160, 140), rgb(150, 60, 150)
            ])
        ),
        BackdropStyle(
            id: "meadow", name: "Meadow",
            kind: .mesh([
                rgb(214, 240, 180), rgb(140, 210, 150), rgb(70, 160, 130),
                rgb(180, 226, 170), rgb(96, 186, 150), rgb(40, 128, 120),
                rgb(140, 200, 150), rgb(60, 150, 130), rgb(20, 96, 104)
            ])
        )
    ]

    static let defaultID = "dusk"

    /// The named style, or the default when a persisted identifier no longer
    /// exists — a config from an older build must never fail to decode over a
    /// style that has been renamed away.
    static func style(_ id: String) -> BackdropStyle {
        all.first { $0.id == id } ?? all.first { $0.id == defaultID } ?? all[0]
    }

    /// Mesh gradients go through SwiftUI's `ImageRenderer`, which is neither
    /// free nor off the main actor. The cache is not an optimisation — it is
    /// what keeps a slider drag smooth, since every drag re-composes.
    @MainActor private static var meshCache: [String: CGImage] = [:]

    static func draw(_ id: String, in ctx: CGContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        switch style(id).kind {
        case let .solid(color):
            ctx.setFillColor(color.cgColor)
            ctx.fill(rect)
        case let .linear(colors):
            drawLinear(colors, in: ctx, rect: rect)
        case let .mesh(colors):
            if let image = MainActor.assumeIsolated({ meshImage(id: id, colors: colors, size: size) }) {
                ctx.draw(image, in: rect)
            } else {
                drawLinear(colors, in: ctx, rect: rect)
            }
        }
    }

    private static func drawLinear(_ colors: [NSColor], in ctx: CGContext, rect: CGRect) {
        let space = CGColorSpaceCreateDeviceRGB()
        let cgColors = colors.compactMap { $0.usingColorSpace(.sRGB)?.cgColor } as CFArray
        guard let gradient = CGGradient(colorsSpace: space, colors: cgColors, locations: nil)
        else {
            ctx.setFillColor(colors[0].cgColor)
            ctx.fill(rect)
            return
        }
        ctx.saveGState()
        ctx.addRect(rect)
        ctx.clip()
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
        ctx.restoreGState()
    }

    @MainActor
    private static func meshImage(id: String, colors: [NSColor], size: CGSize) -> CGImage? {
        let key = "\(id)@\(Int(size.width))x\(Int(size.height))"
        if let cached = meshCache[key] { return cached }
        let points: [SIMD2<Float>] = [
            [0, 0], [0.5, 0], [1, 0],
            [0, 0.5], [0.5, 0.5], [1, 0.5],
            [0, 1], [0.5, 1], [1, 1]
        ]
        let renderer = ImageRenderer(
            content: MeshGradient(
                width: 3, height: 3, points: points, colors: colors.map { Color(nsColor: $0) }
            )
            .frame(width: max(1, size.width), height: max(1, size.height))
        )
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }
        meshCache[key] = image
        return image
    }

    /// Test seam: how many distinct (style, size) backdrops have been rendered.
    @MainActor static var renderedMeshCount: Int { meshCache.count }
    @MainActor static func resetMeshCache() { meshCache.removeAll() }
}
