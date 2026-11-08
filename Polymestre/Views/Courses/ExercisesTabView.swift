import SwiftUI
import SwiftData

/// Exercices : séries, exercices, sous-questions et correction.
///
/// Tout le suivi se fait **dans la liste** : cocher un exercice ou ses
/// questions (visibles, avec leur texte), puis le corriger d'un toucher — vert,
/// orange, rouge. La fiche d'un exercice sert à lire (énoncé complet,
/// documents, indication, solution, théorie de la semaine) et au chrono.
struct ExercisesTabView: View {
    let course: Course

    @Environment(\.modelContext) private var context
    /// La série ouverte dans l'espace de travail, et l'exercice où l'ouvrir.
    @State private var workspace: WorkspaceTarget?
    @State private var editingSeries: SeriesEditTarget?
    @State private var showingPDFImport = false
    /// PDF d'une série importée de Moodle, téléchargé dans la session : il
    /// ouvre l'import avec le fichier déjà choisi.
    @State private var downloadedPDF: DownloadedPDF?
    @State private var downloadingSeries: UUID?
    @State private var downloadError: String?
    @Environment(AppContainer.self) private var app

    struct DownloadedPDF: Identifiable {
        let id = UUID()
        var url: URL
    }
    @State private var deletingSeries: ExerciseSeries?
    @State private var deletingExercise: Exercise?
    /// Séries dont l'étudiant·e a inversé le pliage par défaut (une série
    /// terminée rouverte, une série en cours repliée).
    @State private var toggledSeries: Set<UUID> = []
    /// Exercices dont l'étudiant·e a inversé l'affichage des questions : par
    /// défaut elles sont visibles tant que l'exercice n'est pas fait.
    @State private var toggledQuestions: Set<UUID> = []
    /// Un document ouvert dans l'app (énoncé, corrigé, théorie).
    @State private var browsing: BrowsedLink?
    /// La théorie d'une semaine, ouverte depuis une série.
    @State private var weekContext: WeekContextTarget?

    struct WeekContextTarget: Identifiable {
        let id = UUID()
        var week: Int
    }

    struct WorkspaceTarget: Identifiable {
        let id = UUID()
        var series: ExerciseSeries
        var start: Exercise?
    }

