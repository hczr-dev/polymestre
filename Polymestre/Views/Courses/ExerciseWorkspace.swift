import SwiftUI
import SwiftData
import WebKit

// MARK: - Étape et correction

/// L'étape d'un exercice, en un glyphe : cercle vide (à faire), anneau qui se
/// remplit (questions en cours), coche (fait, à corriger), puis la **couleur de
/// la correction** — vert juste, orange moyen, rouge faux — et ↺ à refaire.
/// La teinte ne porte jamais le sens seule : chaque état a son glyphe.
struct ExerciseStageMark: View {
    let stage: ExerciseStage
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            switch stage {
            case .toDo:
                Circle().strokeBorder(Carnet.inkTertiary, lineWidth: 1.8)
            case .inProgress(let done, let total):
                Circle().stroke(Carnet.rule, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: Double(done) / Double(max(total, 1)))
                    .stroke(Carnet.ink, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            case .toCorrect:
                filled(Carnet.ink, glyph: "checkmark")
            case .corrected(let result):
                filled(Carnet.color(for: result), glyph: result.glyph)
            case .redo:
                Circle().strokeBorder(Carnet.wrong, lineWidth: 2)
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(Carnet.wrong)
            }
        }
        .frame(width: size, height: size)
        .animation(Motion.snappy, value: stage)
    }

    private func filled(_ tint: Color, glyph: String) -> some View {
        ZStack {
            Circle().fill(tint)
            Image(systemName: glyph)
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(Carnet.sheet)
        }
    }
}

extension Correctness {
    /// Le glyphe de la pastille : ✓, ~, ✗.
    var glyph: String {
        switch self {
        case .correct: return "checkmark"
        case .partial: return "minus"
        case .wrong: return "xmark"
        }
    }
}

extension ExerciseStage {
    /// La teinte du libellé d'étape.
    var tint: Color {
        switch self {
        case .toDo: return .secondary
        case .inProgress: return TaskType.exercise.tint
        case .toCorrect: return TaskType.correction.tint
        case .corrected(let result): return result.color
        case .redo: return .red
        }
    }
}

/// Les trois pastilles de correction d'une ligne : vert, orange, rouge.
///
/// Toujours au même endroit, à droite de l'exercice, et **un** toucher corrige :
/// pas de fiche à ouvrir. Toucher la pastille déjà choisie retire la
/// correction. Chaque pastille porte son glyphe (✓ ~ ✗) : vert-orange-rouge est
/// exactement la triade que le daltonisme confond.
struct CorrectionDots: View {
    var value: Correctness?
    var onChange: (Correctness?) -> Void

