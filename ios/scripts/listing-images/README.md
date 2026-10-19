# App Store listing images

Generates the eight 1290×2796 listing images in
`ios/Nod/AppStore/screenshots/` from `template.html`, using the system
WebKit. No browser or extra tools needed; fonts load from Google Fonts,
so it needs a network connection.

```bash
swift ios/scripts/listing-images/render.swift ios/Nod/AppStore/screenshots
```

Output is opaque RGB PNG (App Store Connect rejects images with an alpha
channel). Each slide is `template.html#N`; open the file in a browser
with a hash to preview one.

## Source screens

`screens/` holds real Simulator captures (iPhone 17 Pro, 1206×2622,
dark mode except `chat-light.png`). To refresh them after a UI change:

- Seed a conversation and memory notes into the Simulator's
  `Library/nod-conversation.sqlite`, then launch and capture with
  `xcrun simctl io <device> screenshot <file>.png`.
- Pin the status bar first:
  `xcrun simctl status_bar <device> override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3`.
- States the Simulator can't reach on its own have debug launch
  arguments (see `ios/Nod/Views/DebugUIState.swift`): `-nodRecording YES`
  for the voice screen and `-nodLocked YES` for the lock screen.

## Copy

Headlines match usenod.app and stay within the listing's positioning
(private AI chat, no mental-health or wellness claims; see
`ios/Nod/AppStore/listing.md`).
