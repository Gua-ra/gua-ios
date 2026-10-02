#!/usr/bin/env python3
#
# Copyright 2026 Gua
#
# SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
# Please see LICENSE files in the repository root for full details.
#

"""Fails when Gua would show English to a pt-BR, es or fr user.

Checks:
  1. Every key of the English Localizable and Untranslated tables (.strings and .stringsdict) has a
     translation in pt-BR, es and fr that differs from the English and keeps its placeholders, unless
     `<locale>:<key>` is listed in translations_baseline.txt. Baseline entries that are no longer
     needed fail too, so the list only ever shrinks outside upstream syncs.
  2. Every NS*UsageDescription in the app's Info.plist is translated in each InfoPlist.strings.
  3. The Xcode project ships only the supported localizations.
  4. Lines added under ElementX/Sources since --base do not pass an English literal to a SwiftUI
     text API, an alert or dialog, or a `title:`, `subtitle:`, `message:` or `placeholder:`
     argument. Preview code at the end of a file is skipped. Add `// l10n-ignore` to a line that
     really needs one.

Usage: Tools/Scripts/check_translations.py [--base <git sha>]
"""

import argparse
import plistlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LOCALIZATIONS = ROOT / "ElementX/Resources/Localizations"
BASELINE = Path(__file__).resolve().parent / "translations_baseline.txt"
INFO_PLIST = ROOT / "ElementX/SupportingFiles/Info.plist"
PROJECT = ROOT / "Gua.xcodeproj/project.pbxproj"

SOURCE_LOCALE = "en"
LOCALES = ["pt-BR", "es", "fr"]
SHIPPED_REGIONS = {"Base", SOURCE_LOCALE, *LOCALES}
STRINGS_TABLES = ["Localizable.strings", "Untranslated.strings"]
STRINGSDICT_TABLES = ["Localizable.stringsdict", "Untranslated.stringsdict"]

STRINGS_ENTRY = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.MULTILINE)
PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:#@[A-Za-z_]+@|l{0,2}[@dDuUxXoOfeEgGcCsSp])")

# A string literal containing at least one letter, passed straight to a text-taking API.
TEXT_APIS = (r'(?:\bText|\bLabel|\bButton|\bTextField|\bSecureField|\bToggle|\bSection|\bLink'
             r'|\.navigationTitle|\.accessibilityLabel|\.accessibilityHint|\.accessibilityValue'
             r'|\.alert|\.confirmationDialog|\bprompt:|\b(?:title|subtitle|message|placeholder):)')
LITERAL_CALL = re.compile(TEXT_APIS + r'\(?\s*"((?:[^"\\]|\\.)*)"')
IGNORE_MARKER = "// l10n-ignore"
LITERAL_EXCLUDED_DIRS = ("ElementX/Sources/Generated/", "ElementX/Sources/UITests/", "ElementX/Sources/Mocks/")
# Previews sit at the end of a screen's file; literals from there on are sample data, not copy.
PREVIEW_START = re.compile(r"PreviewProvider|#Preview\b")


def read_strings(path):
    if not path.exists():
        return None
    return dict(STRINGS_ENTRY.findall(path.read_text(encoding="utf-8")))


def read_stringsdict(path):
    if not path.exists():
        return None
    with path.open("rb") as file:
        plist = plistlib.load(file)

    flattened = {}
    for key, entry in plist.items():
        # Join every plural form so a missing or English form shows up as a difference.
        forms = []
        for variable, rules in sorted(entry.items()):
            if isinstance(rules, dict):
                forms += [f"{variable}.{rule}={value}" for rule, value in sorted(rules.items())
                          if rule not in ("NSStringFormatSpecTypeKey", "NSStringFormatValueTypeKey")]
            else:
                forms.append(f"{variable}={rules}")
        flattened[key] = "\n".join(forms)
    return flattened


def placeholders(value):
    return sorted(PLACEHOLDER.findall(value.replace("%%", "")))


def plural_placeholders(value):
    # Plural forms may drop the number ("one" often reads "a minute"), so compare the union only.
    return sorted(set(PLACEHOLDER.findall(value.replace("%%", ""))))


def load_baseline():
    entries = set()
    for line in BASELINE.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            entries.add(line)
    return entries


