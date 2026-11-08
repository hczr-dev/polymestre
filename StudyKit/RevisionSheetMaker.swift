import Foundation
import Observation
import PDFKit

/// Fait la fiche de révision d'un cours et la range dans le cours
/// (`Course.revisionSheet`, synchronisé par iCloud).
///
///   • **Cours Botafogo** : chaque section du polycopié est lue, ses énoncés
///     encadrés repris tels quels (partout, sans IA). Sur le Mac, Claude y
///     ajoute les méthodes et les pièges des séries.
///   • **Autres cours** : Claude (l'abonnement, sur le Mac) ou le tuteur gratuit
///     (l'iPhone, un Mac sans Claude Code) lit tout le matériel — diapositives,
///     notes, documents, séries et corrigés — et écrit la fiche.
@MainActor
@Observable
final class RevisionSheetMaker {
    static let shared = RevisionSheetMaker()

    enum State: Equatable {
        case working(String)
        case failed(String)
    }

    /// Ce qui se passe pour chaque cours (absent : rien en cours).
    private(set) var states: [UUID: State] = [:]

    /// (consigne, message) → réponse : Claude Code ou le tuteur gratuit sur le Mac, le tuteur sur l'iPhone.
    @ObservationIgnored var writer: ((_ instructions: String, _ prompt: String) async throws -> String)?

    var canWrite: Bool { writer != nil }

    func state(_ course: Course) -> State? { states[course.id] }

    /// Toutes les fiches d'un coup (le menu du Mac) : où l'on en est.
    private(set) var batch: (done: Int, total: Int)?

    /// Les fiches qui manquent, faites seules (au lancement du Mac) : un essai
    /// par cours et par jour au plus — un échec ne repaie pas Claude à chaque lancement.
    func makeMissing(_ courses: [Course], hub: SiteHub, now: Date = Date()) async {
        let defaults = UserDefaults.standard
        let missing = courses.filter { course in
            guard course.isTracked, course.revisionSheetRaw.isEmpty, canMake(course) else { return false }
            let last = defaults.double(forKey: "sheet.autoTried." + course.id.uuidString)
            return now.timeIntervalSince1970 - last > 20 * 3600
        }
        for course in missing { defaults.set(now.timeIntervalSince1970, forKey: "sheet.autoTried." + course.id.uuidString) }
        await makeAll(missing, hub: hub)
    }

    /// Chaque cours suivi, l'un après l'autre (Claude n'en écrit qu'une à la fois).
    func makeAll(_ courses: [Course], hub: SiteHub) async {
        guard batch == nil else { return }
        let list = courses.filter { $0.isTracked && canMake($0) }
        guard !list.isEmpty else { return }
        batch = (0, list.count)
        // Les documents de Moodle se lisent dans la session : reconnectée sans rien afficher.
        if list.contains(where: { Self.botafogoSite(of: $0) == nil }) {
            await SchoolConnect.shared.ensure(.moodle, prompting: false)
        }
        for course in list {
            await make(course, hub: hub)
            batch?.done += 1
        }
        batch = nil
    }

    /// Peut-on faire la fiche de ce cours ici ?
    func canMake(_ course: Course) -> Bool {
        Self.botafogoSite(of: course) != nil || canWrite
    }

    static func botafogoSite(of course: Course) -> URL? {
        course.contentSources.compactMap(URL.init(string:)).first { ContentSource.detect(host: $0.host) == .botafogo }
    }

