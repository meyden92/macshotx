import Foundation

/// WebDAV, SFTP and FTP destinations (PRD §6.9.2).
enum ServerUploaders {
    // MARK: - Shared helpers

    /// Joins remoteDirectory + filename into a clean relative path.
    static func remotePath(directory: String, filename: String) -> String {
        var dir = directory
        while dir.hasPrefix("/") { dir.removeFirst() }
        while dir.hasSuffix("/") { dir.removeLast() }
        return dir.isEmpty ? filename : "\(dir)/\(filename)"
    }

    /// Public URL from the destination's template: {filename} (URL-encoded)
    /// and {path} (remoteDirectory/filename, URL-encoded) substituted.
    static func publicURL(settings: ServerSettings, filename: String) -> String? {
        guard !settings.publicURLTemplate.isEmpty else { return nil }
        let encodedName = S3Signer.uriEncode(filename)
        let encodedPath = remotePath(directory: settings.remoteDirectory, filename: filename)
            .split(separator: "/")
            .map { S3Signer.uriEncode(String($0)) }
            .joined(separator: "/")
        return settings.publicURLTemplate
            .replacingOccurrences(of: "{filename}", with: encodedName)
            .replacingOccurrences(of: "{path}", with: encodedPath)
    }

    private static func password(for destination: Destination) -> String? {
        Keychain.get(account: Keychain.secretAccount(for: destination.id, field: "password"))
    }

