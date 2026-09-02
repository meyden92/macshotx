import Foundation

// MARK: - Decoding helper

/// Hand-edited config files must never fail wholesale: any missing or
/// malformed key falls back to its default.
extension KeyedDecodingContainer {
    func decodeOr<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        guard let decoded = try? decodeIfPresent(T.self, forKey: key) else { return fallback }
        return decoded
    }
}

// MARK: - Pipeline

enum PipelineAction: Equatable, Sendable {
    case openInEditor
    case copyImage
    case saveToDisk
    case upload(destination: String)
    case copyURL
    case runShell(command: String)
    case openInApp(bundleID: String)
    case extractText
}

extension PipelineAction: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, destination, command, bundleID
    }

    private enum Kind: String, Codable {
        case openInEditor, copyImage, saveToDisk, upload, copyURL, runShell, openInApp, extractText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .openInEditor: self = .openInEditor
        case .copyImage: self = .copyImage
        case .saveToDisk: self = .saveToDisk
        case .upload: self = .upload(destination: container.decodeOr(.destination, ""))
        case .copyURL: self = .copyURL
        case .runShell: self = .runShell(command: container.decodeOr(.command, ""))
        case .openInApp: self = .openInApp(bundleID: container.decodeOr(.bundleID, ""))
        case .extractText: self = .extractText
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .openInEditor: try container.encode(Kind.openInEditor, forKey: .type)
        case .copyImage: try container.encode(Kind.copyImage, forKey: .type)
        case .saveToDisk: try container.encode(Kind.saveToDisk, forKey: .type)
        case .upload(let destination):
            try container.encode(Kind.upload, forKey: .type)
            try container.encode(destination, forKey: .destination)
        case .copyURL: try container.encode(Kind.copyURL, forKey: .type)
        case .runShell(let command):
            try container.encode(Kind.runShell, forKey: .type)
            try container.encode(command, forKey: .command)
        case .openInApp(let bundleID):
            try container.encode(Kind.openInApp, forKey: .type)
            try container.encode(bundleID, forKey: .bundleID)
        case .extractText: try container.encode(Kind.extractText, forKey: .type)
        }
    }
}

/// The one pipeline, run after every capture. Nothing distinguishes captures
/// from one another any more, so there is nothing to override it for
/// (ADR 0012); the stored key stays `global` so a config written back when
/// overrides existed keeps its action list.
struct PipelineSettings: Equatable, Codable, Sendable {
    var actions: [PipelineAction] = [.copyImage, .saveToDisk]

    init() {}

    private enum CodingKeys: String, CodingKey { case actions = "global" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        actions = c.decodeOr(.actions, [.copyImage, .saveToDisk])
    }
}

// MARK: - Destinations

enum DestinationKind: String, Codable, Sendable {
    case s3
    case sftp
    case ftp
    case webdav
    case customHTTP
}

struct S3Settings: Equatable, Codable, Sendable {
    var endpoint = ""
    var region = "auto"
    var bucket = ""
    var accessKey = ""
    var pathPrefix = ""
    var publicReadACL = false
    var publicURLTemplate = ""
    var serverSideEncryption = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case endpoint, region, bucket, accessKey, pathPrefix
        case publicReadACL, publicURLTemplate, serverSideEncryption
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = c.decodeOr(.endpoint, "")
        region = c.decodeOr(.region, "auto")
        bucket = c.decodeOr(.bucket, "")
        accessKey = c.decodeOr(.accessKey, "")
        pathPrefix = c.decodeOr(.pathPrefix, "")
        publicReadACL = c.decodeOr(.publicReadACL, false)
        publicURLTemplate = c.decodeOr(.publicURLTemplate, "")
        serverSideEncryption = c.decodeOr(.serverSideEncryption, false)
    }
}

/// SFTP and WebDAV share the same connection shape.
struct ServerSettings: Equatable, Codable, Sendable {
    var host = ""
    var port = 0
    var username = ""
    var remoteDirectory = ""
    var sshKeyPath = ""
    var publicURLTemplate = ""

    init() {}

    private enum CodingKeys: String, CodingKey {
        case host, port, username, remoteDirectory, sshKeyPath, publicURLTemplate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = c.decodeOr(.host, "")
        port = c.decodeOr(.port, 0)
        username = c.decodeOr(.username, "")
        remoteDirectory = c.decodeOr(.remoteDirectory, "")
        sshKeyPath = c.decodeOr(.sshKeyPath, "")
        publicURLTemplate = c.decodeOr(.publicURLTemplate, "")
    }
}

