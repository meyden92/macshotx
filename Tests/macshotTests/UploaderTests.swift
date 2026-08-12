import Foundation
import Testing
@testable import MacshotCore

// MARK: - S3 SigV4

/// AWS's published SigV4 test vector ("Example: GET Object" from the
/// S3 API reference) — exact signature match proves the signer.
@Test
func sigV4MatchesAWSTestVector() {
    var components = DateComponents()
    components.year = 2013
    components.month = 5
    components.day = 24
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let date = calendar.date(from: components)!

    let signed = S3Signer.sign(
        method: "GET",
        url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!,
        headers: [
            "host": "examplebucket.s3.amazonaws.com",
            "range": "bytes=0-9"
        ],
        payloadHash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        accessKey: "AKIAIOSFODNN7EXAMPLE",
        secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        region: "us-east-1",
        date: date
    )

    let expected = "AWS4-HMAC-SHA256 "
        + "Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, "
        + "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, "
        + "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
    #expect(signed["Authorization"] == expected)
    #expect(signed["x-amz-date"] == "20130524T000000Z")
}

@Test
func s3RequestUsesPathStyleAndOptions() throws {
    var settings = S3Settings()
    settings.endpoint = "https://account.r2.cloudflarestorage.com"
    settings.region = "auto"
    settings.bucket = "shots"
    settings.accessKey = "AK"
    settings.pathPrefix = "screens"
    settings.publicReadACL = true
    settings.serverSideEncryption = true

    let (request, key) = try S3Uploader.buildRequest(
        data: Data("img".utf8),
        filename: "a b.png",
        settings: settings,
        secretKey: "SK",
        contentType: "image/png"
    )
    #expect(key == "screens/a b.png")
    #expect(request.httpMethod == "PUT")
    #expect(request.url?.absoluteString
        == "https://account.r2.cloudflarestorage.com/shots/screens/a%20b.png")
    #expect(request.value(forHTTPHeaderField: "x-amz-acl") == "public-read")
    #expect(request.value(forHTTPHeaderField: "x-amz-server-side-encryption") == "AES256")
    #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("AWS4-HMAC-SHA256") == true)
}

@Test
func s3PublicURLPrefersTemplate() {
    var settings = S3Settings()
    settings.endpoint = "https://s3.example.com"
    settings.bucket = "shots"
    settings.publicURLTemplate = "https://cdn.example.com/{key}"

    #expect(S3Uploader.publicURL(for: "x/y z.png", settings: settings)
        == "https://cdn.example.com/x/y%20z.png")

    settings.publicURLTemplate = ""
    #expect(S3Uploader.publicURL(for: "x.png", settings: settings)
        == "https://s3.example.com/shots/x.png")
}

// MARK: - Custom HTTP uploader

@Test
func multipartRequestContainsFileAndArguments() throws {
    var settings = CustomUploaderSettings()
    settings.requestURL = "https://up.example.com/upload"
    settings.parameters = ["k": "v"]
    settings.arguments = ["album": "shots"]
    settings.headers = ["Authorization": "Bearer token123"]
    settings.fileFormName = "image"

    let request = try CustomUploader.buildRequest(
        settings: settings,
        data: Data("PNGDATA".utf8),
        filename: "shot.png",
        contentType: "image/png",
        boundary: "BOUNDARY"
    )

    #expect(request.url?.absoluteString == "https://up.example.com/upload?k=v")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token123")
    #expect(request.value(forHTTPHeaderField: "Content-Type")
        == "multipart/form-data; boundary=BOUNDARY")

    let body = String(data: request.httpBody!, encoding: .utf8)!
    #expect(body.contains("Content-Disposition: form-data; name=\"album\"\r\n\r\nshots"))
    #expect(body.contains(
        "Content-Disposition: form-data; name=\"image\"; filename=\"shot.png\""
    ))
    #expect(body.contains("Content-Type: image/png"))
    #expect(body.contains("PNGDATA"))
    #expect(body.hasSuffix("--BOUNDARY--\r\n"))
}

@Test
func binaryAndJSONBodies() throws {
    var settings = CustomUploaderSettings()
    settings.requestURL = "https://up.example.com/u"
    settings.requestMethod = "PUT"
    settings.bodyType = "Binary"

    let binary = try CustomUploader.buildRequest(
        settings: settings, data: Data([1, 2, 3]), filename: "s.png", contentType: "image/png"
    )
    #expect(binary.httpMethod == "PUT")
    #expect(binary.httpBody == Data([1, 2, 3]))
    #expect(binary.value(forHTTPHeaderField: "Content-Type") == "image/png")

    settings.bodyType = "JSON"
    settings.body = #"{"name": "test"}"#
    let json = try CustomUploader.buildRequest(
        settings: settings, data: Data(), filename: "s.png", contentType: "image/png"
    )
    #expect(json.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(String(data: json.httpBody!, encoding: .utf8) == #"{"name": "test"}"#)
}

@Test
func unsupportedMethodOrBodyTypeIsRejected() {
    var settings = CustomUploaderSettings()
    settings.requestURL = "https://up.example.com/u"
    settings.requestMethod = "DELETE"
    #expect(throws: UploadError.self) {
        _ = try CustomUploader.buildRequest(
            settings: settings, data: Data(), filename: "s.png", contentType: "image/png"
        )
    }

    settings.requestMethod = "POST"
    settings.bodyType = "Telepathy"
    #expect(throws: UploadError.self) {
        _ = try CustomUploader.buildRequest(
            settings: settings, data: Data(), filename: "s.png", contentType: "image/png"
        )
    }
}

