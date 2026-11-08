import SwiftUI
import SwiftData
import PDFKit

// Les pièces de l'exercice, les mêmes sur l'iPhone et le Mac.

/// Le papier de nuit du mode étude : `Carnet` en apparence sombre, toujours.
///
/// La fenêtre du mode étude est forcée en sombre (`StudyModeView` et sa
/// fenêtre) : un écran plein qui éblouit fatigue, et le soir comme le jour le
/// travail se lit mieux crème sur encre. Les couleurs dynamiques de `Carnet`
/// prennent alors leurs valeurs de nuit ; ces noms disent l'intention.
enum StudyPalette {
    static let ground = Carnet.ground
    static let raised = Carnet.sheet
    static let raisedMore = Carnet.sheetRaised
    static let rule = Carnet.rule
    static let ink = Carnet.ink
    static let inkSecondary = Carnet.inkSecondary
    static let inkTertiary = Carnet.inkTertiary
}

/// Les sous-questions de l'exercice en cours : cocher sans quitter le chrono.
struct SubQuestionChecklist: View {
    @Bindable var exercise: Exercise
    var tint: Color
    var onDark = false

    var body: some View {
        let questions = exercise.leafSubQuestions
        let next = questions.first { !$0.isDone }?.id
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Kicker("Questions", color: onDark ? StudyPalette.inkSecondary : Carnet.inkSecondary)
                Spacer()
                Text("\(questions.filter(\.isDone).count)/\(questions.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(onDark ? StudyPalette.inkSecondary : Carnet.inkSecondary)
            }
            ForEach(questions) { question in
                Button {
                    question.isDone.toggle()
                    question.doneAt = question.isDone ? Date() : nil
                    exercise.refreshCompletion()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: question.isDone ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(question.isDone ? tint : (onDark ? StudyPalette.inkTertiary : Carnet.inkTertiary))
                        Text(question.path).monospacedDigit()
                            .foregroundStyle(onDark ? StudyPalette.inkSecondary : Carnet.inkSecondary)
                        MacMathText(question.text.isEmpty ? " " : question.text, size: 13)
                            .lineLimit(2)
                            .foregroundStyle(onDark ? StudyPalette.ink : Carnet.ink)
                            .strikethrough(question.isDone, color: onDark ? StudyPalette.inkTertiary : Carnet.inkTertiary)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .background(question.id == next ? (onDark ? StudyPalette.raised : Carnet.marker) : .clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout)
    }
}

/// Fait / juste / moyen / faux, en une rangée.
struct ExerciseQuickMark: View {
    @Bindable var exercise: Exercise

    var body: some View {
        HStack(spacing: 6) {
            Toggle("Fait", isOn: Binding(get: { exercise.isDone }, set: { exercise.setDone($0) }))
                .studyCheckbox()
            Spacer(minLength: 8)
            ForEach(Correctness.allCases) { result in
                let selected = exercise.correctness == result
                Button {
                    if selected { exercise.clearCorrection() } else { exercise.correct(result) }
                } label: {
                    Text(result.shortLabel)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(selected ? Carnet.color(for: result) : Carnet.color(for: result).opacity(0.12)))
                        .foregroundStyle(selected ? Carnet.ground : Carnet.color(for: result))
                }
                .buttonStyle(.plain)
                .help(result.label)
            }
        }
        .font(.callout)
    }
}

/// L'exercice, en feuille : l'énoncé (quand il n'y a pas de PDF), les
/// questions à cocher juste dessous, où on en est (fait, juste / moyen / faux,
/// à refaire), le corrigé quand il est publié, et les gestes (indice, faire
/// vérifier sa copie, exercice suivant).
struct ExerciseStudySheet: View {
    @Bindable var exercise: Exercise
    let series: ExerciseSeries
    /// Demander à Claude (la question, ta copie s'il y en a une).
    var ask: (String, ClaudeTutor.Attachment?) -> Void
    var tint: Color
    var showStatement: Bool
    /// Ta copie dans tes notes, si on la trouve : « Vérifier ma copie » l'envoie.
    var copy: NotesLibrary.Document?
    var next: (Exercise) -> Void
    /// Les paliers de la file de reprise (ceux du projet, sinon les standards).
    var ladder = RedoLadder.Config()
    /// « Relire » dans « À savoir » : la section du polycopié.
    var openPoly: ((String) -> Void)? = nil

