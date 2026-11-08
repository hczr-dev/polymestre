import Foundation
import PDFKit
import SwiftData
import Observation

/// Lance la lecture des énoncés en arrière-plan et annonce le résultat sur
/// l'accueil.
@MainActor
enum SeriesAutoReading {
    static func start(courses: [Course], context: ModelContext, settings: SettingsStore) {
        guard !courses.isEmpty else { return }
        Task { @MainActor in
            let report = await SeriesAutoReader.shared.readPending(courses: courses, context: context, settings: settings)
            guard !report.isEmpty else { return }
            settings.contentRefreshNews = SettingsStore.mergedNews(settings.contentRefreshNews, adding: report.joined(separator: NewsLines.separator))
        }
    }
}

/// Remplit tout seul les séries importées **sans exercices** : on lit leur
/// énoncé là où il est publié.
///
/// Importer « Série 4 » depuis Moodle donnait une série vide et un bouton
/// « Lire les exercices dans le PDF » à toucher, série après série. Désormais,
/// après un import (et à chaque mise à jour automatique), l'app va chercher
/// l'énoncé elle-même :
///   • une page de série HTML (CS-107, `proginsc.epfl.ch`) se lit directement :
///     numéros, titres, niveaux, liens (`SeriesPageParser`) ;
///   • un PDF — sur Moodle, lu avec la session ; public (CS-101 sur GitHub),
///     lu directement — passe par la **même** chaîne que l'import manuel : mise
///     en page, motifs, puis le modèle de langage s'il est disponible.
/// Rien n'est effacé : l'écriture se fait en mode fusion (`SeriesDraftWriter`).
@MainActor
@Observable
final class SeriesAutoReader {
    static let shared = SeriesAutoReader()

    /// Les séries en cours de lecture, pour que la liste le dise.
    private(set) var reading: Set<UUID> = []
    /// Ce qui a échoué, par série, pour le proposer à la main.
    private(set) var failures: [UUID: String] = [:]
    @ObservationIgnored private var running = false

    /// Lit les séries vides des cours donnés, une à la fois.
    ///
    /// - Returns: « CS-107 série 3 : 12 exercices » pour chaque série remplie.
    @discardableResult
    func readPending(courses: [Course], context: ModelContext, settings: SettingsStore) async -> [String] {
        guard !running else { return [] }
        running = true
        defer { running = false }
        var report: [String] = []
        // Une session Moodle expirée faisait échouer chaque série l'une après
        // l'autre (et les marquait en échec). On la rejoue d'abord en silence ;
        // si elle ne revient pas, les séries Moodle attendent la reconnexion
        // sans être marquées.
        let needsMoodle = courses.contains { course in
            course.series.contains { URL(string: $0.urlString)?.host?.contains("moodle") == true && ($0.exercises.isEmpty || MoodleLinks.activityModule(of: URL(string: $0.urlString)!) != nil) }
        }
        let moodleReady = needsMoodle ? await MoodleClient.background.ensureSignedIn() : false
        if moodleReady { await repairLinks(courses: courses, context: context) }
        // Les exercices que la première version des révisions gardait, marqués
        // « retiré de l'énoncé » : ils n'existent plus dans l'énoncé.
        var cleaned = false
        for series in courses.flatMap(\.series) {
            for exercise in series.exercises where exercise.title.hasSuffix("(\(SeriesDraftWriter.removedMark))") {
                series.exercises.removeAll { $0.id == exercise.id }
                context.delete(exercise)
                cleaned = true
            }
        }
        if cleaned { try? context.save() }
        // Un énoncé révisé à la source est relu (`SeriesSourceWatch`).
        await SeriesSourceWatch.flagChanged(courses: courses, moodleReady: moodleReady)
        for course in courses {
            for series in course.sortedSeries where (series.exercises.isEmpty || series.needsReread) && failures[series.id] == nil {
                guard let url = URL(string: series.urlString), url.scheme?.hasPrefix("http") == true else { continue }
                if url.host?.contains("moodle") == true, !moodleReady { continue }
                reading.insert(series.id)
                defer { reading.remove(series.id) }
                // Une série déjà remplie et marquée : c'est une révision de l'énoncé.
                let revising = !series.exercises.isEmpty
                do {
                    let count = try await read(series, from: url, course: course, context: context, settings: settings,
                                               mode: revising ? .revision : .importMerge)
                    series.needsReread = false
                    if count > 0 {
                        if revising { SeriesSourceWatch.commit(series) }
                        try? context.save()
                        // « MATH-101 Série 5b : … » : le nom complet, traduit (`NewsLines` en fait la clé).
                        report.append("\(course.displayCode) \(series.displayName) : "
                                      + (revising ? String(localized: "énoncé révisé, \(count) exercices") : Plural.count(count, "\(count) exercice", "\(count) exercices")))
                    }
                } catch {
                    failures[series.id] = error.localizedDescription
                    AppLog.record(.warning, "import", "Énoncé de la série \(series.seriesNumber) illisible",
                                  detail: "\(course.displayCode) — \(error.localizedDescription)")
                }
            }
        }
        return report
    }