    func make(_ course: Course, hub: SiteHub) async {
        guard states[course.id].map({ if case .working = $0 { return false }; return true }) ?? true else { return }
        do {
            var sheet: RevisionSheet
            if let site = Self.botafogoSite(of: course) {
                sheet = try await handoutSheet(course, site: site, hub: hub)
                if let writer {
                    states[course.id] = .working(String(localized: "Claude écrit les méthodes des séries…"))
                    let material = await seriesMaterial(course, hub: hub)
                    if !material.isEmpty,
                       let answer = try? await writer(RevisionSheetAI.methodsInstructions,
                                                      RevisionSheetAI.prompt(course: course.name, documents: material, budget: 200_000)),
                       let methods = RevisionSheetAI.sheet(fromAnswer: answer) {
                        sheet.chapters += methods.chapters.map { chapter in
                            var copy = chapter
                            copy.title = String(localized: "Méthodes · ") + chapter.title
                            return copy
                        }
                    }
                }
            } else {
                guard let writer else {
                    throw Failure(String(localized: "La fiche de ce cours se fait sur le Mac (Claude lit ses documents)."))
                }
                states[course.id] = .working(String(localized: "Lecture des documents du cours…"))
                let material = await allMaterial(course, hub: hub)
                guard !material.isEmpty else { throw Failure(String(localized: "Aucun document lisible dans ce cours.")) }
                let pages = material.reduce(0) { $0 + $1.text.count } / 2500
                states[course.id] = .working(String(localized: "Claude écrit la fiche (\(material.count) documents, ~\(pages) pages)…"))
                let answer = try await writer(RevisionSheetAI.instructions,
                                              RevisionSheetAI.prompt(course: course.name, documents: material))
                guard let written = RevisionSheetAI.sheet(fromAnswer: answer) else {
                    throw Failure(String(localized: "Claude n'a pas rendu de fiche lisible. Réessaie."))
                }
                sheet = written
            }
            guard !sheet.isEmpty else { throw Failure(String(localized: "Rien à mettre sur la fiche.")) }
            course.revisionSheet = sheet
            try? course.modelContext?.save()
            // Ce qui est à toi (maîtrise, notes, liens, idées) reste ; les liens des citations sont refaits.
            StudyMapStore.shared.sheetChanged(course, sheet: sheet)
            states[course.id] = nil
            AppLog.record(.info, "fiche", "Fiche de révision faite", detail: "\(course.displayCode) : \(sheet.entries.count) entrées")
        } catch {
            states[course.id] = .failed((error as? Failure)?.message ?? error.localizedDescription)
            AppLog.record(.info, "fiche", "Fiche de révision impossible", detail: "\(course.displayCode) : \(error.localizedDescription)")
        }
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // MARK: Le polycopié

    private func handoutSheet(_ course: Course, site: URL, hub: SiteHub) async throws -> RevisionSheet {
        let book = hub.botafogo(site)
        states[course.id] = .working(String(localized: "Lecture du polycopié…"))
        await book.load(site)
        let sections = book.chapters.flatMap(\.sections)
        guard !sections.isEmpty else { throw Failure(String(localized: "Le polycopié de ce cours est introuvable.")) }
        var pages: [String: [BotafogoBlock]] = [:]
        // Six à la fois : le site répond vite, mais il y a cent sections.
        var index = 0
        while index < sections.count {
            let batch = sections[index..<min(index + 6, sections.count)]
            await withTaskGroup(of: (String, [BotafogoBlock]?).self) { group in
                for section in batch {
                    group.addTask { @MainActor in (section.path, await book.page(section.path)) }
                }
                for await (path, blocks) in group { if let blocks { pages[path] = blocks } }
            }
            index += batch.count
            states[course.id] = .working(String(localized: "Lecture du polycopié… \(index)/\(sections.count)"))
        }
        return RevisionSheetBuilder.sheet(chapters: book.chapters, pages: pages)
    }

    // MARK: Le matériel, pour Claude

    /// Les séries : énoncés et corrigés importés, puis les PDF de corrigé.
    private func seriesMaterial(_ course: Course, hub: SiteHub) async -> [(title: String, text: String)] {
        var result: [(String, String)] = []
        for series in course.sortedSeries where !series.exercises.isEmpty {
            let name = series.title.isEmpty ? series.displayName : "\(series.displayName) · \(series.title)"
            var lines: [String] = []
            for exercise in series.sortedExercises {
                lines.append("— \(exercise.displayNumber)\(exercise.title.isEmpty ? "" : " · " + exercise.title)")
                if !exercise.statement.isEmpty { lines.append(exercise.statement) }
                if !exercise.hint.isEmpty { lines.append("Indication : " + exercise.hint) }
                if !exercise.solution.isEmpty { lines.append("Corrigé : " + exercise.solution) }
            }
            if let solution = Self.pdfAddress(series.solutionURLString), let text = await pdfText(solution, hub: hub) {
                lines.append("Corrigé (PDF) :\n" + text)
            }
            result.append((name, lines.joined(separator: "\n")))
        }
        return result
    }

    /// Tout : la théorie de chaque semaine (titres, résumés, PDF), les
    /// documents du cours, les séries (énoncés PDF, exercices, corrigés).
    private func allMaterial(_ course: Course, hub: SiteHub) async -> [(title: String, text: String)] {
        var result: [(String, String)] = []
        var seen = Set<String>()
        var outline: [String] = []
        for item in course.sortedTheoryItems {
            outline.append("Semaine \(item.plannedWeek) · \(item.numberAndTitle)" + (item.summaryText.map { " — " + $0 } ?? ""))
        }
        if !outline.isEmpty { result.append(("Plan du cours", outline.joined(separator: "\n"))) }

        var documents: [(String, String)] = []
        for item in course.sortedTheoryItems {
            for (title, address) in [(item.numberAndTitle, item.urlString)] + item.links.map({ ($0.title.isEmpty ? item.numberAndTitle : $0.title, $0.url) }) {
                if let pdf = Self.pdfAddress(address), seen.insert(pdf).inserted { documents.append(("Semaine \(item.plannedWeek) · \(title)", pdf)) }
            }
        }
        for document in course.documents {
            if let pdf = Self.pdfAddress(document.url), seen.insert(pdf).inserted { documents.append((document.title, pdf)) }
        }
        for series in course.sortedSeries {
            if let pdf = Self.pdfAddress(series.urlString), seen.insert(pdf).inserted {
                documents.append(("Énoncé · \(series.displayName)", pdf))
            }
        }
        for (offset, document) in documents.enumerated() {
            states[course.id] = .working(String(localized: "Lecture des documents… \(offset + 1)/\(documents.count)"))
            if let text = await pdfText(document.1, hub: hub) { result.append((document.0, text)) }
        }
        result += await seriesMaterial(course, hub: hub)
        return result
    }

    /// Une adresse qui mène (sans doute) à un PDF.
    static func pdfAddress(_ address: String) -> String? {
        guard let url = URL(string: address), url.scheme?.hasPrefix("http") == true else { return nil }
        if CoursePane.isDocument(url) || address.lowercased().contains(".pdf") { return address }
        return nil
    }

    private func pdfText(_ address: String, hub: SiteHub) async -> String? {
        guard let file = await hub.pdfFile(address) else { return nil }
        let text = await Task.detached(priority: .utility) { () -> String? in
            guard let document = PDFDocument(url: file) else { return nil }
            return (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        }.value
        guard let text, text.trimmingCharacters(in: .whitespacesAndNewlines).count > 40 else { return nil }
        return text
    }
}
