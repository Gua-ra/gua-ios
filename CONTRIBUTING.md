# Contributing to Gua for iOS

Gua for iOS is a fork of [Element X iOS](https://github.com/element-hq/element-x-ios). Upstream's tooling and project layout still apply. This guide covers what is specific to Gua.

Upstream's CLA, Localazy and pull request instructions do not apply here. There is no CLA, and pull requests go to `Gua-ra/gua-ios`.

## Where the Gua code lives

- `ElementX/Sources/Gua/`: services, screens, common views and app hooks that make up the Gua product layer. New Gua screens follow the existing pattern (coordinator, models, view model, protocol, view); copy an existing Gua screen as a template.
- Upstream files that Gua changed keep their place.
- Fork strings live in `ElementX/Resources/Localizations/<locale>.lproj/Untranslated.strings` and are generated into `UntranslatedL10n`. Do not add Gua strings to `Localizable.strings`, which comes from upstream.

Keeping Gua changes in these places makes the next upstream re-port smaller.

## Setup

Build as described in the README's [Building](README.md#building) section. Run this once first:

```bash
swift run tools setup-project   # brew dependencies, shared git hooks, git LFS, xcodegen
```

Dependencies come through Swift Package Manager, including a release build of the Matrix Rust SDK. `swift run tools build-sdk` builds the SDK locally instead; see `swift run tools build-sdk --help`.

## Before opening a pull request

- SwiftLint and SwiftFormat run as build phases and on CI, with the rules in `.swiftlint.yml` and `.swiftformat`.
- Unit tests: the **Gua** scheme. Preview snapshots: the **PreviewTests** scheme on the simulator pinned in `PreviewTests/Sources/PreviewTests.swift`. Snapshots are stored under `__Snapshots__` in each test target and tracked with git LFS; `swift run tools setup-project` installs it.
- A changed screen needs its preview snapshots re-recorded. Delete the stale PNGs for that screen only and run the PreviewTests scheme; the run records them as missing.
- UI tests run nightly on CI, not on pull requests.
- License headers: a new Gua file starts with `Copyright <year> Gua` followed by the repository's SPDX line. A file generated from upstream's screen template (`Tools/Scripts/createScreen.sh`) keeps the template's New Vector line above the Gua line. A modified upstream file keeps its New Vector notice.

## Pull requests

Branch from `develop`. Commits, pull request text and writing follow the [org contribution guide](https://github.com/Gua-ra/.github/blob/main/CONTRIBUTING.md#pull-requests).

## Reporting problems

- Bugs and requests: [GitHub issues](https://github.com/Gua-ra/gua-ios/issues).
- Security problems: [SECURITY.md](SECURITY.md), never a public issue.

## Upstream

See the README's [Upstream relationship](README.md#upstream-relationship).
