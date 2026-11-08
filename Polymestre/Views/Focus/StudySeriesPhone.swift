import SwiftData
import SwiftUI
import UIKit

/// La série dans le mode étude de l'iPhone — les mêmes pièces que le bureau du
/// Mac (`StudyKit` : le PDF ouvert à l'exercice, la feuille de l'exercice, ta
/// copie GoodNotes), rangées pour un écran étroit : la liste, puis l'exercice
/// avec « Énoncé · Exercice · Ma copie ».
struct StudySeriesPhone: View {
    let course: Course?
    let courses: [Course]
    @Environment(AppContainer.self) private var app
    @State private var seriesID: UUID?
    @State private var opened: Exercise?

    private var focusTarget: UUID? { app.focus.state?.targetID }
    private var allSeries: [ExerciseSeries] { course?.sortedSeries.filter { !$0.exercises.isEmpty } ?? [] }

    private var series: ExerciseSeries? {
        if let seriesID, let found = allSeries.first(where: { $0.id == seriesID }) { return found }
        if let current = course?.allExercises.first(where: { $0.id == focusTarget })?.series { return current }
        let week = course?.currentWeek ?? 0
        return allSeries.first { $0.plannedWeek >= week && !$0.isComplete } ?? allSeries.last
    }

    var body: some View {
        NavigationStack {
            Group {
                if let course, let series {
                    List {
                        Section {
                            ForEach(series.sortedExercises) { exercise in
                                Button { select(exercise, in: course) } label: { row(exercise, tint: Carnet.tint(course.colorHex)) }
                                    .listRowBackground(exercise.id == focusTarget ? Carnet.tint(course.colorHex).opacity(0.14) : Carnet.sheet)
                            }
                        } header: {
                            HStack {
                                Text("\(series.doneCount)/\(series.requiredExercises.count) faits")
                                Spacer()
                                if let due = series.dueDate { Text("à rendre \(DateUtils.countdownLabel(to: due))") }
                            }
                            .font(.caption)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .navigationTitle(name(series))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                ForEach(allSeries) { item in Button(name(item)) { seriesID = item.id } }
                            } label: { Image(systemName: "list.number") }
                        }
                    }
                    .navigationDestination(item: $opened) { exercise in
                        StudyExercisePhone(exercise: exercise, series: series, course: course, courses: courses) { next in
                            select(next, in: course)
                        }
                    }
                } else {
                    ContentUnavailableView("Pas de série", systemImage: "doc.text",
                                           description: Text(course == nil ? "Choisis un cours." : "Rien d'importé."))
                }
            }
            .background(Carnet.ground)
        }
        .task { await NotesStore.shared.refresh() }
    }

    private func name(_ series: ExerciseSeries) -> String {
        series.title.isEmpty ? series.displayName : series.title
    }

    /// Choisir un exercice, c'est y passer le chrono (comme sur le Mac).
    private func select(_ exercise: Exercise, in course: Course) {
        seriesID = exercise.series?.id
        app.focus.updateContext(courseID: .some(course.id), taskType: .exercise, targetID: .some(exercise.id))
        opened = exercise
    }

    private func row(_ exercise: Exercise, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: exercise.isDone ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(exercise.isDone ? tint : Carnet.inkTertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(exercise.displayNumber).foregroundStyle(Carnet.ink)
                if let label = exercise.subQuestionLabel {
                    Text(label).font(.caption.monospacedDigit()).foregroundStyle(Carnet.inkSecondary)
                }
            }
            Spacer()
            if let correctness = exercise.correctness {
                Text(correctness.shortLabel).font(.caption.weight(.medium)).foregroundStyle(Carnet.color(for: correctness))
            }
            if exercise.id == focusTarget { Image(systemName: "timer").font(.caption).foregroundStyle(tint) }
        }
    }
}

/// Un exercice sur l'iPhone : l'énoncé (PDF ouvert à l'exercice), la feuille
/// (questions, où j'en suis, gestes), ta copie.
struct StudyExercisePhone: View {
    @Bindable var exercise: Exercise
    let series: ExerciseSeries
    let course: Course
    let courses: [Course]
    var next: (Exercise) -> Void

    enum Panel: String, CaseIterable { case statement, sheet, copy }
    @State private var panel: Panel = .sheet
    @State private var choseStatement = false
    /// Le tuteur gratuit, sans l'app Claude.
    @State private var tutorQuestion: TutorQuestion?
    @Environment(\.openURL) private var openURL
    private var sites: SiteHub { .shared }

    private var copy: NotesLibrary.Document? { NotesStore.shared.copy(for: series, course: course, among: courses) }
    /// Le site Botafogo du cours : l'exercice se lit tel que le site le montre.
    private var botafogoSite: URL? {
        guard BotafogoLinks.isPage(series.urlString) || BotafogoLinks.isPage(exercise.statementURLString) else { return nil }
        return course.contentSources.compactMap(URL.init(string:)).first { ContentSource.detect(host: $0.host) == .botafogo }
    }
    /// Le PDF de l'énoncé ; vide pour une série Botafogo, lue en natif.
    private var address: String {
        let address = exercise.statementURLString.isEmpty ? series.urlString : exercise.statementURLString
        return BotafogoLinks.isPage(address) ? "" : address
    }

