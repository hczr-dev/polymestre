import Foundation

/// Les vidéos d'un cours (Explique, listes de lecture MediaSpace), rangées
/// dans ses semaines : **chaque semaine a un élément de théorie**, et ses
/// vidéos en sont les liens.
enum CourseVideos {

    struct Video: Equatable {
        var title: String
        var url: String
        /// La semaine, quand la source la donne ; sinon déduite du titre.
        var week: Int?
        /// Une leçon de MOOC sans vidéo est une page à lire.
        var kind: ContentLink.Kind = .video
        /// L'ordre de la source, gardé quand rien d'autre ne départage.
        var order: Int = 0
    }

    /// La semaine d'une vidéo d'après son titre, quand la source ne la donne pas.
    ///
    /// - « Semaine 3 », « Week 3 », « S3 » : 3.
    /// - « Lecture 7 » : un cours par semaine (7), ou deux (4) quand les numéros
    ///   dépassent le nombre de semaines (`lecturesPerWeek`).
    /// - Une date (« live-stream du 1.10.2025 ») : sa semaine, rapportée au
    ///   semestre de son année (les enregistrements de l'an passé servent encore).
    static func week(of title: String, termStart: Date?, totalWeeks: Int, lecturesPerWeek: Int,
                     calendar: Calendar = .current) -> Int? {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        if let n = number(in: folded, #"\b(?:semaine|week|sem\.?|s)\s*0*(\d{1,2})\b"#), (1...totalWeeks).contains(n) { return n }
        if let n = number(in: folded, #"\b(?:lecture|cours|lesson|lecon)\s*0*(\d{1,2})[a-z]?\b"#), n > 0 {
            let week = Int((Double(n) / Double(max(lecturesPerWeek, 1))).rounded(.up))
            if (1...totalWeeks).contains(week) { return week }
        }
        if let termStart, let date = date(in: folded, calendar: calendar) {
            // Même jour de l'année du semestre : l'enregistrement de l'an passé
            // tombe la même semaine.
            let years = calendar.component(.year, from: termStart) - calendar.component(.year, from: date)
            guard let shifted = calendar.date(byAdding: .year, value: years, to: date) else { return nil }
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: termStart),
                                               to: calendar.startOfDay(for: shifted)).day ?? -1
            let week = days / 7 + 1
            if days >= 0, (1...totalWeeks).contains(week) { return week }
        }
        return nil
    }

    /// Deux cours par semaine quand les numéros dépassent le nombre de semaines.
    static func lecturesPerWeek(_ titles: [String], totalWeeks: Int) -> Int {
        let numbers = titles.compactMap { number(in: $0.lowercased(), #"\b(?:lecture|cours)\s*0*(\d{1,2})\b"#) }
        guard let maximum = numbers.max() else { return 1 }
        return maximum > totalWeeks ? Int((Double(maximum) / Double(totalWeeks)).rounded(.up)) : 1
    }

    /// Ajoute les vidéos au brouillon : à l'élément de théorie de leur semaine
    /// (créé au besoin) ; celles sans semaine dans « Vidéos du cours ».
    ///
    /// - Returns: le brouillon et le nombre de vidéos ajoutées.
    static func merge(_ videos: [Video], into draft: ContentDraft, totalWeeks: Int,
                      sourceLabel: String, preferredYear: String? = nil) -> (draft: ContentDraft, added: Int) {
        var result = draft
        var known = Set(result.sections.flatMap(\.items).flatMap { [$0.url] + $0.links.map(\.url) }.filter { !$0.isEmpty })
        var added = 0
        let byWeek = Dictionary(grouping: videos.filter { $0.week != nil }) { min($0.week!, max(totalWeeks, 1)) }
        for week in byWeek.keys.sorted() where week > 0 {
            let ordered = byWeek[week]!.sorted { lhs, rhs in
                let ln = lectureNumber(lhs.title) ?? Int.max, rn = lectureNumber(rhs.title) ?? Int.max
                if ln != rn { return ln < rn }
                if let year = preferredYear {
                    let l = lhs.title.contains(year), r = rhs.title.contains(year)
                    if l != r { return l }
                }
                return lhs.order < rhs.order
            }.filter { known.insert($0.url).inserted }
            guard !ordered.isEmpty else { continue }
            let links = ordered.map { ContentLink(title: $0.title, url: $0.url, kind: $0.kind) }
            if let position = weekItem(week, in: result) {
                var item = result.sections[position.section].items[position.item]
                if item.links.isEmpty, !item.url.isEmpty {
                    item.links = [ContentLink(title: item.title, url: item.url, kind: .page)]
                }
                item.links.append(contentsOf: links)
                item.videoCount = item.links.filter { $0.kind == .video }.count
                if item.videoCount > 0 { item.theoryKind = .video }
                result.sections[position.section].items[position.item] = item
            } else {
                var topics: [String] = []
                for video in ordered {
                    let topic = cleanTopic(video.title)
                    if !topic.isEmpty, !topics.contains(topic) { topics.append(topic) }
                }
                var item = ContentDraftItem(kind: .theory, number: "\(week)",
                                            title: topics.isEmpty ? String(localized: "Cours de la semaine \(week)") : topics.prefix(3).joined(separator: " · "),
                                            url: ordered[0].url, videoCount: links.filter { $0.kind == .video }.count, seriesNumber: nil,
                                            theoryKind: links.contains { $0.kind == .video } ? .video : .reading)
                item.links = links
                append(item, week: week, label: sourceLabel, to: &result)
            }
            added += ordered.count
        }
        // Sans semaine : gardées, dans les documents du cours.
        let loose = videos.filter { $0.week == nil && known.insert($0.url).inserted }
        if !loose.isEmpty {
            let items = loose.map { video -> ContentDraftItem in
                var item = ContentDraftItem(kind: .resource, number: "", title: video.title, url: video.url,
                                            videoCount: 1, seriesNumber: nil, theoryKind: .video)
                item.links = [ContentLink(title: video.title, url: video.url, kind: video.kind)]
                item.group = String(localized: "Vidéos du cours (\(sourceLabel))")
                return item
            }
            if let index = result.sections.firstIndex(where: { $0.title.hasPrefix("Documents") }) {
                result.sections[index].items.append(contentsOf: items)
            } else {
                result.sections.append(ContentDraftSection(title: "Documents du cours (non suivis)", week: 0,
                                                           weekIsInferred: false, isIncluded: true, items: items))
            }
            added += loose.count
        }
        return (result, added)
    }

    // MARK: Utilitaires

    static func lectureNumber(_ title: String) -> Int? {
        number(in: title.lowercased(), #"\blecture\s*(\d+)"#)
    }

    /// « Lecture 5: Proofs (2026) » → « Proofs » ; « CS-107 : Compléments du
    /// cours 2 (bases…) » reste lisible.
    static func cleanTopic(_ title: String) -> String {
        title.replacingOccurrences(of: #"\s*\((?:\d{4}|view on speaker|speaker view)\)"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"^lecture\s*\d+[a-z]?\s*[:–-]\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s*-\s*\d+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func weekItem(_ week: Int, in draft: ContentDraft) -> (section: Int, item: Int)? {
        for (s, section) in draft.sections.enumerated() {
            for (i, item) in section.items.enumerated() where item.kind == .theory && item.plannedWeek(in: section) == week {
                return (s, i)
            }
        }
        return nil
    }

    private static func append(_ item: ContentDraftItem, week: Int, label: String, to draft: inout ContentDraft) {
        if let index = draft.sections.firstIndex(where: { $0.week == week && !$0.title.hasPrefix("Échéances") }) {
            draft.sections[index].items.append(item)
        } else {
            draft.sections.append(ContentDraftSection(title: "Semaine \(week) · \(label)", week: week,
                                                      weekIsInferred: false, isIncluded: true, items: [item]))
            draft.sections.sort { lhs, rhs in
                if lhs.week == 0 || rhs.week == 0 { return lhs.week != 0 && rhs.week == 0 }
                return lhs.week < rhs.week
            }
        }
    }

    private static func number(in text: String, _ pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }

    private static func date(in text: String, calendar: Calendar) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: #"\b(\d{1,2})\.(\d{1,2})\.(\d{4})\b"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ i: Int) -> Int? { Range(match.range(at: i), in: text).flatMap { Int(text[$0]) } }
        guard let d = group(1), let m = group(2), let y = group(3), (1...12).contains(m), (1...31).contains(d) else { return nil }
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))
    }
}