def check_coverage(baseline):
    problems, used = [], set()

    def report(locale, key, message):
        entry = f"{locale}:{key}"
        if entry in baseline:
            used.add(entry)
        else:
            problems.append(f"{entry}: {message}")

    tables = [(name, read_strings, placeholders) for name in STRINGS_TABLES]
    tables += [(name, read_stringsdict, plural_placeholders) for name in STRINGSDICT_TABLES]
    for table, read, placeholder_set in tables:
        source = read(LOCALIZATIONS / f"{SOURCE_LOCALE}.lproj" / table) or {}
        for locale in LOCALES:
            translations = read(LOCALIZATIONS / f"{locale}.lproj" / table) or {}
            for key, english in source.items():
                value = translations.get(key)
                if value is None:
                    report(locale, key, f"missing from {table}")
                elif value == english:
                    report(locale, key, f"same as English in {table}")
                elif placeholder_set(value) != placeholder_set(english):
                    report(locale, key, f"placeholders {placeholder_set(value)} differ from English {placeholder_set(english)} in {table}")

    stale = sorted(baseline - used)
    for entry in stale:
        problems.append(f"{entry}: listed in {BASELINE.name} but translated now, remove the line")
    return problems


def check_info_plist():
    problems = []
    with INFO_PLIST.open("rb") as file:
        info = plistlib.load(file)
    usage_keys = sorted(key for key in info if key.startswith("NS") and key.endswith("UsageDescription"))

    english = read_strings(LOCALIZATIONS / f"{SOURCE_LOCALE}.lproj/InfoPlist.strings") or {}
    for locale in [SOURCE_LOCALE, *LOCALES]:
        strings = read_strings(LOCALIZATIONS / f"{locale}.lproj/InfoPlist.strings") or {}
        for key in usage_keys:
            value = strings.get(key)
            if value is None:
                problems.append(f"{locale}:{key}: missing from InfoPlist.strings")
            elif locale != SOURCE_LOCALE and value == english.get(key):
                problems.append(f"{locale}:{key}: same as English in InfoPlist.strings")
            elif "Element" in value:
                problems.append(f"{locale}:{key}: still names Element in InfoPlist.strings")
    return problems


def check_shipped_localizations():
    project = PROJECT.read_text(encoding="utf-8")
    match = re.search(r"knownRegions = \((.*?)\);", project, re.DOTALL)
    regions = {region.strip().strip('"') for region in match.group(1).split(",") if region.strip()} if match else set()
    folders = set(re.findall(r'path = "?([A-Za-z-]+)\.lproj/', project))
    unexpected = sorted((regions | folders) - SHIPPED_REGIONS)
    return [f"{region}: not a shipped language, exclude Localizations/{region}.lproj in ElementX/SupportingFiles/target.yml"
            for region in unexpected]


def added_lines(base):
    diff = subprocess.run(["git", "-C", str(ROOT), "diff", "--unified=0", "--no-color", base, "HEAD", "--", "ElementX/Sources"],
                          check=True, capture_output=True, text=True).stdout
    path, line_number = None, 0
    for line in diff.splitlines():
        if line.startswith("+++ "):
            path = line[6:] if line.startswith("+++ b/") else None
        elif line.startswith("@@"):
            line_number = int(re.search(r"\+(\d+)", line).group(1))
        elif line.startswith("+") and path:
            yield path, line_number, line[1:]
            line_number += 1


def preview_start_line(path, cache):
    if path not in cache:
        source = subprocess.run(["git", "-C", str(ROOT), "show", f"HEAD:{path}"], capture_output=True, text=True).stdout
        cache[path] = next((number for number, line in enumerate(source.splitlines(), 1) if PREVIEW_START.search(line)), None)
    return cache[path]


def check_literals(base):
    problems, preview_lines = [], {}
    for path, line_number, line in added_lines(base):
        if path.startswith(LITERAL_EXCLUDED_DIRS) or IGNORE_MARKER in line:
            continue
        preview_line = preview_start_line(path, preview_lines)
        if preview_line is not None and line_number >= preview_line:
            continue
        code = line.split("//", 1)[0] if not line.lstrip().startswith(("//", "@available")) else ""
        for literal in LITERAL_CALL.findall(code):
            if re.search(r"[A-Za-z]", re.sub(r"\\\(.*?\)", "", literal)):
                problems.append(f'{path}:{line_number}: English literal "{literal}", use a strings key or add {IGNORE_MARKER}')
    return problems


def resolve_base(base):
    for candidate in (base, "HEAD^1"):
        if candidate and subprocess.run(["git", "-C", str(ROOT), "cat-file", "-e", f"{candidate}^{{commit}}"],
                                        capture_output=True).returncode == 0:
            return candidate
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", help="commit to diff against for the literal check (skipped when omitted)")
    args = parser.parse_args()

    sections = [("Translations", check_coverage(load_baseline())),
                ("Permission prompts", check_info_plist()),
                ("Shipped languages", check_shipped_localizations())]
    if args.base:
        base = resolve_base(args.base)
        if base:
            sections.append((f"English literals added since {base}", check_literals(base)))
        else:
            print(f"warning: cannot find {args.base}, skipping the literal check", file=sys.stderr)

    failed = False
    for title, problems in sections:
        if problems:
            failed = True
            print(f"{title}: {len(problems)} problem(s)")
            for problem in problems:
                print(f"  {problem}")
        else:
            print(f"{title}: OK")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
