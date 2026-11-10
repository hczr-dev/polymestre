import SwiftUI
import SwiftData
import PDFKit

/// La série, dans le bureau : la liste des exercices (choisir l'un, c'est y
/// passer le chrono), le PDF de l'énoncé ouvert à l'exercice, et sous la main
/// les questions à cocher, la correction, « Demander à Claude ».
struct ExercisePane: View {
    let course: Course?
    var desk: StudyDesk
    var openWeb: (URL, String) -> Void
    /// À côté (le volet de droite) : sans la liste des exercices (le menu du
    /// titre suffit), et un volet plus étroit.
    var compact = false

    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings
    @Query private var allCourses: [Course]
    @State private var seriesID: UUID?

    /// Ta copie de la série, dans tes notes (GoodNotes → Google Drive…).
    private func copy(_ series: ExerciseSeries) -> NotesLibrary.Document? {
        guard let course else { return nil }
        return NotesStore.shared.copy(for: series, course: course, among: allCourses)
    }

    private var allSeries: [ExerciseSeries] { course?.sortedSeries.filter { !$0.exercises.isEmpty } ?? [] }

    private var series: ExerciseSeries? {
        if let seriesID, let found = allSeries.first(where: { $0.id == seriesID }) { return found }
        if let current = course?.allExercises.first(where: { $0.id == timer.targetID })?.series { return current }
        let week = course?.currentWeek ?? 0
        return allSeries.first { $0.plannedWeek >= week && !$0.isComplete } ?? allSeries.last
    }

    private var exercise: Exercise? {
        series?.exercises.first { $0.id == timer.targetID }
    }

    /// Le site Botafogo du cours : ses séries se lisent en natif, telles que le site les montre.
    private var botafogoSite: URL? {
        course?.contentSources.compactMap(URL.init(string:)).first { ContentSource.detect(host: $0.host) == .botafogo }
    }

    /// Ouvrir une section du polycopié citée par l'exercice : à côté, l'énoncé
    /// reste sous les yeux.
    private func openPoly(_ path: String) {
        guard let course else { return }
        let title = botafogoSite.flatMap { desk.sites.botafogo($0).section(path)?.title } ?? String(localized: "Polycopié")
        desk.openSide(.init(kind: .reading(.botafogo(title: title, url: path)), title: title, icon: "book.closed", courseID: course.id))
    }

    /// Le panneau « où j'en suis » à droite ; replié par défaut en côte à côte.
    @State private var showsSheet: Bool?
    /// Le corrigé de l'exercice à la place de l'énoncé.
    @State private var showingSolution = false
    /// Les exercices dont on a dit « j'ai essayé » : leur corrigé s'ouvre directement.
    @State private var triedFirst: Set<UUID> = []

    /// Le PDF du corrigé, une fois publié.
    private func solutionAddress(_ series: ExerciseSeries) -> String? {
        guard !series.solutionURLString.isEmpty, !BotafogoLinks.isPage(series.solutionURLString),
              series.solutionURLString != series.urlString,
              series.solutionsAt.map({ $0 <= Date() }) ?? true else { return nil }
        return series.solutionURLString
    }

    private func following(_ exercise: Exercise, in series: ExerciseSeries) -> Exercise? {
        let list = series.sortedExercises
        guard let index = list.firstIndex(where: { $0.id == exercise.id }), index + 1 < list.count else { return nil }
        return list[index + 1]
    }

