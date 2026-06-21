# One-tap TestFlight release

The [`TestFlight` workflow](../.github/workflows/testflight.yml) archives, signs, and
uploads the Gua iOS app to TestFlight from a single button press in the GitHub
Actions UI. No local Xcode, no Match repo, no manual certificate juggling.

## How to release

1. Push the commit you want to ship to its branch (the workflow runs from the
   branch/ref you pick).
2. GitHub -> **Actions** tab -> **TestFlight** (left sidebar) -> **Run workflow**.
3. Pick the branch, optionally type a "What to Test" note, and **Run workflow**.
4. Wait for the run to go green (~30-60 min on a cold cache). The build then shows
   up in App Store Connect -> TestFlight after Apple finishes processing
   (usually another 5-15 min).

Each run uses `github.run_number` as the build number, so every upload is unique
and monotonically increasing — TestFlight never rejects a duplicate.

## Signing approach: cloud-managed automatic signing

The app and both app extensions (`global.gua`, `global.gua.nse`,
`global.gua.shareextension`) all use `CODE_SIGN_STYLE = Automatic` with team
`3HD49L7PSA` (set in `project.yml` / `app.yml` / each target's `target.yml`).

The workflow hands an **App Store Connect API key** to `xcodebuild` via
`-allowProvisioningUpdates -authenticationKeyPath/-authenticationKeyID/-authenticationKeyIssuerID`.
Xcode then fetches or creates, on the fly:

- the iOS Distribution certificate, and
- the App Store provisioning profiles for all three bundle ids (including the app
  group and keychain-access-group entitlements).

That is why there is **no** `.p12`, `.mobileprovision`, keychain import, or
Fastlane Match in this pipeline — the single API key replaces all of it. The same
key is reused by `xcrun altool` for the TestFlight upload.

## Required GitHub secrets

Add these under **Settings -> Secrets and variables -> Actions -> New repository secret**.
These are the same App Store Connect API key credentials already used by the
feedback bot.

| Secret | What it is | Where to get it |
| --- | --- | --- |
| `ASC_ISSUER_ID` | App Store Connect API **issuer id** (a UUID) | App Store Connect -> Users and Access -> Integrations -> App Store Connect API -> the "Issuer ID" shown at the top |
| `ASC_KEY_ID` | The API **key id** (~10 chars) | Same page, the "Key ID" column for your key |
| `ASC_PRIVATE_KEY` | The full contents of the `AuthKey_<KEY_ID>.p8` file | Downloaded once when the key was created. Paste the whole PEM block, `-----BEGIN PRIVATE KEY-----` through `-----END PRIVATE KEY-----`, including newlines. |

The API key needs the **App Manager** role (or at least access to certificates,
identifiers & profiles + TestFlight) so it can manage signing assets and upload
builds.

No other secrets are required. There is **no** manual-signing fallback configured,
because all targets already use automatic signing (see "Fallback" below if that
ever changes).

## What the workflow does

```
checkout (with LFS)
  -> select Xcode 16.x
  -> cache SwiftPM + Homebrew
  -> brew install xcodegen (+ xcbeautify if missing)
  -> xcodegen generate            # regenerate Gua.xcodeproj from project.yml
  -> write AuthKey_<id>.p8 from ASC_PRIVATE_KEY into ~/.appstoreconnect/private_keys
  -> xcodebuild archive  -allowProvisioningUpdates  CURRENT_PROJECT_VERSION=<run #>
  -> xcodebuild -exportArchive  (fastlane/exportOptions.plist, method app-store-connect)
  -> xcrun altool --upload-app -f <ipa> --apiKey ASC_KEY_ID --apiIssuer ASC_ISSUER_ID
  -> upload the .xcarchive as a run artifact (5-day retention)
```

Key build facts the workflow relies on:

- **Build system:** Element X fork using **XcodeGen**. `Gua.xcodeproj` is generated
  from `project.yml` + `app.yml` + the per-target `target.yml` files, so the
  workflow regenerates it rather than trusting the committed copy.
- **Scheme:** `Gua`. **Configuration:** `Release` (which compiles with the
  `GUA_DEVELOPMENT` flag — TestFlight currently points at the dev backend; see the
  note in `ElementX/SupportingFiles/target.yml`).
- **Secrets file:** the committed placeholder `Secrets/Secrets.swift` compiles
  fine for an archive. The workflow deliberately does **not** run the
  `fastlane config_production` lane, because its `update_foss_secrets()` helper
  lives in the Enterprise pipeline that is not part of this fork.

## Caveats

- **macOS minutes:** iOS archiving requires a macOS runner (`macos-15`). GitHub
  bills macOS minutes at 10x the Linux rate, and private repos have a monthly free
  allowance — a full archive run can use a meaningful chunk of it. Budget
  accordingly or use a self-hosted Mac runner.
- **Xcode version:** the project requires Xcode 16+. The workflow selects
  `Xcode_16.4` if present, else the newest `Xcode_16*`, else the newest Xcode on
  the image. If the runner image drops 16.x or the project later requires a newer
  Xcode, adjust the "Select Xcode" step.
- **`altool` vs `notarytool`:** TestFlight/App Store uploads use
  `xcrun altool --upload-app` (still the supported tool in 2026). `notarytool`
  notarizes Mac apps for Gatekeeper and is **not** used for iOS App Store uploads.
- **First run is slow:** SwiftPM has to resolve the Matrix Rust SDK and many other
  packages on a cold cache, and Apple has to provision new signing assets the first
  time. Expect the first green run to take longer than subsequent ones.
- **Marketing version:** `MARKETING_VERSION` comes from `project.yml`
  (currently `25.09.12`). Only the build number auto-increments. Bump the marketing
  version in `project.yml` when you want a new TestFlight version string.

## Fallback: manual signing (only if automatic ever fails)

Automatic signing should work for this project as-is. If Apple ever blocks
cloud-managed signing for these bundle ids, switch to importing assets from
secrets:

1. Add secrets `BUILD_CERTIFICATE_BASE64` (base64 of the distribution `.p12`),
   `P12_PASSWORD`, and one `*_PROVISION_PROFILE_BASE64` per bundle id.
2. In the workflow, before archiving: create a temp keychain, import the `.p12`,
   and install each `.mobileprovision` into
   `~/Library/MobileDevice/Provisioning Profiles/`.
3. Set `signingStyle` to `manual` in `fastlane/exportOptions.plist` and add a
   `provisioningProfiles` dictionary mapping each bundle id to its profile name.
4. Flip `CODE_SIGN_STYLE` to `Manual` (and set `CODE_SIGN_IDENTITY` /
   `PROVISIONING_PROFILE_SPECIFIER`) for the three targets.

This is intentionally not wired up — keep the single-API-key path unless you have
to.
