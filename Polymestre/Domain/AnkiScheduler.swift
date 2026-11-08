import Foundation

// MARK: - Les objets d'Anki, tels que la collection (schéma 11) les range

/// Une réponse à une carte : « À revoir », « Difficile », « Bien », « Facile ».
enum AnkiRating: Int, CaseIterable, Identifiable {
    case again = 1, hard, good, easy
    var id: Int { rawValue }

    var label: String {
        switch self {
        case .again: return String(localized: "À revoir")
        case .hard: return "Difficile"
        case .good: return "Bien"
        case .easy: return "Facile"
        }
    }
}

/// L'état de planification d'une carte : les colonnes de la table `cards`.
///
/// `type` : 0 nouvelle, 1 en apprentissage, 2 en révision, 3 en réapprentissage.
/// `queue` : 0 nouvelle, 1 apprentissage (échéance en secondes), 2 révision et
/// 3 apprentissage sur plusieurs jours (échéance en jours), −1 suspendue,
/// −2/−3 enterrée. `due` : position (nouvelle), instant Unix (file 1) ou
/// numéro de jour depuis la création de la collection (files 2 et 3).
struct AnkiCardState: Equatable {
    var type = 0
    var queue = 0
    var due: Int64 = 0
    var ivl = 0
    var factor = 0
    var reps = 0
    var lapses = 0
    var left = 0
    /// JSON libre ; FSRS y garde l'état de mémoire (`{"s":…,"d":…}`).
    var data = ""

    var isNew: Bool { type == 0 }
}

/// Les options du paquet (`dconf`), celles qui planifient.
struct AnkiDeckOptions: Equatable {
    /// Étapes d'apprentissage, en minutes.
    var learnSteps: [Double] = [1, 10]
    var graduatingInterval = 1
    var easyInterval = 4
    /// Facilité de départ, en pour mille (2500 = 250 %).
    var startingEase = 2500
    var relearnSteps: [Double] = [10]
    var lapseMultiplier = 0.0
    var minimumLapseInterval = 1
    var easyBonus = 1.3
    var hardMultiplier = 1.2
    var intervalModifier = 1.0
    var maximumInterval = 36_500
    var newPerDay = 20
    var reviewsPerDay = 200
    var desiredRetention = 0.9
    /// Paramètres FSRS du préréglage ; vides : les paramètres par défaut.
    var fsrsParams: [Double] = []

    init() {}

    /// Lu dans le JSON d'un `dconf` (schéma 11).
    init(json: [String: Any]) {
        func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
        let new = json["new"] as? [String: Any] ?? [:]
        let lapse = json["lapse"] as? [String: Any] ?? [:]
        let rev = json["rev"] as? [String: Any] ?? [:]
        if let steps = new["delays"] as? [NSNumber] { learnSteps = steps.map(\.doubleValue) }
        if let ints = new["ints"] as? [NSNumber] {
            if ints.count > 0 { graduatingInterval = max(1, ints[0].intValue) }
            if ints.count > 1 { easyInterval = max(1, ints[1].intValue) }
        }
        if let ease = number(new["initialFactor"]) { startingEase = Int(ease) }
        if let perDay = number(new["perDay"]) { newPerDay = Int(perDay) }
        if let steps = lapse["delays"] as? [NSNumber] { relearnSteps = steps.map(\.doubleValue) }
        if let mult = number(lapse["mult"]) { lapseMultiplier = mult }
        if let minimum = number(lapse["minInt"]) { minimumLapseInterval = max(1, Int(minimum)) }
        if let perDay = number(rev["perDay"]) { reviewsPerDay = Int(perDay) }
        if let bonus = number(rev["ease4"]) { easyBonus = bonus }
        if let modifier = number(rev["ivlFct"]), modifier > 0 { intervalModifier = modifier }
        if let maximum = number(rev["maxIvl"]) { maximumInterval = max(1, Int(maximum)) }
        if let hard = number(rev["hardFactor"]) { hardMultiplier = hard }
        if let retention = number(json["desiredRetention"]), retention > 0, retention < 1 { desiredRetention = retention }
        for key in ["fsrsParams6", "fsrsParams5", "fsrsWeights"] {
            if let params = json[key] as? [NSNumber], [17, 19, 21].contains(params.count) {
                fsrsParams = params.map(\.doubleValue)
                break
            }
        }
    }
}

