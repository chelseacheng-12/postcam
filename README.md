# Postcam

Postcam is an iPhone camera. The viewfinder is a normal photo with a postage stamp in the middle. Inside the stamp the same scene is redrawn as flat anime background art: cel-shaded color and sketchy warm ink lines. Outside the stamp the camera is left alone. Photos and videos save that composite, not a clean frame with a sticker added later.

The shooting controls follow the iPhone Camera app: pinch zoom, lens buttons, a photo/video shutter, flash, and a front/back switch. The stamp is the only postal piece. Album and settings stay light and ordinary so the picture can carry the idea.

## Open and run

You need a Mac with **Xcode 16 or later**, and an iPhone on **iOS 17 or later**. The live camera, microphone, and Photos save path have to be tried on a device. The Simulator can show the interface, and Upload can stamp a picture if the Simulator has photos, but it is not a stand-in for the camera.

1. Open `Postcam.xcodeproj`.
2. Select the **Postcam** target, then **Signing & Capabilities**.
3. Choose your **Team**. Signing is automatic. The bundle id is `com.chelseacheng.postcam`. Leave the signing style on Automatic. Do not switch it to a manual profile.
4. Pick your iPhone as the run destination and press Run.
5. On the phone, trust the developer certificate if iOS asks (Settings → General → VPN & Device Management).
6. Allow the camera, the microphone, and adding to Photos when prompted.