@Test
func jsonResponsePathTraversal() {
    let response = #"{"files": [{"url": "https://i.example.com/abc.png"}], "ok": true, "n": 7}"#
    #expect(CustomUploader.jsonValue(at: "files[0].url", in: response)
        == "https://i.example.com/abc.png")
    #expect(CustomUploader.jsonValue(at: "n", in: response) == "7")
    #expect(CustomUploader.jsonValue(at: "missing.path", in: response) == nil)
    #expect(CustomUploader.jsonValue(at: "files[5].url", in: response) == nil)
}

@Test
func responseTemplateExpansion() {
    let response = #"{"data": {"link": "https://x/1.png"}}"#
    #expect(CustomUploader.expandResponseTemplate(
        "{json:data.link}", response: response, regexList: []
    ) == "https://x/1.png")

    #expect(CustomUploader.expandResponseTemplate(
        "{response}", response: "plain", regexList: []
    ) == "plain")

    // Empty template → ShareX treats the whole response as the URL.
    #expect(CustomUploader.expandResponseTemplate(
        "", response: "https://x/2.png", regexList: []
    ) == "https://x/2.png")

    #expect(CustomUploader.expandResponseTemplate(
        "https://host/{regex:0|1}",
        response: "id=abc123;",
        regexList: ["id=([a-z0-9]+)"]
    ) == "https://host/abc123")

    // Unknown constructs stay literal.
    #expect(CustomUploader.expandResponseTemplate(
        "{nope}", response: "x", regexList: []
    ) == "{nope}")
}

@Test
func sxcuImportMapsShareXFields() throws {
    let sxcu = #"""
    {
      "Version": "14.1.0",
      "Name": "My Zipline",
      "DestinationType": "ImageUploader, FileUploader",
      "RequestMethod": "POST",
      "RequestURL": "https://zip.example.com/api/upload",
      "Headers": { "authorization": "TOKEN" },
      "Body": "MultipartFormData",
      "FileFormName": "file",
      "Arguments": { "format": "random" },
      "URL": "{json:files[0].url}",
      "DeletionURL": "{json:files[0].deleteUrl}"
    }
    """#
    let destination = try SxcuImporter.parse(Data(sxcu.utf8))
    #expect(destination.kind == .customHTTP)
    #expect(destination.name == "My Zipline")
    #expect(destination.custom.requestURL == "https://zip.example.com/api/upload")
    #expect(destination.custom.headers["authorization"] == "TOKEN")
    #expect(destination.custom.arguments["format"] == "random")
    #expect(destination.custom.urlTemplate == "{json:files[0].url}")
    #expect(destination.custom.deletionURLTemplate == "{json:files[0].deleteUrl}")
}

@Test
func sxcuImportRejectsGarbage() {
    #expect(throws: UploadError.self) {
        _ = try SxcuImporter.parse(Data("not json".utf8))
    }
    #expect(throws: UploadError.self) {
        _ = try SxcuImporter.parse(Data("{}".utf8))
    }
}

// MARK: - WebDAV / SFTP helpers

@Test
func webDAVRequestBuildsURLAndAuth() throws {
    var settings = ServerSettings()
    settings.host = "dav.example.com"
    settings.port = 8443
    settings.username = "user"
    settings.remoteDirectory = "shots"

    let request = try ServerUploaders.buildWebDAVRequest(
        settings: settings,
        password: "pw",
        data: Data("x".utf8),
        path: "shots/a b.png"
    )
    #expect(request.url?.absoluteString == "https://dav.example.com:8443/shots/a%20b.png")
    #expect(request.httpMethod == "PUT")
    let expectedAuth = "Basic " + Data("user:pw".utf8).base64EncodedString()
    #expect(request.value(forHTTPHeaderField: "Authorization") == expectedAuth)
}

@Test
func webDAVRespectsExistingSchemeAndBasePath() throws {
    var settings = ServerSettings()
    settings.host = "http://nas.local/dav"

    let request = try ServerUploaders.buildWebDAVRequest(
        settings: settings, password: "", data: nil, path: "x.png"
    )
    #expect(request.url?.absoluteString == "http://nas.local/dav/x.png")
}

@Test
func remotePathJoining() {
    #expect(ServerUploaders.remotePath(directory: "/shots/", filename: "a.png") == "shots/a.png")
    #expect(ServerUploaders.remotePath(directory: "", filename: "a.png") == "a.png")
}

@Test
func serverPublicURLTemplates() {
    var settings = ServerSettings()
    settings.remoteDirectory = "shots"
    settings.publicURLTemplate = "https://files.example.com/{path}"
    #expect(ServerUploaders.publicURL(settings: settings, filename: "a b.png")
        == "https://files.example.com/shots/a%20b.png")

    settings.publicURLTemplate = "https://files.example.com/{filename}"
    #expect(ServerUploaders.publicURL(settings: settings, filename: "a b.png")
        == "https://files.example.com/a%20b.png")

    settings.publicURLTemplate = ""
    #expect(ServerUploaders.publicURL(settings: settings, filename: "a.png") == nil)
}

@Test
func sftpBatchScriptCreatesTreeThenUploads() {
    let script = ServerUploaders.sftpBatchScript(
        localPath: "/tmp/x.png",
        remoteFilePath: "a/b/x.png"
    )
    #expect(script == """
    -mkdir "a"
    -mkdir "a/b"
    put "/tmp/x.png" "a/b/x.png"

    """)
}
