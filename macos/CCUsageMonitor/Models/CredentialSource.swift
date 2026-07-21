import Foundation

/// Which store the app is reading its credential from. The composition root picks one at launch, and
/// the reauthenticate screen needs to know which, because the two modes have opposite fixes.
///
/// Getting this backwards is what made the July outage look unfixable. The screen told the user to
/// sign in to Claude Code while the app was in file mode, where `claude /login` writes a store the
/// app never reads. Signing in changed nothing, so the same error returned after every restart.
enum CredentialSource {
    /// Reads `~/.config/cc-usage-monitor/credentials.json` and refreshes it. Signing in to Claude
    /// Code does not touch this file.
    case file
    /// Reads Claude Code's Keychain item and never refreshes it, so Claude Code owns the session and
    /// `claude /login` is the fix.
    case keychain

    struct Advice: Equatable {
        let title: String
        let message: String
    }

    var reauthenticateAdvice: Advice {
        switch self {
        case .keychain:
            return Advice(
                title: "Claude Code sign-in needed",
                message: "The monitor reads the credential Claude Code stores, and it is missing or rejected. Run claude /login in a terminal. The monitor picks the new credential up on its next poll, within a minute.")
        case .file:
            return Advice(
                title: "Monitor credential expired",
                message: "Signing in to Claude Code will not fix this: the monitor reads its own credentials.json, not Claude Code's. Re-seed ~/.config/cc-usage-monitor/credentials.json with all three steps in install.md, then relaunch.")
        }
    }

    /// True when a sign-in button would actually help. Only Keychain mode qualifies: there
    /// `claude /login` writes the store the app reads. Offering the button in file mode would
    /// repeat the exact false promise this type exists to stop.
    var offersSignIn: Bool {
        self == .keychain
    }
}