If Xcode says the project file is from a newer format than the one you have, install [XcodeGen](https://github.com/yonaskolb/XcodeGen) and regenerate it from the repo root:

```bash
brew install xcodegen
xcodegen generate
```

`project.yml` describes the same target. Xcode Cloud does not use it. The cloud build uses the checked-in `Postcam.xcodeproj` and the shared **Postcam** scheme.

## Updates on your iPhone (Xcode Cloud and TestFlight)

Each push to `main` can archive Postcam and send it to TestFlight. You install it from the TestFlight app, without a cable. The workflow itself lives in App Store Connect. This repo already has what that workflow builds: the Xcode project, the shared scheme, automatic signing, and `ci_scripts/ci_post_clone.sh`.

That script runs at the start of every cloud build. It writes `CI_BUILD_NUMBER` into the build number (`CFBundleVersion`). App Store Connect rejects a second upload that reuses a build number, so this is what lets the next push through.

Do this once, in order.

### 1. Use a paid Apple Developer account

Xcode Cloud and TestFlight need the [Apple Developer Program](https://developer.apple.com/programs/). A free Personal Team cannot upload builds. Enroll with the Apple ID you will use in Xcode. The Account Holder or an Admin has to accept the Xcode Cloud agreement the first time. The membership includes a monthly amount of Xcode Cloud build time.

### 2. Create the app in App Store Connect

1. Open [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list) and add an explicit App ID.
   - Description: Postcam
   - Bundle ID: `com.chelseacheng.postcam`
   - No extra capabilities. Camera, microphone, and photo access are usage strings already in `Info.plist`, not entitlements.
2. Open [App Store Connect](https://appstoreconnect.apple.com) → **My Apps** → **+** → **New App**.
   - Platform: iOS
   - Name: Postcam
   - Bundle ID: `com.chelseacheng.postcam`
   - SKU: `postcam`
3. You do not need screenshots or a description for internal TestFlight.

`Info.plist` already sets `ITSAppUsesNonExemptEncryption` to false, so TestFlight should not stop on the export-compliance question.

### 3. Connect this GitHub repo

1. In App Store Connect, go to **Users and Access** → **Integrations** → **Xcode Cloud**.
2. Connect GitHub and grant the Xcode Cloud GitHub app access to this repository.
3. In Xcode on your Mac, sign in with the same Apple ID (**Xcode → Settings → Accounts**) and select the paid team.

Xcode also offers this connection the first time you create a workflow. Either path is enough, as long as Xcode Cloud can read this repo.

### 4. Create a workflow that archives main and ships internal TestFlight

1. Open `Postcam.xcodeproj`.
2. Choose **Integrate → Create Workflow…** (or the Cloud tab in the Report navigator).
3. Select the shared **Postcam** scheme and the paid team. Leave signing on Automatic. If Xcode asks for a team and the project has none saved, pick the team here. Xcode Cloud applies that team during the archive.
4. Name the workflow `TestFlight on main`.
5. Environment: the latest Xcode release. This project needs Xcode 16 or later.
6. Start condition: **Branch Changes**, branch `main`. Leave pull-request builds off unless you also want a build for every PR.
7. Action: **Archive**.
   - Platform: iOS
   - Scheme: Postcam
8. Post-action: **TestFlight Internal Testing**.
   - Create an internal group if you do not have one (the default name is fine).
   - Add the Apple ID that is signed in on the iPhone. Internal testers have to be App Store Connect users on this team (Account Holder, Admin, App Manager, Developer, or Marketing). Add that person under **Users and Access** first if they are not already there.
9. Save, and start the first build if Xcode offers it.

Merging to `main` is what keeps the phone updated. A manual build of another branch is only a one-off. After the workflow exists, every push to `main` clones the repo, runs `ci_scripts/ci_post_clone.sh`, archives, and uploads.

Watch the run in Xcode’s Report navigator, or in App Store Connect under the app’s **Xcode Cloud** tab. The first successful archive still has to finish **Processing** in TestFlight before the phone can install it. That often takes several minutes after the cloud build turns green.

If the archive fails because signing could not find a team, set the Team on the Postcam target in Xcode, commit that change, and push to `main`. Do not switch the target to manual signing.

### 5. Install TestFlight on the iPhone

1. Install **TestFlight** from the App Store.
2. Sign in with the Apple ID you added as an internal tester.
3. When the build is **Ready to Test**, open the TestFlight invite or the TestFlight app, accept Postcam, and install it.
4. Later builds show up in TestFlight as updates. Install the new one from there. The build number on that row is the Xcode Cloud `CI_BUILD_NUMBER`.

Internal testing does not wait for Beta App Review. External testers would.

Use Xcode Cloud as the only way you upload. A local archive is also build 1 until you change it, and App Store Connect will reject it if cloud build 1 is already there.

## Shoot

- **PHOTO / VIDEO** sits above the shutter. Photo is a white button. Video is red, and turns into a square while you are recording.
- Pinch anywhere on the picture to zoom. Double-tap to come back to 1×. The pills are the lenses this phone actually has: usually 0.5×, 1×, and the next optical step, or 2× when there is no telephoto. 1× is the wide camera, which is where the app opens.
- Tap the picture to focus. The bolt is flash on the back camera (a short burst for photos, a torch while you are in video). The front camera uses the screen as a flash for photos.
- The stamp is centered and about 55% of the frame width. What you see is what is written into the file, including the crop that fills the screen.
- The round thumbnail opens the album. **Upload** there picks a photo from your library and prints the same stamp onto it.

Saved files also go to the Photos library when you allow it. Postcam keeps its own copies either way, under Application Support.

## Stamp text

The gear opens the stamp sheet.

| Line | Default | Where it prints |
| --- | --- | --- |
| Date | The month you shoot or upload, `2026.09` | Top left, automatic |
| Label | TRAVEL VLOG | Top right |
| Caption | SPECIAL ADMINISTRATIVE REGION | Bottom left |
| Denomination | 520 | Bottom right, in vermilion, above the place |
| Place | HONGKONG | Bottom right |

Lines print in capitals. The date is not edited by hand.

## If the drawing needs a nudge

The anime chain is `IllustrationStyle.Knob` in `Postcam/Rendering/IllustrationStyle.swift`. Posterize levels, how much sky gradient to keep, line threshold, wobble, and ink color all live there. The scallop and the stamp widths are `StampGeometry` and `StampScale`.

If the preview is sideways on a particular phone, the rotation applied to the camera buffer is `CameraController.portraitRotation` (90 degrees). The stamp bitmap is flipped once in `StampCompositor.upright(_:)` because a `CGImage` and a camera `CIImage` do not share an origin. If the stamp itself is upside down while the photo is upright, that function is the one to change.

## Layout

```
Postcam.xcodeproj          checked-in project and shared Postcam scheme
ci_scripts/ci_post_clone.sh
project.yml
Postcam/
  PostcamApp.swift          app entry, save + upload
  Info.plist                camera, microphone, photo library strings
  Camera/                   session, zoom, recorder, metal preview
  Rendering/                stamp geometry, anime filter, compositor
  Views/                    camera chrome, album, viewer, stamp sheet
  Storage/                  in-app roll and Photos library
```

## What was not verified

This project was written on a machine that cannot compile or run iOS apps. Nothing here was built in Xcode, installed on a phone, or checked against a live camera. In particular, these still need a device:

- That the project opens and signs on your Xcode
- The Xcode Cloud workflow, which is created in App Store Connect rather than in this repo
- Preview frame rate of the Core Image chain
- That saved photos and videos match the preview, including orientation and the front camera mirror
- Audio/video sync and the Photos library write
- Which lens buttons appear on your specific iPhone
- The anime grade against a real street, versus the flat background-art look described for this app

The filter values are a starting point for that comparison, not a finished grade.
