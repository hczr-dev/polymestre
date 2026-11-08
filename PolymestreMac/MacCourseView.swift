import SwiftUI
import SwiftData

/// Un cours : ses séries et sa théorie, semaine par semaine. Cocher ici,
/// c'est cocher sur l'iPhone. Un exercice choisi s'ouvre dans l'inspecteur
/// (énoncé, questions, correction, temps passé).
struct MacCourseView: View {
    @Bindable var course: Course
    @Binding var focusTarget: UUID?

    enum Tab: String, CaseIterable, Identifiable {
        case series = "Séries", theory = "Théorie", notes = "Notes"
        var id: String { rawValue }
    }

    /// `0` = tout le semestre.
    @State private var week = 0
    @State private var tab: Tab = .series
    @State private var selection: UUID?
    /// Fermé tant que rien n'est choisi : la liste garde toute la largeur.
    @State private var showingInspector = false
    /// Ce qui s'édite, dans une feuille (les mêmes formulaires que l'iPhone).
    @State private var editor: Editor?
    @State private var dropTargeted = false
    /// « À rattraper », en feuille.
    @State private var showingLate = false

    enum Editor: Identifiable {
        case course
        case series(ExerciseSeries?)
        case importPDF(URL?)
        case theory(TheoryItem?)
        case exam(Exam?)

        var id: String {
            switch self {
            case .course: return "course"
            case .series(let series): return "series-\(series?.id.uuidString ?? "new")"
            case .importPDF(let url): return "pdf-\(url?.path ?? "")"
            case .theory(let item): return "theory-\(item?.id.uuidString ?? "new")"
            case .exam(let exam): return "exam-\(exam?.id.uuidString ?? "new")"
            }
        }
    }

    @Environment(MacTimer.self) private var timer
    @Environment(\.modelContext) private var context

