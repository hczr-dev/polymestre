import Foundation

/// Ce qui distingue une série d'une autre dans un même cours : son **numéro**
/// et, quand le cours en publie deux par semaine, son **étiquette**.
///
/// Certains cours publient deux séries par semaine, nommées de toutes les
/// manières : « Série 5a » et « Série 5b », « Série 5.1 » et « 5.2 »,
/// « Exercices du mardi » et « Exercices du jeudi », « Série 5 — partie 2 ».
/// Réduites à leur seul numéro, elles fusionnaient en une seule série (et le
/// prompt de lecture écrivait même « Série 02a → 2 »).
///
/// Une série **sans numéro** prend celui de la semaine où elle est posée sur
/// Moodle ; l'étiquette (le jour, la lettre, la partie) départage alors deux
/// séries de la même semaine. Une étiquette vide est le cas de toutes les
/// séries d'avant : rien ne change pour elles.
enum SeriesIdentity {

    struct Key: Hashable, Comparable {
        var number: Int
        var label: String

        init(_ number: Int, _ label: String = "") {
            self.number = number
            self.label = SeriesIdentity.normalized(label)
        }

        static func < (lhs: Key, rhs: Key) -> Bool {
            if lhs.number != rhs.number { return lhs.number < rhs.number }
            return SeriesIdentity.labelPrecedes(lhs.label, rhs.label)
        }
    }

    /// Les jours, dans l'ordre de la semaine, sous leur forme française.
    static let days = ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"]
    private static let dayAliases: [String: String] = [
        "monday": "lundi", "tuesday": "mardi", "wednesday": "mercredi", "thursday": "jeudi",
        "friday": "vendredi", "saturday": "samedi",
        "lundi": "lundi", "mardi": "mardi", "mercredi": "mercredi", "jeudi": "jeudi",
        "vendredi": "vendredi", "samedi": "samedi",
    ]

    static func normalized(_ label: String) -> String {
        label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Les jours dans l'ordre de la semaine, les lettres et les numéros dans
    /// l'ordre naturel ; la série sans étiquette d'abord.
    static func labelPrecedes(_ a: String, _ b: String) -> Bool {
        if a == b { return false }
        if a.isEmpty { return true }
        if b.isEmpty { return false }
        let da = days.firstIndex(of: a), db = days.firstIndex(of: b)
        if let da, let db { return da < db }
        if da != nil { return false }
        if db != nil { return true }
        return a.localizedStandardCompare(b) == .orderedAscending
    }

    /// « Série 5b » · « Série 5.2 » · « Série 5 · mardi » · « Série 5 · partie 2 ».
    static func displayName(number: Int, label: String) -> String {
        // Traduit (« Series 5 ») : le même texte que l'app affichait déjà.
        String(localized: "Série \(number)") + suffix(label)
    }

    /// Ce qui suit le numéro : collé pour une lettre (« 5b »), après un point
    /// pour un chiffre (« 5.2 »), après « · » pour un mot (« 5 · mardi »).
    static func suffix(_ label: String) -> String {
        let label = normalized(label)
        if label.isEmpty { return "" }
        if label.count == 1, label.first!.isLetter { return label }
        if label.allSatisfy(\.isNumber) { return "." + label }
        return " · " + label
    }

    // MARK: Lecture d'un nom

    /// L'étiquette qu'un **nom de série** porte à côté (ou à la place) de son
    /// numéro, ou `""`.
    ///
    ///   « Série 5a », « Serie_05-B », « Série 5 (b) »      → « a », « b », « b »
    ///   « Série 5.2 » (un nom de série, pas un exercice)   → « 2 »
    ///   « Série 5, partie 2 », « Part II »                → « partie 2 »
    ///   « Exercices du mardi », « Exercises (Thursday) »   → « mardi », « jeudi »
    ///   « Série A », « Exercices B »                       → « a », « b »
    ///
    /// Le jour d'une **échéance** (« à rendre avant mardi ») n'en est pas une.
    static func label(in name: String) -> String {
        let text = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "_", with: " ")
        let lead = #"(?:series?|problem ?sets?|exercise sets?|feuilles?|td|tp|homework|exercices?|exercises?|exos?)"#

        // « Série 5a », « Série 05-B », « Série 5 (b) », « Série 5.2 », « Série 5/2 ».
        if let value = firstGroup(text, lead + #"\s*[-#.:]?\s*(?:n[o°]\s*)?0*\d{1,2}(?:\s*[-.(]\s*)?([a-f])\b(?!['’])(?!\s*(?:rendre|remettre|faire)\b)"#) {
            return value
        }
        if let value = firstGroup(text, lead + #"\s*[-#.:]?\s*(?:n[o°]\s*)?0*\d{1,2}\s*[./]\s*([1-4])\b(?![.,]\d)"#) {
            return value
        }
        // « partie 2 », « part II », « 2e partie ».
        let romans = ["i": "1", "ii": "2", "iii": "3", "iv": "4"]
        if let value = firstGroup(text, #"\b(?:partie|part|teil)\s*[-#:]?\s*(\d|i{1,3}|iv)\b"#) {
            return "partie " + (romans[value] ?? value)
        }
        if let value = firstGroup(text, #"\b(\d)\s*(?:e|eme|nd|rd|th)?\s+partie\b"#) {
            return "partie " + value
        }
        // Un jour, sauf celui d'une échéance.
        if !matches(text, #"\b(avant|before|until|jusqu|due|rendre|deadline|pour le|by)\b"#) {
            for (alias, day) in dayAliases {
                if matches(text, #"\b"# + alias + #"\b"#) { return day }
            }
        }
        // « Série A », « Exercices B » : une lettre seule à la place du numéro.
        if let value = firstGroup(text, lead + #"\s*[-#:]?\s*([a-f])\s*$"#) {
            return value
        }
        return ""
    }

    // MARK: Outils

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func firstGroup(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