/// ShareX `.sxcu` compatible subset (PRD §6.9.3).
struct CustomUploaderSettings: Equatable, Codable, Sendable {
    var requestMethod = "POST"
    var requestURL = ""
    var headers: [String: String] = [:]
    /// URL query parameters.
    var parameters: [String: String] = [:]
    /// Form/body fields (ShareX "Arguments").
    var arguments: [String: String] = [:]
    var bodyType = "MultipartFormData"
    var fileFormName = "file"
    var body = ""
    var urlTemplate = ""
    var thumbnailURLTemplate = ""
    var deletionURLTemplate = ""
    /// Patterns referenced by {regex:index|group} in response templates.
    var regexList: [String] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case requestMethod, requestURL, headers, parameters, arguments, bodyType
        case fileFormName, body, urlTemplate, thumbnailURLTemplate, deletionURLTemplate
        case regexList
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestMethod = c.decodeOr(.requestMethod, "POST")
        requestURL = c.decodeOr(.requestURL, "")
        headers = c.decodeOr(.headers, [:])
        parameters = c.decodeOr(.parameters, [:])
        arguments = c.decodeOr(.arguments, [:])
        bodyType = c.decodeOr(.bodyType, "MultipartFormData")
        fileFormName = c.decodeOr(.fileFormName, "file")
        body = c.decodeOr(.body, "")
        urlTemplate = c.decodeOr(.urlTemplate, "")
        thumbnailURLTemplate = c.decodeOr(.thumbnailURLTemplate, "")
        deletionURLTemplate = c.decodeOr(.deletionURLTemplate, "")
        regexList = c.decodeOr(.regexList, [])
    }
}

struct Destination: Equatable, Codable, Identifiable, Sendable {
    var id = UUID()
    var name = ""
    var kind = DestinationKind.customHTTP
    var s3 = S3Settings()
    var server = ServerSettings()
    var custom = CustomUploaderSettings()

    init() {}

    private enum CodingKeys: String, CodingKey { case id, name, kind, s3, server, custom }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeOr(.id, UUID())
        name = c.decodeOr(.name, "")
        kind = c.decodeOr(.kind, .customHTTP)
        s3 = c.decodeOr(.s3, S3Settings())
        server = c.decodeOr(.server, ServerSettings())
        custom = c.decodeOr(.custom, CustomUploaderSettings())
    }
}

// MARK: - Hotkeys

struct HotkeyBinding: Equatable, Codable, Hashable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
}

struct HotkeySettings: Equatable, Codable, Sendable {
    // Defaults: ⌃⇧4 mirrors the system's ⌘⇧4; ⌃⇧C / ⌃⇧M for the utilities.
    // The key is `capture`, not one of the old per-mode keys: a config written
    // before the hotkeys collapsed lands on this default (ADR 0010).
    var capture: HotkeyBinding? = HotkeyBinding(keyCode: 21, carbonModifiers: 0x1200)
    var colorPicker: HotkeyBinding? = HotkeyBinding(keyCode: 8, carbonModifiers: 0x1200)
    var magnifier: HotkeyBinding? = HotkeyBinding(keyCode: 46, carbonModifiers: 0x1200)

    init() {}

    private enum CodingKeys: String, CodingKey {
        case capture, colorPicker, magnifier
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = HotkeySettings()
        capture = c.decodeOr(.capture, defaults.capture)
        colorPicker = c.decodeOr(.colorPicker, defaults.colorPicker)
        magnifier = c.decodeOr(.magnifier, defaults.magnifier)
    }
}

// MARK: - General / capture / filenames

enum ColorOutputFormat: String, Codable, Sendable {
    case hex
    case rgb
    case hsl
}

struct GeneralSettings: Equatable, Codable, Sendable {
    var notificationsEnabled = true
    var captureFeedbackEnabled = true
    var launchAtLogin = false
    var colorFormat = ColorOutputFormat.hex
    /// Which page of the first-run wizard to resume on, or nil once setup is
    /// over. The wizard writes this itself — completion is never inferred from
    /// the app having launched — so quitting mid-setup to grant a permission
    /// comes back to the same step. A config that predates the field has no
    /// value and is left alone: those users already went through setup.
    var setupPage: Int?

