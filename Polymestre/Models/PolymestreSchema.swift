import Foundation
import SwiftData

/// **Version 1** du schéma de données, figée.
///
/// SwiftData migre tout seul les changements *additifs*, et c'est ce qui a été fait
/// jusqu'ici. Ça a coûté deux défauts silencieux : un attribut `roleRaw` ajouté
/// après coup a pris sa valeur par défaut « member » — **y compris pour le
/// créateur du groupe**, qui perdait ses droits sur son propre groupe ; et une
/// session d'authentification non persistée déconnectait à chaque lancement. Aucun
/// des deux ne produisait d'erreur : la migration légère avait « réussi ».
///
/// D'où cette version figée. À partir d'ici, un changement de modèle s'ajoute
/// **à côté** :
///
/// 1. écrire `enum SchemaV2: VersionedSchema` avec la liste complète des modèles ;
/// 2. décrire le passage dans `PolymestreMigrationPlan.stages` ;
/// 3. si un attribut nouveau a besoin d'une valeur calculée — pas d'un défaut —
///    écrire un `MigrationStage.custom` avec son `didMigrate`.
///
/// Le garde-fou de `validate.sh` refuse un `@Model` absent de cette liste : c'est
/// exactement l'oubli qui avait laissé `GroupItemCompletion` hors du conteneur.
enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            AcademicTerm.self,
            Course.self,
            TheoryItem.self,
            ExerciseSeries.self,
            Exercise.self,
            StudySession.self,
            Exam.self,
            PlannedSession.self,
            LinkedTask.self,
            LinkedCalendarEvent.self,
            StudyGroup.self,
            GroupMember.self,
            GroupSeriesCompletion.self,
            GroupItemCompletion.self,
            AcademicMilestone.self,
            PastExam.self,
            SubQuestion.self,
            RelayBeacon.self,
            Mistake.self,
            SavedResource.self
        ]
    }
}

/// Point d'entrée du schéma : l'app ne référence que `current`.
enum PolymestreSchema {
    /// La version utilisée par le conteneur.
    ///
    /// Changer cette ligne est le **seul** geste qui fait passer l'app à une
    /// nouvelle version de schéma — et il oblige à avoir écrit le plan de
    /// migration, puisque `PolymestreMigrationPlan.schemas` doit la contenir.
    static var current: Schema { Schema(SchemaV1.models) }

    /// Version courante, telle qu'écrite dans les réglages.
    ///
    /// Sert à ne rejouer une réparation qu'une fois : sans ce marqueur, une
    /// correction de données s'exécuterait à chaque lancement, indéfiniment.
    static let versionKey = "schema.version"
    static var currentVersion: Int { 1 }
}

/// Plan de migration.
///
/// Vide pour l'instant : il n'existe qu'une version. Sa raison d'être est d'être
/// **déjà branché** le jour où une deuxième apparaîtra — un plan ajouté après coup
/// sur une base déjà migrée ne rattrape rien.
enum PolymestreMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

/// Réparations de données, nommées et jouées une seule fois par version.
///
/// Elles ne sont pas des migrations — le schéma est déjà à jour — mais des
/// corrections de **contenu** rendues nécessaires par un défaut passé. Les nommer
/// permet de dire ce qui a été fait, et de ne pas le refaire.
enum DataRepair {

    struct Outcome {
        var coursesAttached = 0
        var milestonesInstalled = 0
        var bonusCleared = 0

        var summary: String {
            var parts: [String] = []
            if coursesAttached > 0 {
                parts.append(String(localized: "\(Plural.count(coursesAttached, "\(coursesAttached) cours rattaché", "\(coursesAttached) cours rattachés")) à leur semestre"))
            }
            if milestonesInstalled > 0 {
                parts.append(String(localized: "\(milestonesInstalled) échéances de l'EPFL installées"))
            }
            if bonusCleared > 0 {
                parts.append(String(localized: "\(bonusCleared) exercices remis au programme"))
            }
            return parts.joined(separator: " · ")
        }
    }

    /// Applique les réparations connues, puis marque la version comme faite.
    ///
    /// Idempotent par construction : chaque étape ne touche que ce qui est cassé.
    /// Le marqueur évite simplement de relire toute la base à chaque lancement.
    /// Augmente quand une réparation s'ajoute : elle est alors jouée une fois.
    static let repairVersion = 3
    static let repairKey = "dataRepair.version"

    @discardableResult
    static func run(in context: ModelContext, defaults: UserDefaults = .standard) -> Outcome {
        var outcome = Outcome()
        // Le marqueur arrête **vraiment** les réparations : avant, il n'était
        // qu'écrit, et toute la base était relue à chaque lancement.
        guard defaults.integer(forKey: repairKey) < repairVersion else { return outcome }

        // Les cours importés avant la correction n'ont aucun semestre : ils
        // affichaient « semaine 1 » en pleine semaine 2.
        outcome.coursesAttached = AcademicTerm.attachOrphanCourses(in: context)

        // Le calendrier académique doit être là hors ligne, dès l'installation.
        outcome.milestonesInstalled = AcademicMilestone.installSnapshotIfNeeded(in: context)

        // Une série lue tout en « bonus » (une note de page prise pour une
        // mention) : la même règle que l'import d'aujourd'hui
        // (`DetectedSeries.withoutBlanketBonus`).
        outcome.bonusCleared = clearBlanketBonus(in: context)

        defaults.set(PolymestreSchema.currentVersion, forKey: PolymestreSchema.versionKey)
        defaults.set(repairVersion, forKey: repairKey)
        try? context.save()
        return outcome
    }

    static func clearBlanketBonus(in context: ModelContext) -> Int {
        let all = (try? context.fetch(FetchDescriptor<ExerciseSeries>())) ?? []
        var cleared = 0
        for series in all where series.exercises.count >= 3 && series.exercises.allSatisfy(\.isBonus) {
            for exercise in series.exercises { exercise.isBonus = false }
            cleared += series.exercises.count
        }
        return cleared
    }
}
