# Scripts

## Create screen templates
New screen flows are currently using the MVVM-Coordinator pattern. Run [Tools/Scripts/createScreen.sh](Tools/Scripts/createScreen.sh) to create a new screen and all its required dependencies.

Usage:
```
./createScreen.sh Folder MyScreenName
```

After that run `xcodegen` to regenerate the project.  

`createScreen.sh` script will create:

- `Folder` within the `/ElementX/Sources/Screens/`. Files inside will be named `MyScreenNameXxx`.
- `MyScreenNameScreenUITests.swift` within `UITests/Sources`
- `MyScreenNameViewModelTests.swift` within `UnitTests/Sources/Unit`


## Check translations
Gua ships en, pt-BR, es and fr. [check_translations.py](check_translations.py) fails when a pt-BR, es or fr user would see English: a missing or English-identical translation, a permission prompt without a translation, another language in the Xcode project, or (with `--base <sha>`) an English literal added to a SwiftUI text API, an alert or dialog, or a `title:`, `subtitle:`, `message:` or `placeholder:` argument outside previews. CI runs it from `.github/workflows/unit_tests.yml`.

```
Tools/Scripts/check_translations.py --base origin/develop
```

Lines in [translations_baseline.txt](translations_baseline.txt) are accepted without a translation. Add to it only in upstream sync PRs; a line that is no longer needed fails the check. A source line that really needs a literal can end with `// l10n-ignore`.
