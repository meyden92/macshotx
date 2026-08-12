import CommonCrypto
import CryptoKit
import Foundation

enum ConfigPortError: LocalizedError {
    case invalidFormat
    case passphraseRequired
    case wrongPassphrase

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "The file is not a macshot config bundle."
        case .passphraseRequired:
            return "This bundle is encrypted — a passphrase is required."
        case .wrongPassphrase:
            return "Could not decrypt the bundle with that passphrase."
        }
    }
}

/// Export/import of the full configuration (PRD §7.4). Secrets are excluded
/// unless explicitly included; an optional passphrase encrypts the bundle
/// (PBKDF2-HMAC-SHA256 + AES-GCM).
enum ConfigPorter {
    struct Bundle: Codable {
        var config: AppConfig
        /// Keychain account → secret value, only when the user opted in.
        var secrets: [String: String]?
    }

    private struct Envelope: Codable {
        var macshotEncryptedBundle: Int
        var salt: String
        var data: String
    }

    // MARK: - Export

    static func export(
        config: AppConfig,
        secrets: [String: String]?,
        passphrase: String?
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bundle = Bundle(config: config, secrets: secrets)
        let plain = try encoder.encode(bundle)

        guard let passphrase, !passphrase.isEmpty else { return plain }

        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        let key = try deriveKey(passphrase: passphrase, salt: salt)
        let sealed = try AES.GCM.seal(plain, using: key)
        guard let combined = sealed.combined else {
            throw ConfigPortError.invalidFormat
        }
        let envelope = Envelope(
            macshotEncryptedBundle: 1,
            salt: salt.base64EncodedString(),
            data: combined.base64EncodedString()
        )
        return try encoder.encode(envelope)
    }

    // MARK: - Import

    static func isEncrypted(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(Envelope.self, from: data)) != nil
    }

    static func `import`(_ data: Data, passphrase: String?) throws -> Bundle {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(Envelope.self, from: data) {
            guard let passphrase, !passphrase.isEmpty else {
                throw ConfigPortError.passphraseRequired
            }
            guard
                let salt = Data(base64Encoded: envelope.salt),
                let combined = Data(base64Encoded: envelope.data),
                let box = try? AES.GCM.SealedBox(combined: combined)
            else {
                throw ConfigPortError.invalidFormat
            }
            let key = try deriveKey(passphrase: passphrase, salt: salt)
            guard let plain = try? AES.GCM.open(box, using: key) else {
                throw ConfigPortError.wrongPassphrase
            }
            return try parsePlain(plain)
        }
        return try parsePlain(data)
    }

    private static func parsePlain(_ data: Data) throws -> Bundle {
        let decoder = JSONDecoder()
        if let bundle = try? decoder.decode(Bundle.self, from: data) {
            return bundle
        }
        // A bare config.json is also accepted.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["config"] == nil,
           let config = try? decoder.decode(AppConfig.self, from: data) {
            return Bundle(config: config, secrets: nil)
        }
        throw ConfigPortError.invalidFormat
    }

    // MARK: - Secrets

    static func gatherSecrets(for destinations: [Destination]) -> [String: String] {
        var secrets: [String: String] = [:]
        for destination in destinations {
            for field in ["secretKey", "password"] {
                let account = Keychain.secretAccount(for: destination.id, field: field)
                if let value = Keychain.get(account: account), !value.isEmpty {
                    secrets[account] = value
                }
            }
        }
        return secrets
    }

    static func restoreSecrets(_ secrets: [String: String]) {
        for (account, value) in secrets {
            Keychain.set(value, account: account)
        }
    }

    /// Shell commands an imported config would run — surfaced before
    /// activation (PRD §15: malicious config sharing mitigation).
    static func shellCommands(in config: AppConfig) -> [String] {
        var pipelines = [config.pipeline.global]
        for override in [config.pipeline.region, config.pipeline.window, config.pipeline.fullscreen] {
            if case .replace(let actions) = override {
                pipelines.append(actions)
            }
        }
        return pipelines.flatMap { actions in
            actions.compactMap { action in
                if case .runShell(let command) = action { return command }
                return nil
            }
        }
    }

    // MARK: - Key derivation

    private static func deriveKey(passphrase: String, salt: Data) throws -> SymmetricKey {
        var derived = Data(count: 32)
        let passData = Data(passphrase.utf8)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                passData.withUnsafeBytes { passBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        210_000,
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw ConfigPortError.invalidFormat }
        return SymmetricKey(data: derived)
    }
}
