import Foundation

/// Parses the JSON stored in the `Claude Code-credentials` item into a `KeychainCredential`.
/// The value nests the OAuth fields under a `claudeAiOauth` key; this parser also accepts
/// the fields at the top level so a future format change degrades gracefully.
/// Kept separate from the Keychain I/O so the parsing is unit-testable without the Keychain.
enum KeychainCredentialParser {
    static func parse(_ data: Data) throws -> KeychainCredential {
        let decoder = JSONDecoder()
        if let wrapper = try? decoder.decode(Wrapper.self, from: data),
           let oauth = wrapper.claudeAiOauth {
            return oauth
        }
        do {
            return try decoder.decode(KeychainCredential.self, from: data)
        } catch {
            throw KeychainError.invalidData
        }
    }

    private struct Wrapper: Decodable {
        let claudeAiOauth: KeychainCredential?
    }
}