/// Le jour d'Anki : il commence à l'heure de bascule (4 h par défaut), et se
/// compte depuis le jour de création de la collection.
struct AnkiClock {
    var now: Date
    var creation: Date
    var rolloverHour = 4
    var calendar = Calendar.current

    private func dayStart(containing date: Date) -> Date {
        let shifted = date.addingTimeInterval(-Double(rolloverHour) * 3600)
        return calendar.startOfDay(for: shifted).addingTimeInterval(Double(rolloverHour) * 3600)
    }

    /// Numéro du jour courant (celui des échéances de révision).
    var today: Int {
        let start = dayStart(containing: creation)
        let current = dayStart(containing: now)
        return calendar.dateComponents([.day], from: start, to: current).day ?? 0
    }

    /// Début du jour d'Anki suivant : au-delà, une étape passe en file 3.
    var nextDayStart: Date {
        calendar.date(byAdding: .day, value: 1, to: dayStart(containing: now)) ?? now.addingTimeInterval(86_400)
    }

    /// Début du jour d'Anki courant, en millisecondes (comme `revlog.id`).
    var todayStartMillis: Int64 { Int64(dayStart(containing: now).timeIntervalSince1970 * 1000) }

    var seconds: Int64 { Int64(now.timeIntervalSince1970) }
}

// MARK: - FSRS

/// FSRS (Free Spaced Repetition Scheduler), versions 4.5, 5 et 6 — celle
/// qu'Anki utilise quand FSRS est activé dans la collection.
struct FSRS {
    let w: [Double]

    static let defaults: [Double] = [0.40255, 1.18385, 3.173, 15.69105, 7.1949, 0.5345, 1.4604, 0.0046, 1.54575,
                                     0.1192, 1.01925, 1.9395, 0.11, 0.29605, 2.2698, 0.2315, 2.9898, 0.51655, 0.6621]

    init(params: [Double]) {
        w = [17, 19, 21].contains(params.count) ? params : FSRS.defaults
    }

    private var isV6: Bool { w.count >= 21 }
    var decay: Double { isV6 ? -w[20] : -0.5 }
    var factor: Double { pow(0.9, 1 / decay) - 1 }

    func retrievability(days: Double, stability: Double) -> Double {
        pow(1 + factor * days / max(stability, 0.001), decay)
    }

    /// L'intervalle (en jours) qui ramène la rétention à `retention`.
    func interval(stability: Double, retention: Double) -> Double {
        stability / factor * (pow(retention, 1 / decay) - 1)
    }

    func initialStability(_ rating: AnkiRating) -> Double { max(w[rating.rawValue - 1], 0.1) }

    func initialDifficulty(_ rating: AnkiRating) -> Double {
        clampD(w[4] - exp(w[5] * Double(rating.rawValue - 1)) + 1)
    }

    func nextDifficulty(_ d: Double, _ rating: AnkiRating) -> Double {
        let delta = -w[6] * Double(rating.rawValue - 3)
        // FSRS 5 amortit le changement près de 10 ; 4.5 non.
        let moved = w.count >= 19 ? d + delta * (10 - d) / 9 : d + delta
        return clampD(w[7] * initialDifficulty(.easy) + (1 - w[7]) * moved)
    }

    func recallStability(_ s: Double, _ d: Double, _ r: Double, _ rating: AnkiRating) -> Double {
        let hard = rating == .hard ? w[15] : 1
        let easy = rating == .easy ? w[16] : 1
        return s * (1 + exp(w[8]) * (11 - d) * pow(s, -w[9]) * (exp((1 - r) * w[10]) - 1) * hard * easy)
    }

    func forgetStability(_ s: Double, _ d: Double, _ r: Double) -> Double {
        let value = w[11] * pow(d, -w[12]) * (pow(s + 1, w[13]) - 1) * exp((1 - r) * w[14])
        return min(value, s)
    }

    /// Révision le jour même (étapes d'apprentissage) : FSRS 5 et 6.
    func shortTermStability(_ s: Double, _ rating: AnkiRating) -> Double {
        guard w.count >= 19 else { return s }
        var value = s * exp(w[17] * (Double(rating.rawValue) - 3 + w[18]))
        if isV6 {
            value *= pow(s, -w[19])
            if rating.rawValue >= 3 { value = max(value, s) }
        }
        return value
    }