    private var nextExercise: Exercise? { ExerciseFlow.next(after: exercise, in: series.sortedExercises) }
    @State private var showsHint = false
    @State private var showsSolution = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Quand l'énoncé est à côté, il porte déjà le numéro : pas de doublon.
            if showStatement {
            VStack(alignment: .leading, spacing: 4) {
                Kicker(series.title.isEmpty ? series.displayName : series.title, color: tint)
                Text(exercise.displayNumber).font(Carnet.serif(showStatement ? 30 : 24)).foregroundStyle(Carnet.ink)
                if !exercise.title.isEmpty, exercise.title != exercise.displayNumber {
                    MacMathText(exercise.title, size: 14).foregroundStyle(Carnet.inkSecondary)
                }
            }
            }
            if showStatement, !exercise.statement.isEmpty {
                MacMathText(exercise.statement, size: 16).foregroundStyle(Carnet.ink).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !exercise.hint.isEmpty {
                DisclosureGroup("Indication", isExpanded: Binding(get: { showsHint }, set: { open in
                    showsHint = open
                    if open, !exercise.isDone { exercise.recordHint(level: 1, text: String(localized: "Indication du cours lue")) }
                })) {
                    MacMathText(exercise.hint, size: 14).foregroundStyle(Carnet.ink).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
                .foregroundStyle(Carnet.inkSecondary)
            }
            if exercise.hasSubQuestions {
                SubQuestionChecklist(exercise: exercise, tint: tint)
                    .padding(14)
                    .background(Carnet.sheetRaised.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            ExerciseKnowHow(exercise: exercise, tint: tint, openPoly: openPoly)
            if exercise.isQueuedForRedo {
                RedoPanel(exercise: exercise, ladder: ladder, tint: tint)
            }
            VStack(alignment: .leading, spacing: 10) {
                Kicker("Où j'en suis")
                ExerciseQuickMark(exercise: exercise)
                Toggle("À refaire", isOn: $exercise.redoRequired).studyCheckbox()
            }
            if !exercise.mistakes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Kicker("Erreurs notées")
                    ForEach(exercise.mistakes) { mistake in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: mistake.kind.icon).font(.caption).foregroundStyle(Carnet.wrong).frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mistake.kind.label).font(.caption.weight(.semibold)).foregroundStyle(Carnet.inkSecondary)
                                MacMathText(mistake.summary, size: 13).foregroundStyle(Carnet.ink)
                                if !mistake.correction.isEmpty {
                                    MacMathText("→ " + mistake.correction, size: 12).foregroundStyle(Carnet.inkSecondary)
                                }
                            }
                        }
                    }
                }
            }
            if !exercise.hints.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(exercise.hints.enumerated()), id: \.offset) { _, hint in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(hint.level)").font(.caption.monospacedDigit().weight(.semibold))
                                    .frame(width: 18, height: 18)
                                    .background(Carnet.review.opacity(0.18), in: Circle())
                                    .foregroundStyle(Carnet.review)
                                MacMathText(hint.text, size: 12.5).foregroundStyle(Carnet.ink)
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Label("\(exercise.hints.count) indice\(exercise.hints.count > 1 ? "s" : "") de Claude · niveau \(exercise.hintLevel) au plus",
                          systemImage: "lightbulb")
                        .font(.callout)
                }
                .foregroundStyle(Carnet.inkSecondary)
            }
            if !exercise.solution.isEmpty, series.solutionsAt.map({ $0 <= Date() }) ?? true {
                DisclosureGroup("Corrigé", isExpanded: Binding(get: { showsSolution }, set: { open in
                    showsSolution = open
                    if open, !exercise.isDone { exercise.recordHint(level: 4, text: String(localized: "Corrigé lu avant d'avoir fini")) }
                })) {
                    MacMathText(exercise.solution, size: 14).foregroundStyle(Carnet.ink).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
                .foregroundStyle(Carnet.inkSecondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button { ask(ClaudeTutor.QuickAction.hint.prompt, nil) } label: { Label("Un indice", systemImage: "lightbulb") }
                        .buttonStyle(.ink)
                    Button {
                        let attachment = copy.flatMap { copy in
                            NotesStore.shared.attachmentData(copy).map { ClaudeTutor.Attachment(kind: .pdf, data: $0, name: copy.title, notebookPath: copy.path) }
                        }
                        ask(ClaudeTutor.QuickAction.check.prompt, attachment)
                    } label: { Label("Vérifier ma copie", systemImage: "checkmark.circle") }
                        .buttonStyle(.paper)
                        .help(copy.map { "Envoie « \($0.title) » à Claude" } ?? "Joins ta copie")
                }
                if let nextExercise {
                    Button { next(nextExercise) } label: {
                        Label("\(nextExercise.displayNumber)", systemImage: "arrow.right")
                    }
                    .buttonStyle(.paper)
                }
            }
        }
    }
}

