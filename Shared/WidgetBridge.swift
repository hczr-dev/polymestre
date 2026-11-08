import Foundation

/// Instantané de l'état Polymestre, partagé entre l'app et l'extension widget
/// via le conteneur de groupe d'app (`PolymestreAppGroup`, voir `WidgetBridge`).
///
/// Ce fichier est compilé dans **les deux cibles** : il ne dépend donc que de
/// Foundation, et sert de contrat unique entre l'app et le widget.
struct WidgetSnapshot: Codable, Equatable {
    var updatedAt: Date
    /// Avancement de la semaine, cours par cours.
    var courses: [WidgetCourse]? = nil
    /// Chrono en cours, pour l'écran verrouillé.
    var timer: WidgetTimer? = nil
    /// Le temps de la semaine (lundi → dimanche) et l'attendu EPFL.
    var week: WidgetWeek? = nil
    /// Ce qui a une heure aujourd'hui **et demain** : le widget passe au
    /// lendemain à minuit sans attendre l'app.
    var schedule: [WidgetEvent]? = nil
    /// Les prochaines évaluations (trois au plus).
    var deadlines: [WidgetDeadline]? = nil
}

extension WidgetSnapshot {
    /// Les instants où ce que montre un widget change de lui-même : la fin
    /// d'un cours ou son début, une échéance, la fin d'une pause, minuit — et
    /// un quart d'heure sur deux heures tant que le chrono tourne (les heures
    /// du jour avancent). Le système affiche ces entrées **sans réveiller
    /// l'extension** : plus juste qu'un rafraîchissement toutes les 30 min, et
    /// moins coûteux.
    func timelineDates(from now: Date, calendar: Calendar = .current) -> (dates: [Date], reloadAfter: Date) {
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            ?? now.addingTimeInterval(86_400)
        var dates: [Date] = [midnight]
        for event in schedule ?? [] {
            dates.append(event.start)
            if let end = event.end { dates.append(end) }
        }
        dates += (deadlines ?? []).map(\.date)
        dates += (courses ?? []).flatMap { ($0.lateChanges ?? []).map(\.from) }
        if let breakEnd = timer?.breakEndsAt { dates.append(breakEnd) }
        if timer?.isRunning == true {
            dates += (1...8).map { now.addingTimeInterval(Double($0) * 900) }
        }
        let upcoming = Set(dates.filter { $0 > now && $0 <= midnight }).sorted()
        return ([now] + upcoming, midnight)
    }

    /// L'instantané tel qu'il se lit à `date` : le retard de chaque cours est
    /// celui de ce moment-là (`WidgetCourse.lateChanges`).
    func resolved(at date: Date) -> WidgetSnapshot {
        var copy = self
        copy.courses = courses?.map { course in
            var course = course
            course.late = course.late(at: date)
            return course
        }
        return copy
    }
}

struct WidgetCourse: Codable, Equatable, Identifiable {
    var id: String
    var code: String
    var colorHex: String
    var done: Int
    var total: Int
    /// « reste 2 théorie · 1 exo », « à jour », « rien de prévu ».
    var summary: String
    var name: String? = nil
    var theoryDone: Int? = nil
    var theoryTotal: Int? = nil
    var exercisesDone: Int? = nil
    var exercisesTotal: Int? = nil
    /// Éléments des semaines passées pas faits.
    var late: Int? = nil
    /// Ce que devient `late` aux prochains instants où il change de lui-même
    /// (un lundi, une échéance, un corrigé publié, une reprise due) : le widget
    /// passe au bon chiffre sans attendre que l'app tourne. Facultatif : un
    /// instantané d'une version précédente se relit.
    var lateChanges: [WidgetCount]? = nil

    /// Le retard à `date`.
    func late(at date: Date) -> Int? {
        (lateChanges ?? []).last { $0.from <= date }?.value ?? late
    }
}

/// Une valeur à partir d'un instant.
struct WidgetCount: Codable, Equatable {
    var from: Date
    var value: Int
}

struct WidgetWeek: Codable, Equatable {
    var weekStart: Date
    /// Numéro de la semaine du semestre, s'il est en cours.
    var number: Int?
    var totalWeeks: Int?
    /// Réel (sessions + cours suivis) et attendu (cadré + personnel).
    var actualSeconds: Int
    var expectedSeconds: Int
    /// Secondes d'étude, du lundi au dimanche.
    var days: [Int]
}

