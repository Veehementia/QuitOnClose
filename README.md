# QuitOnClose

A menu bar app for Apple Silicon Macs that quits an app as soon as you close its last window, so it doesn't stay running in the background with nothing open.

Apps you want to keep running, like a music player, go on the exclusion list. Finder is never quit.

## The menu

Click the ✕ icon in the menu bar:

- **Quit Apps When Their Last Window Closes** turns QuitOnClose on and off. The icon is dimmed while it's off.
- **Exclude “App”** adds the app you were just using to the exclusion list, or removes it.
- **Excluded Apps…** opens the list. Click **+** to add a running app or choose one from Applications, or select apps and click **−** (or press Delete) to remove them.
- **Recently Quit** shows the last five apps QuitOnClose quit. Check one to exclude it from then on.
- **Open at Login** starts QuitOnClose when you log in.

The app and its menu are in English and Italian, following your Mac's language.

## How it works

QuitOnClose uses the Accessibility API to follow the windows of every app in the Dock. When an app's last window with a close button closes, QuitOnClose waits one second and checks again, so an app that swaps one window for another isn't caught in between. It then asks the app to quit the normal way, as if you'd pressed ⌘Q, so the app can still ask you about unsaved work or running downloads.

- Minimizing or hiding windows doesn't count as closing them.
- Panels, palettes and popovers don't count as windows, so an app whose only remaining window is a palette is quit.
- Splash screens have no close button, so one closing before the app's main window opens doesn't count either.
- An app that's showing an alert isn't quit, even if the alert is all that's left.
- Menu bar apps and background apps are never touched.
- macOS only lists the windows on the current Space, so QuitOnClose keeps track of each window from the moment it opens. A window that was already open on another Space before QuitOnClose started isn't known until you visit that Space. If you close an app's last window on the current Space before then, the app is quit even though it still has that window elsewhere.

## Install

Requires macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/Veehementia/QuitOnClose.git
cd QuitOnClose
./scripts/install.sh
```

The script builds the app, moves it to `/Applications` and opens it. QuitOnClose then asks for Accessibility access: turn it on in System Settings → Privacy & Security → Accessibility. It starts working within a couple of seconds, with no relaunch needed.

The app is signed ad-hoc, so macOS treats every new build as a different app. The install script clears the old Accessibility permission each time, and you allow the new build again. To avoid this, sign with your own certificate:

```bash
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/install.sh
```

If the menu bar icon is dimmed while QuitOnClose is turned on, macOS no longer trusts it for Accessibility. This can happen even when System Settings still shows it switched on. Choose **Reset Permission and Ask Again** from its menu, then allow it again. QuitOnClose notices within a couple of seconds when access is taken away or given back, and sets up its window tracking again after the Mac wakes from sleep.

To build without installing, run `./scripts/build.sh`. The app goes to `build/QuitOnClose.app`, where Spotlight lists it as a second copy until you install or delete it.

## Uninstall

```bash
pkill -x QuitOnClose; rm -rf /Applications/QuitOnClose.app && tccutil reset Accessibility com.matteonardone.QuitOnClose
```

## License

[MIT](LICENSE)