    private func clampD(_ d: Double) -> Double { min(max(d, 1), 10) }
}

// MARK: - Le planificateur

/// Ce que produit une réponse : la carte replanifiée et la ligne d'historique.
struct AnkiAnswer: Equatable {
    var card: AnkiCardState
    /// `revlog` : facilité (1–4), intervalle et intervalle précédent (jours si
    /// positifs, secondes si négatifs), facilité de la carte, type (0
    /// apprentissage, 1 révision, 2 réapprentissage).
    var ease: Int
    var interval: Int
    var lastInterval: Int
    var factor: Int
    var reviewType: Int
}

/// La planification d'Anki (planificateur v3), en SM-2 classique ou en FSRS
/// selon la collection.
///
/// Fidèle à ce qu'Anki fait de chaque bouton : étapes d'apprentissage et de
/// réapprentissage, intervalle de passage et intervalle « facile », facilité
/// (−20 % sur « à revoir », −15 % sur « difficile », +15 % sur « facile »),
/// retard pris en compte, plafonds du paquet. Pas de « fuzz » (la petite
/// variation aléatoire qu'Anki ajoute aux intervalles) : une révision faite
/// ici tombe un jour pile, ce qui ne change rien à la mémorisation.
enum AnkiScheduler {

    static func answer(_ card: AnkiCardState, rating: AnkiRating, options: AnkiDeckOptions,
                       clock: AnkiClock, useFSRS: Bool) -> AnkiAnswer {
        var next = card
        next.reps += 1
        let fsrs = useFSRS ? FSRS(params: options.fsrsParams) : nil
        let lastInterval = currentInterval(card, options: options, clock: clock)
        let reviewType: Int
        switch card.type {
        case 2:
            reviewType = 1
            review(&next, from: card, rating: rating, options: options, clock: clock, fsrs: fsrs)
        case 3:
            reviewType = 2
            learn(&next, from: card, steps: options.relearnSteps, relearning: true, rating: rating,
                  options: options, clock: clock, fsrs: fsrs)
        default:
            reviewType = 0
            learn(&next, from: card, steps: options.learnSteps, relearning: false, rating: rating,
                  options: options, clock: clock, fsrs: fsrs)
        }
        return AnkiAnswer(card: next, ease: rating.rawValue,
                          interval: currentInterval(next, options: options, clock: clock),
                          lastInterval: lastInterval, factor: next.factor, reviewType: reviewType)
    }

    /// « 1 min », « 10 min », « 3 j » : ce que chaque bouton planifierait.
    static func previews(_ card: AnkiCardState, options: AnkiDeckOptions, clock: AnkiClock,
                         useFSRS: Bool) -> [AnkiRating: String] {
        var result: [AnkiRating: String] = [:]
        for rating in AnkiRating.allCases {
            let next = answer(card, rating: rating, options: options, clock: clock, useFSRS: useFSRS).card
            result[rating] = label(for: next, clock: clock)
        }
        return result
    }

    static func label(for card: AnkiCardState, clock: AnkiClock) -> String {
        if card.queue == 1 {
            let seconds = max(0, Double(card.due - clock.seconds))
            if seconds < 3600 { return "\(max(1, Int((seconds / 60).rounded()))) min" }
            return "\(Int((seconds / 3600).rounded())) h"
        }
        let days = max(1, Int(card.due) - clock.today)
        return dayLabel(days)
    }

    static func dayLabel(_ days: Int) -> String {
        if days < 31 { return "\(days) j" }
        if days < 365 { return String(format: "%.1f mois", Double(days) / 30.4).replacingOccurrences(of: ".", with: ",") }
        return String(format: "%.1f an", Double(days) / 365).replacingOccurrences(of: ".", with: ",")
    }

    // MARK: Apprentissage

