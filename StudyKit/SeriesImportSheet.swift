import SwiftUI
import SwiftData
import PDFKit
import UniformTypeIdentifiers

/// Import d'une série en trois temps : **choisir**, **analyser**, **relire**.
///
/// La version précédente affichait la lecture rapide tout de suite, puis la
/// remplaçait quand l'IA répondait : la liste changeait sous le doigt, pendant
/// qu'on la corrigeait. L'analyse a maintenant son écran, avec ses étapes et un
/// « Continuer sans attendre » ; la relecture n'apparaît qu'une fois la lecture
/// choisie, et elle utilise le même formulaire que « Modifier la série ».
struct SeriesImportSheet: View {
    /// Cours d'où l'import est lancé. `nil` depuis l'accueil : le PDF le désigne
    /// souvent lui-même, sinon l'écran le demande — il ne choisit jamais seul.
    let course: Course?
    /// Fichier déjà fourni — par l'extension de partage, par exemple.
    var initialFileURL: URL?
    /// Texte déjà fourni (page web, mail).
    var initialText: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(SettingsStore.self) private var settings
    @Query(sort: \Course.code) private var courses: [Course]

    @State private var selectedCourseID: UUID?
    @State private var courseWasDetected = false
    @State private var phase: Phase = .source
    @State private var sourceName = ""
    @State private var pageCount = 0
    @State private var drafts: [SeriesDraft] = []
    /// Ce qui a été appliqué en dernier : s'en écarter, c'est avoir corrigé.
    @State private var lastApplied: [SeriesDraft] = []
    /// Ce que la lecture locale a trouvé, pour pouvoir y revenir.
    @State private var localResult: [DetectedSeries] = []
    @State private var aiResult: [DetectedSeries]?
    @State private var preferredSeries: Int?
    /// La langue lue dans le document, transmise au modèle pour qu'il ne traduise pas.
    @State private var documentLanguage: String?
    @State private var aiInput = ""
    /// Les pages en JPEG : envoyées au modèle qui lit la mise en page, et
    /// affichées dans l'aperçu de chaque exercice.
    @State private var pageImages: [Data] = []
    @State private var ai: AIState = .idle
    @State private var analysisTask: Task<Void, Never>?
    @State private var previewing: SourcePreview?
    @State private var showingPicker = false
    @State private var showingPaste = false
    @State private var pastedText = ""
    @State private var saveError: String?
    /// Les PDF lus, pour garder celui de la série créée.
    @State private var sourceFiles: [URL] = []

    private enum Phase: Equatable {
        case source
        case reading
        /// Lecture locale faite, l'IA lit les pages.
        case analyzing
        case review
        case noText
        case failed(String)
    }

    private enum AIState: Equatable {
        case idle
        case unavailable
        case running
        case applied(String)
        /// Le modèle a répondu après une correction manuelle : on propose.
        case pending(String)
        case failed(String)
    }

