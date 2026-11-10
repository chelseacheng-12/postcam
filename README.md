# Postcam

Postcam is an iPhone camera. The viewfinder is a normal photo with a postage stamp in the middle. Inside the stamp the same scene is redrawn as flat anime background art: cel-shaded color and sketchy warm ink lines. Outside the stamp the camera is left alone. Photos and videos save that composite, not a clean frame with a sticker added later.

The shooting controls follow the iPhone Camera app: pinch zoom, a photo/video shutter, flash, and a front/back switch. A carousel under the shutter picks the art style. Album stays light and ordinary so the picture can carry the idea.

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

- **PHOTO / VIDEO** sits above the shutter. The selected word is yellow. Photo is a white button. Video is red, and turns into a square while you are recording.
- Pinch anywhere on the picture to zoom. While the pinch is active, the lens pills (0.5×, 1×, tele) and the live zoom readout appear. They fade out about a second after you let go. The idle screen has neither. Double-tap to come back to 1×. 1× is the wide camera, which is where the app opens.
- Tap the picture to focus. The bolt is flash on the back camera (a short burst for photos, a torch while you are in video). The front camera uses the screen as a flash for photos.
- The carousel under the shutter is the art style. Swipe it, or tap a style; the centered one is selected. **Postcard** is the anime stamp: a perforated frame, no words on it, and the drawing only inside the stamp. Tap the stamp to cycle its size. **Sonny Boy** has no stamp. Inside a rectangle framed by both hands (thumb and index on each hand, like a director's frame), the scene turns into a flat cel-shaded world with surreal changes; see Styles. The rest of the picture stays the camera. The choice is remembered.
- What you see is what is written into the file, including the crop that fills the screen and, for Sonny Boy, the hand window at that moment. A photo taken while the window is still fading in is saved at full strength.
- The front camera previews like a mirror. Saved front-camera photos, and Sonny Boy videos, are flipped back to the true view, as the iPhone Camera app does. Postcard videos from the front camera are saved as previewed, because flipping them would write the stamp backwards. `CameraController.saveFrontCameraMirrored` saves everything as previewed instead.
- The round thumbnail opens the album. **Upload** there picks a photo from your library and applies the current style. Postcard prints the stamp. Sonny Boy uses the hand window if one is in the picture, and otherwise turns the whole photo into the scene.

Saved files also go to the Photos library when you allow it. Postcam keeps its own copies either way, under Application Support.

## Styles

Postcard and Sonny Boy are the cases of `ArtStyle`. A new style is another case, a swatch in `StyleSwatch`, and a branch in `CameraController.handleVideo`. The selected style is stored in UserDefaults under `postcam.art.style`.

Sonny Boy is drawn by `SonnyBoyScene` (`Postcam/Rendering/SonnyBoyScene.swift`), with colors, flattening, grade, and line values in `SonnyBoyStyle.Knob`. Everything inside the window that is not sky is drawn as clean cel art with sharp edges. The frame is shrunk and median-filtered until the photo texture is gone (`flattenScale`, `flattenPasses`), then grown to full resolution with Core Image's edge-preserving upsample guided by the full frame (`upsampleLuma`). That smooth image is snapped to a small palette learned with k-means (`CIKMeans`, then `CIPalettize`, `paletteSize` colors, eased between frames by `paletteKeep`), so every region is one flat color and the borders between regions are hard pixel steps rather than soft blends. Two 3×3 median passes (`cleanupPasses`) clean stray pixels along those borders. The grade is bright and high-key (`exposure`, `vibrance`, `saturation`, `coolLift`). Palette regions darker than `shadowLevel` take one flat cool shadow tone (`shadowTint`), with no blur, so the shadow edge is a region edge. Flat or very bright areas above the window's horizon (ceilings, walls, windows, plain sky; `glowLow`/`glowHigh` set how bright counts) become a saturated cobalt sky with painted cumulus clouds, or rarely blank cream space. Usually a whale swims slowly across the sky. The ground usually stays the real floor, painted; sometimes it becomes a flat sea with wave lines, sand, grass, or more sky. Up to two salient objects (Vision objectness saliency) are copied and float above where they stand, bobbing slowly, each with a soft oval shadow on the spot below. Which of these happens is a `SurrealPlan` picked from a seed for each new hand framing, so it holds still while the same framing lasts. The region masks are averaged over time so the edges do not flicker.

Sky and swapped ground only go on empty background, never over an object. An object mask is built from Vision's person segmentation, Vision's foreground instance masks (iOS 17), the objectness saliency heat map (`heatThreshold`), and busy texture (`busyLow`); bright glowing areas such as windows count as objects only if Vision segmented them. The mask is grown by `objectMargin` and subtracted from the sky and ground, and again at full resolution by `objectMarginFull`, so the sky stops just outside every silhouette and the objects stay drawn in cel style in front of it. The masks are computed at working size, then grown to full resolution with the same edge-preserving upsample, using the palette regions as the guide, and cut hard, so their borders are sharp and land on the fill borders. Only salient boxes that Vision segmented as objects (`floatCoverage`) float, and each copy is cut along the object's own silhouette. The camera's depth data is not used; it would need a depth-capable session setup.

The clouds and the whale are drawn in code with Core Graphics in `Postcam/Rendering/SonnyBoyArt.swift`, so no image assets ship and nothing is copied from the show. Cloud size, whale size and crossing time are in `SonnyBoyArt.Knob`, and both are sized to the hand window.

Sonny Boy's outlines are traced at full resolution on the palette regions, so lines sit exactly on fill borders and only clearly different regions get one, not wood grain or fabric: a 3×3 median, a light pre-smooth (`lineBlur`), edge detection, and a hard cut (`lineThreshold`), with no softening afterwards (`lineSoften` is 0). Lines hold still while panning through hysteresis (`lineHysteresis`: last frame's lines survive with less edge strength), not through blur or blending. `despeckle` drops lone dots. The sky and ground boundaries are cut from the same sharp full-resolution masks and drawn `boundaryRadius` wide; because the sky stops at objects, its edge also outlines whatever stands in front of it. The window itself has a hard edge against the photo outside it.

