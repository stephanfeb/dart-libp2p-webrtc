# webrtc_interop

Runs the `dart_libp2p_webrtc` browser interop scenarios on a phone. The phone is
the Dart peer; the browser runs on a desktop, driven by Playwright.

```sh
# Desktop (repo root): signaling relay + headless browser
(cd interop/browser && npm install)
dart run tool/interop_server.dart --browser chrome   # or firefox / webkit

# Phone (same Wi-Fi)
cd example/interop_app
flutter run --dart-define=INTEROP_SERVER=ws://<desktop-ip>:8787
```

Tap **Run all scenarios**. Results also print to the `flutter run` console as
`INTEROP …` lines. Building needs `cmake` and `ninja` (the package's build hook
compiles libdatachannel for the phone).