    /// Les séries déjà tentées par `repairLinks`, pour ne pas relire Moodle à
    /// chaque lancement.
    @ObservationIgnored private var repaired: Set<UUID> = []

    /// Remplace l'adresse d'une page Moodle (page, dossier, lien) par celle du
    /// PDF qu'elle porte.
    ///
    /// Les séries importées avant que l'import ne suive ces pages gardaient
    /// l'adresse de la page : « Énoncé de la série » ouvrait Moodle, et la
    /// lecture des exercices échouait (« ce lien ne mène pas à un PDF »).
    func repairLinks(courses: [Course], context: ModelContext) async {
        var changed = false
        for course in courses {
            for series in course.sortedSeries where !repaired.contains(series.id) {
                guard let url = URL(string: series.urlString),
                      let module = MoodleLinks.activityModule(of: url), module != "resource" else { continue }
                repaired.insert(series.id)
                guard let found = await AuthenticatedDownloader.resolve(url) else { continue }
                series.urlString = found.statement.absoluteString
                if series.solutionURLString.isEmpty, let solution = found.solution {
                    series.solutionURLString = solution.absoluteString
                }
                failures[series.id] = nil
                changed = true
            }
        }
        if changed { try? context.save() }
    }

    /// Après une reconnexion : tout ce qui avait échoué est retenté.
    func retryAll() {
        failures = [:]
        repaired = []
    }

    func retry(_ series: ExerciseSeries) {
        failures[series.id] = nil
    }

    // MARK: Lecture

    private func read(_ series: ExerciseSeries, from url: URL, course: Course,
                      context: ModelContext, settings: SettingsStore, mode: SeriesDraftWriter.Mode = .importMerge,
                      depth: Int = 0) async throws -> Int {
        let file: URL
        if url.host?.contains("moodle") == true {
            file = try await AuthenticatedDownloader.download(url)
        } else {
            // On regarde **ce que le serveur renvoie**, pas l'adresse : les
            // séries de CS-107 (`proginsc.epfl.ch/…/serie07`) sont des pages
            // HTML sans « .html », et partaient au lecteur de PDF — « Ce lien ne
            // mène pas à un PDF ».
            let (data, response) = try await URLSession.shared.data(from: Self.direct(url))
            let base = response.url ?? url
            if Self.isPDF(data: data, response: response) {
                file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
                try data.write(to: file)
            } else {
                let html = String(decoding: data, as: UTF8.self)
                if let page = SeriesPageParser.parseProginsc(html: html, baseURL: base) {
                    write(page.exercises, into: series, course: course, context: context, mode: mode)
                    if series.solutionURLString.isEmpty || URL(string: series.solutionURLString)?.host?.contains("courseware") == true {
                series.solutionURLString = page.solutionURL
            }
                    return series.exercises.count
                }
                // Une page qui porte le PDF de la série (site de cours, GitHub…).
                if depth == 0, let next = MoodleLinks.statementLink(inHTML: html, baseURL: base).statement.flatMap(URL.init(string:)),
                   next != url {
                    let count = (try? await read(series, from: next, course: course, context: context, settings: settings,
                                                 mode: mode, depth: 1)) ?? 0
                    if count > 0 {
                        series.urlString = next.absoluteString
                        return count
                    }
                }
                // Une page qui contient les énoncés eux-mêmes, quel que soit le
                // site : lue comme une mise en page (titres, gras, retraits).
                let count = try await extract(lines: HTMLLayout.lines(fromHTML: html), pageImages: [],
                                              into: series, course: course, context: context, settings: settings, mode: mode)
                if count > 0 { return count }
                throw HiddenSiteSession.SiteError.failed(String(localized: "Page web sans énoncé lisible (\(base.host ?? String(localized: "site inconnu"))) : ouvre-la depuis la série."))
            }
        }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let document = PDFDocument(url: file) else {
            throw HiddenSiteSession.SiteError.failed(String(localized: "Ce lien ne mène pas à un PDF lisible."))
        }
        let lines = PDFLayoutExtractor.lines(from: document)
        guard lines.contains(where: { !$0.isEmpty }) else {
            throw HiddenSiteSession.SiteError.failed(String(localized: "Le PDF ne contient pas de texte (scan ?)."))
        }
        return try await extract(lines: lines, pageImages: PDFPageRenderer.jpegPages(of: document),
                                 into: series, course: course, context: context, settings: settings, mode: mode)
    }