    private static func learn(_ card: inout AnkiCardState, from previous: AnkiCardState, steps: [Double],
                              relearning: Bool, rating: AnkiRating, options: AnkiDeckOptions,
                              clock: AnkiClock, fsrs: FSRS?) {
        if fsrs != nil { updateMemory(&card, from: previous, rating: rating, clock: clock, fsrs: fsrs!) }
        if previous.type == 0 {
            card.type = 1
            card.left = steps.count
            if card.factor == 0 { card.factor = options.startingEase }
        }
        guard !steps.isEmpty else {
            graduate(&card, easy: rating == .easy, relearning: relearning, options: options, clock: clock, fsrs: fsrs)
            return
        }
        var remaining = card.left % 1000
        if remaining <= 0 || remaining > steps.count { remaining = steps.count }
        let index = min(max(steps.count - remaining, 0), steps.count - 1)
        switch rating {
        case .again:
            card.left = steps.count
            schedule(&card, minutes: steps[0], clock: clock)
        case .hard:
            let delay: Double
            if index == 0 {
                delay = steps.count > 1 ? (steps[0] + steps[1]) / 2 : min(steps[0] * 1.5, steps[0] + 1440)
            } else {
                delay = steps[index]
            }
            card.left = remaining
            schedule(&card, minutes: delay, clock: clock)
        case .good:
            remaining -= 1
            if remaining <= 0 {
                graduate(&card, easy: false, relearning: relearning, options: options, clock: clock, fsrs: fsrs)
            } else {
                card.left = remaining
                schedule(&card, minutes: steps[steps.count - remaining], clock: clock)
            }
        case .easy:
            graduate(&card, easy: true, relearning: relearning, options: options, clock: clock, fsrs: fsrs)
        }
    }

    /// Une étape : dans la journée, file 1 (en secondes) ; au-delà, file 3 (en jours).
    private static func schedule(_ card: inout AnkiCardState, minutes: Double, clock: AnkiClock) {
        let seconds = Int64((minutes * 60).rounded())
        let due = clock.seconds + seconds
        if Date(timeIntervalSince1970: TimeInterval(due)) < clock.nextDayStart {
            card.queue = 1
            card.due = due
        } else {
            card.queue = 3
            card.due = Int64(clock.today + max(1, Int((minutes / 1440).rounded())))
        }
    }

    private static func graduate(_ card: inout AnkiCardState, easy: Bool, relearning: Bool,
                                 options: AnkiDeckOptions, clock: AnkiClock, fsrs: FSRS?) {
        var interval: Int
        if let fsrs, let memory = memory(of: card) {
            interval = fsrsInterval(memory.s, options: options, fsrs: fsrs)
            if easy { interval = max(interval, relearning ? card.ivl + 1 : options.easyInterval) }
        } else if relearning {
            interval = easy ? card.ivl + 1 : max(card.ivl, 1)
        } else {
            interval = easy ? options.easyInterval : options.graduatingInterval
        }
        interval = min(max(interval, 1), options.maximumInterval)
        card.type = 2
        card.queue = 2
        card.ivl = interval
        card.due = Int64(clock.today + interval)
        card.left = 0
        if card.factor == 0 { card.factor = options.startingEase }
    }

    // MARK: Révision

    private static func review(_ card: inout AnkiCardState, from previous: AnkiCardState, rating: AnkiRating,
                               options: AnkiDeckOptions, clock: AnkiClock, fsrs: FSRS?) {
        let today = clock.today
        let daysLate = max(0, today - Int(previous.due))
        let ivl = max(previous.ivl, 1)
        if let fsrs { updateMemory(&card, from: previous, rating: rating, clock: clock, fsrs: fsrs) }

        if rating == .again {
            card.lapses += 1
            card.factor = max(1300, previous.factor - 200)
            var lapsed = max(options.minimumLapseInterval, Int((Double(ivl) * options.lapseMultiplier).rounded()))
            if fsrs != nil, let memory = memory(of: card) {
                lapsed = max(options.minimumLapseInterval, min(fsrsInterval(memory.s, options: options, fsrs: fsrs!), ivl))
            }
            card.ivl = min(lapsed, options.maximumInterval)
            if options.relearnSteps.isEmpty {
                card.queue = 2
                card.due = Int64(today + card.ivl)
            } else {
                card.type = 3
                card.left = options.relearnSteps.count
                schedule(&card, minutes: options.relearnSteps[0], clock: clock)
            }
            return
        }

        var interval: Int
        if let fsrs, let memory = memory(of: card) {
            let base = fsrsInterval(memory.s, options: options, fsrs: fsrs)
            // L'ordre des boutons est garanti : difficile < bien < facile.
            let hardIvl = fsrsIntervalFor(previous, .hard, options: options, clock: clock, fsrs: fsrs)
            let goodIvl = max(hardIvl + 1, fsrsIntervalFor(previous, .good, options: options, clock: clock, fsrs: fsrs))
            switch rating {
            case .hard: interval = hardIvl
            case .good: interval = goodIvl
            default: interval = max(goodIvl + 1, base)
            }
        } else {
            let modifier = options.intervalModifier
            let hardIvl = constrained(Double(ivl) * options.hardMultiplier * modifier,
                                      minimum: options.hardMultiplier > 1 ? ivl + 1 : ivl, options: options)
            let goodIvl = constrained((Double(ivl) + Double(daysLate) / 2) * Double(previous.factor) / 1000 * modifier,
                                      minimum: hardIvl + 1, options: options)
            switch rating {
            case .hard:
                card.factor = max(1300, previous.factor - 150)
                interval = hardIvl
            case .good:
                interval = goodIvl
            default:
                card.factor = previous.factor + 150
                interval = constrained((Double(ivl) + Double(daysLate)) * Double(previous.factor) / 1000 * options.easyBonus * modifier,
                                       minimum: goodIvl + 1, options: options)
            }
        }
        interval = min(max(interval, 1), options.maximumInterval)
        card.ivl = interval
        card.due = Int64(today + interval)
        card.queue = 2
        card.type = 2
    }

