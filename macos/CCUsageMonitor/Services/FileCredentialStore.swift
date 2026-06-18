import Foundation

/// Stores the subscription OAuth credential in a file, the file-backed alternative to the macOS
/// Keychain. It conforms to both `KeychainReading` and `KeychainWriting`, so `TokenManager` drives
/// it with the same read, refresh, and write-back loop it runs against the Keychain, unchanged.
///
/// The monitor needs the subscription credential, which carries the `user:profile` scope and a
/// refresh token. `claude setup-token` grants neither, so the file is seeded once from a
/// `claude /login` credential (see install.md). After that the app refreshes the token itself and
/// never reads the Keychain, which sidesteps the broken access-list prompts entirely.
struct FileCredentialStore: KeychainReading, KeychainWriting {
    let url: URL

    init(url: URL = FileCredentialStore.defaultURL) {
        self.url = url
    }

    /// `~/.config/cc-usage-monitor/credentials.json`, mode 0600.
    static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/cc-usage-monitor/credentials.json")
    }

    /// True when the credential file exists, so the composition root can prefer this store over the
    /// Keychain.
    static func isConfigured(url: URL = FileCredentialStore.defaultURL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Reading a file never prompts, so `allowInteraction` has no effect. A missing file maps to
    /// `itemNotFound`, the same signal the Keychain reader gives when the credential is gone, which
    /// the polling coordinator shows as the reauthenticate state.
    func readCredential(allowInteraction: Bool) throws -> KeychainCredential {
        guard let data = try? Data(contentsOf: url) else { throw KeychainError.itemNotFound }
        return try KeychainCredentialParser.parse(data)
    }

    /// Writes the refreshed token fields back, carrying over scopes and subscription type from the
    /// stored credential so a refresh never strips them. `allowInteraction` is irrelevant for a
    /// file. The write is atomic and mode 0600, so a crash cannot leave a torn file and the secret
    /// is never group- or world-readable.
    func updateTokens(accessToken: String, refreshToken: String, expiresAt: TimeInterval,
                      allowInteraction: Bool) throws {
        let previous = try? readCredential()
        let updated = KeychainCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            scopes: previous?.scopes ?? [],
            subscriptionType: previous?.subscriptionType)

        let data = try JSONEncoder().encode(updated)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
