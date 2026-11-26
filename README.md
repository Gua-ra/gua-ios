![](https://github.com/user-attachments/assets/054e40c6-e796-4c6b-9700-7b7c3c4bfc18)

<div align="center">
  
  ![Gua Logo](https://github.com/user-attachments/assets/33d5300f-24ac-42fe-84c2-37ca84920bd1)
  
  <h1>Gua for iOS</h1>
</div>

**Gua** is a private messenger built on the open [Matrix](https://matrix.org/) protocol. It provides end-to-end encrypted conversations, phone-based sign-in and contact discovery.

Sign-in uses a code sent to your phone number, followed by the account's passkey or PIN. Institutional SSO is planned.

The Gua iOS client is based on [`element-hq/element-x-ios`](https://github.com/element-hq/element-x-ios). It uses the Matrix Rust SDK, timelines, calls and encryption, with Gua's routing, onboarding, account security and contact discovery.

## Get the app

Gua for iOS is in an invite-only beta on TestFlight. Request access with the beta form at [gua.global/support](https://gua.global/support#beta-form). Approved testers receive a TestFlight invitation by email. The Android client is in [`gua-android`](https://github.com/Gua-ra/gua-android).

---

## What the app does today

The app selects the homeserver during sign-in:

1. **Request a homeserver from the resolver.** The app sends the phone number to the Gua resolver. For new accounts, the resolver selects a homeserver using its routing policy and roster.
2. **Sign in through the Gua identity host.** The app runs a standard OIDC sign-in (authorization code with PKCE) against [`gua-auth-service`](https://github.com/Gua-ra/gua-auth-service), Gua's fork of the Matrix Authentication Service.
3. **Authenticate through the identity service.** The auth service delegates sign-in to the [Gua Identity Service](https://github.com/Gua-ra/identity-service), which verifies the phone number with a one-time code and checks the account's passkey or PIN. Both steps are required.

The app connects to the returned homeserver without displaying or requesting a server name.

Other features:

- **Usernames.** The interface displays usernames without homeserver names or full Matrix IDs.
- **Onboarding.** Enter a phone number, confirm a one-time code, set up a profile and secure the account. See [Architecture](#architecture) for the services involved.
- **Two-step verification (passkey or account PIN).** After the one-time code, sign-in needs the account's passkey or six-digit PIN. A passkey or PIN is set up during onboarding and is required for sensitive operations. The PIN can be changed or reset with verification. The client mirrors the server's PIN strength policy: no repeated, sequential, or common PINs.
- **Contact discovery.** Find Friends shows which of your contacts are already on Gua. It needs address-book permission to run. The app normalizes the phone numbers on the device and sends them over TLS in capped batches to the Gua identity service, which digests them with a secret pepper, matches them in memory and does not store them. Contact names stay on the device.
- **Phone number changes.** The number linked to an account can be changed from Settings. The new number is verified with a one-time code, and the account's passkey or PIN is required as well.
- **Welcome experience.** A localized welcome screen (en, fr, es, pt, pt-BR) with the animated glass Gua logo.
- **Encryption and app lock.** End-to-end encryption is enabled, and advanced encryption controls are hidden. The app-lock code is labelled "passcode" to distinguish it from the account PIN.

### Architecture

```
Gua iOS app
    |  1. resolver lookup by phone number: which homeserver to use
    ▼
Gua resolver
    |  2. OIDC authorization code + PKCE against the resolved server
    ▼
Matrix Authentication Service (gua-auth-service)
    |  3. delegated sign-in (phone + one-time code, then passkey or PIN; institutional SSO planned)
    ▼
Gua Identity Service
    |
    ▼
Matrix homeserver in the Gua federation
```

- The resolver returns the homeserver to use. The client does not hardcode a server.
- [`gua-auth-service`](https://github.com/Gua-ra/gua-auth-service) is Gua's fork of the Matrix Authentication Service. It delegates authentication to the identity service.
- The [Gua Identity Service](https://github.com/Gua-ra/identity-service) implements verification codes, the account PIN, passkeys, contact lookup, and phone number changes.
- Every sign-in requests fresh authentication using an ephemeral web session with `prompt=login`.

## Current limits and planned work

- **Per-homeserver authentication.** Today every sign-in completes at the single Gua identity host.
- **Routing verification.** The app uses the resolver's response without verifying it against signed federation state, including roster signatures.
- **Federation policy.** Each homeserver operator sets its Matrix federation policy: open, restricted to selected servers, or disabled. Gua's homeservers currently federate with other Matrix servers. Restricting them to roster members is planned.

[Gua identity and federation](https://github.com/Gua-ra/gua-resolver/blob/main/docs/architecture/gua-identity-and-federation.md) documents the current system. [Planned federation work](https://github.com/Gua-ra/gua-resolver/blob/main/docs/architecture/planned-federation-work.md) lists proposed changes and their requirements.

---

## Building

Requirements: **Xcode 26.5** and an iOS simulator (iOS 18.5 or newer).

```bash
git clone git@github.com:Gua-ra/gua-ios.git
cd gua-ios
open Gua.xcodeproj
```

Select the **Gua** scheme and run. Use `Gua.xcodeproj`; the `ElementX.xcodeproj` next to it is an upstream leftover and is not maintained.

Things to know:

- **Secrets.** `Components/Secrets/Secrets.swift` contains localhost endpoints and placeholder analytics keys for debug builds. Set your development endpoints locally and keep those edits out of commits. Release builds use the production configuration.
- **Project generation.** The Xcode project is generated from `project.yml` / `app.yml` with XcodeGen. If you change project configuration, run `xcodegen` and rebuild.
- **Forking.** Bundle identifiers, app groups and team configuration are covered in [docs/FORKING.md](docs/FORKING.md). Gua's OIDC settings live in `ElementX/Sources/Gua/AppHooks/AppHooks+Gua.swift`.
- **Everything else.** Setup tooling, checks and tests are described in the [contribution guide](CONTRIBUTING.md).

---

## Reporting problems

- Bugs and requests: [open an issue](https://github.com/Gua-ra/gua-ios/issues).
- Security problems: follow [SECURITY.md](SECURITY.md). Never put them in a public issue.
- Anything else: the [support form](https://gua.global/support) or [support@gua.global](mailto:support@gua.global).

---

## Upstream relationship

This fork shares git history with [`element-hq/element-x-ios`](https://github.com/element-hq/element-x-ios), starting from a September 2025 commit. Catching up with upstream is a regular `git merge` of an upstream release tag. See [docs/FORKING.md](docs/FORKING.md) for fork configuration.

Element X iOS is the Matrix client made by [Element](https://element.io/), built on the [Matrix Rust SDK](https://github.com/matrix-org/matrix-rust-sdk). Gua inherits its code, tooling and tests. Element X's own App Store listing, translation project, community rooms and support channels are Element's and do not cover Gua.

---

## License

Copyright (c) 2025-2026 Element Creations Ltd (upstream code)
Copyright (c) 2022-2025 New Vector Ltd (upstream code)
Copyright (c) 2025-2026 Gua (Gua modifications)

Licensed under the GNU Affero General Public License v3.0 (AGPL-3.0), see [LICENSE](LICENSE).

Alternatively available under a paid Element Commercial License for the upstream portions; see [LICENSE-COMMERCIAL](LICENSE-COMMERCIAL) if applicable.

Gua's modifications are available under AGPL-3.0-only. The Element Commercial License applies only to the upstream portions.