    /// Les exercices d'un énoncé mis en page (PDF ou page web) : règles, puis
    /// le modèle de langage s'il est disponible, fusionnés.
    private func extract(lines: [PDFLayoutLine], pageImages: [Data], into series: ExerciseSeries, course: Course,
                         context: ModelContext, settings: SettingsStore,
                         mode: SeriesDraftWriter.Mode = .importMerge) async throws -> Int {
        guard lines.contains(where: { !$0.isEmpty }) else { return 0 }
        var detected = SeriesLayoutParser.fillingStatements(SeriesLayoutParser.parse(lines, defaultSeries: series.seriesNumber), from: lines)
        if settings.aiExtractionEnabled, SeriesAIExtractor.plannedSource(settings) != nil {
            let language = SeriesDocumentInference.languageName(of: lines.map(\.text).joined(separator: "\n"))
            let prepared = SeriesAIParsing.prepareLayout(lines, seriesHint: series.seriesNumber, language: language)
            if let result = try? await SeriesAIExtractor.extract(prepared: prepared,
                                                                 pageImages: pageImages,
                                                                 seriesHint: series.seriesNumber,
                                                                 language: language, settings: settings) {
                detected = SeriesAIParsing.merge(heuristic: detected, ai: result.series,
                                                 preferredSeries: series.seriesNumber,
                                                 aiReadsLayout: result.source.readsLayout)
            }
        }
        // Un PDF qui porte « 5a » et « 5b » : la bonne des deux.
        guard let match = detected.first(where: { $0.key == series.key })
                ?? detected.first(where: { $0.number == series.seriesNumber && ($0.label.isEmpty || series.label.isEmpty) })
                ?? detected.first,
              !match.exercises.isEmpty else { return 0 }
        let exercises = match.exercises.map { exercise in
            ContentExerciseDraft(number: "\(series.seriesNumber).\(exercise.number.split(separator: ".").last.map(String.init) ?? exercise.number)",
                                 title: exercise.title, statement: exercise.statement,
                                 isBonus: exercise.isBonus, questions: exercise.subQuestions)
        }
        write(exercises, into: series, course: course, context: context, mode: mode)
        return series.exercises.count
    }

    private func write(_ exercises: [ContentExerciseDraft], into series: ExerciseSeries,
                       course: Course, context: ModelContext, mode: SeriesDraftWriter.Mode = .importMerge) {
        let draft = SeriesDraft(existingID: series.id, number: series.seriesNumber, label: series.label, title: "",
                                plannedWeek: series.plannedWeek,
                                exercises: exercises.map { spec in
                                    var exercise = ExerciseDraft(minor: spec.number.split(separator: ".").last.map(String.init) ?? spec.number,
                                                                 title: spec.title, isBonus: spec.isBonus,
                                                                 subQuestions: spec.questions)
                                    exercise.statement = spec.statement
                                    return exercise
                                })
        SeriesDraftWriter.write(draft, to: course, mode: mode, context: context)
        for spec in exercises where !spec.url.isEmpty {
            series.exercises.first { $0.exerciseNumber == spec.number }?.statementURLString = spec.url
        }
    }

    /// Dropbox sert une page HTML sans `dl=1`.
    private static func direct(_ url: URL) -> URL {
        guard url.host?.contains("dropbox.com") == true,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = (components.queryItems ?? []).filter { $0.name != "dl" }
        items.append(URLQueryItem(name: "dl", value: "1"))
        components.queryItems = items
        return components.url ?? url
    }

    /// Un PDF se reconnaît à sa signature, quel que soit l'en-tête.
    private static func isPDF(data: Data, response: URLResponse) -> Bool {
        if data.starts(with: Data("%PDF".utf8)) { return true }
        let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        return type.contains("pdf") && !type.contains("html")
    }
}
