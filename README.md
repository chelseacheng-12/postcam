# Postcam

Postcam is an iPhone camera. The viewfinder is a normal photo with a postage stamp in the middle. Inside the stamp the same scene is redrawn as crayon: posterized color, pencil lines, paper grain, and a pale pink grade. Outside the stamp the camera is left alone. Photos and videos save that composite, not a clean frame with a sticker added later.

The shooting controls follow the iPhone Camera app: pinch zoom, lens buttons, a photo/video shutter, flash, and a front/back switch. The stamp is the only postal piece. Album and settings stay light and ordinary so the picture can carry the idea.

## Open and run

You need a Mac with **Xcode 16 or later**, and an iPhone on **iOS 17 or later**. The live camera, microphone, and Photos save path have to be tried on a device. The Simulator can show the interface, and Upload can stamp a picture if the Simulator has photos, but it is not a stand-in for the camera.

1. Open `Postcam.xcodeproj`.
2. Select the **Postcam** target, then **Signing & Capabilities**.
3. Choose your **Team**. Signing is automatic. The bundle id is `com.postcam.app`; change it if that id is already taken by another app on your team.
4. Pick your iPhone as the run destination and press Run.
5. On the phone, trust the developer certificate if iOS asks (Settings → General → VPN & Device Management).
6. Allow the camera, the microphone, and adding to Photos when prompted.

If Xcode says the project file is from a newer format than the one you have, install [XcodeGen](https://github.com/yonaskolb/XcodeGen) and regenerate it from the repo root:

```bash
brew install xcodegen
xcodegen generate
```

`project.yml` describes the same target.

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

The crayon chain is `IllustrationStyle.Knob` in `Postcam/Rendering/IllustrationStyle.swift`. Brightness, posterize levels, how pink the wash is, and how heavy the pencil lines are all live there. The scallop and the 55% width are `StampGeometry`.

If the preview is sideways on a particular phone, the rotation applied to the camera buffer is `CameraController.portraitRotation` (90 degrees). The stamp bitmap is flipped once in `StampCompositor.upright(_:)` because a `CGImage` and a camera `CIImage` do not share an origin. If the stamp itself is upside down while the photo is upright, that function is the one to change.

## Layout

```
Postcam.xcodeproj
project.yml
Postcam/
  PostcamApp.swift          app entry, save + upload
  Info.plist                camera, microphone, photo library strings
  Camera/                   session, zoom, recorder, metal preview
  Rendering/                stamp geometry, crayon filter, compositor
  Views/                    camera chrome, album, viewer, stamp sheet
  Storage/                  in-app roll and Photos library
```

## What was not verified

This project was written on a machine that cannot compile or run iOS apps. Nothing here was built in Xcode, installed on a phone, or checked against a live camera. In particular, these still need a device:

- That the project opens and signs on your Xcode
- Preview frame rate of the Core Image chain
- That saved photos and videos match the preview, including orientation and the front camera mirror
- Audio/video sync and the Photos library write
- Which lens buttons appear on your specific iPhone
- The exact crayon color against a real street, versus the reference described for this app

The filter values are a starting point for that comparison, not a finished grade.
