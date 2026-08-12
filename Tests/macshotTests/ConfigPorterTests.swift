import Foundation
import Testing
@testable import MacshotCore

private func sampleConfig() -> AppConfig {
    var config = AppConfig()
    config.capture.format = .jpeg
    config.filenames.template = "%mode/%counter"
    config.pipeline.global = [.saveToDisk, .runShell(command: "echo hi")]
    config.pipeline.window = .replace([.runShell(command: "open $1")])
    var destination = Destination()
    destination.name = "bucket"
    destination.kind = .s3
    config.destinations = [destination]
    return config
}

@Test
func plainExportRoundTrips() throws {
    let config = sampleConfig()
    let data = try ConfigPorter.export(config: config, secrets: nil, passphrase: nil)
    #expect(!ConfigPorter.isEncrypted(data))

    let bundle = try ConfigPorter.import(data, passphrase: nil)
    #expect(bundle.config == config)
    #expect(bundle.secrets == nil)
}

@Test
func secretsAreIncludedOnlyWhenAsked() throws {
    let config = sampleConfig()
    let secrets = ["destination.X.secretKey": "hunter2"]
    let data = try ConfigPorter.export(config: config, secrets: secrets, passphrase: nil)

    // Plain export with secrets carries them verbatim…
    let bundle = try ConfigPorter.import(data, passphrase: nil)
    #expect(bundle.secrets == secrets)

    // …and without, the JSON must not contain the secret value at all.
    let withoutSecrets = try ConfigPorter.export(config: config, secrets: nil, passphrase: nil)
    #expect(!String(data: withoutSecrets, encoding: .utf8)!.contains("hunter2"))
}

@Test
func encryptedExportRoundTripsAndRejectsWrongPassphrase() throws {
    let config = sampleConfig()
    let data = try ConfigPorter.export(
        config: config,
        secrets: ["a": "b"],
        passphrase: "correct horse"
    )
    #expect(ConfigPorter.isEncrypted(data))
    // Ciphertext must not leak plaintext markers.
    let text = String(data: data, encoding: .utf8)!
    #expect(!text.contains("saveToDisk"))

    let bundle = try ConfigPorter.import(data, passphrase: "correct horse")
    #expect(bundle.config == config)
    #expect(bundle.secrets == ["a": "b"])

    #expect(throws: ConfigPortError.self) {
        _ = try ConfigPorter.import(data, passphrase: "wrong")
    }
    #expect(throws: ConfigPortError.self) {
        _ = try ConfigPorter.import(data, passphrase: nil)
    }
}

@Test
func bareConfigJSONIsAccepted() throws {
    let config = sampleConfig()
    let raw = try JSONEncoder().encode(config)
    let bundle = try ConfigPorter.import(raw, passphrase: nil)
    #expect(bundle.config == config)
}

@Test
func garbageIsRejected() {
    #expect(throws: ConfigPortError.self) {
        _ = try ConfigPorter.import(Data("not json".utf8), passphrase: nil)
    }
}

@Test
func shellCommandsAreSurfacedFromAllPipelines() {
    let commands = ConfigPorter.shellCommands(in: sampleConfig())
    #expect(commands == ["echo hi", "open $1"])
}
