import CryptoKit
import Foundation

/// AWS Signature Version 4 request signing, implemented directly so any
/// S3-compatible endpoint (AWS, R2, B2, MinIO, Wasabi) works without an SDK.
enum S3Signer {
    /// Returns the headers to send, including Authorization.
    /// `headers` must already include "host"; payloadHash is hex SHA-256 of the body.
    static func sign(
        method: String,
        url: URL,
        headers: [String: String],
        payloadHash: String,
        accessKey: String,
        secretKey: String,
        region: String,
        date: Date
    ) -> [String: String] {
        let isoFormatter = DateFormatter()
        isoFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        isoFormatter.timeZone = TimeZone(identifier: "UTC")
        isoFormatter.locale = Locale(identifier: "en_US_POSIX")
        let amzDate = isoFormatter.string(from: date)
        let dateStamp = String(amzDate.prefix(8))

        var allHeaders = headers
        allHeaders["x-amz-date"] = amzDate
        allHeaders["x-amz-content-sha256"] = payloadHash

        let sortedHeaderNames = allHeaders.keys
            .map { $0.lowercased() }
            .sorted()
        let canonicalHeaders = sortedHeaderNames
            .map { name in
                let value = allHeaders.first { $0.key.lowercased() == name }!.value
                return "\(name):\(value.trimmingCharacters(in: .whitespaces))\n"
            }
            .joined()
        let signedHeaders = sortedHeaderNames.joined(separator: ";")

        let canonicalQuery = (URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems ?? [])
            .map { (uriEncode($0.name), uriEncode($0.value ?? "")) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")

        let canonicalRequest = [
            method,
            canonicalURI(of: url),
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/s3/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            hexSHA256(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        let dateKey = hmac(key: Data("AWS4\(secretKey)".utf8), data: Data(dateStamp.utf8))
        let regionKey = hmac(key: dateKey, data: Data(region.utf8))
        let serviceKey = hmac(key: regionKey, data: Data("s3".utf8))
        let signingKey = hmac(key: serviceKey, data: Data("aws4_request".utf8))
        let signature = hmac(key: signingKey, data: Data(stringToSign.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        allHeaders["Authorization"] =
            "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)"
        return allHeaders
    }

    /// Path with each segment URI-encoded, slashes preserved.
    private static func canonicalURI(of url: URL) -> String {
        let path = url.path.isEmpty ? "/" : url.path
        return path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { uriEncode(String($0)) }
            .joined(separator: "/")
    }

    /// AWS-style URI encoding: unreserved characters per RFC 3986 only.
    static func uriEncode(_ string: String) -> String {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }

    static func hexSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: data, using: SymmetricKey(data: key)
        ))
    }
}

enum S3Uploader {
    /// Build the signed PUT request. Separated from sending for testability.
    static func buildRequest(
        data: Data,
        filename: String,
        settings: S3Settings,
        secretKey: String,
        contentType: String,
        date: Date = Date()
    ) throws -> (request: URLRequest, key: String) {
        guard var components = URLComponents(string: settings.endpoint),
              components.host != nil
        else {
            throw UploadError.invalidConfiguration("S3 endpoint is not a valid URL")
        }
        guard !settings.bucket.isEmpty else {
            throw UploadError.invalidConfiguration("S3 bucket is empty")
        }

        var key = settings.pathPrefix
        if !key.isEmpty && !key.hasSuffix("/") { key += "/" }
        key += filename

        // Path-style addressing works on every S3-compatible server.
        components.path = "/\(settings.bucket)/\(key)"
        guard let url = components.url else {
            throw UploadError.invalidConfiguration("Could not build S3 object URL")
        }

        var headers: [String: String] = [
            "host": components.host! + (components.port.map { ":\($0)" } ?? ""),
            "content-type": contentType
        ]
        if settings.publicReadACL {
            headers["x-amz-acl"] = "public-read"
        }
        if settings.serverSideEncryption {
            headers["x-amz-server-side-encryption"] = "AES256"
        }

        let signed = S3Signer.sign(
            method: "PUT",
            url: url,
            headers: headers,
            payloadHash: S3Signer.hexSHA256(data),
            accessKey: settings.accessKey,
            secretKey: secretKey,
            region: settings.region.isEmpty ? "auto" : settings.region,
            date: date
        )

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        for (name, value) in signed where name.lowercased() != "host" {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = data
        return (request, key)
    }

    /// Public URL for a stored object: the CDN template if configured
    /// ({key} substituted), otherwise the path-style endpoint URL.
    static func publicURL(for key: String, settings: S3Settings) -> String {
        let encodedKey = key
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { S3Signer.uriEncode(String($0)) }
            .joined(separator: "/")
        if !settings.publicURLTemplate.isEmpty {
            return settings.publicURLTemplate
                .replacingOccurrences(of: "{key}", with: encodedKey)
        }
        let base = settings.endpoint.hasSuffix("/")
            ? String(settings.endpoint.dropLast())
            : settings.endpoint
        return "\(base)/\(settings.bucket)/\(encodedKey)"
    }

    static func upload(
        data: Data,
        filename: String,
        destination: Destination,
        contentType: String
    ) async throws -> UploadResult {
        guard let secretKey = Keychain.get(
            account: Keychain.secretAccount(for: destination.id, field: "secretKey")
        ) else {
            throw UploadError.missingSecret("S3 secret key for \(destination.name)")
        }
        let (request, key) = try buildRequest(
            data: data,
            filename: filename,
            settings: destination.s3,
            secretKey: secretKey,
            contentType: contentType
        )
        let (body, response) = try await HTTPClient.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw UploadError.badResponse(
                status: response.statusCode,
                body: String(data: body, encoding: .utf8) ?? ""
            )
        }
        return UploadResult(url: S3Uploader.publicURL(for: key, settings: destination.s3))
    }
}

enum HTTPClient {
    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw UploadError.requestFailed("Non-HTTP response")
            }
            return (data, http)
        } catch let error as UploadError {
            throw error
        } catch {
            throw UploadError.requestFailed(error.localizedDescription)
        }
    }
}
