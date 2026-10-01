# TestFlight releases

The [`TestFlight` workflow](../.github/workflows/testflight.yml) archives, signs and
uploads the Gua iOS app to TestFlight.

## How to release

| Path | What happens |
| --- | --- |
| Add the `release-qa` label to a pull request | Archives the PR's head commit and uploads it to the **Gua QA** app. Pushing more commits rebuilds it. The PR gets a comment with the build number. Only PRs from this repository qualify: fork PRs never see the signing secrets. |
| Merge `develop` into `main` | Stages the **production** upload. The job runs under the `production` environment and waits for an approver from the deploy-approvers team before step one. Merging never publishes on its own. |
| Actions -> TestFlight -> Run workflow | Either app by hand (`environment` = `prod` or `dev`), with an optional build number override and a "What to Test" note. |

An unlabelled PR does not build: an archive costs about 25 minutes of a metered macOS runner.

## Two apps

| | `prod` | `dev` |
| --- | --- | --- |
| Bundle id | `global.gua` | `global.gua.dev` |
| Name testers see | Gua | Gua QA |
| Backend | `gua.global`, committed in `GuaDeployment.swift` | dev cluster, injected from the `GUA_DEV_*` secrets |
| OIDC redirect | `global.gua:/oidc` | `global.gua.dev:/oidc` |
| App Store Connect record | `ASC_APP_ID` | `ASC_APP_ID_DEV` |

Both are `Release` builds of the `Gua` scheme. `Release` on its own compiles without
`GUA_DEVELOPMENT` and is production. The QA app comes from the XcodeGen overlay
`Variants/Dev/dev.yml`, applied by `fastlane config_dev`, which re-adds `GUA_DEVELOPMENT`
and the dev bundle id so the two apps install side by side. The `GUA_DEV_*` values must be
`https://` URLs; the workflow fails before archiving if any is missing or cleartext.

## Signing

Signing is manual. Cloud signing (`-allowProvisioningUpdates`) is refused for this App
Store Connect key, so the workflow:

1. imports the Apple Distribution certificate from `GUA_DIST_CERT_P12` into a keychain
   created for the run;
2. fetches, or creates, the App Store provisioning profiles for `global.gua[.dev]`,
   `.nse` and `.shareextension` with `sigh`, authenticated by the ASC API key;
3. archives with `CODE_SIGNING_ALLOWED=NO` and signs at `xcodebuild -exportArchive`,
   against those profiles, with the team id read back from a profile;
4. runs `xcrun altool --validate-app`, then `--upload-package` pinned to the app record
   with `--apple-id` and `--bundle-id`, and checks the output for the success marker
   because altool can exit 0 on failure.

The keychain, the `.p12` and every copy of the `.p8` key are removed at the end of the
run, including on failure.

To refresh the certificate secret: export the Apple Distribution identity **with its
private key** from Keychain Access as a `.p12`, then store `base64 -i <file>.p12` as
`GUA_DIST_CERT_P12` and the export password as `GUA_DIST_CERT_PASSWORD`.

## Secrets

Repository secrets under Settings -> Secrets and variables -> Actions. Names only; the
workflow fails early and names the missing one.

| Secret | Used for |
| --- | --- |
| `ASC_ISSUER_ID`, `ASC_KEY_ID`, `ASC_PRIVATE_KEY` | App Store Connect API key (issuer id, key id, full PEM of the `.p8`). Needs access to certificates, identifiers and profiles, and to TestFlight. |
| `ASC_APP_ID` | Numeric Apple ID of the production app record |
| `ASC_APP_ID_DEV` | Numeric Apple ID of the Gua QA app record |
| `GUA_DIST_CERT_P12`, `GUA_DIST_CERT_PASSWORD` | Base64 `.p12` of the Apple Distribution identity and its password |
| `GUA_DEV_RESOLVER_BASE_URL`, `GUA_DEV_IDENTITY_SERVICE_BASE_URL`, `GUA_DEV_ACCOUNT_PROVIDER` | Dev backend endpoints written into `Secrets/Secrets.swift` for QA builds only |

## Versions

- Build number: UTC `YYMMDDHHMM` unless overridden on a manual run. It must be digits only
  and at most 4294967295 (the `CFBundleVersion` limit), which the two-digit year keeps
  until 2043.
- Marketing version: `MARKETING_VERSION` in `project.yml`. Bump it there for a new
  TestFlight version string.
- Toolchain: `macos-26` runner with Xcode 26.x; the project needs the iOS 26 SDK.
- The production `.xcarchive` is kept as a run artifact for 5 days. QA archives are not
  uploaded, because they embed the dev hostnames as string literals.
