import Foundation
import EventKit
import SwiftData

/// Événement lu depuis le calendrier système.
struct ExternalCalendarEvent {
    var identifier: String
    var title: String
    var startsAt: Date
    var endsAt: Date
    var location: String
    var calendarTitle: String
    var notes: String
    var isAllDay: Bool = false
}

/// Spécification de création d'un événement dans le calendrier système.
struct CalendarEventSpec {
    var title: String
    var startsAt: Date
    var endsAt: Date
    var location: String = ""
    var notes: String = ""
    var calendarTitle: String = CalendarEventSpec.appCalendarTitle

    /// Le calendrier où l'app écrit ses sessions planifiées.
    static let appCalendarTitle = "Polymestre"
    /// Son nom avant le changement de nom de l'app : renommé au premier usage.
    static let legacyCalendarTitle = "StudyTrack"
}

/// Abstraction du calendrier (EventKit aujourd'hui, CalDAV demain).
protocol CalendarService: AnyObject {
    var hasAccess: Bool { get }
    var authorizationDenied: Bool { get }
    func requestAccess() async -> Bool
    func availableCalendarTitles() -> [String]
    func fetchEvents(from start: Date, to end: Date) -> [ExternalCalendarEvent]
    func createEvent(_ spec: CalendarEventSpec) -> String?
    func deleteEvent(identifier: String)
}

/// Implémentation EventKit (iOS 17+).
final class EventKitCalendarService: CalendarService {
    private let store = EKEventStore()

    var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    var authorizationDenied: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        return status == .denied || status == .restricted
    }

    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    func availableCalendarTitles() -> [String] {
        store.calendars(for: .event).map(\.title).sorted()
    }

    func fetchEvents(from start: Date, to end: Date) -> [ExternalCalendarEvent] {
        guard hasAccess else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map { event in
            ExternalCalendarEvent(
                identifier: event.eventIdentifier ?? UUID().uuidString,
                title: event.title ?? String(localized: "Sans titre"),
                startsAt: event.startDate,
                endsAt: event.endDate,
                location: event.location ?? "",
                calendarTitle: event.calendar?.title ?? "",
                notes: event.notes ?? "",
                isAllDay: event.isAllDay
            )
        }
    }

    func createEvent(_ spec: CalendarEventSpec) -> String? {
        guard hasAccess else { return nil }
        let event = EKEvent(eventStore: store)
        event.title = spec.title
        event.startDate = spec.startsAt
        event.endDate = spec.endsAt
        event.location = spec.location
        event.notes = spec.notes
        event.calendar = calendar(named: spec.calendarTitle)
        do {
            try store.save(event, span: .thisEvent, commit: true)
            return event.eventIdentifier
        } catch {
            return nil
        }
    }

    func deleteEvent(identifier: String) {
        guard hasAccess, let event = store.event(withIdentifier: identifier) else { return }
        try? store.remove(event, span: .thisEvent, commit: true)
    }

    private func calendar(named title: String) -> EKCalendar? {
        let calendars = store.calendars(for: .event)
        if let existing = calendars.first(where: { $0.title == title }) {
            return existing
        }
        // L'app s'appelait Polymestre : son calendrier garde ses sessions, il change seulement de nom.
        if title == CalendarEventSpec.appCalendarTitle,
           let legacy = calendars.first(where: { $0.title == CalendarEventSpec.legacyCalendarTitle && $0.allowsContentModifications }) {
            legacy.title = title
            try? store.saveCalendar(legacy, commit: true)
            return legacy
        }
        guard let source = store.defaultCalendarForNewEvents?.source else {
            return store.defaultCalendarForNewEvents
        }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = title
        calendar.source = source
        try? store.saveCalendar(calendar, commit: true)
        return calendar
    }
}

/// Synchronisation du calendrier système vers les événements locaux liés aux cours.
enum CalendarSync {

    struct SyncResult {
        var imported = 0
        var updated = 0
        var total = 0
    }

