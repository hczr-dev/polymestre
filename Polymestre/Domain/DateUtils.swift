import Foundation

/// Utilitaires de dates, semaines et formats.
enum DateUtils {

    // MARK: Formatters

    static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Europe/Zurich")
        return f
    }()

    static let shortDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = appLocale
        f.dateFormat = "EEE d MMM"
        return f
    }()

    static let fullDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = appLocale
        f.dateFormat = "EEEE d MMMM"
        return f
    }()

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = appLocale
        f.dateFormat = "HH:mm"
        return f
    }()

    // MARK: Parsing

    /// Parse « 2025-02-17 », « 2025-02-17T08:00:00Z » ou avec fraction de seconde.
    static func parse(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        if let d = iso8601.date(from: value) { return d }
        if let d = iso8601Fractional.date(from: value) { return d }
        if let d = dateOnly.date(from: value) { return d }
        return nil
    }

    // MARK: Semaines

    static func startOfDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    /// Lundi de la semaine de `date`.
    static func startOfWeek(_ date: Date) -> Date {
        var cal = Calendar(identifier: .iso8601)
        cal.firstWeekday = 2 // lundi
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return cal.date(from: comps).map { cal.startOfDay(for: $0) } ?? startOfDay(date)
    }

    /// Numéro de semaine (1-based) d'une date relative au début du semestre.
    /// Début du semestre d'**automne** : le premier lundi dès le 7 septembre.
    ///
    /// L'EPFL fait commencer le semestre d'automne à cette date **pour tout le
    /// monde**. Le demander à l'onboarding était une erreur : la réponse est
    /// connue, et une valeur par défaut approximative décalait tout le suivi
    /// hebdomadaire. Le semestre de printemps, lui, varie et reste une question.
    static func autumnStart(forYear year: Int) -> Date {
        // La date **publiée** par l'EPFL prime sur la règle. Les deux concordent
        // (7 septembre 2026), mais si l'école décale une rentrée, l'app suit sans
        // qu'on touche au code.
        if let official = EPFLCalendarSnapshot.autumnTeachingStart(year: year) {
            return official
        }
        let calendar = Calendar.current
        var components = DateComponents()
        components.year = year
        components.month = 9
        components.day = 7
        guard let seventh = calendar.date(from: components) else { return Date() }
        // `weekday: 2` = lundi dans le calendrier grégorien (1 = dimanche).
        let dayBefore = calendar.date(byAdding: .day, value: -1, to: seventh) ?? seventh
        return calendar.nextDate(after: dayBefore,
                                 matching: DateComponents(weekday: 2),
                                 matchingPolicy: .nextTime) ?? seventh
    }

    /// Début du semestre en cours, déduit du mois : septembre à janvier = automne.
    ///
    /// La saison est renvoyée avec la date : la recalculer à l'appel, c'est se
    /// donner l'occasion de se tromper d'un mois au passage du nouvel an.
    static func currentAutumnOrSpringStart(reference: Date = Date())
        -> (start: Date, weeks: Int, season: TermSeason) {
        let calendar = Calendar.current
        let month = calendar.component(.month, from: reference)
        let year = calendar.component(.year, from: reference)
        let isAutumn = month >= 8 || month <= 1
        return isAutumn
            ? (autumnStart(forYear: year), 14, .autumn)
            : (calendar.date(from: DateComponents(year: year, month: 2, day: 17)) ?? reference, 14, .spring)
    }

    static func weekNumber(for date: Date, term: AcademicTerm) -> Int {
        weekNumber(from: term.startDate, to: date)
    }

    /// Numéro de semaine (1-based) depuis un lundi de semaine 1.
    ///
    /// Extrait pour être utilisable **sans** `AcademicTerm` : un cours dont le
    /// semestre n'est pas renseigné ne doit pas se rabattre sur « semaine 1 », qui
    /// est une réponse fausse — et silencieuse.
    ///
    /// Les semaines **sans cours** ne comptent pas : l'EPFL interrompt les
    /// enseignements une semaine en automne (19–23 octobre 2026) et à Pâques.
    /// Compter les jours depuis la rentrée donnait « semaine 8 » le lundi de la
    /// reprise, au lieu de 7 — et tout ce qui est rangé par semaine (séries,
    /// théorie, progression, sections Moodle datées) glissait d'un cran jusqu'à
    /// la fin du semestre. Pendant la pause, c'est la dernière semaine de cours.
    static func weekNumber(from start: Date, to date: Date = Date()) -> Int {
        let cal = Calendar.current
        let days = cal.dateComponents([.day],
                                      from: cal.startOfDay(for: start),
                                      to: cal.startOfDay(for: date)).day ?? 0
        let raw = days / 7 + 1
        return max(1, raw - breakWeeks(from: start, to: date))
    }

    /// Une interruption des enseignements : du lundi qui suit la fin des cours
    /// au lundi de la reprise.
    struct TeachingBreak: Equatable {
        var start: Date
        var end: Date
        var weeks: Int { max(0, (DateUtils.daysBetween(start, end) + 6) / 7) }
    }

    /// Les pauses du calendrier EPFL embarqué : chaque « Interruption des
    /// enseignements » jusqu'à la « Reprise des enseignements » suivante.
    static let teachingBreaks: [TeachingBreak] = {
        let cal = Calendar.current
        let entries = EPFLCalendarSnapshot.entries
            .filter { $0.kind == .break }
            .compactMap { entry -> (Date, String)? in
                cal.date(from: DateComponents(year: entry.year, month: entry.month, day: entry.day)).map { ($0, entry.title.lowercased()) }
            }
            .sorted { $0.0 < $1.0 }
        var result: [TeachingBreak] = []
        var pending: Date?
        for (date, title) in entries {
            if title.contains("interruption") {
                pending = date
            } else if title.contains("reprise"), let stop = pending {
                // Les cours s'arrêtent en fin de journée : la pause commence le
                // lundi suivant.
                let monday = startOfWeek(addDays(3, to: stop))
                if monday < date { result.append(TeachingBreak(start: monday, end: startOfWeek(date))) }
                pending = nil
            }
        }
        return result
    }()

    /// Semaines de pause écoulées entre la rentrée et `date`.
    static func breakWeeks(from start: Date, to date: Date, breaks: [TeachingBreak] = teachingBreaks) -> Int {
        let day = startOfDay(date)
        return breaks.reduce(0) { total, pause in
            guard pause.start >= startOfDay(start), pause.start <= day else { return total }
            if day >= pause.end { return total + pause.weeks }
            // En pleine pause : les semaines de pause déjà entamées.
            return total + daysBetween(pause.start, day) / 7 + 1
        }
    }

    /// `weeks` semaines **de cours** après `start` : la fin d'un semestre de
    /// quatorze semaines tombe une semaine plus tard s'il contient une pause.
    static func addTeachingWeeks(_ weeks: Int, to start: Date) -> Date {
        var end = addWeeks(weeks, to: start)
        for pause in teachingBreaks where pause.start >= startOfDay(start) && pause.start < end {
            end = addWeeks(pause.weeks, to: end)
        }
        return end
    }

    /// Numéro de semaine borné à la durée du semestre.
    ///
    /// Indispensable pour un semestre importé dont la date de début est ancienne :
    /// sans borne, on obtiendrait « semaine 47 » et tous les écrans hebdomadaires
    /// seraient vides.
    static func clampedWeek(for date: Date, term: AcademicTerm) -> Int {
        let raw = weekNumber(for: date, term: term)
        return min(max(raw, 1), max(term.totalWeeks, 1))
    }

    static func daysBetween(_ from: Date, _ to: Date) -> Int {        Calendar.current.dateComponents([.day],
                                        from: Calendar.current.startOfDay(for: from),
                                        to: Calendar.current.startOfDay(for: to)).day ?? 0
    }

    static func addDays(_ days: Int, to date: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: date) ?? date
    }

    static func addWeeks(_ weeks: Int, to date: Date) -> Date {
        Calendar.current.date(byAdding: .weekOfYear, value: weeks, to: date) ?? date
    }

    static func dateRange(days: Int, endingAt date: Date = Date()) -> (start: Date, end: Date) {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay(date)) ?? date
        let start = startOfDay(addDays(-(days - 1), to: date))
        return (start, end)
    }

    // MARK: Formats

    /// « 45 min », « 1 h 30 », « 3 h ».
    static func durationLabel(seconds: Int) -> String {
        let totalMinutes = max(0, seconds) / 60
        if totalMinutes < 60 { return "\(totalMinutes) min" }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "\(hours) h" : "\(hours) h \(String(format: "%02d", minutes))"
    }

    /// « 2,5 h » (1 décimale, virgule suisse).
    /// La langue de l'interface (français par défaut, anglais si l'app l'est),
    /// avec les formats suisses : les dates et les heures suivent les textes.
    static let appLocale: Locale = {
        // Sans traductions embarquées (la validation), le français de toujours.
        let language = Bundle.main.localizations.count > 1 ? (Bundle.main.preferredLocalizations.first ?? "fr") : "fr"
        return Locale(identifier: language.hasPrefix("en") ? "en_CH" : "fr_CH")
    }()

    static var usesDecimalComma: Bool { appLocale.language.languageCode?.identifier != "en" }

    static func hoursLabel(seconds: Int) -> String {
        let hours = Double(seconds) / 3600
        // « 2 h » plutôt que « 2.0 h » : la décimale seulement quand elle dit quelque chose.
        var raw = String(format: "%.1f", hours)
        if raw.hasSuffix(".0") { raw.removeLast(2) }
        let formatted = raw.replacingOccurrences(of: ".", with: usesDecimalComma ? "," : ".")
        return "\(formatted) h"
    }

    static func hoursLabel(hours: Double) -> String {
        hoursLabel(seconds: Int(hours * 3600))
    }

    /// « Lundi 19 octobre » — seule l'initiale en capitale. `.capitalized` mettait
    /// une majuscule à chaque mot (« Lundi 19 Octobre »), ce qui n'est pas du français.
    static func fullDayLabel(_ date: Date) -> String {
        let raw = fullDay.string(from: date)
        guard let first = raw.first else { return raw }
        return first.uppercased() + raw.dropFirst()
    }

    static func relativeLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return String(localized: "Aujourd'hui") }
        if cal.isDateInTomorrow(date) { return String(localized: "Demain") }
        if cal.isDateInYesterday(date) { return String(localized: "Hier") }
        let days = daysBetween(Date(), date)
        if days > 0 && days < 7 { return String(localized: "Dans \(days) j") }
        if days < 0 && days > -7 { return String(localized: "Il y a \(-days) j") }
        return shortDay.string(from: date)
    }

    /// « J-12 », « Aujourd'hui », « Passé ».
    static func countdownLabel(to date: Date) -> String {
        let days = daysBetween(Date(), date)
        if days == 0 { return String(localized: "Aujourd'hui") }
        if days == 1 { return String(localized: "Demain") }
        if days > 1 { return String(localized: "J-\(days)") }
        return String(localized: "Passé")
    }

    /// Numéro du mois (1 = janvier). Sert à décider de la saison d'un semestre.
    static func monthNumber(_ date: Date) -> Int {
        Calendar.current.component(.month, from: date)
    }

    static func weekdayInitial(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = appLocale
        f.dateFormat = "EEEEE"
        return f.string(from: date).uppercased()
    }
}

extension String {
    /// « lundi 28 septembre » → « Lundi 28 septembre » : seule l'initiale. En
    /// français, `capitalized` écrirait « Lundi 28 Septembre ».
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
