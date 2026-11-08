import Foundation

/// « Nouveau dans tes cours » : des lignes séparées par « · », une par chose.
///
/// Une même série s'y retrouvait plusieurs fois : relue deux fois (« énoncé
/// révisé » puis encore), ou notée une fois en français et une fois en
/// anglais quand la langue de l'app changeait — le texte différait, le
/// dédoublonnage par texte exact laissait les deux. Une ligne qui nomme une
/// série (« MATH-101 série 7 : … », « MATH-101 Series 7b : … ») a pour clé ce
/// qui précède « : », sans la langue : la plus récente remplace l'ancienne,
/// à sa place à elle (la fin). Les autres lignes se dédoublonnent au texte.
enum NewsLines {
    static let separator = " · "

    static func merged(_ existing: String, adding line: String) -> String {
        var order: [String] = []
        var latest: [String: String] = [:]
        for raw in (existing.components(separatedBy: separator) + line.components(separatedBy: separator)) {
            let entry = raw.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty else { continue }
            let key = key(of: entry)
            if latest[key] != nil { order.removeAll { $0 == key } }
            order.append(key)
            latest[key] = entry
        }
        return order.compactMap { latest[$0] }.joined(separator: separator)
    }

    /// « math-101 s 7 » pour « MATH-101 série 7 : … » comme pour
    /// « MATH-101 Series 7 : … » ; le texte entier sinon.
    static func key(of entry: String) -> String {
        guard let colon = entry.range(of: " : ") ?? entry.range(of: ": ") else { return entry }
        let head = entry[..<colon.lowerBound].lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
        let words = head.split(separator: " ").map(String.init)
        guard let index = words.firstIndex(where: { $0 == "serie" || $0 == "series" }), index + 1 < words.count else {
            return entry
        }
        var normalized = words
        normalized[index] = "s"
        return normalized.joined(separator: " ")
    }
}