    /// Write upload bytes to a private temp file for tools that need a path.
    private static func materialize(_ data: Data, filename: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macshot-upload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // MARK: - WebDAV

    /// Builds the PUT request. Separated from sending for testability.
    static func buildWebDAVRequest(
        settings: ServerSettings,
        password: String,
        data: Data?,
        path: String,
        method: String = "PUT"
    ) throws -> URLRequest {
        var base = settings.host
        if !base.contains("://") { base = "https://\(base)" }
        guard var components = URLComponents(string: base), components.host != nil else {
            throw UploadError.invalidConfiguration("WebDAV host is not a valid URL")
        }
        if settings.port > 0 { components.port = settings.port }
        let basePath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        components.percentEncodedPath = basePath + "/" + path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { S3Signer.uriEncode(String($0)) }
            .joined(separator: "/")
        guard let url = components.url else {
            throw UploadError.invalidConfiguration("Could not build WebDAV URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = data
        let credentials = Data("\(settings.username):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func uploadWebDAV(
        data: Data,
        filename: String,
        destination: Destination
    ) async throws -> UploadResult {
        let settings = destination.server
        let password = password(for: destination) ?? ""
        let path = remotePath(directory: settings.remoteDirectory, filename: filename)

        func put() async throws -> (Data, HTTPURLResponse) {
            let request = try buildWebDAVRequest(
                settings: settings, password: password, data: data, path: path
            )
            return try await HTTPClient.send(request)
        }

        var (body, response) = try await put()
        if response.statusCode == 404 || response.statusCode == 409 {
            // Parent collection missing — MKCOL each level, then retry once.
            let segments = path.split(separator: "/").dropLast()
            var partial = ""
            for segment in segments {
                partial += (partial.isEmpty ? "" : "/") + segment
                let mkcol = try buildWebDAVRequest(
                    settings: settings, password: password, data: nil,
                    path: partial, method: "MKCOL"
                )
                _ = try? await HTTPClient.send(mkcol)
            }
            (body, response) = try await put()
        }
        guard (200..<300).contains(response.statusCode) else {
            throw UploadError.badResponse(
                status: response.statusCode,
                body: String(data: body, encoding: .utf8) ?? ""
            )
        }
        let fallback = try buildWebDAVRequest(
            settings: settings, password: "", data: nil, path: path
        ).url?.absoluteString
        return UploadResult(url: publicURL(settings: settings, filename: filename) ?? fallback ?? "")
    }

    // MARK: - SFTP

    /// Batch script for `sftp -b`: create the remote directory tree
    /// (ignoring exists-errors), then upload.
    static func sftpBatchScript(localPath: String, remoteFilePath: String) -> String {
        var lines: [String] = []
        let directories = remoteFilePath.split(separator: "/").dropLast()
        var partial = ""
        for directory in directories {
            partial += (partial.isEmpty ? "" : "/") + directory
            lines.append("-mkdir \"\(partial)\"")
        }
        lines.append("put \"\(localPath)\" \"\(remoteFilePath)\"")
        return lines.joined(separator: "\n") + "\n"
    }

    static func uploadSFTP(
        data: Data,
        filename: String,
        destination: Destination
    ) async throws -> UploadResult {
        let settings = destination.server
        guard !settings.host.isEmpty, !settings.username.isEmpty else {
            throw UploadError.invalidConfiguration("SFTP needs host and username")
        }
        let keyPath = (settings.sshKeyPath as NSString).expandingTildeInPath
        guard !settings.sshKeyPath.isEmpty else {
            throw UploadError.invalidConfiguration(
                "SFTP uploads use SSH key authentication — set an SSH key path "
                + "for \(destination.name) (password-only SFTP is not supported in v1)"
            )
        }

        let local = try materialize(data, filename: filename)
        defer { cleanup(local) }
        let remote = remotePath(directory: settings.remoteDirectory, filename: filename)

        let batch = sftpBatchScript(localPath: local.path, remoteFilePath: remote)
        let batchURL = local.deletingLastPathComponent().appendingPathComponent("batch.sftp")
        try batch.write(to: batchURL, atomically: true, encoding: .utf8)

        var arguments = [
            "-b", batchURL.path,
            "-i", keyPath,
            "-o", "BatchMode=yes",
            // PRD §6.9.2: auto-accept on first connect, reject on mismatch after.
            "-o", "StrictHostKeyChecking=accept-new"
        ]
        if settings.port > 0 {
            arguments += ["-P", String(settings.port)]
        }
        arguments.append("\(settings.username)@\(settings.host)")

        let (status, output) = try await Subprocess.run(
            executable: "/usr/bin/sftp", arguments: arguments
        )
        guard status == 0 else {
            throw UploadError.requestFailed(
                "sftp exited with code \(status): \(output.suffix(300))"
            )
        }
        return UploadResult(url: publicURL(settings: settings, filename: filename))
    }

    // MARK: - FTP

    static func uploadFTP(
        data: Data,
        filename: String,
        destination: Destination
    ) async throws -> UploadResult {
        let settings = destination.server
        guard !settings.host.isEmpty else {
            throw UploadError.invalidConfiguration("FTP needs a host")
        }
        let local = try materialize(data, filename: filename)
        defer { cleanup(local) }

        let host = settings.host
            .replacingOccurrences(of: "ftp://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let port = settings.port > 0 ? settings.port : 21
        let remote = remotePath(directory: settings.remoteDirectory, filename: filename)
            .split(separator: "/")
            .map { S3Signer.uriEncode(String($0)) }
            .joined(separator: "/")
        let url = "ftp://\(host):\(port)/\(remote)"

        // Credentials go through curl's stdin config so they never appear in
        // the process list.
        func escape(_ value: String) -> String {
            value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let password = password(for: destination) ?? ""
        var config = "url = \"\(escape(url))\"\n"
        if !settings.username.isEmpty {
            config += "user = \"\(escape(settings.username)):\(escape(password))\"\n"
        }

        let (status, output) = try await Subprocess.run(
            executable: "/usr/bin/curl",
            arguments: [
                "-sS", "--fail",
                "-T", local.path,
                "--ftp-create-dirs",
                "--config", "-"
            ],
            stdin: Data(config.utf8)
        )
        guard status == 0 else {
            throw UploadError.requestFailed(
                "curl exited with code \(status): \(output.suffix(300))"
            )
        }
        return UploadResult(url: publicURL(settings: settings, filename: filename))
    }
}