struct WidgetEvent: Codable, Equatable, Identifiable {
    var id: String
    var start: Date
    var end: Date?
    var title: String
    var subtitle: String
    var colorHex: String
}

struct WidgetDeadline: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var courseCode: String
    var date: Date
    var colorHex: String
}

struct WidgetTimer: Codable, Equatable {
    var label: String
    var colorHex: String
    /// Début équivalent : `Text(timerInterval:)` compte depuis cet instant, le
    /// temps déjà accumulé inclus.
    var effectiveStart: Date
    var isRunning: Bool
    var elapsedWhenPaused: TimeInterval
    /// Fin de la pause Pomodoro en cours, s'il y en a une. Facultatif : un
    /// instantané écrit par une version précédente se relit.
    var breakEndsAt: Date? = nil
    /// « Pause », « Pause longue ».
    var breakLabel: String? = nil
}

/// Lecture / écriture de l'instantané dans le conteneur partagé.
enum WidgetBridge {
    /// Identifiant du groupe d'app.
    ///
    /// Défini **une seule fois** dans le projet (`POLYMESTRE_APP_GROUP`), puis
    /// injecté dans l'Info.plist des deux cibles et dans leurs entitlements.
    /// Le lire ici évite qu'une valeur codée en dur ne diverge de la configuration.
    static let appGroupID: String = {
        #if os(macOS)
        // Groupe préfixé par l'équipe : pas de profil à part sur macOS.
        return "5GGDH5F3NG.ch.polymestre"
        #else
        if let value = Bundle.main.object(forInfoDictionaryKey: "PolymestreAppGroup") as? String,
           !value.isEmpty {
            return value
        }
        return "group.ch.polymestre.app"
        #endif
    }()

    static let fileName = "widget-snapshot.json"

    /// `nil` si l'app n'a pas l'entitlement App Group (par exemple avant signature).
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    static var fileURL: URL? {
        containerURL?.appendingPathComponent(fileName)
    }

    static func write(_ snapshot: WidgetSnapshot) {
        guard let url = fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func read() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }
}

/// Formats partagés entre l'app et le widget.
///
/// Le widget ne peut pas importer `DateUtils` : ces fonctions sont pures et
/// compilées dans les deux cibles, et vérifiées par `validate.sh`.
enum WidgetFormat {
    /// « 12 », « 1,5 » : des heures, sans unité, pour un anneau.
    static func shortHours(_ seconds: Int) -> String {
        let hours = Double(max(0, seconds)) / 3600
        if hours >= 10 || hours == hours.rounded() { return String(Int(hours.rounded())) }
        return String(format: "%.1f", hours).replacingOccurrences(of: ".", with: ",")
    }

    /// « 45 min », « 2 h », « 1,6 h » — dixièmes d'heure **arrondis**.
    ///
    /// La version précédente écrivait `minutes / 10` : 1 h 35 donnait « 1,3 h »,
    /// soit dix-sept minutes de moins que la réalité.
    static func hours(_ seconds: Int) -> String {
        let totalMinutes = max(0, seconds) / 60
        if totalMinutes < 60 { return "\(totalMinutes) min" }
        let tenths = Int((Double(totalMinutes) / 60 * 10).rounded())
        let hours = tenths / 10
        let fraction = tenths % 10
        return fraction == 0 ? "\(hours) h" : "\(hours),\(fraction) h"
    }

    /// « J-12 », « Demain », « Aujourd'hui ».
    static func countdown(to date: Date, from reference: Date = Date()) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day],
                                           from: calendar.startOfDay(for: reference),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        if days <= 0 { return String(localized: "Aujourd'hui") }
        if days == 1 { return String(localized: "Demain") }
        return "J-\(days)"
    }
}

/// Liens profonds ouverts par les widgets. Le schéma est celui de l'app.
enum WidgetLink {
    static let focus = URL(string: "polymestre://focus")!
    static let today = URL(string: "polymestre://today")!
    static let courses = URL(string: "polymestre://courses")!
    static let agenda = URL(string: "polymestre://agenda")!

    /// Ouvre un cours : `polymestre://course?id=…`.
    static func course(_ id: String) -> URL {
        URL(string: "polymestre://course?id=\(id)") ?? courses
    }
}