    /// Une série à modifier, ou une nouvelle (`series == nil`).
    struct SeriesEditTarget: Identifiable {
        let id = UUID()
        var series: ExerciseSeries?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            if course.series.isEmpty {
                EmptyCard(icon: TaskType.exercise.icon,
                          title: String(localized: "Aucune série"),
                          message: String(localized: "Depuis Moodle, ou le PDF d'une série."),
                          actionTitle: String(localized: "Importer depuis Moodle")) {
                    app.router.openContentImport(courseID: course.id)
                }
                HStack(spacing: Layout.control) {
                    Button {
                        showingPDFImport = true
                    } label: {
                        Label("Un PDF", systemImage: "doc.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    Button {
                        editingSeries = SeriesEditTarget(series: nil)
                    } label: {
                        Label("À la main", systemImage: "square.and.pencil")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .font(.subheadline)
            } else {
                // L'ajout **en haut**, mais discret : en semaine 12, importer la
                // série 12 obligeait à faire défiler onze séries terminées. Deux
                // gros boutons pleins, eux, faisaient concurrence au chrono de
                // la fiche — un menu suffit à un geste hebdomadaire.
                HStack(alignment: .firstTextBaseline) {
                    Text("Séries")
                        .font(.headline)
                    Text("\(course.series.count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Button { showingPDFImport = true } label: {
                            Label("Importer le PDF d'une série", systemImage: "doc.badge.plus")
                        }
                        Button { editingSeries = SeriesEditTarget(series: nil) } label: {
                            Label("Créer une série à la main", systemImage: "square.and.pencil")
                        }
                    } label: {
                        Label("Ajouter", systemImage: "plus.circle.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                    .accessibilityLabel("Ajouter une série")
                }
                .padding(.horizontal, Layout.micro)

                VStack(spacing: Layout.control) {
                    ForEach(course.sortedSeries) { series in
                        seriesCard(series)
                    }
                }

                legend
            }
        }
        .sheet(item: $workspace) { target in
            ExerciseWorkspace(series: target.series, start: target.start)
        }
        .sheet(item: $browsing) { link in
            InAppBrowser(link: link)
        }
        .sheet(item: $weekContext) { target in
            WeekTheorySheet(course: course, week: target.week)
        }
        #if DEBUG
        .onAppear {
            // Le simulateur ne sait pas taper : ce drapeau ouvre le détail d'un
            // exercice pour pouvoir le photographier.
            guard workspace == nil,
                  let wanted = PreviewLaunch.string(PreviewLaunch.exerciseDetailFlag) else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                if let exercise = course.sortedSeries
                    .flatMap(\.sortedExercises)
                    .first(where: { $0.exerciseNumber == wanted }),
                   let series = exercise.series {
                    workspace = WorkspaceTarget(series: series, start: exercise)
                }
            }
        }
        #endif
        .sheet(item: $editingSeries) { target in
            SeriesEditorSheet(course: course, series: target.series)
        }
        .sheet(isPresented: $showingPDFImport) {
            SeriesImportSheet(course: course)
        }
        .sheet(item: $downloadedPDF) { pdf in
            SeriesImportSheet(course: course, initialFileURL: pdf.url)
        }
        .alert("PDF inaccessible", isPresented: Binding(get: { downloadError != nil }, set: { if !$0 { downloadError = nil } })) {
            Button("Choisir le fichier") { showingPDFImport = true }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(downloadError ?? "")
        }
        .confirmationDialog("Supprimer « \(deletingSeries?.title ?? "") » ?",
                            isPresented: Binding(get: { deletingSeries != nil }, set: { if !$0 { deletingSeries = nil } }),
                            titleVisibility: .visible,
                            presenting: deletingSeries) { series in
            Button("Supprimer la série et ses \(series.exercises.count) exercices", role: .destructive) {
                context.delete(series)
                try? context.save()
                Haptics.removed()
            }
        } message: { series in
            let done = series.exercises.filter(\.isDone).count
            Text(done > 0 ? "\(Plural.count(done, "\(done) exercice déjà fait", "\(done) exercices déjà faits")) seront perdus." : "Aucun exercice n'est encore fait.")
        }
        .confirmationDialog("Supprimer l'exercice \(deletingExercise?.exerciseNumber ?? "") ?",
                            isPresented: Binding(get: { deletingExercise != nil }, set: { if !$0 { deletingExercise = nil } }),
                            titleVisibility: .visible,
                            presenting: deletingExercise) { exercise in
            Button("Supprimer", role: .destructive) {
                context.delete(exercise)
                try? context.save()
                Haptics.removed()
            }
        } message: { exercise in
            Text(exercise.isDone ? "Il est marqué fait : son avancement sera perdu." : "Ses questions seront supprimées avec lui.")
        }
    }

    /// La légende : la coche marque « fait », la couleur la **correction**.
    private var legend: some View {
        VStack(alignment: .leading, spacing: Layout.snug) {
            HStack(spacing: Layout.block) {
                legendItem(.toDo, String(localized: "à faire"))
                legendItem(.toCorrect, String(localized: "fait, à corriger"))
                legendItem(.redo, String(localized: "à refaire"))
                Spacer(minLength: 0)
            }
            HStack(spacing: Layout.block) {
                Text("Correction").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                legendItem(.corrected(.correct), "juste")
                legendItem(.corrected(.partial), "moyen")
                legendItem(.corrected(.wrong), "faux")
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, Layout.micro)
        .accessibilityHidden(true)
    }

    private func legendItem(_ stage: ExerciseStage, _ label: String) -> some View {
        HStack(spacing: Layout.snug) {
            ExerciseStageMark(stage: stage, size: 14)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Une série terminée — sans rien « à refaire » — se replie en une ligne :
    /// ce qui reste à faire remonte, ce qui est fait ne disparaît pas.
    private func isCollapsed(_ series: ExerciseSeries) -> Bool {
        let collapsedByDefault = series.isComplete && !series.exercises.contains(where: \.redoRequired)
        return collapsedByDefault != toggledSeries.contains(series.id)
    }

    private func toggleCollapsed(_ series: ExerciseSeries) {
        withAnimation(Motion.snappy) {
            if toggledSeries.contains(series.id) {
                toggledSeries.remove(series.id)
            } else {
                toggledSeries.insert(series.id)
            }
        }
        Haptics.soft()
    }

    /// Une série, repliée ou dépliée : **le même en-tête** dans les deux cas.
    ///
    /// La série repliée était une ligne à part, avec son propre dessin, et la
    /// dépliée une carte à barre de progression : deux objets pour une seule
    /// chose. L'en-tête porte maintenant l'avancement (un anneau, ou le sceau
    /// d'une série finie), et toucher l'en-tête plie ou déplie.
    private func seriesCard(_ series: ExerciseSeries) -> some View {
        let collapsed = isCollapsed(series)
        return VStack(alignment: .leading, spacing: 0) {
            seriesHeader(series, collapsed: collapsed)

            if !collapsed {
                seriesBody(series)
                    .padding(.horizontal, Layout.gutter)
                    .padding(.bottom, Layout.block)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Theme.softBackground, in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
    }

    private func seriesHeader(_ series: ExerciseSeries, collapsed: Bool) -> some View {
        HStack(spacing: Layout.block) {
            Button {
                toggleCollapsed(series)
            } label: {
                HStack(spacing: Layout.block) {
                    Group {
                        if series.isComplete {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.title3)
                                .foregroundStyle(Color.green.accessibleMark)
                        } else {
                            ProgressRing(progress: series.progress,
                                         color: TaskType.exercise.tint,
                                         size: 28,
                                         lineWidth: 4,
                                         showsLabel: false)
                        }
                    }
                    .frame(width: 30)

                    VStack(alignment: .leading, spacing: Layout.micro) {
                        Text(series.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(seriesSubtitle(series))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: Layout.inline)
                    Text("\(series.doneCount)/\(series.requiredExercises.count)")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(collapsed ? 0 : 180))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(series.title), \(series.doneCount) sur \(series.requiredExercises.count)")
            .accessibilityHint(collapsed ? "Afficher les exercices" : "Replier la série")

            Menu {
                seriesMenuItems(series)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: Layout.minTouch)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Actions sur \(series.title)")
        }
        .padding(.leading, Layout.gutter)
        .padding(.trailing, Layout.control)
        .padding(.vertical, Layout.tight)
        .contextMenu { seriesMenuItems(series) }
    }

    @ViewBuilder
    private func seriesBody(_ series: ExerciseSeries) -> some View {
        VStack(alignment: .leading, spacing: Layout.block) {
                Divider()

                if series.exercises.isEmpty, SeriesAutoReader.shared.reading.contains(series.id) {
                    HStack(spacing: Layout.inline) {
                        ProgressView()
                        Text("Lecture de l'énoncé…").font(.subheadline).foregroundStyle(.secondary)
                    }
                } else if series.exercises.isEmpty {
                    // Une série venue de Moodle connaît son PDF : un tap le lit.
                    if let url = URL(string: series.urlString), !series.urlString.isEmpty {
                        Button {
                            Task { await readPDF(of: series, at: url) }
                        } label: {
                            HStack(spacing: Layout.inline) {
                                if downloadingSeries == series.id { ProgressView() }
                                Label("Lire les exercices dans le PDF", systemImage: "doc.text.magnifyingglass")
                            }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.carnetPrimary)
                        .disabled(downloadingSeries != nil)
                    }
                    Button {
                        editingSeries = SeriesEditTarget(series: series)
                    } label: {
                        Label("Saisir les exercices à la main", systemImage: "plus.circle")
                            .font(.subheadline)
                    }
                    .buttonStyle(.borderless)
                }

                seriesDocuments(series)

                VStack(spacing: 0) {
                    ForEach(series.sortedExercises) { exercise in
                        ExerciseRow(exercise: exercise,
                                    seconds: ExerciseFlow.seconds(on: exercise),
                                    showsQuestions: showsQuestions(exercise),
                                    onToggleDone: { toggleDone(exercise) },
                                    onCorrect: { result in correct(exercise, result) },
                                    onToggleQuestions: { toggleQuestions(exercise) },
                                    onToggleQuestion: { question in
                                        question.toggle()
                                        Haptics.tap()
                                        try? context.save()
                                    },
                                    onOpen: { workspace = WorkspaceTarget(series: series, start: exercise) })
                        .contextMenu {
                            Button { workspace = WorkspaceTarget(series: series, start: exercise) } label: {
                                Label("Ouvrir la fiche", systemImage: "doc.text")
                            }
                            StudyModeMenu(courseID: course.id, targetID: exercise.id)
                            Button { editingSeries = SeriesEditTarget(series: series) } label: {
                                Label("Modifier la série…", systemImage: "pencil")
                            }
                            Button(role: .destructive) { deletingExercise = exercise } label: {
                                Label("Supprimer l'exercice", systemImage: "trash")
                            }
                        }
                        if exercise.id != series.sortedExercises.last?.id {
                            Divider().padding(.leading, Layout.minTouch)
                        }
                    }
                }
        }
    }

    /// Les documents de la série et la théorie de sa semaine, en pastilles :
    /// l'énoncé, le corrigé, et « Théorie S3 » — de quoi s'y remettre sans
    /// quitter la liste.
    @ViewBuilder
    private func seriesDocuments(_ series: ExerciseSeries) -> some View {
        let links = ExerciseLinks.seriesLinks(series)
        let theory = series.plannedWeek > 0 ? course.theoryItems.filter { $0.plannedWeek == series.plannedWeek }.count : 0
        if !links.isEmpty || theory > 0 {
            FlowLayout(spacing: Layout.inline) {
                ForEach(links) { link in
                    Button { browsing = link } label: {
                        documentChip(link.title, icon: link.icon)
                    }
                    .buttonStyle(.plain)
                }
                if theory > 0 {
                    Button { weekContext = WeekContextTarget(week: series.plannedWeek) } label: {
                        documentChip(String(localized: "Théorie S\(series.plannedWeek) · \(theory)"), icon: TaskType.theory.icon)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func documentChip(_ title: String, icon: String) -> some View {
        HStack(spacing: Layout.snug) {
            Image(systemName: icon).font(.caption.weight(.semibold))
            Text(title).font(.caption.weight(.semibold)).lineLimit(1)
        }
        .padding(.horizontal, Layout.control)
        .frame(minHeight: 30)
        .background(Color(.tertiarySystemFill), in: Capsule())
        .foregroundStyle(Theme.accentInk)
        .contentShape(Capsule())
    }

    @MainActor
    private func readPDF(of series: ExerciseSeries, at url: URL) async {
        downloadingSeries = series.id
        defer { downloadingSeries = nil }
        do {
            downloadedPDF = DownloadedPDF(url: try await AuthenticatedDownloader.download(url))
        } catch {
            downloadError = String(localized: "\(error.localizedDescription) Reconnecte-toi à Moodle depuis « Importer du contenu », ou choisis le fichier toi-même.")
        }
    }

    private func seriesSubtitle(_ series: ExerciseSeries) -> String {
        var parts = [series.plannedWeek > 0 ? String(localized: "Semaine \(series.plannedWeek)") : String(localized: "Sans semaine")]
        if series.exercises.isEmpty { parts.append(String(localized: "exercices à importer")) }
        if let due = series.dueDate { parts.append(String(localized: "à rendre le \(DateUtils.shortDay.string(from: due))")) }
        if !series.bonusExercises.isEmpty { parts.append("\(series.bonusExercises.count) bonus") }
        let spent = ExerciseFlow.seconds(on: series)
        if spent >= 60 { parts.append(DateUtils.hoursLabel(seconds: spent)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func seriesMenuItems(_ series: ExerciseSeries) -> some View {
        if !series.exercises.isEmpty {
            StudyModeMenu(courseID: course.id,
                          targetID: (series.sortedExercises.first { !$0.isDone } ?? series.sortedExercises.first)?.id)
            Divider()
        }
        Button { editingSeries = SeriesEditTarget(series: series) } label: {
            Label("Modifier la série…", systemImage: "pencil")
        }
        Button { showingPDFImport = true } label: {
            Label("Réimporter un PDF…", systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard")
        }
        if !series.exercises.isEmpty {
            if series.exercises.allSatisfy(\.isDone) {
                Button { setAll(series, done: false) } label: {
                    Label("Tout décocher", systemImage: "circle")
                }
            } else {
                Button { setAll(series, done: true) } label: {
                    Label("Tout marquer fait", systemImage: "checkmark.circle")
                }
            }
        }
        Divider()
        Button(role: .destructive) { deletingSeries = series } label: {
            Label("Supprimer la série…", systemImage: "trash")
        }
    }

    private func setAll(_ series: ExerciseSeries, done: Bool) {
        for exercise in series.exercises {
            exercise.setDone(done)
        }
        Haptics.success()
        try? context.save()
    }

    private func showsQuestions(_ exercise: Exercise) -> Bool {
        let byDefault = !ExerciseStage(exercise).isDone
        return byDefault != toggledQuestions.contains(exercise.id)
    }

    private func toggleQuestions(_ exercise: Exercise) {
        withAnimation(Motion.snappy) {
            if toggledQuestions.contains(exercise.id) {
                toggledQuestions.remove(exercise.id)
            } else {
                toggledQuestions.insert(exercise.id)
            }
        }
        Haptics.soft()
    }

    /// Cocher l'exercice (et ses questions) ; décocher efface sa correction.
    private func toggleDone(_ exercise: Exercise) {
        exercise.setDone(!exercise.isDone)
        // Pas de vibration ici : le glyphe d'étape a déjà la sienne.
        try? context.save()
    }

    /// La couleur de la correction. Corriger un exercice le marque fait.
    private func correct(_ exercise: Exercise, _ result: Correctness?) {
        if let result {
            exercise.correct(result)
            if result == .wrong { Haptics.error() } else { Haptics.success() }
        } else {
            exercise.clearCorrection()
        }
        try? context.save()
    }
}

/// La théorie d'une semaine du cours, chaque élément ouvrable.
struct WeekTheorySheet: View {
    let course: Course
    let week: Int

    @Environment(\.dismiss) private var dismiss
    @State private var browsing: BrowsedLink?

    var body: some View {
        NavigationStack {
            List {
                ForEach(course.sortedTheoryItems.filter { $0.plannedWeek == week }) { item in
                    TheoryLinkRow(item: item) { browsing = $0 }
                }
            }
            .carnetBackground()
            .navigationTitle("\(course.displayCode) · semaine \(week)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
            }
            .sheet(item: $browsing) { InAppBrowser(link: $0) }
        }
        .presentationDetents([.medium, .large])
    }
}

