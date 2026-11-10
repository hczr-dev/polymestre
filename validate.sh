#!/usr/bin/env bash
#
# Validation exécutable des modèles SwiftData et des moteurs métier.
#
# Compile Polymestre/Models + Polymestre/Domain (+ le thème) dans un binaire macOS
# et vérifie : schéma SwiftData, relations inverses, moteurs de progression, de
# charge EPFL et de gamification, ainsi que les entités sociales / tâches.
#
#   ./validate.sh           # contrôles de correction (967 assertions)
#   ./validate.sh --bench   # + repères de performance sur un semestre simulé
#
# Utile car l'app iOS complète ne peut pas être exécutée sans simulateur installé.

set -euo pipefail

# Mode étude du Mac : aucune taille de texte écrite en dur hors de StudyType.swift
# (et des glyphes proportionnels à leur cadre, « size * »).
if grep -nE '\.system\(size: [0-9]|Carnet\.(serif|clock)\([0-9]' "$(cd "$(dirname "$0")" && pwd)"/PolymestreMac/StudyMode/*.swift \
    | grep -v 'StudyType.swift' | grep -v 'size \*' | grep .; then
  echo "❌ taille de texte écrite en dur dans PolymestreMac/StudyMode (voir StudyType.swift)"
  exit 1
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"

# Traductions : un littéral français rendu dans une `String` ne passe jamais par
# le catalogue et reste en français quand l'app est en anglais (« Démarrer »,
# « Jour », « au total »…). Le script refuse les trois formes qui y mènent, et
# tout `String(localized:)` sans anglais au catalogue.
(cd "$ROOT" && python3 scripts/check-strings.py)

# Scratch dir OUTSIDE the project tree. Never write Swift sources into the repo:
# Xcode's synchronized folder groups scan the project, and a second file named
# like a real source file produces "Multiple commands produce <file>.stringsdata".
WORK="$(mktemp -d "${TMPDIR:-/tmp}/polymestre-validation.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Sources"

cp "$ROOT"/Polymestre/Models/*.swift "$WORK/Sources/"
cp "$ROOT"/Polymestre/Domain/*.swift "$WORK/Sources/"
cp "$ROOT"/Polymestre/App/Theme.swift "$WORK/Sources/"
cp "$ROOT"/Polymestre/App/SupabaseConfig.swift "$WORK/Sources/"
cp "$ROOT"/Shared/ColorContrast.swift "$WORK/Sources/"
# La logique de temps de la Live Activity est pure (pas d'ActivityKit) : elle se
# teste donc ici, ce qui aurait attrapé le compteur qui repartait de zéro.
cp "$ROOT"/Shared/ActivityTimerState.swift "$WORK/Sources/"
# Même raison pour le jour d'examen : quand l'activité s'ouvre et quand elle se
# ferme sont des décisions pures, et ce sont les seules qui puissent se tromper.
cp "$ROOT"/Shared/ExamActivityState.swift "$WORK/Sources/"
cp "$ROOT"/Shared/WidgetBridge.swift "$WORK/Sources/"
cp "$ROOT"/Polymestre/Services/DataExporter.swift "$WORK/Sources/"
cp "$ROOT"/Polymestre/Services/CalendarService.swift "$WORK/Sources/"
cp "$ROOT"/Polymestre/Services/TimetableImportService.swift "$WORK/Sources/"
cp "$ROOT"/Polymestre/Services/TimetableImport.swift "$WORK/Sources/"
cp "$ROOT"/Polymestre/Services/CourseImporter.swift "$WORK/Sources/"
cp "$ROOT"/Polymestre/Services/SeriesPDFParser.swift "$WORK/Sources/"
cp "$ROOT"/Polymestre/Services/PDFLayoutExtractor.swift "$WORK/Sources/"
cp "$ROOT"/Validation/main.swift "$WORK/Sources/"
cp "$ROOT"/Validation/PDFFixtures.swift "$WORK/Sources/"
cp "$ROOT"/Validation/BotafogoFixtures.swift "$WORK/Sources/"
cp "$ROOT"/Validation/LocalMCPTests.swift "$WORK/Sources/"
cp "$ROOT"/Validation/SyncTests.swift "$WORK/Sources/"
cp "$ROOT"/Validation/SyncCryptoTests.swift "$WORK/Sources/"
cp "$ROOT"/Validation/IdentityMigrationTests.swift "$WORK/Sources/"
cp "$ROOT"/Validation/SeriesIdentityTests.swift "$WORK/Sources/"
cp "$ROOT"/Validation/LateWorkTests.swift "$WORK/Sources/"

# Garde-fou : tout type annoté `@Model` doit figurer dans le schéma versionné.
#
# C'est l'oubli qui avait laissé `GroupItemCompletion` hors du conteneur — la
# relation le ramassait par chance, mais rien ne le garantissait. On lit donc les
# sources et on **génère** la liste, pour que le test compare le code au schéma.
MODELS=$(awk '/^@Model/ { while (getline > 0 && $0 !~ /class/) ; if (match($0, /class [A-Za-z0-9_]+/)) print substr($0, RSTART + 6, RLENGTH - 6) }' \
  "$ROOT"/Polymestre/Models/*.swift | sort -u)
{
  echo "// Généré par validate.sh à partir des sources : ne pas éditer."
  echo "let declaredModelNames: [String] = ["
  for model in $MODELS; do echo "    \"$model\","; done
  echo "]"
} > "$WORK/Sources/GeneratedModels.swift"
echo "→ Modèles déclarés : $(echo "$MODELS" | wc -l | tr -d ' ')"

SDK="$(xcrun --show-sdk-path --sdk macosx)"

echo "→ Compilation de la validation…"
xcrun swiftc -disable-sandbox \
  -module-cache-path "$WORK/mc" \
  -sdk "$SDK" \
  -target arm64-apple-macosx14.0 \
  -o "$WORK/validate" \
  "$WORK"/Sources/*.swift

echo "→ Exécution…"
export POLYMESTRE_ROOT="$ROOT"
"$WORK/validate" "$@"
