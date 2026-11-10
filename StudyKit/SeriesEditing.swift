import SwiftUI
import ImageIO
import SwiftData

// MARK: - Formulaire d'une série

/// Les sections d'une série en brouillon, à placer dans une `List`.
///
/// Sert **à la fois** à relire un import et à modifier une série enregistrée :
/// mêmes gestes partout — toucher un exercice pour l'ouvrir, glisser pour le
/// supprimer, « Modifier » pour réordonner.
struct SeriesDraftForm: View {
    @Binding var draft: SeriesDraft
    /// Numéros et étiquettes des autres séries du cours, pour signaler un doublon.
    var taken: Set<SeriesIdentity.Key> = []
    var maxWeek: Int = 14
    /// Série du même numéro déjà présente (import seulement).
    var mergesInto: ExerciseSeries?
    /// Ouvre l'aperçu d'un exercice dans le PDF importé.
    var showSource: ((ExerciseDraft) -> Void)?

    var body: some View {
        let problems = draft.problems(taken: taken)
        Section {
            Stepper(value: $draft.number, in: 1...60) {
                LabeledContent("Série", value: "\(draft.number)")
            }
            // Deux séries la même semaine : « a » et « b », « mardi » et « jeudi ».
            TextField("Étiquette (b, jeudi… facultatif)", text: $draft.label)
                .autocorrectionDisabled()
            TextField("Titre (facultatif)", text: $draft.title)
            Stepper(value: $draft.plannedWeek, in: 1...max(maxWeek, draft.plannedWeek)) {
                LabeledContent("Semaine prévue", value: "\(draft.plannedWeek)")
            }
            Toggle("À rendre", isOn: Binding(
                get: { draft.dueDate != nil },
                set: { draft.dueDate = $0 ? (draft.dueDate ?? Calendar.current.date(byAdding: .day, value: 7, to: Date())) : nil }))
            if let due = draft.dueDate {
                DatePicker("Échéance", selection: Binding(get: { due }, set: { draft.dueDate = $0 }),
                           displayedComponents: [.date, .hourAndMinute])
            }
        } header: {
            Text("Série")
        } footer: {
            if let mergesInto {
                Text("La \(mergesInto.displayName) existe déjà (\(mergesInto.exercises.count) exercices) : les exercices de même numéro sont mis à jour, les autres ajoutés. Tes coches sont conservées.")
            }
        }

        Section {
            ForEach($draft.exercises) { $exercise in
                NavigationLink {
                    ExerciseDraftEditor(exercise: $exercise,
                                        seriesNumber: draft.number,
                                        showSource: showSource.map { show in { show(exercise) } })
                } label: {
                    ExerciseDraftSummary(exercise: exercise, seriesNumber: draft.number,
                                         canShowSource: showSource != nil && exercise.pageIndex != nil)
                }
                .swipeActions(edge: .leading) {
                    Button {
                        exercise.isBonus.toggle()
                    } label: {
                        Label(exercise.isBonus ? "Obligatoire" : "Bonus", systemImage: exercise.isBonus ? "star.slash" : "star")
                    }
                    .tint(.orange)
                }
            }
            .onDelete { draft.exercises.remove(atOffsets: $0) }
            .onMove { draft.exercises.move(fromOffsets: $0, toOffset: $1) }

            Menu {
                Button("1 exercice") { add(1) }
                Button("3 exercices") { add(3) }
                Button("5 exercices") { add(5) }
                Button("10 exercices") { add(10) }
                if draft.exercises.count > 1 {
                    Divider()
                    Button {
                        draft.renumberExercises()
                    } label: {
                        Label("Renuméroter \(draft.number).1, \(draft.number).2…", systemImage: "list.number")
                    }
                }
            } label: {
                Label("Ajouter des exercices", systemImage: "plus.circle.fill")
            } primaryAction: {
                add(1)
            }
        } header: {
            HStack {
                Text("Exercices")
                Spacer()
                Text("\(draft.exercises.count) · \(Plural.count(draft.leafCount, "\(draft.leafCount) case", "\(draft.leafCount) cases"))")
                    .monospacedDigit()
            }
        } footer: {
            if !problems.isEmpty {
                Label(problems.joined(separator: "\n"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange.accessibleInk)
            } else if draft.exercises.isEmpty {
                Text("Aucun exercice.")
            }
        }
    }

    private func add(_ count: Int) {
        for _ in 0..<count { draft.addExercise() }
        Haptics.tap()
    }
}

/// Une ligne d'exercice en brouillon : numéro, intitulé, structure des questions.
struct ExerciseDraftSummary: View {
    let exercise: ExerciseDraft
    let seriesNumber: Int
    var canShowSource = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Layout.control) {
            Text("\(seriesNumber).\(exercise.minor.isEmpty ? "?" : exercise.minor)")
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(exercise.minor.isEmpty ? Color.orange.accessibleInk : .primary)
                .frame(minWidth: 40, alignment: .leading)
            VStack(alignment: .leading, spacing: Layout.micro) {
                HStack(spacing: Layout.snug) {
                    MathText(exercise.title.isEmpty ? String(localized: "Sans titre") : exercise.title, font: .subheadline)
                        .foregroundStyle(exercise.title.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                    if exercise.isBonus {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.orange.accessibleMark)
                            .accessibilityLabel("bonus")
                    }
                    if exercise.isDone {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.green.accessibleMark)
                            .accessibilityLabel("fait")
                    }
                }
                if !exercise.statement.isEmpty {
                    MathText(exercise.statement, font: .caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(exercise.subQuestions.isEmpty
                     ? "Un bloc, sans sous-question"
                     : "\(exercise.leafCount) cases · \(SubQuestionTree.outline(exercise.subQuestions))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if canShowSource {
                Image(systemName: "doc.viewfinder")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Éditeur d'exercice

/// Un exercice, sur une page entière : identité, plan, questions.
///
/// Les questions s'éditent **à plat** — une ligne par question ou point —, et la
/// structure se change par des gestes : glisser vers la droite pour faire d'une
/// question un point de la précédente (ou l'inverse), vers la gauche pour
/// supprimer. Le plan en une ligne (« 1(a-d) 2(a-e) + ») reconstruit tout
/// l'arbre d'un coup.
struct ExerciseDraftEditor: View {
    @Binding var exercise: ExerciseDraft
    let seriesNumber: Int
    var showSource: (() -> Void)?

    @State private var outline = ""
    @State private var outlineError = false
    @FocusState private var outlineFocused: Bool

    var body: some View {
        List {
            Section {
                LabeledContent("Numéro") {
                    HStack(spacing: 0) {
                        Text("\(seriesNumber).").foregroundStyle(.secondary)
                        TextField("n°", text: $exercise.minor)
                            
                            .frame(width: 48)
                    }
                    .font(.body.monospacedDigit())
                }
                TextField("Intitulé (facultatif)", text: $exercise.title)
                TextField("Énoncé : ce qu'il faut faire", text: $exercise.statement, axis: .vertical)
                    .lineLimit(1...4)
                // Aperçu rendu : on écrit « a_n », on lit aₙ.
                if MathMarkup.hasMarkup(exercise.statement) {
                    MathText(exercise.statement, font: .subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityHint("Aperçu de l'énoncé")
                }
                Toggle(isOn: $exercise.isBonus) {
                    Label("Bonus", systemImage: "star")
                }
                if let showSource {
                    Button(action: showSource) {
                        Label("Voir dans le PDF", systemImage: "doc.viewfinder")
                    }
                }
            }

            Section {
                HStack {
                    TextField("1(a-d) 2(a-e) 3 +", text: $outline)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .noAutocapitalization()
                        .focused($outlineFocused)
                        .submitLabel(.done)
                        .onSubmit(applyOutline)
                    if outlineFocused {
                        Button("Appliquer", action: applyOutline)
                            .buttonStyle(.borderless)
                            .fontWeight(.semibold)
                    }
                }
            } header: {
                Text("Plan rapide")
            } footer: {
                if outlineError {
                    Text("Plan illisible. Exemples : « 1-4 », « 1(a-c) 2 3(a,b) », « + » pour une partie sans numéro.")
                        .foregroundStyle(Color.orange.accessibleInk)
                } else {
                    Text("Comme sur la feuille : « 1(a-d) 2 3(a,b) ».")
                }
            }

            Section {
                let rows = SubQuestionTree.rows(exercise.subQuestions)
                ForEach(rows) { row in
                    SubQuestionDraftRow(row: row, question: binding(for: row.id))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                mutate { SubQuestionTree.remove(row.id, from: &$0) }
                            } label: {
                                Label("Supprimer", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            if row.canIndent {
                                Button {
                                    mutate { SubQuestionTree.indent(row.id, in: &$0) }
                                } label: {
                                    Label("En point", systemImage: "increase.indent")
                                }
                                .tint(Theme.accent)
                            }
                            if row.canOutdent {
                                Button {
                                    mutate { SubQuestionTree.outdent(row.id, in: &$0) }
                                } label: {
                                    Label("En question", systemImage: "decrease.indent")
                                }
                                .tint(.indigo)
                            }
                            if row.depth == 0, row.question.kind == .question {
                                Button {
                                    mutate { SubQuestionTree.addChild(to: row.id, in: &$0) }
                                } label: {
                                    Label("Point", systemImage: "plus")
                                }
                                .tint(.teal)
                            }
                        }
                        .contextMenu {
                            if row.depth == 0, row.question.kind == .question {
                                Button { mutate { SubQuestionTree.addChild(to: row.id, in: &$0) } } label: {
                                    Label("Ajouter un point", systemImage: "plus")
                                }
                            }
                            if row.canIndent {
                                Button { mutate { SubQuestionTree.indent(row.id, in: &$0) } } label: {
                                    Label("Point de la question précédente", systemImage: "increase.indent")
                                }
                            }
                            if row.canOutdent {
                                Button { mutate { SubQuestionTree.outdent(row.id, in: &$0) } } label: {
                                    Label("Remonter en question", systemImage: "decrease.indent")
                                }
                            }
                            Button(role: .destructive) { mutate { SubQuestionTree.remove(row.id, from: &$0) } } label: {
                                Label("Supprimer", systemImage: "trash")
                            }
                        }
                }

                HStack(spacing: Layout.gutter) {
                    Button {
                        mutate { SubQuestionTree.addQuestion(to: &$0) }
                    } label: {
                        Label("Question", systemImage: "plus.circle.fill")
                    }
                    Button {
                        mutate { $0.append(DetectedSubQuestion(label: "", kind: .part)) }
                    } label: {
                        Label("Partie", systemImage: "text.badge.plus")
                    }
                    Spacer(minLength: 0)
                    if exercise.subQuestions.count > 1 {
                        Button {
                            mutate { SubQuestionTree.relabel(&$0) }
                        } label: {
                            Image(systemName: "list.number")
                        }
                        .accessibilityLabel("Renuméroter 1, 2, 3 et a, b, c")
                    }
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
            } header: {
                HStack {
                    Text("Questions")
                    Spacer()
                    if !exercise.subQuestions.isEmpty {
                        Text(Plural.count(exercise.leafCount, "\(exercise.leafCount) case", "\(exercise.leafCount) cases")).monospacedDigit()
                    }
                }
            } footer: {
                if exercise.subQuestions.isEmpty {
                    Text("Sans sous-question, l'exercice se coche d'un bloc.")
                }
            }
        }
        .carnetBackground()
        .navigationTitle("Exercice \(seriesNumber).\(exercise.minor)")
        .inlineTitle()
        .onAppear { outline = SubQuestionTree.outline(exercise.subQuestions) }
        .onChange(of: exercise.subQuestions) { _, new in
            if !outlineFocused { outline = SubQuestionTree.outline(new) }
        }
        .animation(Motion.snappy, value: exercise.subQuestions.map(\.id))
    }

    private func applyOutline() {
        guard let parsed = SubQuestionTree.parse(outline, keeping: exercise.subQuestions) else {
            outlineError = true
            Haptics.warning()
            return
        }
        outlineError = false
        exercise.subQuestions = parsed
        outlineFocused = false
        Haptics.success()
    }

    private func mutate(_ change: (inout [DetectedSubQuestion]) -> Void) {
        change(&exercise.subQuestions)
        Haptics.tap()
    }

    private func binding(for id: UUID) -> Binding<DetectedSubQuestion> {
        Binding(get: {
            SubQuestionTree.rows(exercise.subQuestions).first { $0.id == id }?.question ?? DetectedSubQuestion(label: "")
        }, set: { new in
            SubQuestionTree.update(id, in: &exercise.subQuestions) { $0 = new }
        })
    }
}

/// Une question ou un point : étiquette et énoncé, décalé selon le niveau.
private struct SubQuestionDraftRow: View {
    let row: SubQuestionTree.Row
    @Binding var question: DetectedSubQuestion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Layout.inline) {
            if row.depth == 1 {
                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 2, height: 18)
                    .padding(.leading, Layout.control)
            }
            if question.kind == .part {
                Image(systemName: "text.alignleft")
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .leading)
                    .accessibilityLabel("Partie sans numéro")
            } else {
                TextField("n°", text: $question.label)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .frame(width: 36)
                    .accessibilityLabel(row.depth == 0 ? "Étiquette de la question" : "Étiquette du point")
            }
            TextField(question.kind == .part ? "Consigne (ex. Ensuite, représenter…)" : "Énoncé (facultatif)",
                      text: $question.text, axis: .vertical)
                .font(.subheadline)
                .lineLimit(1...4)
        }
    }
}

// MARK: - Modifier une série enregistrée

/// Modifier une série déjà enregistrée — ou en créer une à la main.
///
/// Auparavant une série ne se modifiait **nulle part** : ni son titre, ni sa
/// semaine, ni sa suppression ; un exercice ne se supprimait qu'au fond de sa
/// fiche. Tout passe maintenant par cet écran, le même que la relecture d'import.
struct SeriesEditorSheet: View {
    let course: Course
    /// `nil` : nouvelle série, créée à la main.
    let series: ExerciseSeries?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var draft: SeriesDraft
    @State private var confirmingDelete = false
    @State private var confirmingLoss = false

    init(course: Course, series: ExerciseSeries?) {
        self.course = course
        self.series = series
        if let series {
            _draft = State(initialValue: SeriesDraft(series: series))
        } else {
            let number = (course.series.map(\.seriesNumber).max() ?? 0) + 1
            var draft = SeriesDraft(number: number, title: "", plannedWeek: max(course.currentWeek, 1), exercises: [])
            for _ in 0..<3 { draft.addExercise() }
            _draft = State(initialValue: draft)
        }
    }

    private var taken: Set<SeriesIdentity.Key> {
        Set(course.series.filter { $0.id != series?.id }.map(\.key))
    }

    /// Exercices faits qui disparaîtraient à l'enregistrement.
    private var lostDone: [Exercise] {
        guard let series else { return [] }
        let kept = Set(draft.exercises.compactMap(\.existingID))
        return series.exercises.filter { !kept.contains($0.id) && $0.isDone }
    }

    var body: some View {
        NavigationStack {
            List {
                SeriesDraftForm(draft: $draft,
                                taken: taken,
                                maxWeek: course.term?.totalWeeks ?? 14)
                if series != nil {
                    Section {
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            Label("Supprimer la série", systemImage: "trash")
                        }
                    }
                }
            }
            .groupedList()
            .scrollDismissesKeyboard(.interactively)
            .carnetBackground()
            .navigationTitle(series == nil ? "Nouvelle série" : "Modifier la série")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(series == nil ? "Créer" : "Enregistrer") {
                        if lostDone.isEmpty { save() } else { confirmingLoss = true }
                    }
                    .fontWeight(.semibold)
                    .disabled(!draft.problems(taken: taken).isEmpty)
                }
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                #endif
            }
            .confirmationDialog("Supprimer la série \(draft.number) ?", isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
                Button("Supprimer la série et ses \(series?.exercises.count ?? 0) exercices", role: .destructive) {
                    deleteSeries()
                }
            } message: {
                let done = series?.exercises.filter(\.isDone).count ?? 0
                Text(done > 0 ? "\(Plural.count(done, "\(done) exercice déjà fait", "\(done) exercices déjà faits")) seront perdus." : "Aucun exercice n'est encore fait.")
            }
            .confirmationDialog("Supprimer \(Plural.count(lostDone.count, "\(lostDone.count) exercice déjà fait", "\(lostDone.count) exercices déjà faits")) ?",
                                isPresented: $confirmingLoss, titleVisibility: .visible) {
                Button("Enregistrer quand même", role: .destructive) { save() }
            } message: {
                Text(lostDone.map(\.exerciseNumber).joined(separator: ", ") + " : leur avancement sera perdu.")
            }
        }
    }

