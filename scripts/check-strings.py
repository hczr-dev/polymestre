#!/usr/bin/env python3
"""Garde-fou de traduction, lancé par validate.sh.

Un littéral français rendu dans une `String` (et non une `LocalizedStringKey`)
ne passe jamais par le catalogue : il reste en français quand l'app est en
anglais. Trois formes y mènent à coup sûr, et ce script les refuse dans les
dossiers d'interface :

  return "Progression"                 dans un `var title: String`
  nom ?? "au total"                    le repli d'une valeur optionnelle
  cond ? "Jour" : heure(…)             un ternaire dont l'autre branche est une String

Le remède est `String(localized: "…")` (et l'entrée anglaise au catalogue).
Un texte volontairement laissé tel quel (consigne envoyée à Claude, nom
propre, donnée d'exemple) porte `// l10n: tel quel` sur sa ligne.

Deuxième contrôle : tout littéral passé à `String(localized:)` sans
interpolation doit avoir sa traduction anglaise au catalogue.
"""
import glob, json, re, sys

ROOTS = ["Polymestre/Views", "Polymestre/App", "PolymestreMac", "StudyKit"]
CATALOG = "StudyKit/Localizable.xcstrings"
# Fichiers de consignes, de données d'exemple ou d'outils : rien d'affiché tel quel.
SKIP_FILES = ("Debug", "DemoSemester", "SampleData", "MacStore.swift", "SeriesAIExtractor", "MacLocalMCP",
              "MoodleCourseAIService", "RevisionSheetMaker", "IdentityMigration", "NotesStore",
              "ClaudeMeasureService", "StudyMapStore", "SpotifyLocal", "PolymestreMacApp", "HeadlessCapture")
LIT = r'"((?:[^"\\]|\\\((?:[^()]|\([^()]*\))*\)|\\.)*)"'
PROSE = re.compile(r"[À-ÖØ-öø-ÿ]|[A-Za-zÀ-ÿ]{2,} [A-Za-zÀ-ÿ]{2,}|^[A-ZÀ-Ü][a-zà-ÿ]{3,}$")
# Noms propres : les mêmes dans toutes les langues.
NAMES = {"Moodle", "Courseware", "Claude", "Explique", "General", "Quiz", "Dropbox", "Wooclap", "Spotify"}
SKIP_LINE = re.compile(
    r"^\s*//|l10n: tel quel|String\(localized|systemImage|forKey|NSLog|log\.|print\(|fatalError|assert|Logger"
    r"|accessibilityIdentifier|CommandLine|UserDefaults|AppStorage|case \w+ = \"|Notification\.Name|URL\(string"
    r"|rawValue|== \"|!= \"|hasPrefix|hasSuffix|contains\(\"|replacingOccurrences|dateFormat|AppLog\.record"
    r"|Image\(|case \"|evaluateJavaScript|querySelector|fetch\(|FileHandle|write\(")
RETURN = re.compile(r"\breturn\s+" + LIT + r"\s*$")
COALESCE = re.compile(r"\?\?\s*" + LIT)
TERN_THEN = re.compile(r"[^?]\?\s+" + LIT + r"\s+:\s+(?![\"(]*\")")      # « ? "x" : autre »
TERN_ELSE = re.compile(r"\?\s+(?!\")[^:\"]+\s+:\s+" + LIT)                 # « ? autre : "x" »
LOCALIZED = re.compile(r"String\(localized:\s*" + LIT)

def is_prose(s):
    return bool(PROSE.search(s)) and s not in NAMES and "://" not in s and not s.startswith(("/", ".", "-", "%", "#")) and "\\(" not in s

DECLARATION = re.compile(r"\b(var|func)\b.*(:|->)\s*[A-Za-z]")

def returns_key(lines, index):
    for back in range(index, max(-1, index - 25), -1):
        if DECLARATION.search(lines[back]) and "{" in lines[back]:
            return "LocalizedStringKey" in lines[back]
    return False

def sources():
    for root in ROOTS:
        for path in sorted(glob.glob(root + "/**/*.swift", recursive=True)):
            if not any(name in path for name in SKIP_FILES):
                yield path

def bare_literals():
    found = []
    for path in sources():
        lines = open(path, encoding="utf-8").read().split("\n")
        for number, line in enumerate(lines, 1):
            if SKIP_LINE.search(line):
                continue
            for rule in (RETURN, COALESCE, TERN_THEN, TERN_ELSE):
                for match in rule.finditer(line):
                    if not is_prose(match.group(1)):
                        continue
                    # Un `return "…"` dans une propriété typée `LocalizedStringKey`
                    # est bien une clé : la déclaration la plus proche le dit.
                    if rule is RETURN and returns_key(lines, number - 1):
                        continue
                    found.append((path, number, match.group(1)))
    return sorted(set(found))

def untranslated():
    strings = json.load(open(CATALOG, encoding="utf-8"))["strings"]
    def has_english(key):
        return "en" in strings.get(key, {}).get("localizations", {})
    missing = []
    for path in sources():
        for number, line in enumerate(open(path, encoding="utf-8"), 1):
            if line.lstrip().startswith("//") or "l10n: tel quel" in line:
                continue
            for match in LOCALIZED.finditer(line):
                key = match.group(1)
                if "\\(" in key or "\\" in key:
                    continue
                if not has_english(key):
                    missing.append((path, number, key))
    return sorted(set(missing))

if __name__ == "__main__":
    bare, missing = bare_literals(), untranslated()
    if "--list" in sys.argv:
        for path, number, text in bare:
            print(f"{path}:{number}: {text}")
        sys.exit(0)
    for path, number, text in bare:
        print(f"  ✗ {path}:{number} : « {text} » ne passe pas par le catalogue (String(localized:))")
    for path, number, key in missing:
        print(f"  ✗ {path}:{number} : « {key} » n'a pas de traduction anglaise au catalogue")
    if bare or missing:
        print(f"❌ Traductions : {len(bare)} littéral(aux) hors catalogue, {len(missing)} sans anglais")
        sys.exit(1)
    print("✓ Traductions : aucun littéral d'interface hors catalogue")
