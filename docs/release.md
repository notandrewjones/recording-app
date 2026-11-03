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

## In-app updates (Sparkle)

The app checks `https://notandrewjones.github.io/recording-app/appcast.xml` daily and on **ISO Recorder > Check for Updates…**. Updates are verified with an EdDSA key, not an API key:

- **Public key**: `SPARKLE_PUBLIC_KEY` in `Config/App.xcconfig`, copied into Info.plist as `SUPublicEDKey`. Empty disables updates.
- **Private key**: in your login Keychain and the `SPARKLE_ED_PRIVATE_KEY` GitHub secret. Back it up (`generate_keys -x`). If it is lost, installed copies cannot accept updates signed with a new key.

One-time setup: the repo must be public (the app downloads the feed and .dmg without credentials). Run `scripts/sparkle-setup-keys.sh`, commit `Config/App.xcconfig`, then in Settings > Pages deploy from the `gh-pages` branch (it exists after the first tagged release).

On each `v*` tag, after the GitHub Release is published, CI runs `scripts/make_appcast.sh`, which signs the .dmg and adds it to `appcast.xml` on `gh-pages`. Enclosures point at the release asset. Prereleases are included, since all v0.x tags are prereleases.

If an operator accepts an update during a recording, the relaunch waits until recording stops and segments are finalized.