    private func save() {
        SeriesDraftWriter.write(draft, to: course, mode: .edit, context: context)
        do {
            try context.save()
            Haptics.success()
            dismiss()
        } catch {
            AppLog.record(.error, AppLog.Category.storage, "Série non enregistrée", detail: error.localizedDescription)
        }
    }

    private func deleteSeries() {
        guard let series else { return }
        context.delete(series)
        try? context.save()
        Haptics.removed()
        dismiss()
    }
}

// MARK: - Aperçu du PDF

/// Ce que l'aperçu montre : une page, et la bande où se trouve l'exercice.
struct SourcePreview: Identifiable {
    let id = UUID()
    var title: String
    var page: Int
    var top: Double?
    var bottom: Double?
}

/// La page du PDF, cadrée sur l'exercice : on compare à la vraie feuille au lieu
/// de faire confiance à la lecture.
struct SourcePreviewSheet: View {
    let preview: SourcePreview
    let pages: [Data]
    @Environment(\.dismiss) private var dismiss
    @State private var showWholePage = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFit()
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
                        .padding()
                        .accessibilityLabel("Page \(preview.page + 1) du PDF")
                } else {
                    ContentUnavailableView("Page indisponible", systemImage: "doc")
                }
            }
            .background(Theme.softBackground)
            .carnetBackground()
            .navigationTitle(preview.title)
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
                ToolbarItem(placement: Self.bottomPlacement) {
                    Toggle("Page entière", isOn: $showWholePage)
                        .toggleStyle(.button)
                        .disabled(preview.top == nil)
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }

    #if os(iOS)
    private static let bottomPlacement = ToolbarItemPlacement.bottomBar
    #else
    private static let bottomPlacement = ToolbarItemPlacement.automatic
    #endif

    private var image: PlatformImage? {
        guard preview.page < pages.count,
              let source = CGImageSourceCreateWithData(pages[preview.page] as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        guard !showWholePage, let top = preview.top else { return Self.image(cg) }
        let height = Double(cg.height)
        let start = max(0, top - 0.02)
        let end = min(1, max(start + 0.12, (preview.bottom ?? min(1, top + 0.45)) + 0.01))
        let rect = CGRect(x: 0, y: start * height, width: Double(cg.width), height: (end - start) * height)
        guard let cropped = cg.cropping(to: rect.integral) else { return Self.image(cg) }
        return Self.image(cropped)
    }

    private static func image(_ cg: CGImage) -> PlatformImage {
        #if os(iOS)
        UIImage(cgImage: cg)
        #else
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #endif
    }
}