What the live filter cannot do is redraw objects. It paints over what the camera sees, so a cluttered desk stays a cluttered desk in flat color, shadows come from the real light rather than being designed, and new objects cannot be invented. That needs a generative image model, which is not part of this app.

The hand window is `FramingPose` in `HandFrameTracker.swift`. It asks Vision for up to four hands and keeps any hand whose thumb and index form a loose L (20° to 170°). Only thumb and index joints are used, at low confidence. A fingertip cut off by the frame edge falls back to the next joint, a missing knuckle falls back to a joint further up the finger, and when the knuckles are out of view the corner of the L is where the two finger lines meet. Detection then tries, in order:

1. Every pair of L's, keeping the largest window. This switches the window on at once.
2. A partial frame: a single L, run out to the frame edges in the direction its fingers point, or two lone fingers from different hands. Near-parallel fingers bound a band across the picture; crossing fingers make an L where their lines meet. Partial frames need a squarer angle, arms at least 10% of the frame (`partialArm`), and a larger window (`partialMinimumArea`).
3. The same on a zoomed-out copy of the frame (`zoomOut`), where big close-up hands fit Vision's detector better.
4. When Vision sees no usable hand, `SkinFrame`: skin-colored fingers that come in from the picture edges and bracket an empty rectangle on at least three sides. It is only used live, not on uploads.

Partial and skin windows must be found `partialConfirm` and `skinConfirm` detections in a row before they switch the window on, and a recent two-hand window is never replaced by a partial one. With no fingers in view nothing triggers. The window is held for `holdWithOneHand` seconds while any hand or finger is still in view, and fades soon after none is. The detection knobs are `HandFrameTracker.Knob`, `FramingPose.Knob`, and `SkinFrame.Knob`. There is no stamp on this style.