    /// Setup counts as done only once the user finished or skipped the wizard.
    var setupCompleted: Bool { setupPage == nil }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case notificationsEnabled, captureFeedbackEnabled, launchAtLogin, colorFormat
        case setupPage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notificationsEnabled = c.decodeOr(.notificationsEnabled, true)
        captureFeedbackEnabled = c.decodeOr(.captureFeedbackEnabled, true)
        launchAtLogin = c.decodeOr(.launchAtLogin, false)
        colorFormat = c.decodeOr(.colorFormat, .hex)
        setupPage = (try? c.decodeIfPresent(Int.self, forKey: .setupPage))
            .flatMap { $0 }
            .map { max(0, $0) }
    }
}

enum ImageFormat: String, Codable, Sendable, CaseIterable {
    case png
    case jpeg
    case heic

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        }
    }
}

/// Which corner of the capture the watermark sits in.
enum WatermarkCorner: String, Codable, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    var label: String {
        switch self {
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }
}

/// A logo composited into every capture. Size and margin are percentages of the
/// capture's width rather than pixels, so one setting looks the same on a Retina
/// fullscreen shot and on a small crop.
struct WatermarkSettings: Equatable, Codable, Sendable {
    /// Separate from having a logo configured, so the logo survives turning it
    /// off and back on.
    var enabled = false
    var imagePath = ""
    var corner = WatermarkCorner.bottomRight
    /// Logo width as a percentage of the capture's width.
    var scalePercent = 15
    /// Distance from the two edges it sits against, as a percentage of the
    /// capture's width.
    var marginPercent = 2
    var opacityPercent = 80

    init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, imagePath, corner, scalePercent, marginPercent, opacityPercent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.decodeOr(.enabled, false)
        imagePath = c.decodeOr(.imagePath, "")
        corner = c.decodeOr(.corner, .bottomRight)
        scalePercent = min(100, max(1, c.decodeOr(.scalePercent, 15)))
        marginPercent = min(40, max(0, c.decodeOr(.marginPercent, 2)))
        opacityPercent = min(100, max(1, c.decodeOr(.opacityPercent, 80)))
    }
}

struct CaptureSettings: Equatable, Codable, Sendable {
    var saveDirectory = "~/Pictures/macshot"
    var format = ImageFormat.png
    /// 1–100, applies to jpeg/heic only.
    var quality = 90
    /// Training-wheel chrome in the capture overlay: the selecting-state hint
    /// chip attached to a live Selection.
    var showOverlayHints = true
    var watermark = WatermarkSettings()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case saveDirectory, format, quality, showOverlayHints, watermark
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        saveDirectory = c.decodeOr(.saveDirectory, "~/Pictures/macshot")
        format = c.decodeOr(.format, .png)
        quality = min(100, max(1, c.decodeOr(.quality, 90)))
        showOverlayHints = c.decodeOr(.showOverlayHints, true)
        watermark = c.decodeOr(.watermark, WatermarkSettings())
    }
}

struct FilenameSettings: Equatable, Codable, Sendable {
    var template = "Screenshot_%y-%mo-%d_%h-%mi-%s.png"
    var counterPadding = 4

    init() {}

    private enum CodingKeys: String, CodingKey { case template, counterPadding }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        template = c.decodeOr(.template, "Screenshot_%y-%mo-%d_%h-%mi-%s.png")
        counterPadding = max(1, c.decodeOr(.counterPadding, 4))
    }
}

/// The typography axes of a text-bearing tool, persisted as a unit so adding
/// one does not mean adding two more flat fields to EditorStyles. Every default
/// here is what macshot drew before the axis existed, so a config from an older
/// build decodes to exactly today's look.
struct RichTextDefaults: Equatable, Codable, Sendable {
    var fontFamily = ""
    var bold = true
    var italic = false
    var underline = false
    var strikethrough = false
    var alignment = TextAlignment.left.rawValue
    /// Empty means off, which is how both of these start.
    var backgroundColorHex = ""
    var outlineColorHex = ""
    var outlineWidth = 2.0

    init() {}