    private var tint: Color { Carnet.tint(course.colorHex) }
    private var weeks: [Int] {
        let all = Set(course.series.map(\.plannedWeek) + course.theoryItems.map(\.plannedWeek)).filter { $0 > 0 }
        return all.sorted()
    }

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                Section { header }
                switch tab {
                case .series: seriesSections
                case .theory: theorySections
                case .notes: CourseNotesView(course: course, textSize: 14)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(Carnet.ground)
            // Au clavier : Espace coche, ↩ chronomètre ce qui est choisi.
            .onKeyPress(.space) {
                guard let id = selection else { return .ignored }
                toggle(id)
                return .handled
            }
            .onKeyPress(.return) {
                guard let id = selection else { return .ignored }
                time(id, course.theoryItems.contains { $0.id == id } ? .theory : .exercise)
                return .handled
            }
            .onChange(of: selection) { _, value in
                if value != nil { showingInspector = true }
            }
            .onAppear {
                // On arrive sur la semaine en cours, pas sur la série 1.
                guard focusTarget == nil, course.currentWeek > 0,
                      let current = course.sortedSeries.first(where: { $0.plannedWeek >= course.currentWeek && !$0.exercises.isEmpty }),
                      let first = current.sortedExercises.first else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    proxy.scrollTo(first.id, anchor: .top)
                }
            }
            .onChange(of: focusTarget, initial: true) { _, target in
                guard let target else { return }
                // Viser le cours lui-même : ouvrir « À rattraper » (le « N en retard »
                // d'Aujourd'hui).
                if target == course.id {
                    focusTarget = nil
                    showingLate = true
                    return
                }
                if course.theoryItems.contains(where: { $0.id == target }) { tab = .theory } else { tab = .series }
                week = 0
                selection = target
                showingInspector = true
                focusTarget = nil
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    withAnimation { proxy.scrollTo(target, anchor: .center) }
                }
            }
        }
        .navigationTitle(course.displayCode)
        .inspector(isPresented: $showingInspector) {
            inspector
                .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Affichage", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
            ToolbarItem {
                Menu {
                    Button("Importer une série (PDF)…") { editor = .importPDF(nil) }
                    Button("Nouvelle série…") { editor = .series(nil) }
                    Button("Ajouter de la théorie…") { editor = .theory(nil) }
                    Button("Nouvelle évaluation…") { editor = .exam(nil) }
                    Divider()
                    Button("Modifier le cours…") { editor = .course }
                } label: {
                    Label("Ajouter", systemImage: "plus")
                }
                .help("Ajouter une série, de la théorie, une évaluation")
            }
            ToolbarItem {
                Button { showingInspector.toggle() } label: {
                    Label("Inspecteur", systemImage: "sidebar.trailing")
                }
                .help("Inspecteur")
            }
        }
        .sheet(isPresented: $showingLate) {
            NavigationStack {
                LateWorkView(course: course,
                             openExercise: { reveal($0.id) },
                             openTheory: { reveal($0.id) },
                             openURL: { NSWorkspace.shared.open($0) })
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Fermer") { showingLate = false } }
                    }
            }
            .frame(minWidth: 520, idealWidth: 620, minHeight: 560, idealHeight: 720)
        }
        .sheet(item: $editor) { editor in
            switch editor {
            case .course: CourseFormView(course: course)
            case .series(let series): SeriesEditorSheet(course: course, series: series)
            case .importPDF(let url): SeriesImportSheet(course: course, initialFileURL: url)
            case .theory(let item): TheoryItemForm(course: course, item: item)
            case .exam(let exam): ExamFormSheet(course: course, exam: exam)
            }
        }
        // Un PDF de série glissé sur le cours : l'import, avec sa relecture.
        .dropDestination(for: URL.self) { urls, _ in
            guard let pdf = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) else { return false }
            editor = .importPDF(pdf)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(tint, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(8)
                    .overlay(Label("Déposer le PDF de la série", systemImage: "doc.badge.plus")
                        .padding(10).background(.regularMaterial, in: Capsule()))
                    .allowsHitTesting(false)
            }
        }
    }

    /// Ferme « À rattraper » et montre l'élément dans la liste et l'inspecteur.
    private func reveal(_ id: UUID) {
        showingLate = false
        focusTarget = id
    }

    // MARK: En-tête

    /// Le titre sur toute la largeur, les chiffres dessous : un long nom de
    /// cours (« Advanced information, computation, communication I ») ne doit
    /// jamais être écrasé par les compteurs.
    private var header: some View {
        let progress = ProgressEngine.progress(for: course)
        let late = ProgressEngine.lateCount(for: course)
        return VStack(alignment: .leading, spacing: 12) {
            CourseTag(code: course.displayCode, tint: tint)
            Text(course.name)
                .font(Carnet.serif(30))
                .foregroundStyle(Carnet.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            CourseSitesRow(course: course) { url, _ in NSWorkspace.shared.open(url) }
            HStack(alignment: .center, spacing: 22) {
                Text([course.credits > 0 ? "\(course.credits.formatted()) ECTS" : nil,
                      course.currentWeek > 0 ? String(localized: "semaine \(course.currentWeek)") : nil,
                      late > 0 ? nil : String(localized: "à jour")].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(Carnet.inkSecondary)
                    .lineLimit(1)
                if late > 0 {
                    Button { showingLate = true } label: {
                        Label("\(late) en retard", systemImage: "exclamationmark.circle")
                            .foregroundStyle(Carnet.wrong)
                    }
                    .buttonStyle(.borderless)
                    .help("Ce qui est à rattraper")
                }
                Picker("Semaine", selection: $week) {
                    Text("Tout le semestre").tag(0)
                    Divider()
                    ForEach(weeks, id: \.self) { value in
                        Text(value == course.currentWeek ? "Semaine \(value) (en cours)" : "Semaine \(value)").tag(value)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("Semaine")
                Spacer(minLength: 12)
                stat(String(localized: "Théorie"), progress.watchedCount, progress.videoCount)
                stat(String(localized: "Exercices"), progress.doneCount, progress.exerciseCount)
                ZStack {
                    TimerRing(progress: progress.completion, tint: tint, lineWidth: 4)
                    Text("\(Int((progress.completion * 100).rounded()))").font(Carnet.serif(.callout, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Carnet.ink)
                }
                .frame(width: 44, height: 44)
                .help("\(Int((progress.completion * 100).rounded())) %")
            }
        }
        .padding(.vertical, 8)
        .selectionDisabled()
    }

    private func stat(_ title: String, _ done: Int, _ total: Int) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(done)/\(total)").font(Carnet.serif(.title3).monospacedDigit()).foregroundStyle(Carnet.ink)
            Text(ui: title).font(.caption).foregroundStyle(Carnet.inkSecondary)
        }
    }

    // MARK: Séries

    @ViewBuilder
    private var seriesSections: some View {
        let series = course.sortedSeries.filter { week == 0 || $0.plannedWeek == week }
        if series.isEmpty {
            Text(week == 0 ? "Aucune série." : "Pas de série en semaine \(week).").foregroundStyle(.secondary)
                .selectionDisabled()
        }
        ForEach(series) { item in
            Section {
                ForEach(item.sortedExercises) { exercise in
                    ExerciseMacRow(exercise: exercise, isTimed: timer.phase != .idle && timer.targetID == exercise.id)
                        .tag(exercise.id)
                        .id(exercise.id)
                        .contextMenu { exerciseMenu(exercise) }
                }
            } header: {
                SeriesHeader(series: item, tint: tint)
                    .contextMenu {
                        Button("Modifier la série…") { editor = .series(item) }
                        Button("Réimporter un PDF…") { editor = .importPDF(nil) }
                    }
            }
        }
    }

    @ViewBuilder
    private func exerciseMenu(_ exercise: Exercise) -> some View {
        Button(exercise.isDone ? "Marquer à faire" : "Marquer comme fait") { exercise.setDone(!exercise.isDone) }
        Menu("Correction") {
            ForEach(Correctness.allCases) { result in
                Button(result.label) { exercise.correct(result) }
            }
            if exercise.correctness != nil {
                Divider()
                Button("Retirer la correction") { exercise.clearCorrection() }
            }
        }
        Divider()
        Button("Chronométrer") { time(exercise.id, .exercise) }
        if let series = exercise.series {
            Button("Modifier la série…") { editor = .series(series) }
        }
        if let url = web(exercise.statementURLString) ?? web(exercise.series?.urlString ?? "") {
            Link("Ouvrir l'énoncé", destination: url)
        }
    }

    // MARK: Théorie

    @ViewBuilder
    private var theorySections: some View {
        let items = course.sortedTheoryItems.filter { week == 0 || $0.plannedWeek == week }
        let grouped = Dictionary(grouping: items, by: \.plannedWeek)
        if items.isEmpty {
            Text(week == 0 ? "Aucune théorie." : "Pas de théorie en semaine \(week).").foregroundStyle(.secondary)
                .selectionDisabled()
        }
        ForEach(grouped.keys.sorted { ($0 == 0 ? Int.max : $0) < ($1 == 0 ? Int.max : $1) }, id: \.self) { key in
            Section {
                ForEach(grouped[key] ?? []) { item in
                    TheoryMacRow(item: item, tint: tint, isTimed: timer.phase != .idle && timer.targetID == item.id)
                        .tag(item.id)
                        .id(item.id)
                        .contextMenu {
                            Button(item.isWatched ? "Marquer non vu" : "Marquer comme vu") {
                                item.watchedAt = item.isWatched ? nil : Date()
                            }
                            Button("Chronométrer") { time(item.id, .theory) }
                            if let url = web(item.urlString) { Link("Ouvrir", destination: url) }
                            Divider()
                            Button("Modifier…") { editor = .theory(item) }
                        }
                }
            } header: {
                HStack {
                    Text(key > 0 ? "Semaine \(key)" : "Documents").font(Carnet.serif(.title3))
                    if key == course.currentWeek {
                        Text("en cours").font(.caption.weight(.semibold)).foregroundStyle(tint)
                    }
                }
                .foregroundStyle(Carnet.ink)
                .padding(.top, 8)
            }
        }
    }

    // MARK: Inspecteur

    @ViewBuilder
    private var inspector: some View {
        if let id = selection, let exercise = course.allExercises.first(where: { $0.id == id }) {
            ExerciseInspector(exercise: exercise, tint: tint) { time(exercise.id, .exercise) }
        } else if let id = selection, let item = course.theoryItems.first(where: { $0.id == id }) {
            TheoryInspector(item: item, tint: tint) { time(item.id, .theory) }
        } else {
            ContentUnavailableView("Choisis un exercice", systemImage: "sidebar.trailing",
                                   description: Text("Choisis-en un à gauche."))
        }
    }

    private func toggle(_ id: UUID) {
        if let exercise = course.allExercises.first(where: { $0.id == id }) {
            exercise.setDone(!exercise.isDone)
        } else if let item = course.theoryItems.first(where: { $0.id == id }) {
            item.watchedAt = item.isWatched ? nil : Date()
        }
        try? context.save()
    }

    /// Démarre — ou, si une session tourne, bascule dessus sans couper.
    private func time(_ target: UUID, _ type: TaskType) {
        if timer.phase == .idle {
            timer.start(courseID: course.id, taskType: type, targetID: target)
        } else {
            timer.retarget(courseID: course.id, taskType: type, targetID: target)
        }
    }

    private func web(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }
}

private struct SeriesHeader: View {
    let series: ExerciseSeries
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(series.title.isEmpty ? series.displayName : series.title)
                .font(Carnet.serif(.title3))
                .foregroundStyle(Carnet.ink)
            if series.plannedWeek > 0 {
                Text("S\(series.plannedWeek)").foregroundStyle(.secondary)
            }
            if let due = series.dueDate {
                Label("à rendre le \(DateUtils.shortDay.string(from: due))", systemImage: "tray.and.arrow.up")
                    .foregroundStyle(due < Date() ? Carnet.wrong : Carnet.review)
            }
            Spacer()
            ProgressView(value: Double(series.doneCount), total: Double(max(series.requiredExercises.count, 1)))
                .frame(width: 60)
                .controlSize(.small)
                .tint(tint)
            Text("\(series.doneCount)/\(series.requiredExercises.count)").monospacedDigit().foregroundStyle(.secondary)
            if let url = web(series.urlString) {
                Link(destination: url) { Label("Énoncé", systemImage: "doc.richtext") }
            }
            if let url = web(series.solutionURLString) {
                if let date = series.solutionsAt, date > Date() {
                    Label("Corrigé le \(DateUtils.shortDay.string(from: date))", systemImage: "lock")
                        .foregroundStyle(.secondary)
                } else {
                    Link(destination: url) { Label("Corrigé", systemImage: "checkmark.seal") }
                }
            }
        }
        .font(.callout)
        .padding(.top, 10)
    }

    private func web(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }
}

