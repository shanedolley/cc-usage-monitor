# Install CC Usage Monitor

CC Usage Monitor is a menu bar app that shows your Claude Code usage and alerts you when a metric crosses a threshold you set. It runs as a menu bar accessory: no Dock icon, and it keeps running after you close its window.

## Requirements

- macOS 14 or later.
- Claude Code signed in on this Mac. The app reads its credentials from the `Claude Code-credentials` Keychain item; it never asks you for a password.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) and Xcode command line tools, to build from source.

## Build

Run the build script from the repository root:

```
./scripts/build-release.sh
```

It generates the Xcode project, builds the Release configuration, ad-hoc signs the app, and writes `build/CCUsageMonitor.app`. Ad-hoc signing needs no Apple Developer account.

## First launch

Launch the app:

```
open build/CCUsageMonitor.app
```

A menu bar item appears showing your highest usage percentage. If the app lives in `build/`, the build script has already cleared the quarantine flag, so it opens directly.

If you move or download the app, Gatekeeper quarantines it and blocks the first open. Clear it one of two ways:

- Right-click the app in Finder and choose Open, then confirm. macOS remembers the choice.
- Or clear the quarantine attribute from the terminal:

  ```
  xattr -cr /path/to/CCUsageMonitor.app
  ```

## Grant access

On first launch the app asks for two things:

- **Notifications.** Allow them so threshold alerts can fire. The Rules tab shows a banner while notifications are off, with a button that opens Settings.
- **Keychain.** macOS prompts to let the app read the Claude Code credentials item. Choose Always Allow. If you deny it, the window shows a Keychain message with a button that opens Keychain Access, where you can grant access to the item; relaunch the app afterward.

## Use

- The menu bar item shows the highest of your three usage metrics. It turns amber at 80 percent and red at 90 percent.
- Click the menu bar item to open the window. The **Usage** tab shows the current session, the two weekly limits, your plan tier, and usage credits. The **Rules** tab adds, lists, and deletes threshold alerts.
- Add a rule by picking a metric and a threshold from 1 to 99. The app notifies you once when the metric reaches the threshold, and re-arms only after the metric drops back below it.
- Rules persist in `~/Library/Application Support/CCUsageMonitor/notification-rules.json`.

## Quit

The menu bar item has no Quit command in this version. To quit, run `osascript -e 'quit app "CCUsageMonitor"'` or force-quit from Activity Monitor.

## Notes on distribution

This build is ad-hoc signed for local use on this Mac. Distributing it to other Macs without a warning would require a Developer ID certificate and notarization from a paid Apple Developer account, which is outside the scope of this single-user app.
