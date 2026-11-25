# Go2 Blocks for iPad

> **This folder is the whole iPad app and can be its own repository.** The built editor is in
> `Go2Blocks/web`, so Xcode (and XcodeGen, `brew install xcodegen`) is all you need to build and
> install it: `./build.sh`, open `Go2Blocks.xcodeproj`, pick your Team, Run. Changing the *editor*
> (blocks, texts, sounds) needs the full Go2 Blocks project (`ui/`, `scripts/`): there, `./build.sh`
> rebuilds the editor first, and `scripts/publish-update.py` makes updates for the Update button.
> The animal sounds inside the editor have their own licences: see `SOUND-CREDITS.md`.

A small Swift app (`Go2Blocks/*.swift`, about 200 lines) around the web editor. The editor, the safety limits
and the robot connection are the TypeScript in `../ui/src` and run inside the iPad; Swift only shows the page,
makes the robot's plain-HTTP sign-in request (a web page may not), keeps the screen on, shows `confirm()`
dialogs, and stops the robot when the app is left.

## Build and install

You need a Mac with **Xcode** and an Apple ID (free: the app then expires after 7 days; a school fleet needs the
Apple Developer Program or Apple School Manager).

```bash
brew install xcodegen          # once
cd ios && ./build.sh           # builds ../ui, copies it into the app, makes Go2Blocks.xcodeproj
```

Open `Go2Blocks.xcodeproj`, set your Team under Signing & Capabilities (change `bundleIdPrefix` in
`project.yml` to yours first), pick the iPad, press Run. On the iPad, trust the developer in Settings, General,
VPN & Device Management.

## Use

1. Turn the robot on and join its Wi-Fi network in the iPad's Settings (the same network the Unitree app uses;
   it has no internet, tap "Use Without Internet" if iPadOS asks).
2. Open Go2 Blocks. The first time, allow the Local Network question. Tap the status pill, then Connect.
3. Only one app can control the robot: close the Unitree phone app first.

## Updates without reinstalling

Almost everything we change (blocks, texts, sounds, fixes) is in the editor, which is a web app inside the iPad app. The iPad app can fetch a newer editor from a web address, so you do not have to touch every iPad again. Changes to the Swift code in `ios/Go2Blocks/*.swift` still need a normal install (Xcode or TestFlight).

**Set up once**
1. Host a folder on any static web host with https: GitHub Pages (a public repo, or a paid plan for a private one), Netlify, Cloudflare Pages, or the school's web server. (Plain `http://` is accepted only for addresses on the school's own network, like `http://192.168.1.5/...`.)
2. Put the address of `manifest.json` in `ios/project.yml` under `info.properties` as `Go2UpdateURL`, for example `https://yourname.github.io/go2-updates/manifest.json`. Run `./build.sh` and install the app once more. Until the address is set, the app has no Update button.

**For every update**
1. `python3 scripts/publish-update.py` builds the editor and writes `update-site/` (a `manifest.json` and the files).
2. Upload the contents of `update-site/` to the host (for GitHub Pages: copy them into the repo's published folder and push).

**On the iPad:** the Update button (circular arrows, top bar) shows a red dot when a newer editor is waiting. Tap it, tap *Update now*, then *Restart now*. Only the files that changed are downloaded (usually a few hundred kB), each one is checked against its hash, and the new editor is used only when everything arrived. The robot's own Wi-Fi has no internet: join the school Wi-Fi to update, then go back to the robot's.

**Safety**
- If a new editor never starts, the app drops it at the next launch and uses the editor inside the app again.
- Whoever controls the web address controls the editor's code, so the address is set in the app at build time (kids cannot change it) and must be https.
- If an update needs new Swift code, raise `CFBundleVersion` in `project.yml` and publish with `--min-shell <that number>`: older apps then say that the app itself must be installed again, and do not download the update.
- Apple's rules allow an app to load new JavaScript that runs in its own web view as long as it does not change what the app is for.

The update logic is tested on a Mac without an iPad: `ios/Tests/run-update-tests.sh` (partial downloads, wrong hashes, an update that needs a newer app, a malicious manifest, the rollback).

## Landscape only

The iPad app opens in landscape (either way up) and does not turn to portrait. `UIRequiresFullScreen` is set for that (an iPad app that is not open to every orientation must opt out of Split View); Xcode may warn that all orientations "will soon be required", and App Store review may one day ask for them. All of the app's Info.plist keys are in `project.yml` (`info.properties`): edit them there, because `xcodegen generate` rewrites `Go2Blocks/Info.plist` from it.

## Loading screen

iOS takes a few seconds to start the web view, and the editor takes a moment more, so the app shows the logo with a progress line over the web view until the editor is drawn (it also never stays longer than 20 seconds). The page has the same screen of its own for the Mac app and browsers. The logo for both is made from `images/logoAPP.png` by `scripts/make-ios-icon.py`.

## Sounds and the microphone

The sound blocks play through the page's WebAudio. The app keeps the iPad's audio session on "play and record, speaker", so sounds are heard even with the silent switch on. The page cannot use the microphone itself (it is not a secure context), so the Swift app records (AAC, 22 kHz, mono, 30 s at most) and hands the audio to the page. The first recording asks for microphone permission.

## What is verified and what is not

Verified here (`cd ../ui && npm test`): the block programs, the safety checks and the closed-loop moves
behave exactly like the Python bridge; the robot sign-in (AES, RSA, MD5) matches Python's byte for byte; the
real driver runs programs against a fake robot; the page works with no server in a browser (examples, run,
STOP, save, reopen).

**Not verified, needs the iPad and the robot** (quickstart.md checklist V1-V32, plus):

- The Swift app was only syntax-checked; this Mac has no Xcode, so it was never built or run.
- WebRTC from WKWebView to the robot: iPadOS may hide the iPad's local address in the connection
  offer; the robot may or may not accept that. If connecting fails with "did not open", this is the first suspect.
- STOP and "app left" timing over Wi-Fi, and what the robot does when Move commands stop (check that it stops
  by itself within about a second, as the Python bridge assumes).
- iPadOS routing: a cellular iPad may prefer cellular over a Wi-Fi network without internet for non-local
  traffic; the robot's address is local, so it should be fine, but check.
- Calibration: walks are less exact until calibrated. Put the file's text under the key `go2blocks.calibration`
  in the page's storage (a settings screen for it is not built yet).
- Recording with the microphone and playing sounds in the iPad app: the page side (record, store, upload, play until done) was run in a browser with a stand-in microphone; the Swift recording code and the iPad's audio session were never built or run.
- Older robot firmware (before 1.1.6) is ported but was never run through this path.