    private enum CodingKeys: String, CodingKey {
        case fontFamily, bold, italic, underline, strikethrough
        case alignment, backgroundColorHex, outlineColorHex, outlineWidth
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RichTextDefaults()
        fontFamily = c.decodeOr(.fontFamily, d.fontFamily)
        bold = c.decodeOr(.bold, d.bold)
        italic = c.decodeOr(.italic, d.italic)
        underline = c.decodeOr(.underline, d.underline)
        strikethrough = c.decodeOr(.strikethrough, d.strikethrough)
        alignment = c.decodeOr(.alignment, d.alignment)
        backgroundColorHex = c.decodeOr(.backgroundColorHex, d.backgroundColorHex)
        outlineColorHex = c.decodeOr(.outlineColorHex, d.outlineColorHex)
        outlineWidth = c.decodeOr(.outlineWidth, d.outlineWidth)
    }
}

// MARK: - Editor styles (persisted per-tool, PRD §6.5.1)

struct EditorStyles: Equatable, Codable, Sendable {
    var strokeColorHex = "#FF3B30"
    var strokeLineWidth = 3.0
    var highlighterColorHex = "#FFCC00"
    var highlighterLineWidth = 22.0
    var textColorHex = "#FF3B30"
    var textFontSize = 22.0
    var calloutColorHex = "#FF3B30"
    var calloutFontSize = 22.0
    var fillColorHex = "#000000"
    var stepMarkerColorHex = "#FF3B30"
    /// The user's saved colours. App-level, not per-tool.
    var customPaletteHex: [String] = []
    /// Shared by the stroke tools, like the colour and width above it; only the
    /// line and arrow tools ever offer it.
    var strokeDashStyle = DashStyle.solid.rawValue
    var arrowHeadStyle = ArrowHead.standard.rawValue
    /// Shape fill: stroke-only is the default so existing configs are unchanged.
    var textRichDefaults = RichTextDefaults()
    var calloutRichDefaults = RichTextDefaults()
    var shapeFillMode = FillMode.strokeOnly.rawValue
    var shapeFillColorHex = "#FF3B304D"
    var rectangleCornerRadius = 0.0
    /// The measure tool keeps its own colour and width: a dimension line reads
    /// better thinner than the shape tools' default stroke.
    var measureColorHex = "#FF3B30"
    var measureLineWidth = 2.0
    /// The loupe's chrome and how hard it zooms. White rings read over both
    /// light and dark content, which is what a magnifier usually sits on.
    var loupeOutlineColorHex = "#FFFFFF"
    var loupeOutlineVisible = true
    var loupeMagnification = 2.0
    /// Spotlight: the shape the next one takes, and how dark the one composed
    /// dim layer goes.
    var spotlightShape = SpotlightShape.rectangle.rawValue
    var spotlightDimStrength = 0.6

    init() {}

    private enum CodingKeys: String, CodingKey {
        case strokeColorHex, strokeLineWidth, highlighterColorHex, highlighterLineWidth
        case textColorHex, textFontSize, calloutColorHex, calloutFontSize
        case fillColorHex, stepMarkerColorHex, customPaletteHex
        case strokeDashStyle, arrowHeadStyle
        case shapeFillMode, shapeFillColorHex, rectangleCornerRadius
        case textRichDefaults, calloutRichDefaults
        case measureColorHex, measureLineWidth
        case loupeOutlineColorHex, loupeOutlineVisible, loupeMagnification
        case spotlightShape, spotlightDimStrength
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EditorStyles()
        strokeColorHex = c.decodeOr(.strokeColorHex, d.strokeColorHex)
        strokeLineWidth = c.decodeOr(.strokeLineWidth, d.strokeLineWidth)
        highlighterColorHex = c.decodeOr(.highlighterColorHex, d.highlighterColorHex)
        highlighterLineWidth = c.decodeOr(.highlighterLineWidth, d.highlighterLineWidth)
        textColorHex = c.decodeOr(.textColorHex, d.textColorHex)
        textFontSize = c.decodeOr(.textFontSize, d.textFontSize)
        calloutColorHex = c.decodeOr(.calloutColorHex, d.calloutColorHex)
        calloutFontSize = c.decodeOr(.calloutFontSize, d.calloutFontSize)
        fillColorHex = c.decodeOr(.fillColorHex, d.fillColorHex)
        stepMarkerColorHex = c.decodeOr(.stepMarkerColorHex, d.stepMarkerColorHex)
        customPaletteHex = c.decodeOr(.customPaletteHex, d.customPaletteHex)
        strokeDashStyle = c.decodeOr(.strokeDashStyle, d.strokeDashStyle)
        arrowHeadStyle = c.decodeOr(.arrowHeadStyle, d.arrowHeadStyle)
        shapeFillMode = c.decodeOr(.shapeFillMode, d.shapeFillMode)
        shapeFillColorHex = c.decodeOr(.shapeFillColorHex, d.shapeFillColorHex)
        rectangleCornerRadius = c.decodeOr(.rectangleCornerRadius, d.rectangleCornerRadius)
        textRichDefaults = c.decodeOr(.textRichDefaults, d.textRichDefaults)
        calloutRichDefaults = c.decodeOr(.calloutRichDefaults, d.calloutRichDefaults)
        measureColorHex = c.decodeOr(.measureColorHex, d.measureColorHex)
        measureLineWidth = c.decodeOr(.measureLineWidth, d.measureLineWidth)
        loupeOutlineColorHex = c.decodeOr(.loupeOutlineColorHex, d.loupeOutlineColorHex)
        loupeOutlineVisible = c.decodeOr(.loupeOutlineVisible, d.loupeOutlineVisible)
        loupeMagnification = c.decodeOr(.loupeMagnification, d.loupeMagnification)
        spotlightShape = c.decodeOr(.spotlightShape, d.spotlightShape)
        spotlightDimStrength = c.decodeOr(.spotlightDimStrength, d.spotlightDimStrength)
    }
}

