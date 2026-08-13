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

// MARK: - Capture modes

enum CaptureMode: String, Codable, Sendable {
    case region
    case window
    case fullscreen
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

enum PipelineOverride: Equatable, Codable, Sendable {
    case useGlobal
    case replace([PipelineAction])

    private enum CodingKeys: String, CodingKey { case mode, actions }
    private enum Kind: String, Codable { case useGlobal, replace }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch container.decodeOr(.mode, Kind.useGlobal) {
        case .useGlobal: self = .useGlobal
        case .replace: self = .replace(container.decodeOr(.actions, []))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .useGlobal:
            try container.encode(Kind.useGlobal, forKey: .mode)
        case .replace(let actions):
            try container.encode(Kind.replace, forKey: .mode)
            try container.encode(actions, forKey: .actions)
        }
    }
}

struct PipelineSettings: Equatable, Codable, Sendable {
    var global: [PipelineAction] = [.copyImage, .saveToDisk]
    var region: PipelineOverride = .useGlobal
    var window: PipelineOverride = .useGlobal
    var fullscreen: PipelineOverride = .useGlobal

    func actions(for mode: CaptureMode) -> [PipelineAction] {
        let override: PipelineOverride
        switch mode {
        case .region: override = region
        case .window: override = window
        case .fullscreen: override = fullscreen
        }
        switch override {
        case .useGlobal: return global
        case .replace(let actions): return actions
        }
    }

    init() {}

    private enum CodingKeys: String, CodingKey { case global, region, window, fullscreen }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        global = c.decodeOr(.global, [.copyImage, .saveToDisk])
        region = c.decodeOr(.region, .useGlobal)
        window = c.decodeOr(.window, .useGlobal)
        fullscreen = c.decodeOr(.fullscreen, .useGlobal)
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

    init() {}

    private enum CodingKeys: String, CodingKey {
        case notificationsEnabled, captureFeedbackEnabled, launchAtLogin, colorFormat
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notificationsEnabled = c.decodeOr(.notificationsEnabled, true)
        captureFeedbackEnabled = c.decodeOr(.captureFeedbackEnabled, true)
        launchAtLogin = c.decodeOr(.launchAtLogin, false)
        colorFormat = c.decodeOr(.colorFormat, .hex)
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

    /// JPEG cannot store transparency. HEIC can — verified against the system
    /// encoder by round-tripping a transparent image, not assumed.
    var supportsAlpha: Bool { self != .jpeg }

    /// The format a run should actually use. Resolved in one place so the
    /// encode call and the filename extension can never disagree and write PNG
    /// bytes into a `.jpg`. Flattening the transparency onto a colour was
    /// rejected: it destroys the thing the user clicked a button to create.
    func effective(mayContainTransparency: Bool) -> ImageFormat {
        guard mayContainTransparency, !supportsAlpha else { return self }
        Log.info("\(rawValue) cannot store transparency; writing png instead")
        return .png
    }
}

struct CaptureSettings: Equatable, Codable, Sendable {
    var saveDirectory = "~/Pictures/macshot"
    var format = ImageFormat.png
    /// 1–100, applies to jpeg/heic only.
    var quality = 90
    /// Training-wheel chrome in the capture overlay: the idle helper card and
    /// the selecting-state hint.
    var showOverlayHints = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case saveDirectory, format, quality, showOverlayHints
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        saveDirectory = c.decodeOr(.saveDirectory, "~/Pictures/macshot")
        format = c.decodeOr(.format, .png)
        quality = min(100, max(1, c.decodeOr(.quality, 90)))
        showOverlayHints = c.decodeOr(.showOverlayHints, true)
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
