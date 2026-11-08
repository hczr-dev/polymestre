import Foundation

/// Range le MOOC d'un cours dans les semaines de son Moodle.
///
/// Plusieurs cours EPFL renvoient, depuis Moodle, à un MOOC sur Courseware :
/// l'algèbre linéaire en classe inversée (les vidéos **sont** le cours), CS-107
/// (« Matériel MOOC de la semaine »). Importer Moodle seul laissait ce travail
/// hors de l'app ; importer le MOOC seul le posait sans semaines. Ici, chaque
/// leçon du MOOC reçoit la semaine où Moodle la cite :
///   1. un lien Moodle qui pointe **dans** la leçon (ou son chapitre) : la
///      semaine de la section Moodle où il apparaît ;
///   2. sinon, « Semaine 3 » / « Week 3 » dans le titre du chapitre ;
///   3. sinon, le numéro du chapitre (« 4. Espaces vectoriels ») : la semaine
///      où Moodle traite ce chapitre (« 04-Espaces-vectoriels ») ;
///   4. sinon, sans semaine : à placer à la relecture.
enum MoocMerger {

    static func merge(mooc: ScrapedCourse,
                      references: [MoocReference],
                      snapshot: MoodleCourseSnapshot,
                      into draft: ContentDraft,
                      termStart: Date?,
                      totalWeeks: Int = 14,
                      calendar: Calendar = .current,
                      plannedWeeks: [String: Int] = [:],
                      plannedLessons: [String: Int] = [:],
                      ordinal: Int = 1) -> ContentDraft {
        var result = draft
        let sectionWeeks = Dictionary(snapshot.sections.compactMap { section -> (Int, Int)? in
            guard let week = MoodleCourseAnalyzer.week(of: section, termStart: termStart,
                                                       totalWeeks: totalWeeks, calendar: calendar) else { return nil }
            return (section.number, week)
        }, uniquingKeysWith: { first, _ in first })

        // La semaine de chaque bloc cité depuis Moodle.
        var blockWeeks: [String: Int] = [:]
        for reference in references {
            guard let block = reference.blockID, let number = reference.sectionNumber,
                  let week = sectionWeeks[number] else { continue }
            blockWeeks[block] = min(blockWeeks[block] ?? week, week)
        }

        // Les chapitres que le **plan du cours** demande de regarder, lus par
        // le modèle (CS-107 : « MOOC 1 : vidéos Module 2 » en semaine 3).
        for (block, week) in plannedWeeks { blockWeeks[block] = min(blockWeeks[block] ?? week, week) }

        // La semaine où Moodle traite chaque chapitre (« 4 · Espaces vectoriels »).
        var chapterWeeks: [Int: Int] = [:]
        for section in draft.sections where section.week > 0 {
            for item in section.items where item.kind == .theory {
                guard let chapter = Int(item.number.split(separator: ".").first ?? "") else { continue }
                let week = item.week ?? section.week
                chapterWeeks[chapter] = min(chapterWeeks[chapter] ?? week, week)
            }
        }

        // **Seulement ce que le cours demande.** Un MOOC entier n'est pas le
        // travail de la semaine : CS-107 cite quelques vidéos par semaine, et
        // ses exercices en ligne ne sont pas à faire. Une leçon est gardée si
        // Moodle la cite (ou cite son chapitre), si son chapitre porte une
        // semaine (« Semaine 3 »), ou si Moodle traite ce chapitre une semaine
        // donnée (« 04-Espaces-vectoriels » ↔ « 4. Espaces vectoriels », la
        // classe inversée où le MOOC **est** le cours).
        // Chaque chapitre demandé devient **son propre élément** de théorie, dans
        // sa semaine : c'est du travail à faire (et à cocher), distinct du cours
        // de la semaine. Fondus dans les vidéos du cours, les chapitres du MOOC
        // de CS-107 ne se voyaient plus.
        for (chapterIndex, chapter) in mooc.sections.enumerated() {
            let title = ContentDraftBuilder.cleanTitle(chapter.title)
            guard !title.isEmpty, !chapter.items.isEmpty else { continue }
            let chapterCited = chapter.id.flatMap { blockWeeks[$0] }
            let chapterWeek = chapterCited
                ?? weekInTitle(title)
                ?? ContentDraftBuilder.leadingNumber(in: title).flatMap { Int($0.number) }.flatMap { chapterWeeks[$0] }
            var byWeek: [Int: [ContentLink]] = [:]
            var firstURL: [Int: String] = [:]
            var videoCounts: [Int: Int] = [:]
            // **Leçon par leçon**, quand le plan le dit (« vidéos 1.6 à 1.8 » en
            // semaine 2) : seules les leçons demandées, chacune à sa semaine.
            // Un chapitre n'est plus posé en bloc sur une semaine.
            func lessonPlan(_ lesson: ScrapedItem) -> Int? {
                ([lesson.id, lesson.url] + (lesson.blockIDs ?? [])).compactMap { $0 }.compactMap { plannedLessons[$0] }.min()
            }
            let byLesson = chapter.items.contains { lessonPlan($0) != nil }
            for lesson in chapter.items {
                // Les exercices du MOOC ne sont pas à faire, sauf ses quiz en
                // ligne (« Exercices online (6 Questions) ») : une ligne du chapitre.
                guard !lesson.url.isEmpty, !isExercise(lesson) || isQuiz(lesson) || lessonPlan(lesson) != nil else { continue }
                let ids = [lesson.id].compactMap { $0 } + (lesson.blockIDs ?? [])
                let planned = byLesson ? lessonPlan(lesson) : (ids.compactMap({ blockWeeks[$0] }).min() ?? chapterWeek)
                guard let raw = planned, raw > 0 else { continue }
                let week = min(raw, max(totalWeeks, 1))
                let lessonTitle = ContentDraftBuilder.cleanTitle(lesson.title)
                let videoLinks = (lesson.links ?? []).filter { $0.kind == .video }
                if firstURL[week] == nil { firstURL[week] = lesson.url }
                if videoLinks.isEmpty {
                    let isVideo = (lesson.videoCount ?? 0) > 0
                    byWeek[week, default: []].append(ContentLink(title: lessonTitle.isEmpty ? title : lessonTitle,
                                                                 url: lesson.url, kind: isVideo ? .video : .page))
                    videoCounts[week, default: 0] += lesson.videoCount ?? 0
                } else {
                    for link in videoLinks {
                        let name = ContentDraftBuilder.cleanTitle(link.title)
                        byWeek[week, default: []].append(ContentLink(title: name.isEmpty || name == lessonTitle ? lessonTitle : "\(lessonTitle) — \(name)",
                                                                     url: link.url, kind: .video))
                    }
                    videoCounts[week, default: 0] += videoLinks.count
                }
            }
            let split = byWeek.count > 1
            for week in byWeek.keys.sorted() {
                let links = byWeek[week] ?? []
                guard !links.isEmpty, let url = firstURL[week] else { continue }
                // Un chapitre réparti sur plusieurs semaines : un élément par
                // semaine, chacun avec ses seules leçons.
                var item = ContentDraftItem(kind: .theory,
                                            number: "M\(ordinal)-\(chapterIndex + 1)" + (split ? "-s\(week)" : ""),
                                            title: "MOOC · \(title)",
                                            url: url,
                                            videoCount: videoCounts[week] ?? 0,
                                            seriesNumber: nil,
                                            theoryKind: (videoCounts[week] ?? 0) > 0 ? .video : .reading,
                                            week: week)
                item.links = links
                if let index = result.sections.firstIndex(where: { $0.week == week && !$0.title.hasPrefix("Échéances") }) {
                    if !result.sections[index].items.contains(where: { $0.url == url }) {
                        result.sections[index].items.append(item)
                    }
                } else {
                    result.sections.append(ContentDraftSection(title: "Semaine \(week) · MOOC", week: week,
                                                               weekIsInferred: false, isIncluded: true, items: [item]))
                }
            }
        }
        result.sections.sort { lhs, rhs in
            if lhs.week == 0 || rhs.week == 0 { return lhs.week != 0 && rhs.week == 0 }
            return lhs.week < rhs.week
        }
        // Le MOOC lui-même reste à portée, pour le reste (facultatif).
        if !mooc.url.isEmpty {
            var item = ContentDraftItem(kind: .resource, number: "", title: "MOOC · \(mooc.title)", url: mooc.url,
                                        videoCount: 0, seriesNumber: nil, theoryKind: .reading)
            item.links = [ContentLink(title: mooc.title, url: mooc.url, kind: .page)]
            item.group = String(localized: "Cours en ligne")
            if let index = result.sections.firstIndex(where: { $0.title.hasPrefix("Documents") }) {
                if !result.sections[index].items.contains(where: { $0.url == mooc.url }) { result.sections[index].items.append(item) }
            } else {
                result.sections.append(ContentDraftSection(title: "Documents du cours (non suivis)", week: 0,
                                                           weekIsInferred: false, isIncluded: true, items: [item]))
            }
        }
        return result
    }