    var body: some View {
        content
            .sheet(item: $tutorQuestion) { question in
                PhoneTutorChat(course: course, exercise: exercise, first: question.text)
                    .presentationDetents([.medium, .large])
            }
    }

    private var content: some View {
        VStack(spacing: 0) {
            Picker("Afficher", selection: $panel) {
                if !address.isEmpty || !exercise.statement.isEmpty || botafogoSite != nil { Text("Énoncé").tag(Panel.statement) }
                Text("Exercice").tag(Panel.sheet)
                if copy != nil { Text("Ma copie").tag(Panel.copy) }
            }
            .pickerStyle(.segmented)
            .padding(12)
            switch panel {
            case .statement:
                statement
            case .sheet:
                ScrollView {
                    ExerciseStudySheet(exercise: exercise, series: series, ask: ask, tint: Carnet.tint(course.colorHex),
                                       showStatement: address.isEmpty, copy: copy, next: next)
                        .padding(20)
                }
            case .copy:
                if let copy, let url = NotesStore.shared.url(copy) { PDFPane(url: url) }
            }
        }
        .background(Carnet.ground)
        // Une série Botafogo s'ouvre sur l'énoncé du site : c'est lui qu'on lit d'abord.
        .onAppear { if botafogoSite != nil, !choseStatement { panel = .statement; choseStatement = true } }
        .navigationTitle(exercise.displayNumber)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var statement: some View {
        if let site = botafogoSite {
            BotafogoExerciseStatement(book: sites.botafogo(site), site: site,
                                      exercisePath: BotafogoLinks.coursPath(exercise.statementURLString),
                                      seriesPath: BotafogoLinks.coursPath(series.urlString),
                                      position: series.sortedExercises.firstIndex { $0.id == exercise.id } ?? 0,
                                      heading: nil, desk: sites,
                                      openPoly: { path in sites.request = .init(courseID: course.id, source: .botafogo, reading: .botafogo(title: path, url: path)) },
                                      openWeb: { url, _ in openURL(url) }, tint: Carnet.tint(course.colorHex))
        } else if address.isEmpty {
            ScrollView {
                MacMathText(exercise.statement, size: 17).foregroundStyle(Carnet.ink).padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            switch sites.document(address) {
            case .ready(let file)?:
                ExercisePDFView(file: file, exercise: exercise,
                                next: series.sortedExercises.drop { $0.id != exercise.id }.dropFirst().first, memory: address)
            case .needsLogin?:
                VStack(spacing: 12) {
                    Text("Connecte-toi à l'école.").foregroundStyle(Carnet.inkSecondary)
                    Button("Se connecter") { sites.signIn = .moodle }.buttonStyle(.ink)
                }
                .frame(maxHeight: .infinity)
            case .failed?:
                VStack(spacing: 12) {
                    Text("Énoncé introuvable").foregroundStyle(Carnet.inkSecondary)
                    Button("Réessayer") { sites.retry(address) }.buttonStyle(.paper)
                }
                .frame(maxHeight: .infinity)
            case .loading?, nil:
                ProgressView().frame(maxHeight: .infinity).onAppear { sites.loadPDF(address) }
            }
        }
    }

    /// Claude sur l'iPhone : l'app Claude si elle est là (la question et le contexte copiés),
    /// sinon le tuteur gratuit dans l'app.
    private func ask(_ question: String, _ attachment: ClaudeTutor.Attachment?) {
        if PhoneClaude.hasClaudeApp || !PhoneClaude.hasFreeTutor {
            UIPasteboard.general.string = StudyPhoneClaude.prompt(question, exercise: exercise, course: course)
            if let url = URL(string: "claude://") { openURL(url) }
        } else {
            tutorQuestion = TutorQuestion(text: question)
        }
    }
}

enum StudyPhoneClaude {
    /// Le message à coller dans Claude : le cours, la série, l'exercice, la question.
    static func prompt(_ question: String, exercise: Exercise?, course: Course?) -> String {
        let context = ClaudeTutor.contextPreamble(.init(
            courseCode: course?.displayCode, courseName: course?.name,
            exercise: exercise.map { "\($0.series.map { "Série \($0.seriesNumber) · " } ?? "")\($0.displayNumber)" },
            statement: exercise?.statement,
            questions: exercise?.leafSubQuestions.map { "\($0.path) \($0.text)" } ?? [],
            doneQuestions: exercise?.subQuestionDoneCount ?? 0))
        return ClaudeTutor.displayText(context).isEmpty ? question : context.replacingOccurrences(of: "[Polymestre]\n", with: "")
            .replacingOccurrences(of: "[/Polymestre]", with: "") + question
    }
}