    private var trackedCourses: [Course] { courses.filter(\.isTracked) }
    private var selectedCourse: Course? { courses.first { $0.id == selectedCourseID } }
    private var exerciseCount: Int { drafts.reduce(0) { $0 + $1.exercises.count } }
    private var hasEdited: Bool { drafts != lastApplied }
    private var problems: [String] { drafts.flatMap { $0.problems(taken: []) } }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .source: sourceStep
                case .reading, .analyzing: analysisStep
                case .review: reviewStep
                case .noText: noTextStep
                case .failed(let message): failedStep(message)
                }
            }
            .carnetBackground()
            .navigationTitle(title)
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        analysisTask?.cancel()
                        dismiss()
                    }
                }
                if phase == .review {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(exerciseCount > 0 ? "Importer (\(exerciseCount))" : "Importer") { create() }
                            .fontWeight(.semibold)
                            .disabled(exerciseCount == 0 || selectedCourse == nil || !problems.isEmpty)
                    }
                }
            }
            .fileImporter(isPresented: $showingPicker,
                          allowedContentTypes: [.pdf],
                          allowsMultipleSelection: true) { result in
                handle(result)
            }
            .sheet(isPresented: $showingPaste) { pasteSheet }
            .sheet(item: $previewing) { preview in
                SourcePreviewSheet(preview: preview, pages: pageImages)
            }
            .task {
                if selectedCourseID == nil { selectedCourseID = course?.id }
                guard phase == .source else { return }
                if let initialFileURL {
                    read([initialFileURL])
                } else if let initialText, !initialText.isEmpty {
                    analyze(text: initialText)
                }
            }
            .onDisappear { analysisTask?.cancel() }
        }
        .interactiveDismissDisabled(phase == .review && hasEdited)
    }

    private var title: String {
        switch phase {
        case .review: return "Vérifier l'import"
        case .reading, .analyzing: return "Analyse"
        default: return "Importer une série"
        }
    }

    // MARK: 1. Source

    private var sourceStep: some View {
        List {
            Section {
                Button {
                    showingPicker = true
                } label: {
                    bigChoice(icon: "doc.badge.plus", title: "Choisir un PDF",
                              detail: "Une série ou plusieurs à la fois, depuis Fichiers.")
                }
                Button {
                    pastedText = ""
                    showingPaste = true
                } label: {
                    bigChoice(icon: "doc.on.clipboard", title: "Coller l'énoncé",
                              detail: "Depuis Moodle, un mail ou une page web.")
                }
            }
            if let course {
                Section {
                    LabeledContent("Cours", value: "\(course.displayCode) · \(course.name)")
                }
            }
        }
        .groupedList()
    }

    private func bigChoice(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: Layout.block) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Theme.accentInk)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: Layout.micro) {
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, Layout.snug)
        .contentShape(Rectangle())
    }

    // MARK: 2. Analyse

    private var analysisStep: some View {
        List {
            Section {
                stepRow(done: phase == .analyzing, running: phase == .reading,
                        title: "Lecture du document",
                        detail: phase == .reading ? sourceName
                            : "\(sourceName)\(pageCount > 0 ? " · \(Plural.count(pageCount, "\(pageCount) page", "\(pageCount) pages"))" : "") · \(localSummary)")
                if phase == .analyzing {
                    stepRow(done: false, running: true,
                            title: pageImages.isEmpty ? "Vérification par l'IA" : "Lecture des pages par l'IA",
                            detail: pageImages.isEmpty
                                ? "Structure, intitulés et bonus."
                                : "Environ 5 à 20 s.")
                }
            }
            if phase == .analyzing {
                Section {
                    Button {
                        continueWithoutWaiting()
                    } label: {
                        Label("Continuer sans attendre", systemImage: "forward.fill")
                    }
                    Button(role: .destructive) {
                        cancelAnalysis()
                    } label: {
                        Label("Arrêter l'IA", systemImage: "stop.fill")
                    }
                    // L'icône suit le texte : un carré indigo à côté d'un libellé
                    // rouge se lisait comme deux boutons.
                    .foregroundStyle(.red)
                }
            }
        }
        .groupedList()
    }

    private func stepRow(done: Bool, running: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Layout.block) {
            Group {
                if running {
                    ProgressView()
                } else {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(done ? Color.green.accessibleMark : .secondary)
                }
            }
            .frame(width: 24)
            VStack(alignment: .leading, spacing: Layout.micro) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Layout.tight)
    }

    private var localSummary: String {
        let exercises = localResult.reduce(0) { $0 + $1.exercises.count }
        return Plural.count(exercises, "\(exercises) exercice repéré", "\(exercises) exercices repérés")
    }

    // MARK: 3. Relecture

    private var reviewStep: some View {
        List {
            Section {
                Picker("Cours", selection: $selectedCourseID) {
                    if selectedCourseID == nil {
                        Text("Choisir…").tag(UUID?.none)
                    }
                    ForEach(trackedCourses) { course in
                        Text("\(course.displayCode) · \(course.name)").tag(Optional(course.id))
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedCourseID) { _, _ in courseWasDetected = false }
                analysisStatus
            } footer: {
                if selectedCourse == nil {
                    Text("Choisis le cours auquel ajouter cette série.")
                        .foregroundStyle(Color.orange.accessibleInk)
                } else if courseWasDetected {
                    Text("Cours reconnu dans le document.")
                }
            }

            ForEach($drafts) { $draft in
                SeriesDraftForm(draft: $draft,
                                maxWeek: selectedCourse?.term?.totalWeeks ?? 14,
                                mergesInto: selectedCourse?.series(number: draft.number, label: draft.label),
                                showSource: pageImages.isEmpty ? nil : { exercise in preview(exercise, in: draft) })
            }

            Section {
                Button {
                    let next = (drafts.map(\.number).max() ?? preferredSeries.map { $0 - 1 } ?? 0) + 1
                    var draft = SeriesDraft(number: next, title: "", plannedWeek: defaultWeek(for: next), exercises: [])
                    draft.addExercise()
                    drafts.append(draft)
                    Haptics.tap()
                } label: {
                    Label(drafts.isEmpty ? "Ajouter une série à la main" : "Ajouter une autre série",
                          systemImage: "plus.rectangle.on.rectangle")
                }
            } footer: {
                if let saveError {
                    Text(saveError).foregroundStyle(Color.orange.accessibleInk)
                }
            }
        }
        .groupedList()
        .scrollDismissesKeyboard(.interactively)
    }

    /// Qui a lu le document, en une ligne — et ce qu'on peut y faire.
    @ViewBuilder
    private var analysisStatus: some View {
        switch ai {
        case .idle, .unavailable:
            statusRow(icon: "text.magnifyingglass", tint: .secondary, title: "Lecture rapide",
                      detail: ai == .unavailable ? "IA désactivée (Réglages › IA de lecture). Vérifie les questions." : "")
        case .running:
            HStack(spacing: Layout.control) {
                ProgressView()
                Text("L'IA lit encore les pages…").font(.subheadline)
                Spacer(minLength: 0)
                Button("Arrêter") { cancelAnalysis() }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
            }
        case .applied(let detail):
            statusRow(icon: "checkmark.seal.fill", tint: .green, title: "Lu par l'IA", detail: detail)
            Button("Revenir à la lecture rapide") {
                apply(localResult)
                ai = .idle
                Haptics.tap()
            }
            .font(.subheadline)
        case .pending(let detail):
            statusRow(icon: "sparkles", tint: Theme.accent, title: "L'IA propose une autre lecture", detail: detail)
            Button("Utiliser la lecture de l'IA (remplace tes corrections)") {
                if let aiResult { apply(aiResult) }
                ai = .applied(detail)
                Haptics.success()
            }
            .font(.subheadline)
        case .failed(let message):
            statusRow(icon: "exclamationmark.triangle.fill", tint: .orange,
                      title: "Lecture rapide — l'IA n'a pas abouti", detail: message)
            Button("Réessayer l'IA") { runAI() }
                .font(.subheadline)
        }
    }

    private func statusRow(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Layout.control) {
            Image(systemName: icon)
                .foregroundStyle(tint.accessibleMark)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: Layout.micro) {
                Text(title).font(.subheadline.weight(.semibold))
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func preview(_ exercise: ExerciseDraft, in draft: SeriesDraft) {
        guard let page = exercise.pageIndex, page < pageImages.count, !pageImages[page].isEmpty else { return }
        previewing = SourcePreview(title: "Exercice \(draft.number).\(exercise.minor)",
                                   page: page, top: exercise.top, bottom: exercise.bottom)
    }

    // MARK: États sans relecture

    private var noTextStep: some View {
        List {
            Section {
                Label("Aucun texte lisible", systemImage: "doc.text.magnifyingglass")
                    .font(.subheadline.weight(.semibold))
            } footer: {
                Text("Document scanné : crée la série à la main, avec le plan « 1(a-d) 2 3 ».")
            }
            Section {
                Button {
                    let number = preferredSeries ?? 1
                    var draft = SeriesDraft(number: number, title: "", plannedWeek: defaultWeek(for: number), exercises: [])
                    draft.addExercise()
                    drafts = [draft]
                    lastApplied = []
                    phase = .review
                } label: {
                    Label("Créer la série à la main", systemImage: "plus.rectangle.on.rectangle")
                }
                Button("Choisir un autre fichier") { showingPicker = true }
            }
        }
        .groupedList()
    }

    private func failedStep(_ message: String) -> some View {
        List {
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color.orange.accessibleInk)
            }
            Section {
                Button("Choisir un autre fichier") { showingPicker = true }
            }
        }
        .groupedList()
    }

    // MARK: Collage

    /// Le texte d'un énoncé copié depuis Moodle ou un mail : même pipeline que le
    /// PDF, sans fichier.
    private var pasteSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $pastedText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 220)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Colle l'énoncé tel quel.")
                }
            }
            .carnetBackground()
            .navigationTitle("Coller un énoncé")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { showingPaste = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Analyser") {
                        showingPaste = false
                        sourceName = "Texte collé"
                        analyze(text: pastedText)
                    }
                    .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: Lecture

    private func handle(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            phase = .failed(error.localizedDescription)
        case .success(let urls):
            guard !urls.isEmpty else { return }
            read(urls)
        }
    }

    private struct ReadResult: Sendable {
        var lines: [PDFLayoutLine]
        var pages: [Data]
        var unreadable: Int
    }

    /// Lit un ou plusieurs PDF **hors du fil principal**, en conservant leur mise
    /// en page. Un polycopié de trente pages figeait l'écran le temps de la lecture.
    private func read(_ urls: [URL]) {
        analysisTask?.cancel()
        sourceFiles = urls
        phase = .reading
        ai = .idle
        sourceName = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) documents"
        let filename = urls.first?.lastPathComponent

        analysisTask = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> ReadResult in
                var allLines: [PDFLayoutLine] = []
                var pages: [Data] = []
                var unreadable = 0
                for url in urls {
                    // Un fichier choisi hors du bac à sable doit être ouvert explicitement.
                    let needsScope = url.startAccessingSecurityScopedResource()
                    defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
                    guard let document = PDFDocument(url: url) else {
                        unreadable += 1
                        continue
                    }
                    var lines = PDFLayoutExtractor.lines(from: document)
                    // Les numéros de page repartent de zéro à chaque fichier.
                    let offset = pages.count
                    for index in lines.indices { lines[index].pageIndex += offset }
                    allLines.append(contentsOf: lines)
                    // Une image par page, pour garder les index alignés sur les lignes.
                    let rendered = PDFPageRenderer.jpegPages(of: document)
                    pages.append(contentsOf: rendered)
                    pages.append(contentsOf: Array(repeating: Data(), count: max(0, document.pageCount - rendered.count)))
                }
                return ReadResult(lines: allLines, pages: pages, unreadable: unreadable)
            }.value
            guard !Task.isCancelled else { return }
            pageImages = result.pages
            pageCount = result.pages.count

            if result.lines.allSatisfy(\.isEmpty) {
                if result.unreadable == urls.count {
                    phase = .failed(urls.count == 1
                                    ? "Ce fichier n'a pas pu être ouvert comme PDF."
                                    : "Aucun de ces fichiers n'a pu être ouvert comme PDF.")
                } else {
                    drafts = []
                    phase = .noText
                }
                return
            }
            analyze(lines: result.lines, filename: filename)
        }
    }

    private func analyze(text: String) {
        pageImages = []
        pageCount = 0
        // Texte collé (Moodle, mail) : aucune information de police. L'analyse
        // retombe sur les motifs.
        analyze(lines: text.components(separatedBy: .newlines).map { PDFLayoutLine(text: $0) },
                filename: nil)
    }

    /// Le pipeline commun : ce que le document dit de lui, motifs tout de suite,
    /// IA ensuite, relecture toujours.
    private func analyze(lines: [PDFLayoutLine], filename: String?) {
        guard lines.contains(where: { !$0.isEmpty }) else {
            drafts = []
            phase = .noText
            return
        }

        preferredSeries = SeriesDocumentInference.seriesNumber(lines: lines, filename: filename)?.number
        if course == nil || selectedCourseID == nil,
           let detected = SeriesDocumentInference.course(
               in: lines, filename: filename,
               candidates: trackedCourses.map { .init(id: $0.id, code: $0.code, name: $0.name) }) {
            selectedCourseID = detected
            // Le `onChange` du sélecteur remet l'indicateur à faux : on le pose après.
            Task { @MainActor in courseWasDetected = true }
        }

        let parsed = SeriesLayoutParser.fillingStatements(SeriesLayoutParser.parse(lines, defaultSeries: preferredSeries), from: lines)
        localResult = parsed
        aiResult = nil
        apply(parsed)
        if drafts.isEmpty, let preferredSeries {
            // Rien de reconnu, mais le numéro est connu : une série vide à remplir.
            drafts = [SeriesDraft(number: preferredSeries, title: "", plannedWeek: defaultWeek(for: preferredSeries), exercises: [])]
            lastApplied = drafts
        }

        let hasLayout = lines.contains { $0.fontSize > 0 }
        let language = SeriesDocumentInference.languageName(of: lines.map(\.text).joined(separator: "\n"))
        documentLanguage = language
        aiInput = hasLayout
            ? SeriesAIParsing.prepareLayout(lines, seriesHint: preferredSeries, language: language)
            : (preferredSeries.map { "[Indice : ce document semble être la série \($0)]\n" } ?? "")
                + (SeriesDocumentInference.languageHint(language).map { $0 + "\n" } ?? "")
                + SeriesAIParsing.prepare(lines.map(\.text).joined(separator: "\n"))
        if settings.aiExtractionEnabled, SeriesAIExtractor.plannedSource(settings) != nil {
            phase = .analyzing
            runAI()
        } else {
            ai = .unavailable
            phase = .review
            Haptics.success()
        }
    }

    /// Demande au modèle de lire le document. Le résultat est fusionné : les
    /// exercices sûrs restent, les repères douteux doivent être confirmés.
    private func runAI() {
        guard !aiInput.isEmpty else { return }
        analysisTask?.cancel()
        ai = .running
        let input = aiInput
        let base = localResult
        let preferred = preferredSeries
        let language = documentLanguage
        let pages = pageImages.allSatisfy { !$0.isEmpty } ? pageImages : []
        analysisTask = Task {
            do {
                let result = try await SeriesAIExtractor.extract(prepared: input, pageImages: pages,
                                                                 seriesHint: preferred, language: language,
                                                                 settings: settings)
                guard !Task.isCancelled else { return }
                let merged = SeriesAIParsing.merge(heuristic: base, ai: result.series, preferredSeries: preferred,
                                                   aiReadsLayout: result.source.readsLayout)
                aiResult = merged
                let detail = summary(local: base, merged: merged, source: result.source)
                if phase == .review, hasEdited {
                    ai = merged == base ? .applied(detail) : .pending(detail)
                } else {
                    apply(merged)
                    ai = .applied(detail)
                }
                phase = .review
                Haptics.success()
            } catch {
                guard !Task.isCancelled else { return }
                // La lecture locale reste valable : on la garde, et on dit
                // pourquoi le modèle n'a rien ajouté.
                ai = .failed(error.localizedDescription)
                phase = .review
                AppLog.record(.warning, AppLog.Category.ai, "Analyse IA sans résultat",
                              detail: error.localizedDescription)
            }
        }
    }

    private func continueWithoutWaiting() {
        // L'IA continue ; son résultat sera proposé, pas imposé.
        phase = .review
        Haptics.tap()
    }

    private func cancelAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        ai = .failed("Analyse arrêtée.")
        phase = .review
        Haptics.removed()
    }

    private func summary(local: [DetectedSeries], merged: [DetectedSeries], source: SeriesExtractionSource) -> String {
        let before = local.reduce(0) { $0 + $1.exercises.count }
        let after = merged.reduce(0) { $0 + $1.exercises.count }
        let leaves = merged.flatMap(\.exercises).reduce(0) { $0 + max(1, $1.leafQuestionCount) }
        let changed = zip(local.flatMap(\.exercises), merged.flatMap(\.exercises))
            .filter { $0.number == $1.number && $0.subQuestions != $1.subQuestions }.count
        var parts = ["\(Plural.count(after, "\(after) exercice", "\(after) exercices")), \(leaves) cases"]
        if changed > 0 { parts.append("questions relues pour \(changed)") }
        if after > before { parts.append(Plural.count(after - before, "\(after - before) ajouté", "\(after - before) ajoutés")) }
        if after < before { parts.append(Plural.count(before - after, "\(before - after) repère douteux écarté", "\(before - after) repères douteux écartés")) }
        return parts.joined(separator: " · ") + " — \(source.label)"
    }

    // MARK: Brouillons

    private func apply(_ series: [DetectedSeries]) {
        drafts = series.map { detected in
            SeriesDraft(number: detected.number,
                        label: detected.label,
                        title: SeriesDocumentInference.seriesTitle(detected.title,
                                                                   courseName: selectedCourse?.name ?? "",
                                                                   courseCode: selectedCourse?.code ?? ""),
                        plannedWeek: defaultWeek(for: detected.number),
                        exercises: detected.exercises.enumerated().map { index, exercise in
                            var draft = ExerciseDraft(detected: exercise)
                            // L'aperçu s'arrête où commence l'exercice suivant, s'il est sur la même page.
                            let next = detected.exercises.dropFirst(index + 1).first
                            if let next, next.pageIndex == exercise.pageIndex {
                                draft.bottom = next.verticalPosition
                            }
                            return draft
                        })
        }
        lastApplied = drafts
    }

    /// La semaine où la série est prévue : son numéro, quand il tient dans le
    /// semestre — la série 4 se fait en semaine 4 — sinon la semaine en cours.
    private func defaultWeek(for number: Int) -> Int {
        let total = selectedCourse?.term?.totalWeeks ?? 14
        if (1...total).contains(number) { return number }
        return max(selectedCourse?.currentWeek ?? 1, 1)
    }

    // MARK: Création

    private func create() {
        guard let course = selectedCourse else { return }
        for draft in drafts where !draft.exercises.isEmpty {
            let written = SeriesDraftWriter.write(draft, to: course, mode: .importMerge, context: context)
            // Le PDF d'une seule série est gardé : le chrono et la fiche en
            // montrent l'énoncé exercice par exercice, même sans adresse.
            if drafts.filter({ !$0.exercises.isEmpty }).count == 1, sourceFiles.count == 1 {
                SeriesPDFStore.shared.keep(sourceFiles[0], for: written.series.id)
            }
        }
        do {
            try context.save()
            Haptics.success()
            dismiss()
        } catch {
            AppLog.record(.error, AppLog.Category.storage, "Import de série non enregistré",
                          detail: error.localizedDescription)
            saveError = "L'enregistrement a échoué : \(error.localizedDescription)"
        }
    }
}
