# Protect Cameras for KDE Plasma 6

A Plasma 6 widget (plasmoid) port of the macOS app, in QML/Qt 6: the camera glyph with a new-events badge, a snapshot grid of every camera, a near-live view of any one of them, the event log, and desktop notifications with the snapshot attached.

- **In a panel or the system tray**: the camera glyph with a count, a dot, or nothing, in blue or monochrome. It dims while the widget isn't receiving events; an orange dot means an error. **Click** for the popup, **middle-click** to refresh. **Right-click** for Refresh Now, Open Protect in Browser, Pause Notifications (1 hour, or until tomorrow morning), Send Test Notification and Configure.
- **In the popup**: **Cameras** refreshes every camera's snapshot every few seconds while it's open (nothing is fetched while it's closed). A red outline and icon mark a camera with a detection in progress. **Click a camera** for a large view that refreshes about once a second in high quality, its recent events, and a button to mute its notifications. **Events** lists detections, doorbell rings and alarm sounds with the snapshot taken when each happened; click one to jump to its camera. The bell button in the footer pauses notifications (30 minutes to tomorrow morning).
- **On the desktop**: the popup itself. Its snapshots keep refreshing while it's on screen.

## Install

Requires Plasma 6, `python3` (standard library only) and `secret-tool` (in `libsecret`) for keyring storage.

```sh
make kde-install    # or: kpackagetool6 -t Plasma/Applet -i kde/package
```

Then right-click a panel or the desktop → **Add Widgets…** → **Protect Cameras**, and open its **Configure…** dialog.

To remove it: `make kde-uninstall` (or `kpackagetool6 -t Plasma/Applet -r dev.protectcameras.plasmoid`). The event log stays in `~/.local/share/protect-cameras-kde/` until you delete it.

After upgrading an installed copy, restart Plasma so it reloads the QML: `systemctl --user restart plasma-plasmashell`. To try it in a window without touching your panel: `plasmawindowed dev.protectcameras.plasmoid`.

## Setting it up

1. In Protect, go to **Settings → Control Plane → Integrations** and create an API key.
2. In **Configure… → Console**, enter the console's address. The page shows a `secret-tool store …` command: run it in a terminal and paste the key when it asks. The key goes into your keyring (KWallet or GNOME Keyring) through the Secret Service, so it never lands in shell history or a process listing. The widget picks it up within 30 seconds.
3. If the console uses its built-in self-signed certificate (or you entered an IP address), the popup shows the certificate's SHA-256 fingerprint. Compare it with what your browser shows for the console, then click **Trust This Certificate**. From then on the widget accepts exactly that certificate. A certificate your system already trusts, such as Let's Encrypt on a hostname, needs no confirmation and can renew freely.

With no console set, the widget falls back to `PROTECT_CAMERAS_HOST` and `PROTECT_CAMERAS_API_KEY` in plasmashell's environment, the variables the macOS app's terminal commands use. To use them, export them from a `.sh` file in `~/.config/plasma-workspace/env/`, which Plasma sources at login.

The widget only reads from Protect: it never changes camera settings, arms the alarm, or talks back through a doorbell.

## How it differs from the macOS version

- **A small helper does the networking.** QML can't pin a self-signed certificate, send the API key on a websocket, or load an image that needs a header, so `protect-bridge.py` (Python, standard library only) talks to the console: certificate pinning, the request pacer that keeps under Protect's rate limit, both push channels with keepalive pings and reconnects, snapshots, and the event log on disk. The widget starts it through Plasma's executable data engine and talks to it over `127.0.0.1` behind a random token kept in a `0600` file in `$XDG_RUNTIME_DIR/protect-cameras-kde/`. It reads the API key from the keyring itself, so the key never reaches the widget, and it exits on its own a few minutes after the widget stops talking to it.
- **The API key is stored with `secret-tool`** in a terminal, not typed into Settings: a widget can't hand a secret to a process without it showing up in a process listing. Settings tells you whether one is stored and can remove it.
- **Desktop notifications** go through Plasma's notification system with the event's snapshot attached. Alarm sounds (smoke, CO, glass break…) are sent as urgent. Sounds follow System Settings → Notifications, so there's no separate doorbell sound setting. Click one to show the camera, or (Settings → Notifications) open the event in Protect.
- **The event log** is kept in `~/.local/share/protect-cameras-kde/<widget id>/` (`events.json` and `thumbnails/`), 7 days or 500 events, whichever is less.
- **Settings pages** show the console's status as of when you opened them, since they can't see the widget live. Clearing the event log happens when you apply.
- **Resume from suspend** is detected from a gap between clock ticks and reconnects the event stream 4 seconds later. There's no network-change monitor; the helper's keepalive pings notice a dead connection within about 25 seconds.
- No launch-at-login setting (Plasma restores widgets itself) and no `--print`/`--watch` CLI.

## Files

| File | What's in it |
| --- | --- |
| `package/contents/code/protect.js` | Event kinds and wording, event and device messages, notification rules, the unseen count, camera parsing, errors, host and certificate-pin helpers, snooze times, formatting. A port of `Models.swift` and the logic in `ProtectStore.swift`. |
| `package/contents/code/protect-bridge.py` | The helper: certificate pinning, pacing, websockets, snapshots, the log on disk. A port of `ProtectAPI.swift`. |
| `package/contents/ui/main.qml` | State, talking to the helper, refreshing, push messages, notifications, the log |
| `package/contents/ui/Shell.qml` | Starting the helper, checking the keyring, reading the environment |
| `package/contents/ui/CameraGlyph.qml` | The camera glyph, drawn from the same shapes as `Logo.swift` |
| `package/contents/ui/CompactRepresentation.qml` | Panel icon |
| `package/contents/ui/PopupView.qml`, `CameraTile.qml`, `CameraDetail.qml`, `SnapshotImage.qml`, `EventRow.qml`, `CertificatePanel.qml` | The popup |
| `package/contents/ui/config*.qml`, `package/contents/config/main.xml` | Settings |

`make kde-test` runs the logic tests under Node and an end-to-end test of the helper against a fake console with a self-signed certificate (needs `openssl`). `python3 kde/test/bridge_test.py --serve 18443` runs that fake console on its own, for trying the widget: `PROTECT_CAMERAS_HOST=http://127.0.0.1:18443 PROTECT_CAMERAS_API_KEY=test-key plasmawindowed dev.protectcameras.plasmoid`. `PROTECT_CAMERAS_DEBUG=1` in the widget's environment makes the helper log to `$XDG_RUNTIME_DIR/protect-cameras-kde/`.