The stamp itself has no lettering. The gear that used to edit stamp text is gone. Shape, perforations, and the tap-to-resize sizes remain for Postcard.

## If the drawing needs a nudge

The Postcard chain is `IllustrationStyle.Knob` in `Postcam/Rendering/IllustrationStyle.swift`. Posterize levels, how much sky gradient to keep, line threshold, wobble, and ink color all live there.

Both styles are made steady over time. The camera image is median-filtered and denoised before anything else. Colors and flat fills are blended with the previous frame (`colorKeep`, `fillKeep`; higher is calmer but trails more on fast pans) through `FrameHistory`. Lines use hysteresis (`StableInk`): an edge that was ink last frame stays ink at a lower threshold, so contours do not crawl, and fine texture under `lineThreshold` never inks. The wobble and grain are fixed textures made once, so they never shimmer. The history clears when you switch cameras or when frames stop for a moment. The scallop and the stamp widths are `StampGeometry` and `StampScale`. Sonny Boy's flat grade is `SonnyBoyStyle.Knob`.

Camera orientation is done in Core Image, not on the capture connection. The connection stays at the sensor's own orientation with no mirroring, for both cameras. `FrameOrientation` (`Postcam/Camera/FrameOrientation.swift`) picks the clockwise quarter turns from Apple's `AVCaptureDevice.RotationCoordinator`, which knows how each camera is mounted, and checks them against the buffer's shape: a landscape buffer gets an odd number of quarter turns, a portrait buffer an even number. The front camera then adds a left-right flip for the selfie view. On most iPhones that is `.right` for the back camera and `.leftMirrored` for the front; front cameras that deliver portrait buffers get no turn and `.upMirrored`. Saved front-camera shots use the same turn without the flip. The stamp bitmap is flipped once in `StampCompositor.upright(_:)` because a `CGImage` and a camera `CIImage` do not share an origin. If the stamp itself is upside down while the photo is upright, that function is the one to change.

## Layout

```
Postcam.xcodeproj          checked-in project and shared Postcam scheme
ci_scripts/ci_post_clone.sh
project.yml
Postcam/
  PostcamApp.swift          app entry, save + upload
  Info.plist                camera, microphone, photo library strings
  Camera/                   session, zoom, hand frame, recorder, metal preview
  Rendering/                stamp geometry, Postcard and Sonny Boy filters, compositor
  Views/                    camera chrome, style carousel, album, viewer
  Storage/                  in-app roll and Photos library
```

## What was not verified

This project was written on a machine that cannot compile or run iOS apps. Nothing here was built in Xcode, installed on a phone, or checked against a live camera. In particular, these still need a device:

- That the project opens and signs on your Xcode
- The Xcode Cloud workflow, which is created in App Store Connect rather than in this repo
- Preview frame rate of the Core Image chain. Sonny Boy runs two full-resolution edge-preserving upsamples, k-means and palette snapping, and full-resolution medians and morphology per frame, plus foreground instance masks every eighth frame and a second hand-pose pass when the first finds no pair
- That the Core Graphics whale and clouds come out upright and in the right colors on device
- That saved photos and videos match the preview, including orientation and the front camera mirror. The Xcode console prints a line per camera whenever the turn changes, such as `front buffer 1080x1920 angle 0.0 mirrored false coordinator 0 turn 0° clockwise, mirrored`. If a preview is still wrong, that line says what the camera delivered and what turn was chosen
- The Sonny Boy sky and ground masks, which are heuristics on brightness, flatness, and position. They will misfire on some rooms, and a white desk or wall above the horizon can turn into sky
- Audio/video sync and the Photos library write
- Which lens buttons appear on your specific iPhone
- The anime grade against a real street, versus the flat background-art look described for this app
- Sonny Boy's hand window against a real pair of hands. It has not been tried on a phone. The skin-color fallback in particular will misfire on skin-toned walls, wood, or faces, and partial single-L windows run to the frame edges

The filter values are a starting point for that comparison, not a finished grade.
