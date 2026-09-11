![](https://github.com/user-attachments/assets/054e40c6-e796-4c6b-9700-7b7c3c4bfc18)

<div align="center">
  
  ![Gua Logo](https://github.com/user-attachments/assets/33d5300f-24ac-42fe-84c2-37ca84920bd1)
  
  <h1>Gua for iOS</h1>
</div>

**Gua** is a private messenger built on the open [Matrix](https://matrix.org/) protocol. Conversations are end-to-end encrypted and run on a federated network. The app feels like the messengers people already use: sign in with something you already have, find your friends privately, and start talking.

Sign-in is deliberately simple. Today it uses your phone number. The account model is designed to stay flexible, and institutional SSO is planned for organizations that bring their own identity.

This repository is the Gua iOS client. It began as a fork of [`element-hq/element-x-ios`](https://github.com/element-hq/element-x-ios) and keeps its Matrix core: the Matrix Rust SDK, timelines, calls, and encryption. On top of that core, Gua adds its own product layer: routing, onboarding, account security, contact discovery, and the day-to-day experience.

---

## What the app does today

Sign-in takes three steps. The user sees none of the routing behind them.

1. **Ask the resolver which homeserver to use.** The app sends the phone number to the Gua resolver. The resolver answers with the homeserver in the closed Gua federation that this account should use.
2. **Sign in through the Gua identity host.** The app runs a standard OIDC sign-in (authorization code with PKCE) against [`gua-auth-service`](https://github.com/Gua-ra/gua-auth-service), Gua's fork of the Matrix Authentication Service.
3. **Delegate to the identity service.** The MAS fork hands sign-in to the [Gua Identity Service](https://github.com/Gua-ra/identity-service). The identity service verifies the phone number with a one-time code and checks the account PIN as the second factor.

The app then connects to the homeserver the resolver named. Users never pick, type, or see a server name.

Beyond sign-in, the Gua product layer adds:

- **Homeserver abstraction.** Server details stay out of the product. People appear as simple usernames rather than full Matrix IDs. The homeserver behind an account never shows in the interface.
- **Simplified onboarding.** A native welcome and sign-in flow, all inside the app: enter a phone number, confirm a one-time code, set up a profile, and secure the account. The pieces behind it are described under [Architecture](#architecture).
- **Two-step verification (account PIN).** A six-digit account PIN is the account's second factor. It is set during onboarding and required for sensitive operations. It can be changed or reset with verification. The client mirrors the server's PIN strength policy: no repeated, sequential, or common PINs.
- **Private contact discovery.** Find Friends shows which of your contacts are already on Gua. It needs address-book permission to run. The app normalizes numbers on the device and sends hashed identifiers in capped batches, never the address book itself. Hashing is a privacy-hardening step. It does not make the numbers impossible to recover.
- **Phone number changes.** The number linked to an account can be changed from Settings. The new number is verified with a one-time code, and the account PIN acts as the second factor.
- **Welcome experience.** A polished, localized welcome screen (en, fr, es, pt, pt-BR) with the animated glass Gua logo.
- **Safe defaults.** End-to-end encryption stays on with sensible defaults, and advanced encryption controls are hidden. The app-lock code is called a passcode so it is never confused with the account PIN.

### Architecture

```
Gua iOS app
    |  1. resolver lookup by phone number: which homeserver to use
    ▼
Gua resolver
    |  2. OIDC authorization code + PKCE against the resolved server
    ▼
Matrix Authentication Service (gua-auth-service)
    |  3. delegated sign-in (phone + one-time code + PIN today; institutional SSO planned)
    ▼
Gua Identity Service
    |
    ▼
Matrix homeserver in the Gua federation
```

- The resolver tells the app which homeserver to use. The client stays universal and never hardcodes a server.
- [`gua-auth-service`](https://github.com/Gua-ra/gua-auth-service) is Gua's fork of the Matrix Authentication Service. Today it delegates identity upstream to the identity service.
- The [Gua Identity Service](https://github.com/Gua-ra/identity-service) implements verification codes, the account PIN, contact lookup, and phone number changes.
- Every sign-in performs a fresh upstream authentication. The app uses an ephemeral web session with `prompt=login`, so a cached browser session never bypasses verification.

## Today versus the target

Everything above describes the app as it ships today. Two parts of the target design are not shipped yet:

- **Per-homeserver authentication.** Today every sign-in completes at the single Gua identity host.
- **Verified routing.** Today the app follows the resolver's answer without verifying it against signed federation state.

[Gua identity and federation](https://github.com/Gua-ra/gua-resolver/blob/main/docs/architecture/gua-identity-and-federation.md) explains the target in plain language. [ADM-001](https://github.com/Gua-ra/gua-resolver/blob/main/docs/decisions/ADM-001-identifier-binding-placement-trust.md) records the decision behind it.

---

## Building

Requirements: **Xcode 26.5** and an iOS simulator (iOS 17.5 or newer).

```bash
git clone git@github.com:Gua-ra/gua-ios.git
cd gua-ios
open Gua.xcodeproj
```

Select the **Gua** scheme and run. Use `Gua.xcodeproj`; the `ElementX.xcodeproj` next to it is an upstream leftover scheduled for removal.

Things to know:

- **Secrets.** `Secrets/Secrets.swift` is committed with placeholder values, so the project always compiles. The placeholders are localhost development endpoints and dummy analytics keys. Debug builds read their development backend endpoints from this file. Point them at your own backend locally and keep those edits out of your commits. Release builds use the production configuration instead.
- **Project generation.** The Xcode project is generated from `project.yml` / `app.yml` with XcodeGen. If you change project configuration, run `xcodegen` and rebuild.
- **Forking.** Bundle identifiers, app groups, team configuration, and the OIDC client requirements are covered in [docs/FORKING.md](docs/FORKING.md).
- **Everything else.** Code generation, tests, and tooling are described in the [contribution guide](CONTRIBUTING.md).

---

## Upstream relationship

This fork tracks [`element-hq/element-x-ios`](https://github.com/element-hq/element-x-ios) as its upstream but does not share git history with it. Catching up with upstream means re-porting Gua's changes onto a new upstream snapshot, not running `git merge`. See [docs/FORKING.md](docs/FORKING.md) for the fork configuration itself.

---

## License

Copyright (c) 2022-2025 New Vector Ltd (upstream code)
Copyright (c) 2025 Gua (Gua modifications)

Licensed under the GNU Affero General Public License v3.0 (AGPL-3.0), see [LICENSE](LICENSE).

Alternatively available under a paid Element Commercial License for the upstream portions; see [LICENSE-COMMERCIAL](LICENSE-COMMERCIAL) if applicable.
