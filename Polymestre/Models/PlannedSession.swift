import Foundation
import SwiftData

/// Session d'étude planifiée (personnelle ou partagée avec un groupe).
@Model
final class PlannedSession {
    var id: UUID = UUID()
    var course: Course?
    /// Identifiant distant du groupe (Supabase) — `nil` = session personnelle.
    var groupRemoteID: String?
    var groupName: String = ""
    var title: String = ""
    var startsAt: Date = Date.now
    var durationMinutes: Int = 0
    var location: String = ""
    var createdByUserID: String = ""
    var goingCount: Int = 0
    var maybeCount: Int = 0
    var myRSVP: String = ""
    var externalCalendarEventID: String = ""

    init(id: UUID = UUID(),
         course: Course? = nil,
         groupRemoteID: String? = nil,
         groupName: String = "",
         title: String = "",
         startsAt: Date = Date(),
         durationMinutes: Int = 90,
         location: String = "",
         createdByUserID: String = "",
         goingCount: Int = 0,
         maybeCount: Int = 0,
         myRSVP: String = "going") {
        self.id = id
        self.course = course
        self.groupRemoteID = groupRemoteID
        self.groupName = groupName
        self.title = title.isEmpty ? String(localized: "Session d'étude") : title
        self.startsAt = startsAt
        self.durationMinutes = durationMinutes
        self.location = location
        self.createdByUserID = createdByUserID
        self.goingCount = goingCount
        self.maybeCount = maybeCount
        self.myRSVP = myRSVP
        self.externalCalendarEventID = ""
    }

    var isGroupSession: Bool { groupRemoteID != nil }
    var endsAt: Date { startsAt.addingTimeInterval(TimeInterval(durationMinutes * 60)) }
    var isToday: Bool { Calendar.current.isDateInToday(startsAt) }
    var isPast: Bool { endsAt < Date() }
    var durationLabel: String { DateUtils.durationLabel(seconds: durationMinutes * 60) }

    var rsvp: RSVPStatus {
        get { RSVPStatus(rawValue: myRSVP) ?? .going }
        set { myRSVP = newValue.rawValue }
    }
}

enum RSVPStatus: String, Codable, CaseIterable, Identifiable {
    case going, maybe, declined
    var id: String { rawValue }
    var label: String {
        switch self {
        case .going: return String(localized: "Je participe")
        case .maybe: return String(localized: "Peut-être")
        case .declined: return String(localized: "Je ne peux pas")
        }
    }
    var icon: String {
        switch self {
        case .going: return "checkmark.circle.fill"
        case .maybe: return "questionmark.circle.fill"
        case .declined: return "xmark.circle.fill"
        }
    }
}