    private static func constrained(_ value: Double, minimum: Int, options: AnkiDeckOptions) -> Int {
        min(max(Int(value.rounded()), minimum, 1), options.maximumInterval)
    }

    /// L'intervalle qu'un bouton donnerait, en FSRS (pour ordonner les boutons).
    private static func fsrsIntervalFor(_ card: AnkiCardState, _ rating: AnkiRating, options: AnkiDeckOptions,
                                        clock: AnkiClock, fsrs: FSRS) -> Int {
        var copy = card
        updateMemory(&copy, from: card, rating: rating, clock: clock, fsrs: fsrs)
        return memory(of: copy).map { fsrsInterval($0.s, options: options, fsrs: fsrs) } ?? max(card.ivl, 1)
    }

    private static func fsrsInterval(_ stability: Double, options: AnkiDeckOptions, fsrs: FSRS) -> Int {
        let days = fsrs.interval(stability: stability, retention: options.desiredRetention) * options.intervalModifier
        return min(max(Int(days.rounded()), 1), options.maximumInterval)
    }

    // MARK: Mémoire FSRS

    static func memory(of card: AnkiCardState) -> (s: Double, d: Double)? {
        guard let data = card.data.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = (json["s"] as? NSNumber)?.doubleValue, let d = (json["d"] as? NSNumber)?.doubleValue,
              s > 0 else { return nil }
        return (s, d)
    }

    private static func updateMemory(_ card: inout AnkiCardState, from previous: AnkiCardState, rating: AnkiRating,
                                     clock: AnkiClock, fsrs: FSRS) {
        let s: Double, d: Double
        if let memory = memory(of: previous) {
            // Jours depuis la dernière révision : nul pendant les étapes.
            let elapsed: Double = previous.type == 2 ? Double(max(0, clock.today - (Int(previous.due) - previous.ivl))) : 0
            if elapsed < 1 {
                s = fsrs.shortTermStability(memory.s, rating)
            } else {
                let r = fsrs.retrievability(days: elapsed, stability: memory.s)
                s = rating == .again ? fsrs.forgetStability(memory.s, memory.d, r)
                                     : fsrs.recallStability(memory.s, memory.d, r, rating)
            }
            d = fsrs.nextDifficulty(memory.d, rating)
        } else if previous.type == 0 {
            s = fsrs.initialStability(rating)
            d = fsrs.initialDifficulty(rating)
        } else {
            // Une carte révisée avant FSRS, sans état : on part de son intervalle.
            s = Double(max(previous.ivl, 1))
            d = fsrs.nextDifficulty(5, rating)
        }
        var json = (previous.data.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        json["s"] = (max(s, 0.001) * 10_000).rounded() / 10_000
        json["d"] = (d * 1000).rounded() / 1000
        card.data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? previous.data
    }

    /// Intervalle courant pour l'historique : jours, ou −secondes en apprentissage.
    private static func currentInterval(_ card: AnkiCardState, options: AnkiDeckOptions, clock: AnkiClock) -> Int {
        switch card.queue {
        case 1: return -Int(max(0, card.due - clock.seconds))
        case 3: return -Int(max(0, Int(card.due) - clock.today)) * 86_400
        case 0: return 0
        default: return card.ivl
        }
    }
}
