import Foundation

/// ShareX-compatible custom HTTP uploader (PRD §6.9.3).
enum CustomUploader {
    // MARK: - Request building

    static func buildRequest(
        settings: CustomUploaderSettings,
        data: Data,
        filename: String,
        contentType: String,
        boundary: String = "macshot-\(UUID().uuidString)"
    ) throws -> URLRequest {
        let context = FilenameTemplate.Context()
        func expand(_ template: String) -> String {
            FilenameTemplate.expand(template, context: context)
        }

        guard var components = URLComponents(string: expand(settings.requestURL)),
              components.host != nil
        else {
            throw UploadError.invalidConfiguration("Request URL is not a valid URL")
        }
        if !settings.parameters.isEmpty {
            var items = components.queryItems ?? []
            for (name, value) in settings.parameters.sorted(by: { $0.key < $1.key }) {
                items.append(URLQueryItem(name: name, value: expand(value)))
            }
            components.queryItems = items
        }
        guard let url = components.url else {
            throw UploadError.invalidConfiguration("Could not build request URL")
        }

        var request = URLRequest(url: url)
        let method = settings.requestMethod.uppercased()
        guard method == "POST" || method == "PUT" else {
            throw UploadError.invalidConfiguration(
                "Unsupported request method \"\(settings.requestMethod)\" (POST and PUT only)"
            )
        }
        request.httpMethod = method
        for (name, value) in settings.headers {
            request.setValue(expand(value), forHTTPHeaderField: name)
        }

        switch settings.bodyType {
        case "MultipartFormData":
            var body = Data()
            func append(_ string: String) { body.append(Data(string.utf8)) }
            for (name, value) in settings.arguments.sorted(by: { $0.key < $1.key }) {
                append("--\(boundary)\r\n")
                append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
                append("\(expand(value))\r\n")
            }
            append("--\(boundary)\r\n")
            append(
                "Content-Disposition: form-data; name=\"\(settings.fileFormName)\"; "
                + "filename=\"\(filename)\"\r\n"
            )
            append("Content-Type: \(contentType)\r\n\r\n")
            body.append(data)
            append("\r\n--\(boundary)--\r\n")
            request.setValue(
                "multipart/form-data; boundary=\(boundary)",
                forHTTPHeaderField: "Content-Type"
            )
            request.httpBody = body

        case "Binary":
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
            request.httpBody = data

        case "JSON":
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            request.httpBody = Data(expand(settings.body).utf8)

        case "FormURLEncoded":
            let encoded = settings.arguments
                .sorted { $0.key < $1.key }
                .map { "\(formEncode($0.key))=\(formEncode(expand($0.value)))" }
                .joined(separator: "&")
            request.setValue(
                "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"
            )
            request.httpBody = Data(encoded.utf8)

        default:
            throw UploadError.invalidConfiguration(
                "Unsupported body type \"\(settings.bodyType)\""
            )
        }
        return request
    }

    private static func formEncode(_ string: String) -> String {
        S3Signer.uriEncode(string)
    }

    // MARK: - Response templates

    /// Expand `{response}`, `{json:path.to[0].field}` and `{regex:index|group}`
    /// against the response body. Unknown constructs stay literal.
    static func expandResponseTemplate(
        _ template: String,
        response: String,
        regexList: [String]
    ) -> String {
        guard !template.isEmpty else { return response }
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else {
                out += rest[open...]
                return out
            }
            let token = rest[rest.index(after: open)..<close]
            if token == "response" {
                out += response
            } else if token.hasPrefix("json:") {
                out += jsonValue(at: String(token.dropFirst(5)), in: response) ?? ""
            } else if token.hasPrefix("regex:") {
                out += regexValue(spec: String(token.dropFirst(6)), in: response, regexList: regexList) ?? ""
            } else {
                out += "{\(token)}"
            }
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        return out
    }

