import XCTest
@testable import CCUsageMonitor

/// The reauthenticate advice differs by credential source, and getting it backwards is what made the
/// July outage look unfixable: the user ran `claude /login` repeatedly against a mode that ignores
/// the Keychain entirely. Each mode must name its own fix and rule out the other.
final class CredentialSourceTests: XCTestCase {
    func testKeychainModeSendsTheUserToClaudeLogin() {
        let advice = CredentialSource.keychain.reauthenticateAdvice
        XCTAssertTrue(advice.message.contains("claude /login"),
                      "Keychain mode is fixed by signing in to Claude Code")
        XCTAssertFalse(advice.message.contains("credentials.json"),
                       "Keychain mode must not send the user to a file it does not read")
    }

    func testFileModeSendsTheUserToTheFile() {
        let advice = CredentialSource.file.reauthenticateAdvice
        XCTAssertTrue(advice.message.contains("credentials.json"),
                      "file mode is fixed by re-seeding the file")
        XCTAssertTrue(advice.message.lowercased().contains("will not fix"),
                      "file mode must rule out signing in, which cannot clear this state")
    }

    /// Only Keychain mode can offer a working sign-in, since only there does `claude /login` write
    /// the store the app reads.
    func testOnlyKeychainModeOffersSignIn() {
        XCTAssertTrue(CredentialSource.keychain.offersSignIn)
        XCTAssertFalse(CredentialSource.file.offersSignIn)
    }

    func testBothModesNameTheirFixInTheTitle() {
        XCTAssertFalse(CredentialSource.keychain.reauthenticateAdvice.title.isEmpty)
        XCTAssertFalse(CredentialSource.file.reauthenticateAdvice.title.isEmpty)
    }

    /// The script is injected so this asserts the command without opening Terminal.
    func testSignInLaunchesClaudeLoginInTerminal() {
        var script = ""
        ClaudeLoginLauncher.launch { script = $0 }
        XCTAssertTrue(script.contains("claude /login"))
        XCTAssertTrue(script.contains("Terminal"))
        XCTAssertTrue(script.contains("activate"), "Terminal must come to the front to be usable")
    }
}