// MARK: - Beautify defaults (beautify-effects phase)

/// The last-used beautify *look*. Deliberately not the toggle and not the
/// effect values: persisting either would mean one dressed-up screenshot
/// silently dressing up the next twenty, or a strong correction leaking into
/// unrelated captures.
struct BeautifyDefaults: Equatable, Codable, Sendable {
    var styleID = Backdrops.defaultID
    var paddingFraction = 0.08
    var cornerRadius = 12.0
    var shadow = ShadowIntensity.medium.rawValue
    var windowFrame = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case styleID, paddingFraction, cornerRadius, shadow, windowFrame
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BeautifyDefaults()
        styleID = c.decodeOr(.styleID, d.styleID)
        paddingFraction = c.decodeOr(.paddingFraction, d.paddingFraction)
        cornerRadius = c.decodeOr(.cornerRadius, d.cornerRadius)
        shadow = c.decodeOr(.shadow, d.shadow)
        windowFrame = c.decodeOr(.windowFrame, d.windowFrame)
    }
}

// MARK: - Selection preferences (selection-mechanics phase)

struct SelectionPrefs: Equatable, Codable, Sendable {
    /// Active aspect lock as width/height; 0 means freeform. Persists across
    /// captures and relaunches.
    var aspectLockRatio = 0.0
    /// Resolution box unit: device pixels (false) or points (true).
    var showSizesInPoints = false

    init() {}

    private enum CodingKeys: String, CodingKey { case aspectLockRatio, showSizesInPoints }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aspectLockRatio = max(0, c.decodeOr(.aspectLockRatio, 0.0))
        showSizesInPoints = c.decodeOr(.showSizesInPoints, false)
    }
}

// MARK: - Root config

struct AppConfig: Equatable, Codable, Sendable {
    var general = GeneralSettings()
    var capture = CaptureSettings()
    var filenames = FilenameSettings()
    var pipeline = PipelineSettings()
    var destinations: [Destination] = []
    var hotkeys = HotkeySettings()
    var editorStyles = EditorStyles()
    var beautify = BeautifyDefaults()
    var selection = SelectionPrefs()
    /// Per-folder %counter state (folder path → last used value).
    var counters: [String: Int] = [:]
    /// Last ~10 saved file paths, newest first.
    var recents: [String] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case general, capture, filenames, pipeline, destinations
        case hotkeys, editorStyles, beautify, selection, counters, recents
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        general = c.decodeOr(.general, GeneralSettings())
        capture = c.decodeOr(.capture, CaptureSettings())
        filenames = c.decodeOr(.filenames, FilenameSettings())
        pipeline = c.decodeOr(.pipeline, PipelineSettings())
        destinations = c.decodeOr(.destinations, [])
        hotkeys = c.decodeOr(.hotkeys, HotkeySettings())
        editorStyles = c.decodeOr(.editorStyles, EditorStyles())
        beautify = c.decodeOr(.beautify, BeautifyDefaults())
        selection = c.decodeOr(.selection, SelectionPrefs())
        counters = c.decodeOr(.counters, [:])
        recents = c.decodeOr(.recents, [])
    }
}
