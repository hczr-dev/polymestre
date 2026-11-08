import Foundation
import SwiftData

/// Une échéance de la vie de l'EPFL : borne de semestre, vacances, délai
/// administratif, session d'examens, publication officielle.
///
/// Les cours disent ce qu'on étudie ; ceci dit **quand** l'école vit. Sans ces
/// dates, l'agenda de l'app ne connaissait ni la fin des enseignements, ni le
/// début des examens, ni la date limite d'inscription — c'est-à-dire tout ce qui
/// ne se rattrape pas.
@Model
final class AcademicMilestone {
    var id: UUID = UUID()
    /// Clé stable : celle du parseur pour une échéance officielle, un identifiant
    /// local pour une échéance ajoutée à la main. C'est elle qui permet de
    /// **mettre à jour** au lieu de dupliquer à chaque rafraîchissement.
    var externalID: String = ""
    var title: String = ""
    var date: Date = Date.now
    var kindRaw: String = ""
    /// Mise en évidence par l'EPFL lui-même dans son tableau.
    var isImportant: Bool = false
    /// Date approximative (« fin décembre ») : l'app le dit à l'écran au lieu de
    /// faire passer une approximation pour une date exacte.
    var isApproximate: Bool = false
    var termLabel: String = ""
    /// Vrai si l'échéance vient de l'EPFL, faux si l'étudiant·e l'a ajoutée.
    var isOfficial: Bool = false
    var notes: String = ""
    var addedAt: Date = Date.now
    /// Date de dernière confirmation par la source, pour distinguer une échéance
    /// rafraîchie d'une échéance héritée de l'instantané.
    var confirmedAt: Date = Date.now

    init(id: UUID = UUID(),
         externalID: String,
         title: String,
         date: Date,
         kind: MilestoneKind,
         isImportant: Bool = false,
         isApproximate: Bool = false,
         termLabel: String = "",
         isOfficial: Bool = true,
         notes: String = "",
         confirmedAt: Date = Date()) {
        self.id = id
        self.externalID = externalID
        self.title = title
        self.date = date
        self.kindRaw = kind.rawValue
        self.isImportant = isImportant
        self.isApproximate = isApproximate
        self.termLabel = termLabel
        self.isOfficial = isOfficial
        self.notes = notes
        self.addedAt = Date()
        self.confirmedAt = confirmedAt
    }

    var kind: MilestoneKind {
        get { MilestoneKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    var value: AcademicMilestoneValue {
        AcademicMilestoneValue(id: externalID,
                               title: title,
                               date: date,
                               kind: kind,
                               isImportant: isImportant,
                               isApproximate: isApproximate,
                               termLabel: termLabel)
    }

    var isPast: Bool { date < Date() }

    /// « dans 12 j », « aujourd'hui » — avec la mention d'approximation.
    func countdown(from reference: Date = Date()) -> String {
        let base = value.countdown(from: reference)
        return isApproximate ? String(localized: "vers le \(DateUtils.shortDay.string(from: date))") : base
    }

    /// Installe l'instantané embarqué si l'app ne connaît encore aucune échéance.
    ///
    /// Au niveau du modèle et non du service : la réparation de données, qui vit
    /// dans la couche modèle, doit pouvoir l'appeler sans dépendre du réseau.
    @discardableResult
    static func installSnapshotIfNeeded(in context: ModelContext) -> Int {
        let count = (try? context.fetchCount(FetchDescriptor<AcademicMilestone>())) ?? 0
        guard count == 0 else { return 0 }
        let values = EPFLCalendarSnapshot.milestones()
        upsert(values, in: context)
        return values.count
    }

    @discardableResult
    static func upsert(_ values: [AcademicMilestoneValue],
                       in context: ModelContext,
                       official: Bool = true) -> (added: Int, updated: Int, removed: Int) {
        let existing = (try? context.fetch(FetchDescriptor<AcademicMilestone>())) ?? []
        var byKey = Dictionary(existing.map { ($0.externalID, $0) },
                               uniquingKeysWith: { first, _ in first })
        var added = 0
        var updated = 0
        let now = Date()

        for value in values {
            if let match = byKey[value.id] {
                if match.date != value.date
                    || match.title != value.title
                    || match.kindRaw != value.kind.rawValue
                    || match.isImportant != value.isImportant {
                    updated += 1
                }
                match.title = value.title
                match.date = value.date
                match.kind = value.kind
                match.isImportant = value.isImportant
                match.isApproximate = value.isApproximate
                match.termLabel = value.termLabel
                match.confirmedAt = now
                match.isOfficial = official
            } else {
                let created = AcademicMilestone(externalID: value.id,
                                                title: value.title,
                                                date: value.date,
                                                kind: value.kind,
                                                isImportant: value.isImportant,
                                                isApproximate: value.isApproximate,
                                                termLabel: value.termLabel,
                                                isOfficial: official,
                                                confirmedAt: now)
                context.insert(created)
                byKey[value.id] = created
                added += 1
            }
        }

        // Une échéance officielle **à venir** qui n'est plus publiée a été corrigée
        // ou retirée par l'EPFL. La garder ferait croire à une date qui n'existe
        // plus ; les échéances passées, elles, restent comme historique.
        var removed = 0
        if official {
            let fresh = Set(values.map(\.id))
            for milestone in existing
            where milestone.isOfficial && !fresh.contains(milestone.externalID) && milestone.date > now {
                context.delete(milestone)
                removed += 1
            }
        }
        return (added, updated, removed)
    }
}