    @ScaledMetric(relativeTo: .body) private var dot: CGFloat = 22

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Correctness.allCases) { option in
                let isOn = value == option
                Button {
                    Haptics.soft()
                    onChange(isOn ? nil : option)
                } label: {
                    ZStack {
                        Circle().fill(isOn ? Carnet.color(for: option) : Carnet.color(for: option).opacity(0.14))
                        Image(systemName: option.glyph)
                            .font(.system(size: dot * 0.45, weight: .bold))
                            .foregroundStyle(isOn ? Carnet.sheet : Carnet.color(for: option))
                    }
                    .frame(width: dot, height: dot)
                    .opacity(value == nil || isOn ? 1 : 0.45)
                    .frame(width: dot + 12, height: Layout.minTouch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Correction : \(option.label)")
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
        .animation(Motion.snappy, value: value)
    }
}

/// La même chose en grand, pour la fiche d'un exercice.
struct CorrectionPicker: View {
    var value: Correctness?
    var onChange: (Correctness?) -> Void

    var body: some View {
        HStack(spacing: Layout.inline) {
            ForEach(Correctness.allCases) { option in
                let isOn = value == option
                Button {
                    Haptics.soft()
                    onChange(isOn ? nil : option)
                } label: {
                    HStack(spacing: Layout.snug) {
                        Image(systemName: option.glyph).font(.caption.weight(.bold))
                        Text(option.lineLabel.capitalizedFirst).font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(isOn ? Carnet.color(for: option) : Carnet.sheet,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(isOn ? Carnet.sheet : Carnet.color(for: option))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(scale: 0.96))
                .accessibilityLabel("Correction : \(option.label)")
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
    }
}

// MARK: - Sous-questions

/// Une sous-question, cochable d'un toucher sur toute la ligne, avec son texte.
struct SubQuestionRow: View {
    let question: SubQuestion
    var fullText = false
    var onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .firstTextBaseline, spacing: Layout.inline) {
                Image(systemName: question.isDone ? "checkmark.circle.fill" : "circle")
                    .font(question.parent == nil ? .body : .subheadline)
                    .foregroundStyle(question.isDone ? Color.green.accessibleMark : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                Text(label)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(question.isDone ? .secondary : .primary)
                if !question.text.isEmpty {
                    MathText(question.text, font: .subheadline)
                        .foregroundStyle(question.isDone ? .tertiary : .secondary)
                        .lineLimit(fullText ? nil : 2)
                        .fixedSize(horizontal: false, vertical: fullText)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, question.parent == nil ? 0 : 26)
            .padding(.vertical, 5)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) \(MathMarkup.plain(question.text))")
        .accessibilityValue(question.isDone ? "fait" : "à faire")
    }

    /// « 1. », « (a) », « Partie » pour une partie sans numéro ; « Question 1 »
    /// quand le libellé est seul (il n'y a pas de texte pour le compléter).
    private var label: String {
        if question.kind == .part { return String(localized: "Partie") }
        let shown = question.displayLabel
        guard question.text.isEmpty else { return shown }
        let bare = shown.trimmingCharacters(in: CharacterSet(charactersIn: ".) ("))
        return bare.allSatisfy(\.isNumber) ? "Question \(bare)" : shown
    }
}

// MARK: - Ligne d'exercice

/// Un exercice dans la liste, **avec** ses sous-questions.
///
/// Tout le suivi se fait ici, sans ouvrir de fiche : la coche (fait / à faire),
/// les questions (cochables une par une, avec leur texte), et à droite les
/// trois pastilles de **correction**, qui apparaissent dès que l'exercice est
/// fait. Les questions d'un exercice fini se replient en « 4/4 » ; un toucher
/// les rouvre. Le numéro et le titre ouvrent la fiche (énoncé complet, liens,
/// indication, solution, remarque, chrono).
struct ExerciseRow: View {
    let exercise: Exercise
    var seconds: Int = 0
    var showsQuestions: Bool
    var onToggleDone: () -> Void
    var onCorrect: (Correctness?) -> Void
    var onToggleQuestions: () -> Void
    var onToggleQuestion: (SubQuestion) -> Void
    var onOpen: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    private var stage: ExerciseStage { ExerciseStage(exercise) }
    private var showsCorrection: Bool { exercise.isDone || exercise.isCorrected }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Button(action: onToggleDone) {
                    ExerciseStageMark(stage: stage)
                        .frame(width: Layout.minTouch, height: Layout.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(exercise.isDone ? "Marquer \(exercise.displayNumber) à faire" : "Marquer \(exercise.displayNumber) fait")
                .accessibilityValue(stage.label)

                Button(action: onOpen) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Layout.snug) {
                            Text(exercise.exerciseNumber)
                                .font(.body.weight(.semibold).monospacedDigit())
                            if exercise.isBonus {
                                Image(systemName: "star.fill")
                                    .font(.caption2)
                                    .foregroundStyle(Color.orange.accessibleMark)
                                    .accessibilityLabel("bonus")
                            }
                            if exercise.redoRequired {
                                Pill(text: String(localized: "à refaire"), color: .red, icon: "arrow.counterclockwise")
                            }
                            if seconds >= 60 {
                                Text(DateUtils.durationLabel(seconds: seconds))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        if let summary {
                            MathText(summary, font: .subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .padding(.top, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Ouvre l'exercice : énoncé, liens, solution, chrono")

                if showsCorrection, !typeSize.isAccessibilitySize {
                    CorrectionDots(value: exercise.correctness, onChange: onCorrect)
                }
            }

            if showsCorrection, typeSize.isAccessibilitySize {
                CorrectionDots(value: exercise.correctness, onChange: onCorrect)
                    .padding(.leading, Layout.minTouch)
            }

            if exercise.hasSubQuestions {
                if showsQuestions {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(exercise.sortedSubQuestions) { question in
                            SubQuestionRow(question: question) { onToggleQuestion(question) }
                            ForEach(question.sortedChildren) { child in
                                SubQuestionRow(question: child) { onToggleQuestion(child) }
                            }
                        }
                    }
                    .padding(.leading, Layout.minTouch)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Button(action: onToggleQuestions) {
                    HStack(spacing: Layout.snug) {
                        Image(systemName: showsQuestions ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.bold))
                        Text(showsQuestions ? "Replier"
                                            : "\(exercise.subQuestionDoneCount)/\(exercise.leafSubQuestions.count) questions")
                            .font(.caption.monospacedDigit())
                    }
                    .foregroundStyle(.secondary)
                    .padding(.leading, Layout.minTouch)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, Layout.micro)
    }

    /// Le titre, sinon le début de l'énoncé : ce dont parle l'exercice.
    private var summary: String? {
        if !exercise.title.isEmpty { return exercise.title }
        if !exercise.statement.isEmpty { return exercise.statement }
        return nil
    }
}

// MARK: - Fiche d'un exercice

/// La fiche ouverte sur un exercice précis — depuis l'accueil, la progression
/// ou la recherche, qui ne connaissent que l'exercice.
struct ExerciseSheet: View {
    let exercise: Exercise

    var body: some View {
        if let series = exercise.series {
            ExerciseWorkspace(series: series, start: exercise)
        }
    }
}

/// La fiche d'un exercice, dans sa série.
///
/// Un exercice se fait en deux temps, et l'écran le dit : **1 · Faire** (les
/// sous-questions en liste, un toucher coche la ligne entière) puis
/// **2 · Corriger** (juste · à revoir · faux, le corrigé à côté). L'énoncé est
/// en haut, à taille de lecture. En bas, une barre fixe : l'exercice précédent,
/// le chrono de cet exercice, le suivant. Le chrono suit l'exercice affiché :
/// passer au suivant attribue le temps déjà compté au précédent.
struct ExerciseWorkspace: View {
    let series: ExerciseSeries
    @State private var selection: UUID

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var app

    @State private var editingSeries = false
    @State private var deleting: Exercise?
    @State private var browsing: BrowsedLink?
    @State private var ankiCard: Exercise?

    init(series: ExerciseSeries, start: Exercise? = nil) {
        self.series = series
        let first = start ?? ExerciseFlow.resumePoint(in: series.exercises) ?? series.sortedExercises.first
        _selection = State(initialValue: first?.id ?? UUID())
    }

    private var exercises: [Exercise] { series.sortedExercises }
    private var current: Exercise? { exercises.first { $0.id == selection } }
    private var index: Int { exercises.firstIndex { $0.id == selection } ?? 0 }
    private var course: Course? { series.course }

    var body: some View {
        NavigationStack {
            Group {
                if let current {
                    ExerciseDetailContent(exercise: current,
                                          onOpenLink: { browsing = $0 })
                        .id(current.id)
                } else {
                    ContentUnavailableView("Aucun exercice", systemImage: TaskType.exercise.icon)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let current {
                    ExerciseStepBar(exercise: current,
                                    previous: exercises.indices.contains(index - 1) ? exercises[index - 1] : nil,
                                    next: exercises.indices.contains(index + 1) ? exercises[index + 1] : nil,
                                    onStep: step)
                }
            }
            .background(Carnet.sheet.ignoresSafeArea())
            .carnetBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Fermer")
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(current?.displayNumber ?? series.title)
                            .font(Carnet.serif(.headline, weight: .semibold))
                            .foregroundStyle(Carnet.ink)
                        Text("Série \(series.seriesNumber) · \(index + 1) sur \(exercises.count)")
                            .font(.caption)
                            .foregroundStyle(Carnet.inkSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if let current {
                            ForEach(ExerciseLinks.links(for: current)) { link in
                                Button { browsing = link } label: { Label(link.title, systemImage: link.icon) }
                            }
                            Divider()
                        }
                        if let current {
                            Button { ankiCard = current } label: {
                                Label("Créer une carte Anki", systemImage: "rectangle.stack.badge.plus")
                            }
                        }
                        Button { editingSeries = true } label: {
                            Label("Modifier la série…", systemImage: "pencil")
                        }
                        if let current {
                            Button(role: .destructive) { deleting = current } label: {
                                Label("Supprimer l'exercice \(current.exerciseNumber)", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("Documents et actions")
                }
            }
            .onChange(of: selection) { _, id in follow(id) }
            .onAppear { follow(selection) }
            .sheet(isPresented: $editingSeries) {
                if let course { SeriesEditorSheet(course: course, series: series) }
            }
            .sheet(item: $browsing) { link in
                InAppBrowser(link: link)
            }
            .sheet(item: $ankiCard) { AnkiCardComposer(exercise: $0) }
            .confirmationDialog("Supprimer l'exercice \(deleting?.exerciseNumber ?? "") ?",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible,
                                presenting: deleting) { exercise in
                Button("Supprimer", role: .destructive) { delete(exercise) }
            } message: { exercise in
                Text(exercise.isDone ? "Il est marqué fait : son avancement sera perdu." : "Ses questions seront supprimées avec lui.")
            }
        }
    }

    private func step(_ delta: Int) {
        let target = min(max(0, index + delta), exercises.count - 1)
        guard exercises.indices.contains(target) else { return }
        withAnimation(Motion.snappy) { selection = exercises[target].id }
        Haptics.soft()
    }

    /// Le chrono suit l'exercice affiché — s'il tourne **sur ce cours**, pour
    /// des exercices ou leur correction. Une session sur un autre cours, ou sur
    /// de la théorie, n'est jamais déplacée par une simple navigation.
    private func follow(_ id: UUID) {
        let focus = app.focus
        guard focus.hasSession, let state = focus.state,
              let course, state.courseID == course.id,
              [.exercise, .correction].contains(state.taskType.canonical),
              state.targetID != id,
              exercises.contains(where: { $0.id == id }) else { return }
        focus.updateContext(targetID: .some(id), label: "")
    }

    private func delete(_ exercise: Exercise) {
        if let next = ExerciseFlow.next(after: exercise, in: exercises) ?? exercises.first(where: { $0.id != exercise.id }) {
            selection = next.id
        } else {
            dismiss()
        }
        context.delete(exercise)
        try? context.save()
        Haptics.removed()
    }
}

/// Le contenu de la fiche : l'énoncé, puis **1 · Faire** et **2 · Corriger**,
/// puis l'aide.
///
/// Sans texte lu, le document d'origine (la page Botafogo, le PDF de la série)
/// occupe le haut de l'écran et la liste des questions reste sous le pouce.
private struct ExerciseDetailContent: View {
    @Bindable var exercise: Exercise
    var onOpenLink: (BrowsedLink) -> Void

    @Environment(\.modelContext) private var context

    @State private var note = ""
    @State private var scoreText = ""
    @State private var maxScoreText = ""
    @State private var showingHint = false
    @State private var showingSolution = false
    @State private var showingNote = false
    @StateObject private var document = BrowserModel()

    private var stage: ExerciseStage { ExerciseStage(exercise) }
    private var course: Course? { exercise.series?.course }
    private var tint: Color { course.map { Carnet.tint($0.colorHex) } ?? Carnet.ink }
    private var hasText: Bool {
        !exercise.statement.isEmpty || exercise.sortedSubQuestions.contains { !$0.text.isEmpty }
    }

    /// Le document d'origine : l'énoncé de l'exercice, sinon celui de la série.
    private var documentURL: URL? {
        ExerciseLinks.web(exercise.statementURLString) ?? exercise.series.flatMap { ExerciseLinks.web($0.urlString) }
    }

    private var hasSeriesPDF: Bool {
        exercise.series.map { SeriesPDFStore.shared.hasDocument(for: $0) } ?? false
    }

    private var currentQuestion: SubQuestion? {
        exercise.leafSubQuestions.first { !$0.isDone }
    }

    private var hasSolution: Bool {
        !exercise.solution.isEmpty || !(exercise.series?.solutionURLString.isEmpty ?? true)
    }

    var body: some View {
        Group {
            // Un PDF de série : l'énoncé découpé dedans, en haut de la fiche, au
            // lieu du document entier. Une page web (Botafogo) s'affiche telle
            // quelle, au-dessus des questions.
            if hasText || documentURL == nil || hasSeriesPDF {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        statementPage
                        doSection
                        correctSection
                        extras
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                    .frame(maxWidth: Layout.readableWidth)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
            } else if let documentURL {
                VStack(spacing: 0) {
                    WebView(model: document, initialURL: documentURL, followsDocumentLinks: true)
                        .overlay(alignment: .top) {
                            if document.isLoading {
                                ProgressView(value: document.progress).progressViewStyle(.linear).tint(Carnet.ink)
                            }
                        }
                    Rectangle().fill(Carnet.rule).frame(height: 1)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            doSection
                            correctSection
                            extras
                        }
                        .padding(16)
                    }
                    .frame(maxHeight: 330)
                    .scrollDismissesKeyboard(.interactively)
                }
            }
        }
        .background(Carnet.sheet.ignoresSafeArea())
        .onAppear {
            note = exercise.correctionNote ?? ""
            scoreText = exercise.score.map { String(format: "%g", $0) } ?? ""
            maxScoreText = exercise.maxScore.map { String(format: "%g", $0) } ?? ""
            showingNote = !note.isEmpty || !scoreText.isEmpty
        }
        .onChange(of: note) { _, _ in persist() }
        .onChange(of: scoreText) { _, _ in persist() }
        .onChange(of: maxScoreText) { _, _ in persist() }
    }

    // MARK: L'énoncé

    private var statementPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            // La série est dans la barre (« Série 2 · 1 sur 3 ») : pas deux fois.
            CarnetKicker([course?.displayCode, exercise.isBonus ? "bonus" : nil]
                            .compactMap { $0 }.joined(separator: " · "),
                         color: tint)
            if !exercise.title.isEmpty {
                Text(MathMarkup.plain(exercise.title))
                    .font(Carnet.serif(.title2))
                    .foregroundStyle(Carnet.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if hasSeriesPDF {
                // La bande du PDF : formules et figures telles qu'imprimées ;
                // le texte lu en repli.
                ExerciseStatementView(exercise: exercise, onOpenLink: onOpenLink)
            } else if !exercise.statement.isEmpty {
                MathText(exercise.statement, font: .system(.body, design: .serif))
                    .foregroundStyle(Carnet.ink)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let documentURL {
                Button {
                    onOpenLink(BrowsedLink(title: "Énoncé d'origine", url: documentURL, icon: "doc.richtext"))
                } label: {
                    Label("Énoncé d'origine", systemImage: "doc.richtext")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Carnet.ink)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 34)
                        .background(Carnet.sheetRaised, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 1 · Faire

    private var doSection: some View {
        let leaves = exercise.leafSubQuestions
        return VStack(alignment: .leading, spacing: 10) {
            stepTitle(number: 1, title: String(localized: "Faire"),
                      isActive: !exercise.isDone,
                      trailing: leaves.isEmpty ? nil : "\(exercise.subQuestionDoneCount)/\(leaves.count)")
            VStack(spacing: 0) {
                if exercise.hasSubQuestions {
                    let rows = questionRows
                    ForEach(Array(rows.enumerated()), id: \.element.question.id) { index, row in
                        questionRow(row.question, depth: row.depth)
                        if index < rows.count - 1 { CarnetRule(inset: 52) }
                    }
                } else {
                    wholeExerciseRow
                }
            }
            .background(Carnet.ground, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
            if exercise.hasSubQuestions, currentQuestion != nil, leaves.count > 1 {
                Button {
                    exercise.setDone(true)
                    Haptics.success()
                    try? context.save()
                } label: {
                    Text("Tout marquer fait")
                        .font(.subheadline)
                        .foregroundStyle(Carnet.inkSecondary)
                        .underline()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
            }
        }
    }

    private var questionRows: [(question: SubQuestion, depth: Int)] {
        exercise.sortedSubQuestions.flatMap { question in
            [(question, 0)] + question.sortedChildren.map { ($0, 1) }
        }
    }

    /// Une sous-question : la coche à gauche, son libellé et son texte ; toute
    /// la ligne se touche. La suivante à faire est surlignée.
    private func questionRow(_ question: SubQuestion, depth: Int) -> some View {
        let isCurrent = question.id == currentQuestion?.id
        let isGroup = !question.children.isEmpty
        return Button { toggle(question) } label: {
            HStack(alignment: .top, spacing: 12) {
                checkMark(isOn: question.isDone, size: isGroup ? 20 : 24)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(label(for: question))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(question.isDone ? Carnet.inkSecondary : Carnet.ink)
                    if !question.text.isEmpty {
                        MathText(question.text, font: .system(.body, design: .serif))
                            .foregroundStyle(question.isDone ? Carnet.inkSecondary : Carnet.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isCurrent {
                    Text("en cours")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Carnet.inkSecondary)
                        .padding(.top, 3)
                }
            }
            .padding(.leading, 14 + CGFloat(depth) * 24)
            .padding(.trailing, 14)
            .padding(.vertical, 12)
            .background(isCurrent ? Carnet.marker : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sous-question \(question.displayLabel). \(MathMarkup.plain(question.text))")
        .accessibilityValue(question.isDone ? "faite" : "à faire")
        .accessibilityHint("Touche pour cocher")
    }

    private var wholeExerciseRow: some View {
        Button {
            exercise.setDone(!exercise.isDone)
            if exercise.isDone { Haptics.success() } else { Haptics.tap() }
            try? context.save()
        } label: {
            HStack(spacing: 12) {
                checkMark(isOn: exercise.isDone, size: 24)
                Text(exercise.isDone ? "Exercice fait" : "Marquer l'exercice fait")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Carnet.ink)
                Spacer()
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func checkMark(isOn: Bool, size: CGFloat) -> some View {
        ZStack {
            Circle().strokeBorder(isOn ? Carnet.ink : Carnet.inkTertiary, lineWidth: 1.6)
            if isOn {
                Circle().fill(Carnet.ink)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.46, weight: .bold))
                    .foregroundStyle(Carnet.ground)
            }
        }
        .frame(width: size, height: size)
        .animation(Motion.snappy, value: isOn)
    }

    /// « (a) », « 1. », « Question 1 » quand le libellé est seul.
    private func label(for question: SubQuestion) -> String {
        if question.kind == .part { return String(localized: "Partie") }
        let shown = question.displayLabel
        guard question.text.isEmpty else { return shown }
        let bare = shown.trimmingCharacters(in: CharacterSet(charactersIn: ".) ("))
        return bare.allSatisfy(\.isNumber) ? "Question \(bare)" : shown
    }

    // MARK: 2 · Corriger

    private var correctSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Le résultat se lit sur le bouton choisi : pas de rappel à côté du titre.
            stepTitle(number: 2, title: String(localized: "Corriger"), isActive: exercise.isDone && !exercise.isCorrected, trailing: nil)
            VStack(alignment: .leading, spacing: 12) {
                CorrectionPicker(value: exercise.correctness) { setCorrection($0) }
                    .opacity(exercise.isDone ? 1 : 0.45)
                if hasSolution {
                    Button(action: openSolution) {
                        Label(solutionLocked ? "Corrigé publié le \(solutionDate)" : "Voir le corrigé",
                              systemImage: solutionLocked ? "lock" : "checkmark.seal")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.carnetSecondaryWide)
                    .disabled(solutionLocked && exercise.solution.isEmpty && (exercise.series?.solutionURLString.isEmpty ?? true))
                }
                if exercise.isCorrected || exercise.redoRequired {
                    Toggle("À refaire", isOn: Binding(get: { exercise.redoRequired },
                                                      set: { exercise.redoRequired = $0; try? context.save() }))
                        .tint(Carnet.wrong)
                }
                if showingNote {
                    TextField("Ce qu'il faut retenir", text: $note, axis: .vertical)
                        .lineLimit(1...5)
                        .padding(12)
                        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    HStack(spacing: 8) {
                        TextField("Points", text: $scoreText).keyboardType(.decimalPad)
                        Text("sur").foregroundStyle(Carnet.inkSecondary)
                        TextField("max", text: $maxScoreText).keyboardType(.decimalPad)
                    }
                    .padding(12)
                    .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else if exercise.isDone {
                    Button {
                        withAnimation(Motion.snappy) { showingNote = true }
                    } label: {
                        Label("Ajouter une note ou des points", systemImage: "square.and.pencil")
                            .font(.subheadline)
                            .foregroundStyle(Carnet.inkSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .background(Carnet.ground, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
        }
    }

    private var solutionLocked: Bool {
        exercise.series?.solutionsAt.map { $0 > Date() } ?? false
    }

    private var solutionDate: String {
        exercise.series?.solutionsAt.map { DateUtils.shortDay.string(from: $0) } ?? ""
    }

    /// « ① Faire   2/4 » : l'étape active est à l'encre, l'autre en retrait.
    private func stepTitle(number: Int, title: String, isActive: Bool, trailing: String?) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(isActive ? Carnet.ground : Carnet.inkSecondary)
                .frame(width: 22, height: 22)
                .background(isActive ? Carnet.ink : Carnet.sheetRaised, in: Circle())
            Text(title)
                .font(Carnet.serif(.title3))
                .foregroundStyle(Carnet.ink)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(Carnet.mono(.subheadline, weight: .medium))
                    .foregroundStyle(Carnet.inkSecondary)
            }
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Plus bas

    @ViewBuilder
    private var extras: some View {
        if !exercise.hint.isEmpty || (!exercise.solution.isEmpty && !solutionLocked) { helpBlock }
        weekTheoryBlock
        timeBlock
    }

    private var helpBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle("Aide")
            VStack(alignment: .leading, spacing: 12) {
                if !exercise.hint.isEmpty {
                    DisclosureGroup(isExpanded: $showingHint) {
                        MathText(exercise.hint, font: .body)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 6)
                    } label: {
                        Label("Indication", systemImage: "lightbulb").foregroundStyle(Carnet.ink)
                    }
                }
                if !exercise.solution.isEmpty, !solutionLocked {
                    DisclosureGroup(isExpanded: $showingSolution) {
                        MathText(exercise.solution, font: .body)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 6)
                    } label: {
                        Label("Solution", systemImage: "checkmark.seal").foregroundStyle(Carnet.ink)
                    }
                }
            }
            .tint(Carnet.ink)
            .padding(14)
            .background(Carnet.ground, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
        }
    }

    @ViewBuilder
    private var weekTheoryBlock: some View {
        if let series = exercise.series, let course, series.plannedWeek > 0 {
            let theory = course.sortedTheoryItems.filter { $0.plannedWeek == series.plannedWeek }
            if !theory.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    CarnetSectionTitle(String(localized: "Théorie de la semaine")) { Text("S\(series.plannedWeek)") }
                    VStack(spacing: 0) {
                        ForEach(theory.prefix(12)) { item in
                            TheoryLinkRow(item: item, onOpen: onOpenLink)
                                .padding(.horizontal, Carnet.rowInset)
                                .padding(.vertical, 10)
                            if item.id != theory.prefix(12).last?.id { CarnetRule(inset: Carnet.rowInset) }
                        }
                    }
                    .background(Carnet.ground, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
                }
            }
        }
    }

    private var timeBlock: some View {
        let spent = ExerciseFlow.seconds(on: exercise)
        return Group {
            if spent >= 60 {
                Label("\(DateUtils.durationLabel(seconds: spent)) passées sur cet exercice", systemImage: "clock")
                    .font(.footnote)
                    .foregroundStyle(Carnet.inkSecondary)
                    .padding(.horizontal, 6)
            }
        }
    }

    // MARK: Actions

    private func toggle(_ question: SubQuestion) {
        question.toggle()
        if exercise.isDone { Haptics.success() } else { Haptics.tap() }
        try? context.save()
    }

    private func setCorrection(_ result: Correctness?) {
        if let result {
            exercise.correct(result)
            if result == .wrong {
                Haptics.error()
                AnkiWebSync.shared.enqueueRedo(exercise)
            } else {
                Haptics.success()
            }
        } else {
            exercise.clearCorrection()
        }
        try? context.save()
    }

    /// Le corrigé : la solution lue quand elle est là, sinon le document du corrigé.
    private func openSolution() {
        if !exercise.solution.isEmpty, !solutionLocked {
            withAnimation(Motion.snappy) { showingSolution = true }
            return
        }
        if let series = exercise.series, let url = ExerciseLinks.web(series.solutionURLString) {
            onOpenLink(BrowsedLink(title: "Corrigé · \(series.displayName)", url: url, icon: "checkmark.seal"))
        }
    }

    private func persist() {
        exercise.correctionNote = note.isEmpty ? nil : note
        exercise.score = Double(scoreText.replacingOccurrences(of: ",", with: "."))
        exercise.maxScore = Double(maxScoreText.replacingOccurrences(of: ",", with: "."))
        try? context.save()
    }
}

/// La barre du bas d'un exercice : le précédent, le chrono **de cet exercice**,
/// le suivant. « Suivant » passe à l'encre quand l'exercice est fait — c'est
/// alors le geste attendu.
private struct ExerciseStepBar: View {
    @Bindable var exercise: Exercise
    let previous: Exercise?
    let next: Exercise?
    var onStep: (Int) -> Void

    @Environment(AppContainer.self) private var app

    private var course: Course? { exercise.series?.course }
    private var workType: TaskType { ExerciseStage(exercise) == .toCorrect ? .correction : .exercise }

    var body: some View {
        HStack(spacing: 8) {
            stepButton(previous, direction: -1)
            timerButton
                .frame(maxWidth: .infinity)
            stepButton(next, direction: 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(Carnet.sheet.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Carnet.rule).frame(height: 1) }
    }

    private func stepButton(_ target: Exercise?, direction: Int) -> some View {
        let emphasized = direction > 0 && exercise.isDone && target != nil
        return Button { onStep(direction) } label: {
            HStack(spacing: 5) {
                if direction < 0 { Image(systemName: "chevron.left").font(.footnote.weight(.bold)) }
                Text(target.map { $0.exerciseNumber } ?? (direction < 0 ? "Début" : "Fin"))
                    .font(Carnet.mono(.subheadline, weight: .medium))
                if direction > 0 { Image(systemName: "chevron.right").font(.footnote.weight(.bold)) }
            }
            .foregroundStyle(emphasized ? Carnet.ground : Carnet.ink)
            .padding(.horizontal, 14)
            .frame(minWidth: 84, minHeight: 46)
            .background(emphasized ? Carnet.ink : Carnet.sheetRaised, in: Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.96))
        .disabled(target == nil)
        // Au premier exercice, pas de « Début » grisé : rien (la place reste).
        .opacity(target == nil ? (direction < 0 ? 0 : 0.4) : 1)
        .accessibilityHidden(target == nil && direction < 0)
        .accessibilityLabel(direction < 0 ? "Exercice précédent" : "Exercice suivant")
        .accessibilityValue(target?.displayNumber ?? "aucun")
    }

    /// Démarrer, mettre en pause, ou faire venir ici un chrono qui tourne ailleurs.
    private var timerButton: some View {
        TimelineView(.periodic(from: FocusTimerState.tickAnchor(app.focus.state), by: 1)) { timeline in
            let focus = app.focus
            let state = focus.state
            let onThis = focus.hasSession && state?.targetID == exercise.id
            let running = onThis && state?.isRunning == true
            let live = onThis ? (state?.allocation(at: timeline.date).first { $0.targetID == exercise.id }?.seconds ?? 0) : 0
            let spent = ExerciseFlow.seconds(on: exercise, live: live)
            Button {
                if onThis, let state {
                    if state.isRunning { focus.pause() } else { focus.resume() }
                } else if focus.hasSession {
                    focus.updateContext(courseID: .some(course?.id), taskType: workType,
                                        targetID: .some(exercise.id), label: "")
                } else {
                    focus.start(courseID: course?.id, taskType: workType, targetID: exercise.id)
                }
                Haptics.tap()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: running ? "pause.fill" : "play.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(running ? Carnet.ink : Carnet.ground)
                        .frame(width: 26, height: 26)
                        .background(running ? Carnet.sheet : Carnet.ink, in: Circle())
                    VStack(alignment: .leading, spacing: 0) {
                        Text(spent > 0 ? TimerText.clock(TimeInterval(spent)) : "00:00")
                            .font(Carnet.mono(.body, weight: .semibold))
                            .foregroundStyle(Carnet.ink)
                            .contentTransition(.numericText())
                        Text(running ? "en cours" : (onThis ? String(localized: "en pause") : (focus.hasSession ? String(localized: "chrono ailleurs") : String(localized: "chrono"))))
                            .font(.caption2)
                            .foregroundStyle(running ? Carnet.wrong : Carnet.inkSecondary)
                    }
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 46)
                .background(Carnet.sheetRaised, in: Capsule())
            }
            .buttonStyle(PressableStyle(scale: 0.96))
            .accessibilityLabel(running ? "Mettre le chrono en pause"
                                : (onThis ? String(localized: "Reprendre le chrono")
                                   : (focus.hasSession ? String(localized: "Passer le chrono sur cet exercice") : String(localized: "Démarrer le chrono sur cet exercice"))))
            .accessibilityValue(TimerText.clock(TimeInterval(spent)))
        }
    }
}

// MARK: - Liens

/// Les documents d'un exercice : son énoncé, celui de la série, le corrigé.
enum ExerciseLinks {
    static func links(for exercise: Exercise) -> [BrowsedLink] {
        var links: [BrowsedLink] = []
        if let url = web(exercise.statementURLString) {
            links.append(BrowsedLink(title: "Énoncé de l'exercice", url: url, icon: "doc.text"))
        }
        if let series = exercise.series {
            links.append(contentsOf: seriesLinks(series).filter { link in !links.contains { $0.url == link.url } })
        }
        return links
    }

    static func seriesLinks(_ series: ExerciseSeries) -> [BrowsedLink] {
        var links: [BrowsedLink] = []
        if let url = web(series.urlString) {
            links.append(BrowsedLink(title: "Énoncé de la série", url: url, icon: "doc.richtext"))
        }
        if let url = web(series.solutionURLString) {
            if let date = series.solutionsAt, date > Date() {
                links.append(BrowsedLink(title: "Corrigé (publié le \(DateUtils.shortDay.string(from: date)))", url: url, icon: "lock"))
            } else {
                links.append(BrowsedLink(title: "Corrigé", url: url, icon: "checkmark.seal"))
            }
        }
        return links
    }

    static func web(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme?.hasPrefix("http") == true else { return nil }
        return SiteLinks.normalize(url)
    }
}

/// Un élément de théorie qui s'ouvre d'un toucher : section, vidéo, diapos.
struct TheoryLinkRow: View {
    let item: TheoryItem
    var onOpen: (BrowsedLink) -> Void

    var body: some View {
        Button {
            if let url = ExerciseLinks.web(item.urlString) {
                onOpen(BrowsedLink(title: "\(item.number) \(MathMarkup.plain(item.title))", url: url, icon: item.kind.icon))
            }
        } label: {
            HStack(spacing: Layout.control) {
                Image(systemName: item.isWatched ? "checkmark.circle.fill" : item.kind.icon)
                    .foregroundStyle(item.isWatched ? Color.green.accessibleMark : TaskType.theory.tint.accessibleMark)
                    .frame(width: 22)
                MathText("\(item.number) · \(item.title)", font: .subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if !item.urlString.isEmpty {
                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .disabled(item.urlString.isEmpty)
    }
}

/// Un document à ouvrir : énoncé, corrigé, section de théorie, vidéo.
struct BrowsedLink: Identifiable, Hashable {
    var id: URL { url }
    var title: String
    var url: URL
    var icon: String = "doc.text"
}

/// Un document ouvert **dans l'app**, avec la session des sites de cours.
///
/// Safari ne connaît pas la connexion Moodle faite dans l'app : un lien Moodle
/// ouvert là-bas redemandait de se connecter. Le navigateur intégré partage le
/// magasin de cookies de l'import — un PDF de série s'ouvre directement.
struct InAppBrowser: View {
    let link: BrowsedLink

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = BrowserModel()

    var body: some View {
        // Une vidéo de cours se lit dans le lecteur de l'app.
        if VideoLinks.isVideo(link.url) {
            VideoPlayerView(link: link)
        } else {
            page
        }
    }

    private var page: some View {
        NavigationStack {
            // Un énoncé gardé hors ligne s'ouvre depuis l'iPhone, sans réseau.
            WebView(model: model, initialURL: OfflineLibrary.shared.localFile(for: link.url) ?? link.url,
                    followsDocumentLinks: true)
                .overlay(alignment: .top) {
                    if model.isLoading {
                        ProgressView(value: model.progress).progressViewStyle(.linear).tint(Theme.accent)
                    }
                }
                .ignoresSafeArea(edges: .bottom)
                .carnetBackground()
                .navigationTitle(link.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Fermer") { dismiss() }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        ShareLink(item: model.url ?? link.url) { Image(systemName: "square.and.arrow.up") }
                        Link(destination: model.url.flatMap { $0.isFileURL ? nil : $0 } ?? link.url) { Image(systemName: "safari") }
                            .accessibilityLabel("Ouvrir dans Safari")
                    }
                }
        }
    }
}