    var body: some View {
        if let course, let series {
            let tint = Carnet.tint(course.colorHex)
            VStack(spacing: 0) {
                SeriesBar(series: series, allSeries: allSeries, current: exercise, tint: tint,
                          hasCopy: copy(series) != nil, hasSolution: solutionAddress(series) != nil,
                          view: Binding(get: { desk.showingCopy ? .copy : (showingSolution ? .solution : .statement) },
                                        set: { desk.showingCopy = $0 == .copy; showingSolution = $0 == .solution }),
                          showsSheet: exercise == nil ? nil : Binding(get: { showsSheet ?? !compact }, set: { showsSheet = $0 }),
                          compact: compact,
                          pickSeries: { seriesID = $0.id },
                          select: { select($0, in: course) },
                          overview: { timer.retarget(courseID: course.id, taskType: .exercise, targetID: nil) })
                Rectangle().fill(Carnet.rule).frame(height: 1)
                if let exercise {
                    HStack(spacing: 0) {
                        statement(exercise, in: series, course: course, tint: tint)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Carnet.ground)
                        if showsSheet ?? !compact {
                            Rectangle().fill(Carnet.rule).frame(width: 1)
                            ScrollView {
                                ExerciseStudySheet(exercise: exercise, series: series, ask: { desk.ask($0, attachment: $1) }, tint: tint,
                                                   showStatement: false, copy: copy(series), next: { next in select(next, in: course) },
                                                   ladder: ClaudeProjectSetup.file(settings: settings)?.redo ?? RedoLadder.Config(),
                                                   openPoly: openPoly, marksDone: false)
                                    .padding(18)
                            }
                            .frame(width: compact ? 290 : 340)
                            .background(Carnet.sheet.opacity(0.35))
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                } else {
                    SeriesOverview(series: series, tint: tint, compact: compact, start: { select($0, in: course) })
                }
            }
            .animation(.snappy(duration: 0.22), value: showsSheet)
            .task { await NotesStore.shared.refresh() }
        } else {
            ContentUnavailableView {
                Label("Pas de série", systemImage: "doc.text")
            } description: {
                Text(course == nil ? "Choisis un cours." : "Rien d'importé pour ce cours.")
            }
        }
    }

    /// L'énoncé au centre : ta copie si tu l'as demandée, sinon le PDF, la page
    /// Botafogo lue en natif, ou le texte importé.
    @ViewBuilder
    private func statement(_ exercise: Exercise, in series: ExerciseSeries, course: Course, tint: Color) -> some View {
        if showingSolution, let solution = solutionAddress(series) {
            if exercise.isDone || triedFirst.contains(exercise.id) {
                document(series, address: solution)
            } else {
                // Le corrigé se lit après avoir cherché : une marche, pas un mur.
                VStack(spacing: 14) {
                    Image(systemName: "eye.slash").font(.largeTitle).foregroundStyle(Carnet.inkTertiary)
                    Text("Tu as cherché \(exercise.displayNumber) ?").font(Carnet.serif(.title2)).foregroundStyle(Carnet.ink)
                    Text("Le corrigé apprend bien plus après un vrai essai, même raté.")
                        .foregroundStyle(Carnet.inkSecondary)
                    HStack {
                        Button {
                            triedFirst.insert(exercise.id)
                            // Lu avant d'avoir fini : noté comme l'indice le plus fort.
                            exercise.recordHint(level: 4, text: String(localized: "Corrigé (PDF) lu avant d'avoir fini"))
                        } label: { Label("Voir le corrigé", systemImage: "checkmark.seal") }
                            .buttonStyle(.ink)
                        Button {
                            showingSolution = false
                            desk.ask(ClaudeTutor.QuickAction.hint.prompt, attachment: nil)
                        } label: { Label("Plutôt un indice", systemImage: "lightbulb") }
                            .buttonStyle(.paper)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if desk.showingCopy, copy(series) != nil {
            document(series, address: address(series))
        } else if !statementAddress(series).isEmpty {
            document(series, address: statementAddress(series))
        } else if let site = botafogoSite, BotafogoLinks.isPage(series.urlString) || BotafogoLinks.isPage(exercise.statementURLString) {
            BotafogoExerciseStatement(book: desk.sites.botafogo(site), site: site,
                                      exercisePath: BotafogoLinks.coursPath(exercise.statementURLString),
                                      seriesPath: BotafogoLinks.coursPath(series.urlString),
                                      position: series.sortedExercises.firstIndex { $0.id == exercise.id } ?? 0,
                                      heading: (exercise.displayNumber, exercise.title),
                                      desk: desk.sites, openPoly: openPoly, openWeb: openWeb, tint: tint)
        } else {
            nativeStatement
        }
    }

    private func name(_ series: ExerciseSeries) -> String {
        series.title.isEmpty ? series.displayName : series.title
    }

    /// Choisir un exercice, c'est y passer le chrono : le temps est compté à
    /// l'exercice, sans rien couper.
    private func select(_ exercise: Exercise, in course: Course) {
        seriesID = exercise.series?.id
        timer.retarget(courseID: course.id, taskType: .exercise, targetID: exercise.id)
    }

    // MARK: Document

    private func address(_ series: ExerciseSeries) -> String {
        if desk.showingCopy, let copy = copy(series), let url = NotesStore.shared.url(copy) { return url.absoluteString }
        return statementAddress(series)
    }

    /// Le PDF de l'énoncé ; vide pour une série Botafogo, lue en natif.
    private func statementAddress(_ series: ExerciseSeries) -> String {
        let address = exercise?.statementURLString.isEmpty == false ? exercise!.statementURLString : series.urlString
        return BotafogoLinks.isPage(address) ? "" : address
    }

    @ViewBuilder
    private func document(_ series: ExerciseSeries, address: String) -> some View {
        Group {
            switch desk.document(address) {
            case .ready(let file)?:
                if desk.showingCopy, !showingSolution {
                    PDFPane(url: file, search: searchTerms)
                } else if let exercise {
                    // L'exercice seul (énoncé ou corrigé), le PDF entier sur demande.
                    ExercisePDFView(file: file, exercise: exercise, next: following(exercise, in: series), memory: address)
                } else {
                    PDFPane(url: file, memory: address)
                }
            case .needsLogin?:
                loginPrompt(address)
            case .failed?:
                VStack(spacing: 12) {
                    Image(systemName: "doc.questionmark").font(.largeTitle).foregroundStyle(Carnet.inkTertiary)
                    Text("Énoncé introuvable").foregroundStyle(Carnet.inkSecondary)
                    Button("Réessayer") { desk.retry(address) }.buttonStyle(.paper)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loading?, nil:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear { desk.loadPDF(address) }
            }
        }
    }

    /// Les mots qui retrouvent l'exercice dans le PDF : « Exercice 2 »,
    /// « Ex-03-02 »…
    private var searchTerms: [String] {
        guard let exercise else { return [] }
        let number = exercise.exerciseNumber
        let last = number.split(separator: ".").last.map(String.init) ?? number
        var terms = ["Exercice \(number)", "Exercice \(last)", "Exercise \(last)", "Ex. \(last)"]
        if let series = exercise.series, let n = Int(last) {
            terms.insert(String(format: "Ex-%02d-%02d", series.seriesNumber, n), at: 0)
            terms.append(String(format: "Exercice %d.%d", series.seriesNumber, n))
        }
        return terms
    }

    /// L'énoncé lu par l'import (Botafogo, ou extrait du PDF), quand il n'y a
    /// pas de PDF à montrer.
    @ViewBuilder
    private var nativeStatement: some View {
        if let exercise, !exercise.statement.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(exercise.displayNumber).font(Carnet.serif(.largeTitle)).foregroundStyle(Carnet.ink)
                    MacMathText(exercise.statement, size: 15).foregroundStyle(Carnet.ink).textSelection(.enabled)
                    if !exercise.hint.isEmpty {
                        DisclosureGroup("Indication") {
                            MacMathText(exercise.hint, size: 14).foregroundStyle(Carnet.ink).textSelection(.enabled)
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: 760, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Choisis un exercice", systemImage: "list.number")
        }
    }

    private func loginPrompt(_ address: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "person.badge.key").font(.largeTitle).foregroundStyle(Carnet.inkSecondary)
            Text("Connecte-toi à Moodle").font(Carnet.serif(.title2)).foregroundStyle(Carnet.ink)
            HStack {
                Button("Se connecter") { desk.signIn = .moodle }.buttonStyle(.ink)
                Button("Réessayer") { desk.retry(address) }.buttonStyle(.paper)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - La barre de la série

/// Ce que montre le centre : l'énoncé, le corrigé, ou ta copie.
enum StatementView: Hashable { case statement, solution, copy }

/// En haut du volet : la série (menu), ses exercices en pastilles — où en est
/// chacun d'un coup d'œil, un clic pour y passer —, précédent / suivant
/// (⌥⌘← ⌥⌘→), l'énoncé ou ta copie, et le panneau « où j'en suis ».
private struct SeriesBar: View {
    let series: ExerciseSeries
    let allSeries: [ExerciseSeries]
    let current: Exercise?
    let tint: Color
    let hasCopy: Bool
    let hasSolution: Bool
    @Binding var view: StatementView
    /// `nil` sans exercice ouvert (rien à montrer à droite).
    var showsSheet: Binding<Bool>?
    let compact: Bool
    var pickSeries: (ExerciseSeries) -> Void
    var select: (Exercise) -> Void
    var overview: () -> Void

    private var exercises: [Exercise] { series.sortedExercises }


    private var neighbours: (previous: Exercise?, next: Exercise?) {
        guard let current, let index = exercises.firstIndex(where: { $0.id == current.id }) else {
            return (nil, ExerciseFlow.resumePoint(in: exercises) ?? exercises.first)
        }
        return (index > 0 ? exercises[index - 1] : nil, index + 1 < exercises.count ? exercises[index + 1] : nil)
    }

    /// Entière si elle tient dans la place donnée ; sinon resserrée (« J'ai
    /// fini » en icône, l'affichage en menu, sans l'échéance) plutôt que de
    /// déborder.
    var body: some View {
        Group {
            if compact {
                bar(narrow: true)
            } else {
                ViewThatFits(in: .horizontal) {
                    bar(narrow: false)
                    bar(narrow: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 46)
        .background(Carnet.sheet.opacity(0.4))
    }

    private func bar(narrow: Bool) -> some View {
        HStack(spacing: narrow ? 8 : 12) {
            Menu {
                ForEach(allSeries) { item in
                    Button { pickSeries(item) } label: {
                        Text(item.title.isEmpty ? item.displayName : item.title)
                        Text("\(item.doneCount)/\(item.requiredExercises.count) faits")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    ThinRing(fraction: series.requiredExercises.isEmpty ? 0 : Double(series.doneCount) / Double(series.requiredExercises.count), tint: tint)
                        .frame(width: 16, height: 16)
                    Text(series.title.isEmpty ? series.displayName : series.title)
                        .font(Carnet.serif(.title3, weight: .medium))
                        .foregroundStyle(Carnet.ink)
                        .lineLimit(1)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize(horizontal: !narrow, vertical: false)
            .help("Changer de série")

            Button(action: overview) {
                Image(systemName: "square.grid.2x2")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(current == nil ? tint : Carnet.inkSecondary)
            .help("Vue d'ensemble de la série")

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(exercises) { item in
                            ExerciseChip(exercise: item, isCurrent: item.id == current?.id, tint: tint) { select(item) }
                                .id(item.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onAppear { if let current { proxy.scrollTo(current.id, anchor: .center) } }
                .onChange(of: current?.id) { _, id in
                    if let id { withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) } }
                }
            }

            HStack(spacing: 2) {
                Button { neighbours.previous.map(select) } label: { Image(systemName: "chevron.left") }
                    .disabled(neighbours.previous == nil)
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    .help("Exercice précédent (⌥⌘←)")
                Button { neighbours.next.map(select) } label: { Image(systemName: "chevron.right") }
                    .disabled(neighbours.next == nil)
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    .help("Exercice suivant (⌥⌘→)")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Carnet.inkSecondary)

            if let current {
                DoneControl(exercise: current, tint: tint, next: neighbours.next, select: select, iconOnly: narrow)
            }

            if hasCopy || hasSolution, current != nil {
                if narrow {
                    Picker("Afficher", selection: $view) {
                        Text("Énoncé").tag(StatementView.statement)
                        if hasSolution { Text("Corrigé").tag(StatementView.solution) }
                        if hasCopy { Text("Ma copie").tag(StatementView.copy) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                } else {
                    Picker("Afficher", selection: $view) {
                        Text("Énoncé").tag(StatementView.statement)
                        if hasSolution { Text("Corrigé").tag(StatementView.solution) }
                        if hasCopy { Text("Ma copie").tag(StatementView.copy) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if !narrow, let due = series.dueDate {
                Text("à rendre \(DateUtils.countdownLabel(to: due))")
                    .font(.caption)
                    .foregroundStyle(due < Date() ? Carnet.wrong : Carnet.inkSecondary)
                    .fixedSize()
            }
            if let showsSheet {
                Button { showsSheet.wrappedValue.toggle() } label: { Image(systemName: "sidebar.right") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(showsSheet.wrappedValue ? tint : Carnet.inkSecondary)
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .help("Où j'en suis (⌥⌘I)")
            }
        }
        .padding(.horizontal, narrow ? 10 : 14)
    }
}

private struct DoneLabelStyle: LabelStyle {
    let iconOnly: Bool
    func makeBody(configuration: Configuration) -> some View {
        if iconOnly { configuration.icon } else { HStack(spacing: 6) { configuration.icon; configuration.title } }
    }
}

/// « J'ai fini » : les questions faites, puis la sûreté (demandée, jamais
/// supposée) — choisir marque l'exercice fait et passe au suivant. Fait, le
/// bouton le dit, et un clic l'annule.
private struct DoneControl: View {
    @Bindable var exercise: Exercise
    let tint: Color
    let next: Exercise?
    var select: (Exercise) -> Void
    /// La barre est étroite : l'icône seule.
    var iconOnly = false
    @State private var asking = false

    var body: some View {
        Button {
            asking = true
        } label: {
            Label(exercise.isDone ? "Fait" : "J'ai fini", systemImage: exercise.isDone ? "checkmark.circle.fill" : "checkmark.circle")
                .labelStyle(DoneLabelStyle(iconOnly: iconOnly))
                .font(.callout.weight(.semibold))
                .padding(.horizontal, iconOnly ? 8 : 12)
                .frame(height: 28)
                .foregroundStyle(exercise.isDone ? Carnet.correct : Carnet.ground)
                .background(exercise.isDone ? Carnet.correct.opacity(0.14) : Carnet.ink, in: Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: [.command, .shift])
        .help(exercise.isDone ? "Fait — modifier" : "J'ai fini cet exercice (⇧⌘↩)")
        .popover(isPresented: $asking, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                Text(exercise.displayNumber).font(Carnet.serif(.title2)).foregroundStyle(Carnet.ink)
                if exercise.hasSubQuestions {
                    VStack(alignment: .leading, spacing: 6) {
                        Kicker("Les questions faites")
                        SubQuestionChecklist(exercise: exercise, tint: tint)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Kicker("Tu es sûr·e de toi ?")
                    HStack(spacing: 8) {
                        ForEach(ConfidenceLevel.allCases) { level in
                            Button { finish(level) } label: {
                                Label(level.label, systemImage: level.icon)
                                    .font(.callout)
                                    .padding(.horizontal, 10)
                                    .frame(height: 30)
                                    .foregroundStyle(exercise.confidence == level ? Carnet.ground : level.color)
                                    .background(exercise.confidence == level ? level.color : level.color.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                HStack {
                    if exercise.isDone {
                        Button("Marquer à faire") { exercise.setDone(false); asking = false }.buttonStyle(.paper)
                    } else {
                        Button("Fait, sans le dire") { finish(nil) }.buttonStyle(.paper)
                    }
                    Spacer()
                    if let next {
                        Text("ensuite \(next.displayNumber)").font(.caption).foregroundStyle(Carnet.inkTertiary)
                    }
                }
            }
            .padding(18)
            .frame(width: 420)
        }
    }

    private func finish(_ level: ConfidenceLevel?) {
        let wasDone = exercise.isDone
        if let level { exercise.confidence = level }
        if !wasDone { exercise.setDone(true) }
        asking = false
        // Fini : on passe au suivant (pas quand on corrige seulement la sûreté).
        if !wasDone, let next {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                select(next)
            }
        }
    }
}

/// Un exercice en pastille : son numéro, et sa couleur dit où il en est —
/// contour (à faire), arc (questions en cours), coche (fait, à corriger),
/// vert / orange / rouge (corrigé), ↻ (à refaire).
private struct ExerciseChip: View {
    @Bindable var exercise: Exercise
    let isCurrent: Bool
    let tint: Color
    var select: () -> Void
    @State private var hovering = false

    private var stage: ExerciseStage { ExerciseStage(exercise) }

    private var number: String {
        exercise.exerciseNumber.split(separator: ".").last.map(String.init) ?? exercise.exerciseNumber
    }

    private var fill: Color {
        switch stage {
        case .corrected(let result): return Carnet.color(for: result)
        case .redo: return Carnet.wrong
        case .toCorrect: return tint
        default: return .clear
        }
    }

    var body: some View {
        Button(action: select) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isCurrent ? tint.opacity(0.22) : (hovering ? Carnet.sheetRaised : Carnet.sheet.opacity(0.6)))
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isCurrent ? tint : Carnet.rule, lineWidth: isCurrent ? 1.5 : 1)
                HStack(spacing: 4) {
                    Text(number)
                        .font(.callout.weight(isCurrent ? .semibold : .medium).monospacedDigit())
                        .foregroundStyle(isCurrent ? Carnet.ink : Carnet.inkSecondary)
                    marker
                }
                .padding(.horizontal, 8)
            }
            .frame(minWidth: 34)
            .frame(height: 28)
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(exercise.displayNumber)\(exercise.title.isEmpty ? "" : " — \(exercise.title)") · \(stage.label)")
        .contextMenu {
            Button(exercise.isDone ? "Marquer à faire" : "Marquer comme fait") { exercise.setDone(!exercise.isDone) }
            Toggle("À refaire", isOn: $exercise.redoRequired)
        }
    }

    @ViewBuilder
    private var marker: some View {
        switch stage {
        case .toDo:
            EmptyView()
        case .inProgress(let done, let total):
            ThinRing(fraction: Double(done) / Double(max(total, 1)), tint: tint).frame(width: 9, height: 9)
        case .toCorrect:
            Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(tint)
        case .corrected:
            Circle().fill(fill).frame(width: 7, height: 7)
        case .redo:
            Image(systemName: "arrow.counterclockwise").font(.caption2.weight(.bold)).foregroundStyle(Carnet.wrong)
        }
    }
}

// MARK: - Vue d'ensemble

/// La série quand aucun exercice n'est ouvert : où on en est, ce qui reste,
/// et le bouton qui reprend là où il faut.
private struct SeriesOverview: View {
    let series: ExerciseSeries
    let tint: Color
    let compact: Bool
    var start: (Exercise) -> Void

    private var resume: Exercise? { ExerciseFlow.resumePoint(in: series.sortedExercises) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    if let course = series.course { Kicker(course.displayCode, color: tint) }
                    Text(series.title.isEmpty ? series.displayName : series.title)
                        .font(StudyType.display)
                        .foregroundStyle(Carnet.ink)
                    HStack(spacing: 14) {
                        Label("\(series.doneCount) sur \(series.requiredExercises.count) faits", systemImage: "checkmark.circle")
                        if let due = series.dueDate {
                            Label("à rendre \(DateUtils.countdownLabel(to: due))", systemImage: "calendar")
                                .foregroundStyle(due < Date() ? Carnet.wrong : Carnet.inkSecondary)
                        }
                        let seconds = ExerciseFlow.seconds(on: series)
                        if seconds >= 60 { Label(DateUtils.durationLabel(seconds: seconds), systemImage: "timer") }
                    }
                    .font(.callout)
                    .foregroundStyle(Carnet.inkSecondary)
                    GeometryReader { proxy in
                        let fraction = series.requiredExercises.isEmpty ? 0 : CGFloat(series.doneCount) / CGFloat(series.requiredExercises.count)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Carnet.rule)
                            Capsule().fill(tint).frame(width: max(6, proxy.size.width * fraction))
                        }
                    }
                    .frame(height: 6)
                    .padding(.top, 4)
                }
                if let resume {
                    Button { start(resume) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ExerciseStage(resume) == .toDo && series.doneCount == 0 ? "Commencer" : "Reprendre")
                                    .font(.caption.weight(.semibold)).textCase(.uppercase).opacity(0.8)
                                Text(resume.displayNumber + (resume.title.isEmpty ? "" : " — \(resume.title)"))
                                    .font(Carnet.serif(.title2, weight: .medium))
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "arrow.right").font(.title3.weight(.semibold))
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .foregroundStyle(Carnet.ground)
                        .background(tint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])
                } else {
                    Label("Toute la série est corrigée.", systemImage: "checkmark.seal")
                        .font(Carnet.serif(.title2))
                        .foregroundStyle(Carnet.correct)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 180 : 220), spacing: 10)], spacing: 10) {
                    ForEach(series.sortedExercises) { exercise in
                        ExerciseCard(exercise: exercise, tint: tint, isNext: exercise.id == resume?.id) { start(exercise) }
                    }
                }
            }
            .padding(compact ? 22 : 36)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Carnet.ground)
    }
}

private struct ExerciseCard: View {
    @Bindable var exercise: Exercise
    let tint: Color
    let isNext: Bool
    var open: () -> Void
    @State private var hovering = false

    private var stage: ExerciseStage { ExerciseStage(exercise) }

    private var stageColor: Color {
        switch stage {
        case .corrected(let result): return Carnet.color(for: result)
        case .redo: return Carnet.wrong
        case .toCorrect, .inProgress: return tint
        case .toDo: return Carnet.inkTertiary
        }
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(exercise.displayNumber).font(Carnet.serif(.title3, weight: .medium)).foregroundStyle(Carnet.ink)
                    if exercise.isBonus { Text("bonus").font(.caption2).foregroundStyle(Carnet.inkTertiary) }
                    Spacer()
                    Text(stage.label)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .foregroundStyle(stageColor)
                        .background(stageColor.opacity(0.14), in: Capsule())
                }
                let line = exercise.title.isEmpty ? exercise.statement : exercise.title
                if !line.isEmpty {
                    MacMathText(line, size: 12.5)
                        .foregroundStyle(Carnet.inkSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                let seconds = ExerciseFlow.seconds(on: exercise)
                if seconds >= 60 {
                    Label(DateUtils.durationLabel(seconds: seconds), systemImage: "timer")
                        .font(.caption2).foregroundStyle(Carnet.inkTertiary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
            .background(hovering ? Carnet.sheetRaised : Carnet.sheet, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(isNext ? tint : Carnet.rule, lineWidth: isNext ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(exercise.isDone ? "Marquer à faire" : "Marquer comme fait") { exercise.setDone(!exercise.isDone) }
            Toggle("À refaire", isOn: $exercise.redoRequired)
        }
    }
}