    /// Une leçon d'exercices, de quiz ou d'évaluation du MOOC : pas à faire ici.
    static func isExercise(_ lesson: ScrapedItem) -> Bool {
        guard (lesson.videoCount ?? 0) == 0, !(lesson.links ?? []).contains(where: { $0.kind == .video }) else { return false }
        let folded = ContentDraftBuilder.fold(lesson.title)
        return folded.range(of: #"\b(exercices?|exercises?|quiz+|quizzes|problemes?|problems?|series?|evaluation|assessment|test|devoir|homework|graded)\b"#,
                            options: .regularExpression) != nil
    }

    /// Un quiz en ligne du MOOC : « Exercices online (6 Questions) ».
    static func isQuiz(_ lesson: ScrapedItem) -> Bool {
        ContentDraftBuilder.fold(lesson.title).range(of: #"\(\d+ questions?\)|\bquiz"#, options: .regularExpression) != nil
    }

    /// « Semaine 3 — Les boucles » / « Week 3 » → 3.
    static func weekInTitle(_ title: String) -> Int? {
        let folded = ContentDraftBuilder.fold(title)
        guard let range = folded.range(of: #"\b(semaine|week|sem\.?)\s*0*(\d{1,2})\b"#, options: .regularExpression) else { return nil }
        let digits = folded[range].filter(\.isNumber)
        return Int(digits)
    }
}