    @discardableResult
    static func sync(context: ModelContext,
                     courses: [Course],
                     service: CalendarService,
                     daysBack: Int = 30,
                     daysForward: Int = 150) -> SyncResult {
        var result = SyncResult()
        guard service.hasAccess else { return result }

        let start = DateUtils.addDays(-daysBack, to: Date())
        let end = DateUtils.addDays(daysForward, to: Date())
        let external = service.fetchEvents(from: start, to: end)
        result.total = external.count

        var existing = (try? context.fetch(FetchDescriptor<LinkedCalendarEvent>())) ?? []
        // Les séances de l'horaire importé (`.ics`) : la même séance lue dans le
        // calendrier de l'iPhone abonné au même flux n'est **pas** ajoutée une
        // seconde fois. C'était la moitié des 35 h d'amphi.
        let imported = existing.filter { $0.sourceCalendarID == "ics" }
        let learned = learnedKinds(existing)

        func importedTwin(course: Course?, start: Date) -> Bool {
            imported.contains { TimetableClassifier.isSameSession(courseA: $0.course?.id, startA: $0.startsAt,
                                                                  courseB: course?.id, startB: start) }
        }

        for item in external {
            // L'agenda n'est pas le calendrier personnel : on ne garde que ce qui
            // se rattache à un cours, ou qui est une évaluation ou une révision.
            // Les journées entières (anniversaires, congés) n'y entrent jamais.
            let course = matchCourse(for: item.title, in: courses)
            let kind = classify(title: item.title, location: item.location, course: course, start: item.startsAt, learned: learned)
            let academic = course != nil || [.midterm, .exam, .study].contains(kind)
            guard !item.isAllDay, academic, !importedTwin(course: course, start: item.startsAt) else {
                if let stale = existing.first(where: { $0.externalEventID == item.identifier }) {
                    context.delete(stale)
                    existing.removeAll { $0 === stale }
                }
                continue
            }
            // Par identifiant, sinon par intitulé et horaire : la même séance
            // arrivée d'un autre appareil (iCloud) porte l'identifiant de son
            // calendrier à lui. La recréer ferait un doublon à chaque relecture.
            let twin = existing.first(where: { $0.externalEventID == item.identifier })
                ?? existing.first(where: { $0.title == item.title && $0.startsAt == item.startsAt && $0.endsAt == item.endsAt })
            if let match = twin {
                match.title = item.title
                match.startsAt = item.startsAt
                match.endsAt = item.endsAt
                match.location = item.location
                match.lastSyncedAt = Date()
                if match.course == nil {
                    match.course = course
                }
                // Un type choisi à la main n'est jamais recalculé.
                if !match.kindIsManual {
                    match.kind = classify(title: item.title, location: item.location, course: match.course,
                                          start: item.startsAt, learned: learned)
                }
                result.updated += 1
                continue
            }

            let linked = LinkedCalendarEvent(
                externalEventID: item.identifier,
                sourceCalendarID: item.calendarTitle,
                title: item.title,
                startsAt: item.startsAt,
                endsAt: item.endsAt,
                location: item.location,
                kind: kind
            )
            linked.course = course
            linked.lastSyncedAt = Date()
            context.insert(linked)
            existing.append(linked)
            result.imported += 1
        }

        try? context.save()
        return result
    }

    /// Le type d'un événement du calendrier : ce que l'on sait de son créneau,
    /// sinon son intitulé et ses salles (`TimetableClassifier`).
    static func classify(title: String, location: String, course: Course?, start: Date,
                         learned: [TimetableClassifier.Slot: CalendarEventKind]) -> CalendarEventKind {
        let base = TimetableClassifier.kind(title: title, location: location, hasCourse: course != nil)
        // Une évaluation se lit dans l'intitulé : un créneau d'exercices peut
        // accueillir un midterm, qui reste un midterm.
        if base == .midterm || base == .exam { return base }
        // Un bloc personnel ou une échéance au même créneau qu'un cours reste ce
        // qu'il est : le créneau appris ne vaut que pour l'horaire.
        if TimetableClassifier.isPersonal(title) || TimetableClassifier.isDeadline(title) { return base }
        let slot = TimetableClassifier.slot(owner: TimetableClassifier.owner(courseID: course?.id, title: title), start: start)
        return learned[slot] ?? base
    }