    /// Walk a dotted JSON path with optional [index] subscripts, e.g.
    /// `files[0].url` or `data.link`.
    static func jsonValue(at path: String, in response: String) -> String? {
        guard let root = try? JSONSerialization.jsonObject(
            with: Data(response.utf8), options: [.fragmentsAllowed]
        ) else { return nil }

        var current: Any = root
        for rawSegment in path.split(separator: ".") {
            var segment = Substring(rawSegment)
            var indexes: [Int] = []
            while segment.hasSuffix("]"), let bracket = segment.lastIndex(of: "[") {
                guard let idx = Int(segment[segment.index(after: bracket)..<segment.index(before: segment.endIndex)])
                else { return nil }
                indexes.insert(idx, at: 0)
                segment = segment[..<bracket]
            }
            if !segment.isEmpty {
                guard let dict = current as? [String: Any],
                      let next = dict[String(segment)]
                else { return nil }
                current = next
            }
            for idx in indexes {
                guard let array = current as? [Any], array.indices.contains(idx)
                else { return nil }
                current = array[idx]
            }
        }
        switch current {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    /// `{regex:index}` or `{regex:index|group}` — pattern from regexList,
    /// capture group by number (0 = whole match).
    static func regexValue(spec: String, in response: String, regexList: [String]) -> String? {
        let parts = spec.split(separator: "|", maxSplits: 1)
        guard let patternIndex = Int(parts[0]),
              regexList.indices.contains(patternIndex),
              let regex = try? NSRegularExpression(pattern: regexList[patternIndex])
        else { return nil }
        let group = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0

        let range = NSRange(response.startIndex..., in: response)
        guard let match = regex.firstMatch(in: response, range: range),
              group < match.numberOfRanges,
              let groupRange = Range(match.range(at: group), in: response)
        else { return nil }
        return String(response[groupRange])
    }

    // MARK: - Upload

    static func upload(
        data: Data,
        filename: String,
        destination: Destination,
        contentType: String
    ) async throws -> UploadResult {
        let settings = destination.custom
        let request = try buildRequest(
            settings: settings, data: data, filename: filename, contentType: contentType
        )
        let (body, response) = try await HTTPClient.send(request)
        let text = String(data: body, encoding: .utf8) ?? ""
        guard (200..<300).contains(response.statusCode) else {
            throw UploadError.badResponse(status: response.statusCode, body: text)
        }
        func expandOrNil(_ template: String) -> String? {
            guard !template.isEmpty else { return nil }
            let result = expandResponseTemplate(template, response: text, regexList: settings.regexList)
            return result.isEmpty ? nil : result
        }
        return UploadResult(
            // ShareX behavior: empty URL template means the whole response is the URL.
            url: expandOrNil(settings.urlTemplate)
                ?? text.trimmingCharacters(in: .whitespacesAndNewlines),
            thumbnailURL: expandOrNil(settings.thumbnailURLTemplate),
            deletionURL: expandOrNil(settings.deletionURLTemplate)
        )
    }
}

/// Imports ShareX `.sxcu` JSON into a Destination (PRD §6.9.3).
enum SxcuImporter {
    static func parse(_ data: Data) throws -> Destination {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UploadError.invalidConfiguration(".sxcu file is not valid JSON")
        }
        guard let requestURL = root["RequestURL"] as? String, !requestURL.isEmpty else {
            throw UploadError.invalidConfiguration(".sxcu file has no RequestURL")
        }

        var destination = Destination()
        destination.kind = .customHTTP
        destination.name = (root["Name"] as? String) ?? "Imported uploader"

        var custom = CustomUploaderSettings()
        custom.requestURL = requestURL
        // Older ShareX exports use "RequestType" instead of "RequestMethod".
        custom.requestMethod = (root["RequestMethod"] as? String)
            ?? (root["RequestType"] as? String)
            ?? "POST"
        custom.headers = (root["Headers"] as? [String: String]) ?? [:]
        custom.parameters = (root["Parameters"] as? [String: String]) ?? [:]
        custom.arguments = stringify(root["Arguments"] as? [String: Any] ?? [:])
        custom.bodyType = (root["Body"] as? String) ?? "MultipartFormData"
        custom.fileFormName = (root["FileFormName"] as? String) ?? "file"
        custom.body = (root["Data"] as? String) ?? ""
        custom.urlTemplate = (root["URL"] as? String) ?? ""
        custom.thumbnailURLTemplate = (root["ThumbnailURL"] as? String) ?? ""
        custom.deletionURLTemplate = (root["DeletionURL"] as? String) ?? ""
        custom.regexList = (root["RegexList"] as? [String]) ?? []
        destination.custom = custom
        return destination
    }

    private static func stringify(_ dict: [String: Any]) -> [String: String] {
        dict.mapValues { value in
            if let string = value as? String { return string }
            if let number = value as? NSNumber { return number.stringValue }
            return ""
        }
    }
}
