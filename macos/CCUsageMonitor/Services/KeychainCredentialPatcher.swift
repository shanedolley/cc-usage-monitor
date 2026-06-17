import Foundation

/// Patches the token fields inside the stored Keychain JSON, preserving every other field.
/// Pure and unit-testable, separate from the Keychain I/O. Named to match its sibling
/// `KeychainCredentialParser`.
enum KeychainCredentialPatcher {
    static func patch(_ data: Data, accessToken: String, refreshToken: String,
                      expiresAt: TimeInterval) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KeychainError.invalidData
        }
        // expiresAt is stored as an integer millisecond value in the original item.
        let expiresAtInt = Int(expiresAt.rounded())

        if var oauth = root["claudeAiOauth"] as? [String: Any] {
            oauth["accessToken"] = accessToken
            oauth["refreshToken"] = refreshToken
            oauth["expiresAt"] = expiresAtInt
            root["claudeAiOauth"] = oauth
        } else {
            root["accessToken"] = accessToken
            root["refreshToken"] = refreshToken
            root["expiresAt"] = expiresAtInt
        }
        return try JSONSerialization.data(withJSONObject: root)
    }
}
