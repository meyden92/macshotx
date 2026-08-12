import AppKit

/// The app-private annotation clipboard. Copy writes a versioned payload of the
/// selected annotations and nothing else — no image, no text; copying the
/// capture itself is the pipeline's job. Paste reads only this type, so an
/// image or a string on the pasteboard is never mistaken for annotations.
///
/// The format carries no compatibility promise beyond "reject what you do not
/// understand": a payload whose version this build does not know is ignored
/// rather than partially applied.
enum AnnotationClipboard {
    static let pasteboardType = NSPasteboard.PasteboardType("dev.macshot.annotations")
    static let version = 1

    private struct Payload: Codable {
        var version: Int
        var annotations: [Annotation]
    }

    static func encode(_ annotations: [Annotation]) -> Data? {
        try? JSONEncoder().encode(Payload(version: version, annotations: annotations))
    }

    static func decode(_ data: Data) -> [Annotation]? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == version
        else { return nil }
        return payload.annotations
    }

    /// Writes nothing at all for an empty set, so Cmd+C with no selection
    /// leaves whatever the user had on the pasteboard alone.
    static func write(_ annotations: [Annotation], to pasteboard: NSPasteboard) {
        guard !annotations.isEmpty, let data = encode(annotations) else { return }
        pasteboard.clearContents()
        pasteboard.setData(data, forType: pasteboardType)
    }

    static func read(from pasteboard: NSPasteboard) -> [Annotation]? {
        guard let data = pasteboard.data(forType: pasteboardType) else { return nil }
        return decode(data)
    }
}

extension AnnotationGeometry {
    /// How far a duplicate or a paste lands from what it came from.
    static let pasteOffsetStep: CGFloat = 12

    /// Where a duplicated or pasted set lands: nudged off the originals by
    /// `steps` of the standard offset, then slid as a unit so the whole set
    /// stays on the canvas — a set copied from a bigger screen still arrives
    /// somewhere the user can see it.
    static func offset(
        _ annotations: [Annotation], steps: Int, within bounds: CGRect
    ) -> [Annotation] {
        let delta = pasteOffsetStep * CGFloat(steps)
        var moved = annotations.map { translate($0, dx: delta, dy: delta) }
        guard let box = combinedBounds(of: moved) else { return moved }

        // Pull back inside on each axis; a set wider than the canvas gives up
        // on the far edge and lines up with the near one.
        var dx: CGFloat = 0, dy: CGFloat = 0
        if box.maxX > bounds.maxX { dx = bounds.maxX - box.maxX }
        if box.minX + dx < bounds.minX { dx = bounds.minX - box.minX }
        if box.maxY > bounds.maxY { dy = bounds.maxY - box.maxY }
        if box.minY + dy < bounds.minY { dy = bounds.minY - box.minY }
        if dx != 0 || dy != 0 {
            moved = moved.map { translate($0, dx: dx, dy: dy) }
        }
        return moved
    }
}
