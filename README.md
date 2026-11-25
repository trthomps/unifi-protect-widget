# Protect Cameras

Your UniFi Protect cameras and events at a glance: a snapshot grid of every camera, a near-live view of any one of them, a log of detections and doorbell rings, and notifications with the snapshot attached. It comes in two versions with the same features and design:

- **macOS**: a menu bar app (Swift, in `Sources/`).
- **KDE Plasma 6 on Linux**: a panel or system tray widget that also works on the desktop (QML, in [`kde/`](kde/README.md)). See [KDE Plasma](#kde-plasma).

![Menu bar styles, light](docs/menubar-light.png)
![Menu bar styles, dark](docs/menubar-dark.png)

## Install

Both versions need UniFi Protect 5.3 or later (for the Integration API).

### macOS

Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`).

```sh
make install      # builds "Protect Cameras.app", copies it to ~/Applications, launches it
```

`make app` builds into `build/` without installing. Opening the app again (Spotlight, Finder) brings up Settings, which helps when a menu bar manager has hidden the item.

### KDE Plasma (Linux)

Requires Plasma 6, `python3` and `secret-tool` (in `libsecret`).

```sh
make kde-install  # installs the widget for your user with kpackagetool6
```

Then right-click a panel or the desktop → **Add Widgets…** → **Protect Cameras**. More in [KDE Plasma](#kde-plasma) below.

## Setting it up on macOS

1. In Protect, go to **Settings → Control Plane → Integrations** and create an API key.
2. In the app's **Settings → Console**, enter the console's address and paste the key. Click **Connect**.
3. If the console uses its built-in self-signed certificate (or you entered an IP address), the app shows the certificate's SHA-256 fingerprint. Compare it with what your browser shows for the console, then click **Trust This Certificate**. From then on the app accepts exactly that certificate. A certificate macOS already trusts, such as Let's Encrypt on a hostname, needs no confirmation and can renew freely.
4. Allow notifications when macOS asks, and allow local network access if prompted.

The key is stored in the login Keychain. The app only reads from Protect: it never changes camera settings, arms the alarm, or talks back through a doorbell.

## Using it

- **Click** the icon for the popover.
  - **Cameras**: a snapshot of every camera, refreshed every few seconds while the popover is open (nothing is fetched while it's closed). A red outline and icon mark a camera with a detection in progress.
  - **Click a camera** for a large view that refreshes about once a second in high quality, its recent events, and a button to mute that camera's notifications.
  - **Events**: detections, doorbell rings and alarm sounds, each with the snapshot taken when it happened. Click one to jump to its camera.
- The **badge** counts new events you'd be notified about since you last opened the popover. The icon dims while the app isn't receiving events, and an orange dot means an error (the popover explains it).
- **Right-click** the icon for Refresh, Open Protect in Browser, Pause Notifications (30 minutes to tomorrow morning), Settings and Quit.

## Notifications

Settings → Notifications picks what's worth a banner:

- **Kinds**: doorbell rings, people, vehicles, packages and alarm sounds (smoke, CO, glass break, siren…) and sensors are on by default. Animals, license plates, faces and plain motion are off.
- **Cameras**: turn individual cameras off, or use the mute button in a camera's view.
- **Don't repeat** for the same camera and kind within a minute (adjustable), so one person walking around the yard is one banner. Doorbell rings always come through after 10 seconds.
- **Clicking a banner** shows that camera in the popover, or opens Protect in the browser.
- **Send Test Notification** posts a sample with a live snapshot.

## Limitations

- **No history from before the app started.** Protect's Integration API pushes events as they happen but has no way to list past ones. The event log (kept for 7 days in `~/Library/Application Support/ProtectCameras/`) only covers time the app was running and connected. If your laptop is asleep or off your network, those events are only in Protect.
- **"Live" means about one frame per second.** The view is built from snapshots. Real video would need an RTSP player, which macOS doesn't include. Use **Open in Protect** for full video and playback.
- **Thumbnails are snapshots taken when the event arrives**, not Protect's own event thumbnails (the Integration API doesn't offer those), so they can be a moment late.

## KDE Plasma

The Plasma widget is a port of the macOS app: the same camera grid, live view, event log, badge styles and notification rules, drawn with Plasma's own theme.

- **In a panel or the system tray**: the camera glyph with a count or dot for new events. **Click** for the popup, **middle-click** to refresh, **right-click** for Refresh Now, Open Protect in Browser, Pause Notifications, Send Test Notification and Configure.
- **On the desktop**: the popup itself. Resize and move it like any Plasma widget.
- **Settings** (right-click → Configure): General, Console and Notifications, the same options as the macOS app.

Setting it up works the same way (an API key, and a one-time check of a self-signed certificate's fingerprint, which the popup offers when it sees one), except that the key goes into your keyring (KWallet or GNOME Keyring) with `secret-tool`: Configure → Console shows the command to run in a terminal, which prompts for the key so it never appears in shell history or a process listing. A small Python helper that ships with the widget does the networking QML can't (certificate pinning, the websockets, snapshots).

Desktop notifications go through Plasma's notification system. After upgrading, restart Plasma to load the new version (`systemctl --user restart plasma-plasmashell`). `make kde-uninstall` removes it. Details are in [`kde/README.md`](kde/README.md).

## Terminal

```sh
ProtectCameras --print                    # console, cameras, recent events from the app's log
ProtectCameras --watch                    # stream raw websocket events (Ctrl-C to stop)
ProtectCameras --snapshot "Front Yard" yard.jpg
```

They use the app's saved console and key (or `PROTECT_CAMERAS_HOST` / `PROTECT_CAMERAS_API_KEY`) and never write the app's event log, so they're safe to run while it's open. `make print` and `make watch` run them through `swift run`.

## Development

```sh
swift build
swift run ProtectCameras --render-previews docs   # regenerate the images above
PROTECT_CAMERAS_DEBUG=1 "build/Protect Cameras.app/Contents/MacOS/ProtectCameras"   # log requests and events
```

| File | What's in it |
| --- | --- |
| `ProtectAPI.swift` | Integration API calls, certificate pinning, the reconnecting websocket |
| `ProtectStore.swift` | Camera list, snapshot feeds, event log, notification rules |
| `Models.swift` | Cameras, events, event kinds and their wording, errors |
| `SystemNotifier.swift` | macOS notifications with snapshot attachments |
| `Logo.swift` | Camera glyph, menu bar renderer, app icon |
| `StatusItemController.swift`, `PopoverView.swift`, `SettingsView.swift` | UI |

The KDE widget lives in `kde/package` (a standard Plasma applet package). Its event, notification and camera logic in `kde/package/contents/code/protect.js` mirrors `Models.swift` and `ProtectStore.swift`, and its helper `protect-bridge.py` mirrors `ProtectAPI.swift`, so a change to one usually needs the same change in the other. `make kde-test` runs its tests. [`kde/README.md`](kde/README.md) has the file map.

## License

[MIT](LICENSE). UniFi and UniFi Protect are trademarks of Ubiquiti Inc. This project isn't affiliated with Ubiquiti.