private struct ExerciseMacRow: View {
    @Bindable var exercise: Exercise
    let isTimed: Bool

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { exercise.isDone }, set: { exercise.setDone($0) })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
            Text(exercise.exerciseNumber).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 36, alignment: .leading)
            Text(exercise.title.isEmpty ? exercise.displayNumber : exercise.title)
                .foregroundStyle(exercise.isDone ? .secondary : .primary)
            if let label = exercise.subQuestionLabel {
                Text(label).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if exercise.isBonus {
                Text("bonus").font(.caption).foregroundStyle(.secondary)
            }
            if exercise.redoRequired {
                Text("à refaire").font(.caption.weight(.semibold)).foregroundStyle(Carnet.wrong)
            }
            Spacer()
            if isTimed {
                Image(systemName: "timer").foregroundStyle(.secondary).help("En cours")
            }
            if let correctness = exercise.correctness {
                VerdictTag(correctness: correctness)
            } else if exercise.isDone {
                Text("à corriger").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct TheoryMacRow: View {
    @Bindable var item: TheoryItem
    let tint: Color
    let isTimed: Bool

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { item.isWatched },
                                 set: { item.watchedAt = $0 ? (item.watchedAt ?? Date()) : nil })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
            Image(systemName: item.kind.icon).foregroundStyle(tint).frame(width: 18)
            if !item.number.isEmpty {
                Text(item.number).monospacedDigit().foregroundStyle(.secondary)
            }
            Text(item.title.isEmpty ? item.kind.label : item.title).lineLimit(2)
                .foregroundStyle(item.isWatched ? .secondary : .primary)
            Spacer()
            if isTimed { Image(systemName: "timer").foregroundStyle(.secondary) }
            if item.durationSeconds > 0 {
                Text(item.durationLabel).foregroundStyle(.secondary).monospacedDigit()
            }
            if let url = URL(string: item.urlString), url.scheme?.hasPrefix("http") == true {
                Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                    .help("Ouvrir")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Inspecteurs

private struct ExerciseInspector: View {
    @Bindable var exercise: Exercise
    let tint: Color
    var time: () -> Void

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(exercise.displayNumber).font(.caption.weight(.semibold)).foregroundStyle(tint)
                    Text(exercise.title.isEmpty ? exercise.displayNumber : exercise.title)
                        .font(Carnet.serif(.title3))
                    if !exercise.statement.isEmpty {
                        Text(exercise.statement).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Toggle("Fait", isOn: Binding(get: { exercise.isDone }, set: { exercise.setDone($0) }))
            }

            if exercise.hasSubQuestions {
                Section("Questions · \(exercise.subQuestionLabel ?? "")") {
                    ForEach(exercise.leafSubQuestions) { question in
                        Toggle(isOn: Binding(get: { question.isDone }, set: { done in
                            question.isDone = done
                            question.doneAt = done ? Date() : nil
                            exercise.refreshCompletion()
                        })) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(question.path).monospacedDigit().foregroundStyle(.secondary)
                                Text(question.text.isEmpty ? " " : question.text).lineLimit(3)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }

            Section("Correction") {
                Picker("Correction", selection: Binding(get: { exercise.correctness }, set: { value in
                    if let value { exercise.correct(value) } else { exercise.clearCorrection() }
                })) {
                    Text("—").tag(Correctness?.none)
                    ForEach(Correctness.allCases) { Text($0.shortLabel).tag(Correctness?.some($0)) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Toggle("À refaire", isOn: $exercise.redoRequired)
                TextField("Remarque", text: Binding(get: { exercise.correctionNote ?? "" },
                                                    set: { exercise.correctionNote = $0.isEmpty ? nil : $0 }),
                          axis: .vertical)
                    .lineLimit(2...5)
            }

            if !exercise.hint.isEmpty {
                Section("Indication") {
                    Text(exercise.hint).textSelection(.enabled)
                }
            }
            if !exercise.solution.isEmpty, exercise.series?.solutionsAt.map({ $0 <= Date() }) ?? true {
                Section("Solution") {
                    DisclosureGroup("Afficher la solution") {
                        Text(exercise.solution).textSelection(.enabled)
                    }
                }
            }

            Section {
                LabeledContent("Temps passé", value: DateUtils.hoursLabel(seconds: ExerciseFlow.seconds(on: exercise)))
                Button(action: time) { Label("Chronométrer", systemImage: "play.circle") }
                if let url = URL(string: exercise.statementURLString.isEmpty ? (exercise.series?.urlString ?? "") : exercise.statementURLString),
                   url.scheme?.hasPrefix("http") == true {
                    Link(destination: url) { Label("Énoncé", systemImage: "doc.richtext") }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Carnet.ground)
    }
}

private struct TheoryInspector: View {
    @Bindable var item: TheoryItem
    let tint: Color
    var time: () -> Void

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text([item.kind.label, item.number].filter { !$0.isEmpty }.joined(separator: " "))
                        .font(.caption.weight(.semibold)).foregroundStyle(tint)
                    Text(item.title.isEmpty ? item.kind.label : item.title).font(Carnet.serif(.title3))
                    if item.plannedWeek > 0 { Text("Semaine \(item.plannedWeek)").foregroundStyle(.secondary) }
                }
                Toggle("Vu", isOn: Binding(get: { item.isWatched },
                                           set: { item.watchedAt = $0 ? (item.watchedAt ?? Date()) : nil }))
            }
            if let summary = item.summaryText, !summary.isEmpty {
                Section("Résumé") { Text(summary).textSelection(.enabled) }
            }
            Section {
                let sessions = item.targetedSessions ?? []
                LabeledContent("Temps passé", value: DateUtils.hoursLabel(seconds: sessions.reduce(0) { $0 + $1.durationSeconds }))
                Button(action: time) { Label("Chronométrer", systemImage: "play.circle") }
                if let url = URL(string: item.urlString), url.scheme?.hasPrefix("http") == true {
                    Link(destination: url) { Label("Ouvrir", systemImage: "arrow.up.right.square") }
                }
                ForEach(item.links, id: \.url) { link in
                    if let url = URL(string: link.url) {
                        Link(destination: url) { Label(link.title, systemImage: link.kind.icon) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Carnet.ground)
    }
}