    /// Ce que les séances au type sûr (horaire `.ics`, choix manuel) disent de
    /// chaque créneau.
    static func learnedKinds(_ events: [LinkedCalendarEvent]) -> [TimetableClassifier.Slot: CalendarEventKind] {
        TimetableClassifier.learnedKinds(events
            .filter { $0.sourceCalendarID == "ics" || $0.kindIsManual }
            .filter { [.lecture, .exerciseSession].contains($0.kind) }
            .map { event in
                TimetableClassifier.KnownSession(
                    slot: TimetableClassifier.slot(owner: TimetableClassifier.owner(courseID: event.course?.id, title: event.title),
                                                   start: event.startsAt),
                    kind: event.kind,
                    isManual: event.kindIsManual)
            })
    }

    /// Remet l'horaire d'aplomb : retire les doublons (même séance lue par
    /// l'`.ics` et par le calendrier de l'iPhone) et reclasse ce qui n'a pas de
    /// type sûr. Idempotent ; appelé au lancement.
    ///
    /// - Returns: le nombre d'événements retirés ou reclassés.
    @discardableResult
    static func repair(context: ModelContext) -> Int {
        let events = (try? context.fetch(FetchDescriptor<LinkedCalendarEvent>())) ?? []
        // Les séances importées, rangées par cours : chaque séance du calendrier
        // ne se compare qu'à celles de son cours (avant : à toutes, deux fois).
        let imported = Dictionary(grouping: events.filter { $0.sourceCalendarID == "ics" && $0.course != nil },
                                  by: { $0.course!.id })
        let learned = learnedKinds(events)
        var changes = 0
        for event in events where event.sourceCalendarID != "ics" {
            if let twin = event.course.flatMap({ imported[$0.id] })?.first(where: {
                TimetableClassifier.isSameSession(courseA: $0.course?.id, startA: $0.startsAt,
                                                  courseB: event.course?.id, startB: event.startsAt) }) {
                // Le doublon garde ce qu'on y avait noté : un amphi marqué
                // manqué le reste.
                if event.isSkipped { twin.isSkipped = true }
                if event.kindIsManual, !twin.kindIsManual { twin.kind = event.kind; twin.kindIsManual = true }
                context.delete(event)
                changes += 1
                continue
            }
            guard !event.kindIsManual, [.lecture, .exerciseSession, .other].contains(event.kind) else { continue }
            let kind = classify(title: event.title, location: event.location, course: event.course,
                                start: event.startsAt, learned: learned)
            if kind != event.kind {
                event.kind = kind
                changes += 1
            }
        }
        if changes > 0 { try? context.save() }
        return changes
    }

    /// « C'est une séance d'exercices » : le type choisi pour **tout le
    /// créneau** (même cours, même jour, même heure), semaines passées et à venir.
    ///
    /// - Returns: le nombre de séances changées.
    @discardableResult
    static func setKind(_ kind: CalendarEventKind, forSlotOf event: LinkedCalendarEvent, context: ModelContext) -> Int {
        let owner = TimetableClassifier.owner(courseID: event.course?.id, title: event.title)
        let slot = TimetableClassifier.slot(owner: owner, start: event.startsAt)
        let events = (try? context.fetch(FetchDescriptor<LinkedCalendarEvent>())) ?? []
        var count = 0
        for other in events where TimetableClassifier.slot(owner: TimetableClassifier.owner(courseID: other.course?.id, title: other.title),
                                                           start: other.startsAt) == slot {
            other.kind = kind
            other.kindIsManual = true
            count += 1
        }
        if kind == .lecture, let course = event.course, !course.hasLectures { course.hasLectures = true }
        try? context.save()
        return count
    }

    /// Un événement lié a-t-il sa place dans l'agenda ?
    static func isAcademic(_ event: LinkedCalendarEvent) -> Bool { event.isAcademic }

    /// Devine le cours d'un événement à partir de son titre (code ou nom).
    static func matchCourse(for title: String, in courses: [Course]) -> Course? {
        let haystack = title.uppercased()
        for course in courses where haystack.contains(course.code.uppercased()) {
            return course
        }
        for course in courses {
            let tokens = course.name.uppercased().split(separator: " ").filter { $0.count >= 4 }
            if !tokens.isEmpty, tokens.allSatisfy({ haystack.contains($0) }) {
                return course
            }
        }
        return nil
    }

    /// Devine le type d'événement à partir de son titre (sans lieu ni créneau).
    static func classify(title: String, course: Course?) -> CalendarEventKind {
        TimetableClassifier.kind(title: title, location: "", hasCourse: course != nil)
    }
}