/// Un anneau de progression, fin.
struct ThinRing: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        ZStack {
            Circle().stroke(Carnet.rule, lineWidth: 2.5)
            Circle().trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}



// MARK: - En reprise

/// Un exercice de la file de reprise : quand le refaire, pourquoi, et —
/// seulement après une tentative — son premier geste. Le résultat le fait
/// avancer d'un palier, le sort de la file, ou le garde une semaine de plus.
struct RedoPanel: View {
    @Bindable var exercise: Exercise
    let ladder: RedoLadder.Config
    let tint: Color
    @State private var showsFirstMove = false
    @State private var note: String?

    private var step: String {
        guard let pass = exercise.redoPass, ladder.steps.indices.contains(pass) else { return "" }
        return ladder.steps[pass].label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("En reprise · \(step)", systemImage: "arrow.counterclockwise")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Carnet.review)
                Spacer()
                if let due = exercise.redoDueAt {
                    Text(due <= Date() ? "à faire" : "le \(due.formatted(.dateTime.day().month(.abbreviated)))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(due <= Date() ? Carnet.review : Carnet.inkSecondary)
                }
            }
            if !exercise.redoWhy.isEmpty {
                MacMathText(exercise.redoWhy, size: 13).foregroundStyle(Carnet.inkSecondary)
            }
            Text("Sur papier, l'énoncé seul, sans tes notes.").font(.caption).foregroundStyle(Carnet.inkTertiary)
            if !exercise.redoFirstMove.isEmpty {
                if showsFirstMove {
                    MacMathText("Premier geste : " + exercise.redoFirstMove, size: 13)
                        .foregroundStyle(Carnet.ink)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Carnet.marker.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Button("J'ai essayé, je bloque : le premier geste") { withAnimation(.snappy) { showsFirstMove = true } }
                        .buttonStyle(.paper)
                }
            }
            HStack(spacing: 6) {
                ForEach(RedoLadder.Result.allCases, id: \.self) { result in
                    Button(result.label) { record(result) }
                        .buttonStyle(.paper)
                        .controlSize(.small)
                }
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(Carnet.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Carnet.review.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Carnet.review.opacity(0.3)))
    }

    private func record(_ result: RedoLadder.Result) {
        let outcome = SeriesReview.recordRedo(result, on: exercise, ladder: ladder, examDate: exercise.series?.course?.nextExam?.date)
        showsFirstMove = false
        if outcome.pass == nil {
            note = String(localized: "Sorti de la file. Bien joué.")
        } else if outcome.gap {
            note = String(localized: "Deuxième échec de suite : c'est une lacune de cours, pas un manque d'entraînement. Relis la notion avant de le refaire.")
        } else if let due = outcome.due {
            note = String(localized: "Prochaine reprise le \(due.formatted(.dateTime.day().month(.wide))).")
        }
    }
}
