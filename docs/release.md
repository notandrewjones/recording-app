# Releases

`.github/workflows/release.yml` builds, signs, notarizes and staples `ISORecorder.dmg`, using the same
scripts you can run locally.

## One-time setup

Run `scripts/ci-set-github-secrets.sh`. It needs:

- The Developer ID Application certificate exported from Keychain Access as a `.p12`, with its password
- An App Store Connect API key `.p8`, with its Key ID and Issuer ID
- The Apple Team ID

The workflow uses the same secret names as ProductionDeck, and those credentials are valid here. GitHub
won't reveal secret values, so they have to come from the original files.

## Cutting a release

```sh
git tag v0.5.0
git push origin v0.5.0
```

The tag sets the version and the commit count sets the build number, so no files need bumping. Tags starting
`v0.` or containing `-` publish as pre-releases. Running the workflow by hand from the Actions tab skips the
GitHub Release and leaves the `.dmg` as a workflow artifact.

The workflow only runs on a tag if the tagged commit contains it.

CI runs `ISOCoreTests` and `FrameRingTests`. Run the integration tests locally before tagging, because
runner VMs have no hardware ProRes: `cd Packages/ISOCore && swift test`.

## Building locally

```sh
cp scripts/signing.env.example scripts/signing.env   # then fill it in
scripts/build_release.sh
scripts/notarize.sh
```

The output is `build/ISORecorder.dmg`. A local build includes uncommitted changes. CI builds only the tagged commit.

## What the target Mac needs

The `.dmg` contains only the app. The Mac running it also needs Blackmagic Desktop Video, and ffmpeg
(`brew install ffmpeg`). Bundling ffmpeg is covered in [setup.md](setup.md#ffmpeg).

The app runs on Apple Silicon only, so releases are `arm64`.

## App icon

`swift tools/make-app-icon.swift` redraws every size in `App/Assets.xcassets/AppIcon.appiconset`.
