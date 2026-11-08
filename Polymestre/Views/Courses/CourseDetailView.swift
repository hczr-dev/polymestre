import SwiftUI
import SwiftData

/// Un cours, **semaine par semaine**.
///
/// On ouvre un cours pour savoir quoi faire cette semaine : la théorie à voir
/// (vidéo, transparents, section du polycopié, leçon du MOOC — chacune liée),
/// la série et ses exercices jusqu'aux sous-questions, ce qui tombe cette
/// semaine. Les puces S1…S14 changent de semaine ; « Tout le cours » garde les
/// listes complètes (Séries | Théorie) et leurs outils d'édition. L'en-tête est
/// du papier : le nom du cours en serif, puis la carte de la semaine choisie —
/// théorie et exercices faits sur prévus, et le retard dit en mots.
struct CourseDetailView: View {
    let course: Course
    /// Section ouverte à l'arrivée. La recherche y mène directement.
    var initialSection: Section = .exercises
    /// L'exercice ou la théorie à ouvrir en arrivant (recherche, Spotlight).
    var initialTargetID: UUID? = nil

    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Section = .exercises
    @State private var showingProgress = false
    @State private var showingLate = false
    @State private var showingExams = false
    @State private var showingDocuments = false
    @State private var showingNotes = false
    @State private var hasAppliedInitialSection = false
    @State private var showingEditor = false
    @State private var showingDelete = false
    @State private var showingSeriesImport = false
    @State private var showingAddTheory = false
    @State private var showingAddExam = false

    enum Section: String, CaseIterable, Identifiable, Hashable {
        case exercises, theory
        /// Pages poussées, pas des segments.
        case exams, progress
        var id: String { rawValue }
        static var segments: [Section] { [.exercises, .theory] }
        var title: String {
            switch self {
            case .theory: return "Théorie"
            case .exercises: return "Séries"
            case .progress: return "Progression"
            case .exams: return "Examens"
            }
        }
    }

    /// `-scrollDown` : `simctl` ne sait pas faire défiler ; l'en-tête est
    /// masqué pour que la capture montre la liste.
    private var debugHidesHeader: Bool {
        #if DEBUG
        return PreviewLaunch.isSet(PreviewLaunch.scrollDownFlag)
        #else
        return false
        #endif
    }

    /// La semaine affichée ; `nil` = « Tout le cours ».
    @State private var shownWeek: Int?
    @State private var hasChosenWeek = false
    /// La dernière semaine cochée d'un geste, le temps de proposer « Annuler ».
    @State private var completion: CompletionUndo?

    struct CompletionUndo: Equatable {
        var change: WeekCompletion.Change
        var label: String
    }
    @State private var openedExercise: Exercise?
    @State private var openedVideo: TheoryItem?
    @State private var browsing: BrowsedLink?

    private var totalWeeks: Int {
        let planned = course.theoryItems.map(\.plannedWeek) + course.series.map(\.plannedWeek)
        return max(course.term?.totalWeeks ?? 14, planned.max() ?? 0)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 22) {
                    if !debugHidesHeader {
                        hero
                    }
                    weekPicker
                    if let week = shownWeek {
                        weekContent(week)
                    } else {
                        allContent
                    }
                }
                .padding(.horizontal, Carnet.screenPadding)
                .padding(.top, 8)
                .padding(.bottom, 32)
                .frame(maxWidth: Layout.readableWidth)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Carnet.ground.ignoresSafeArea())
        .overlay(alignment: .bottom) { completionBar }
        .animation(Motion.snappy, value: completion)
        .navigationTitle(course.displayCode)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(isPresented: $showingEditor) { CourseFormView(course: course) }
        .sheet(isPresented: $showingSeriesImport) { SeriesImportSheet(course: course) }
        .sheet(isPresented: $showingAddTheory) { TheoryItemForm(course: course) }
        .sheet(isPresented: $showingAddExam) { ExamFormSheet(course: course) }
        .sheet(item: $openedExercise) { exercise in ExerciseSheet(exercise: exercise) }
        .sheet(item: $openedVideo) { video in VideoDetailSheet(video: video) }
        .sheet(item: $browsing) { InAppBrowser(link: $0) }
        .navigationDestination(isPresented: $showingProgress) {
            ScrollView {
                ProgressTabView(course: course)
                    .padding(Layout.screenPadding)
                    .adaptiveColumn()
            }
            .background(Carnet.ground.ignoresSafeArea())
            .navigationTitle("Progression · \(course.displayCode)")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationDestination(isPresented: $showingLate) {
            LateWorkScreen(course: course)
        }
        .navigationDestination(isPresented: $showingExams) {
            CourseExamsView(course: course)
        }
        .navigationDestination(isPresented: $showingNotes) {
            ScrollView {
                CourseNotesView(course: course)
                    .padding(Layout.screenPadding)
                    .adaptiveColumn()
            }
            .background(Carnet.ground.ignoresSafeArea())
            .navigationTitle("Notes · \(course.displayCode)")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationDestination(isPresented: $showingDocuments) {
            CourseDocumentsView(course: course)
        }
        .onAppear {
            if !hasChosenWeek {
                hasChosenWeek = true
                let empty = course.theoryItems.isEmpty && course.series.isEmpty
                shownWeek = (course.isTermRunning && !empty) ? min(max(course.currentWeek, 1), totalWeeks) : nil
            }
            if !hasAppliedInitialSection {
                hasAppliedInitialSection = true
                switch initialSection {
                case .progress: showingProgress = true
                case .exams: showingExams = true
                case .theory: shownWeek = nil; tab = .theory
                default: break
                }
                if let target = initialTargetID {
                    if let exercise = course.allExercises.first(where: { $0.id == target }) {
                        tab = .exercises
                        openedExercise = exercise
                    } else if let item = course.theoryItems.first(where: { $0.id == target }) {
                        tab = .theory
                        openedVideo = item
                    }
                }
            }
            #if DEBUG
            if let raw = PreviewLaunch.string(PreviewLaunch.courseTabFlag) {
                if raw == "all" { shownWeek = nil }
                if raw == "weekTheory" { tab = .theory }
                if let section = Section(rawValue: raw) {
                    switch section {
                    case .progress: showingProgress = true
                    case .exams: showingExams = true
                    default: shownWeek = nil; tab = section
                    }
                }
            }
            #endif
        }
        .confirmationDialog("Supprimer « \(course.displayCode) » ?",
                            isPresented: $showingDelete,
                            titleVisibility: .visible) {
            Button("Supprimer le cours et son historique", role: .destructive) { deleteCourse() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Théorie, séries, évaluations et \(DateUtils.hoursLabel(seconds: WorkloadEngine.studySeconds(for: course))) de sessions seront effacées. « Archiver » garde tout, hors de la vue.")
        }
    }

    // MARK: En-tête

    /// Le cours sur papier : son code à sa couleur, son nom en serif, ses heures.
    /// L'ancien bandeau mettait du texte blanc sur la couleur du cours — illisible
    /// sur un jaune ou un vert pâle — et un panneau de verre aux libellés éteints.
    private var hero: some View {
        let tint = Carnet.tint(course.colorHex)
        return VStack(alignment: .leading, spacing: 6) {
            // Le code est déjà le titre de la barre : ici, seulement d'où vient le cours.
            if let source = CarnetCourseCard.sourceLabel(course) {
                CarnetKicker(source, color: tint)
            }
            Text(course.name.isEmpty ? course.displayCode : course.name)
                .font(Carnet.serif(.largeTitle))
                .foregroundStyle(Carnet.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(metaLine)
                .font(.footnote)
                .foregroundStyle(Carnet.inkSecondary)
            CourseSitesRow(course: course) { url, title in
                browsing = BrowsedLink(title: title, url: url, icon: "globe")
            }
            .padding(.top, 4)
            if course.theoryItems.isEmpty && course.series.isEmpty {
                Button {
                    app.router.openContentImport(courseID: course.id)
                } label: {
                    Label("Importer le contenu du cours", systemImage: "square.and.arrow.down.on.square")
                }
                .buttonStyle(.carnetPrimaryWide)
                .padding(.top, 10)
            }
        }
        .padding(.horizontal, 6)
    }

    /// La carte d'une semaine : ce qu'elle demande, ce qui est fait, et où en est
    /// le cours — en mots (« 3 éléments des semaines passées à rattraper »),
    /// jamais en nombre signé.
    private func weekSummary(_ week: Int) -> some View {
        let tint = Carnet.tint(course.colorHex)
        let progress = ProgressEngine.weekProgress(for: course, week: week)
        let isCurrent = course.isTermRunning && week == course.currentWeek
        let late = ProgressEngine.lateCount(for: course)
        let ahead = ProgressEngine.aheadCount(for: course)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isCurrent ? "Cette semaine · S\(week)" : "Semaine \(week)")
                        .font(Carnet.serif(.title2))
                        .foregroundStyle(Carnet.ink)
                    if let dates = weekDates(week) {
                        Text(dates).font(.footnote).foregroundStyle(Carnet.inkSecondary)
                    }
                }
                Spacer(minLength: 8)
                if progress.isComplete {
                    Label("faite", systemImage: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Carnet.correct)
                } else if progress.hasItems {
                    completionMenu(week...week, title: "Semaine \(week)") {
                        Label("Tout cocher", systemImage: "checklist.checked")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Carnet.ink)
                    }
                }
            }
            if progress.hasItems {
                HStack(spacing: 16) {
                    summaryAxis("Théorie", done: progress.watchedCount, total: progress.videoCount, tint: tint)
                    summaryAxis("Exercices", done: progress.doneCount, total: progress.exerciseCount, tint: tint)
                    if progress.doneCount > 0 {
                        summaryAxis("Corrigés", done: progress.correctedCount, total: progress.doneCount, tint: tint)
                    }
                }
            } else {
                Text("Rien n'est rangé dans cette semaine.")
                    .font(.subheadline)
                    .foregroundStyle(Carnet.inkSecondary)
            }
            if isCurrent || late > 0 {
                Rectangle().fill(Carnet.rule).frame(height: 1)
                Button { if late > 0 { showingLate = true } else { showingProgress = true } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: late > 0 ? "exclamationmark.circle" : "checkmark.circle")
                            .foregroundStyle(late > 0 ? Carnet.wrong : Carnet.correct)
                        Text(standingSentence(late: late, ahead: ahead))
                            .font(.subheadline)
                            .foregroundStyle(Carnet.ink)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Carnet.inkTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(late > 0 ? "Ouvre ce qui est à rattraper" : "Ouvre la progression semaine par semaine")
            }
        }
        .padding(16)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: Carnet.sheetCorner, bottomLeadingRadius: Carnet.sheetCorner,
                                   style: .continuous)
                .fill(tint)
                .frame(width: 5)
        }
        .clipShape(RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
    }

    private func summaryAxis(_ title: String, done: Int, total: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(ui: title).font(.caption).foregroundStyle(Carnet.inkSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(total == 0 ? "—" : "\(done)")
                    .font(Carnet.serif(.title2))
                    .foregroundStyle(total > 0 && done == total ? Carnet.correct : Carnet.ink)
                if total > 0 {
                    Text("/\(total)").font(.subheadline).foregroundStyle(Carnet.inkSecondary)
                }
            }
            CarnetBar(value: CourseProgress.ratio(done, total), tint: tint, height: 4)
                .opacity(total == 0 ? 0.3 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) : \(done) sur \(total)")
    }

    /// « 4 à rattraper : 1 à refaire, 3 exercices à faire », « À jour, 2 d'avance ».
    private func standingSentence(late: Int, ahead: Int) -> String {
        if late > 0 {
            return "\(late) à rattraper : " + LateWork.of(course).summary
        }
        if ahead > 0 { return "À jour, et \(ahead) d'avance" }
        return "À jour sur les semaines passées"
    }

    /// « 28 sept – 2 oct » : du lundi au vendredi de la semaine d'enseignement.
    private func weekDates(_ week: Int) -> String? {
        guard let term = course.term else { return nil }
        let monday = DateUtils.addTeachingWeeks(week - 1, to: term.startDate)
        let friday = DateUtils.addDays(4, to: monday)
        let format = Date.FormatStyle().day().month(.abbreviated).locale(Locale(identifier: "fr_CH"))
        return "\(monday.formatted(format)) – \(friday.formatted(format))"
    }

    // MARK: Semaines

    private var weekPicker: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button { withAnimation(Motion.snappy) { shownWeek = nil } } label: {
                        CarnetChip(text: "Tout le cours", isSelected: shownWeek == nil)
                    }
                    .buttonStyle(.plain)
                    ForEach(1...max(totalWeeks, 1), id: \.self) { week in
                        let progress = ProgressEngine.weekProgress(for: course, week: week)
                        Button { withAnimation(Motion.snappy) { shownWeek = week } } label: {
                            weekChip(week, progress: progress)
                        }
                        .buttonStyle(.plain)
                        .id(week)
                        .accessibilityLabel("Semaine \(week)")
                    }
                }
                .padding(.horizontal, 2)
            }
            .onAppear {
                if let shownWeek { proxy.scrollTo(shownWeek, anchor: .center) }
            }
        }
    }

    private func weekChip(_ week: Int, progress: WeeklyProgress) -> some View {
        let selected = shownWeek == week
        let isCurrent = course.isTermRunning && week == course.currentWeek
        return VStack(spacing: 3) {
            Text("S\(week)")
                .font(.subheadline.weight(selected || isCurrent ? .semibold : .regular))
                .foregroundStyle(selected ? Carnet.ground : (progress.hasItems ? Carnet.ink : Carnet.inkTertiary))
            Circle()
                .fill(progress.isComplete ? Carnet.correct : (progress.hasItems ? (selected ? Carnet.ground : Carnet.inkTertiary) : .clear))
                .frame(width: 4, height: 4)
        }
        .frame(minWidth: 42, minHeight: 40)
        .background(selected ? Carnet.ink : (isCurrent ? Carnet.sheetRaised : Carnet.sheet), in: Capsule())
    }

    // MARK: Une semaine

    @ViewBuilder
    private func weekContent(_ week: Int) -> some View {
        let theory = course.sortedTheoryItems.filter { $0.plannedWeek == week }
        let series = course.sortedSeries.filter { $0.plannedWeek == week }
        let deadlines = course.sortedExams.filter { exam in
            course.term.map { DateUtils.weekNumber(for: exam.date, term: $0) == week } ?? false
        }
        weekSummary(week)

        // Deux volets, comme « Tout le cours » : les séries, ou la théorie.
        Picker("Volet", selection: $tab) {
            Text("Séries · \(series.reduce(0) { $0 + $1.doneCount })/\(series.reduce(0) { $0 + $1.requiredExercises.count })")
                .tag(Section.exercises)
            Text("Théorie · \(theory.filter(\.isWatched).count)/\(theory.count)")
                .tag(Section.theory)
        }
        .pickerStyle(.segmented)

        if tab == .theory {
            AnkiCourseRow(course: course)
            if theory.isEmpty {
                CarnetEmpty(icon: "book", title: "Pas de théorie",
                            message: "Rien en semaine \(week).")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(watchSummary(theory))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Carnet.ink)
                        if let topic = weekTopic(theory: theory, series: series) {
                            Text(topic)
                                .font(.footnote)
                                .foregroundStyle(Carnet.inkSecondary)
                        }
                        // La consigne de la semaine, comprise en lisant tout le cours.
                        if let guide = course.weekGuide[week] {
                            Label {
                                Text(guide)
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(Carnet.tint(course.colorHex))
                            }
                            .font(.footnote)
                            .foregroundStyle(Carnet.inkSecondary)
                            .padding(.top, 2)
                            .accessibilityLabel("Cette semaine : \(guide)")
                        }
                    }
                    .padding(.horizontal, 6)
                    // Ce qu'il faut regarder cette semaine : le cours (son
                    // enregistrement, ses supports), puis les chapitres du MOOC
                    // demandés — chacun avec ses vidéos, nommées une à une.
                    let ordered = theory.sorted { lhs, rhs in
                        let l = lhs.title.hasPrefix("MOOC"), r = rhs.title.hasPrefix("MOOC")
                        if l != r { return !l }
                        // Les chapitres du MOOC dans l'ordre du MOOC (« M1-12 » avant « M1-13 »).
                        if l, r, lhs.number != rhs.number {
                            return lhs.number.localizedStandardCompare(rhs.number) == .orderedAscending
                        }
                        return lhs.sortOrder < rhs.sortOrder
                    }
                    ForEach(ordered) { item in
                        WeekTheoryCard(item: item, onOpen: { openedVideo = item }, onBrowse: { browsing = $0 })
                    }
                }
            }
        } else {
            if series.isEmpty {
                CarnetEmpty(icon: "list.number", title: "Pas de série",
                            message: "Rien en semaine \(week).")
            }
            ForEach(series) { item in
                seriesBlock(item)
            }
        }

        if !deadlines.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                CarnetSectionTitle("Cette semaine")
                CarnetSheet {
                    ForEach(Array(deadlines.enumerated()), id: \.element.id) { index, exam in
                        CarnetRow(icon: exam.kind.icon, tint: Carnet.tint(course.colorHex),
                                  title: exam.title.isEmpty ? exam.kind.label : exam.title,
                                  subtitle: DateUtils.fullDayLabel(exam.date) + " · " + DateUtils.time.string(from: exam.date)) {
                            Text(DateUtils.countdownLabel(to: exam.date))
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Carnet.inkSecondary)
                        }
                        if index < deadlines.count - 1 { CarnetRule() }
                    }
                }
            }
        }

        besideLinks
    }

    /// « À regarder : l'enregistrement du cours et 2 chapitres du MOOC (14 vidéos) ».
    private func watchSummary(_ theory: [TheoryItem]) -> String {
        let remaining = theory.filter { !$0.isWatched }
        guard !remaining.isEmpty else { return "Tout est vu cette semaine" }
        let mooc = remaining.filter { $0.title.hasPrefix("MOOC") }
        let lectures = remaining.filter { !$0.title.hasPrefix("MOOC") }
        var parts: [String] = []
        if !lectures.isEmpty {
            let recorded = lectures.contains { $0.links.contains { $0.kind == .video } }
            parts.append(recorded ? "l'enregistrement du cours" : (lectures.count > 1 ? "\(lectures.count) cours" : "le cours"))
        }
        if !mooc.isEmpty {
            let videos = mooc.reduce(0) { $0 + $1.links.filter { $0.kind == .video }.count }
            parts.append("\(Plural.count(mooc.count, "\(mooc.count) chapitre", "\(mooc.count) chapitres")) du MOOC" + (videos > 0 ? " (\(videos) vidéos)" : ""))
        }
        return "À regarder : " + parts.joined(separator: " et ")
    }

    private func weekTopic(theory: [TheoryItem], series: [ExerciseSeries]) -> String? {
        if let section = theory.first?.sectionTitle, !section.isEmpty {
            let cleaned = section.replacingOccurrences(of: #"^(semaine|week)\s*\d+\s*[:·–-]?\s*"#, with: "",
                                                       options: [.regularExpression, .caseInsensitive])
            if !cleaned.isEmpty, cleaned.count < 80 { return cleaned }
        }
        if let topic = series.first?.topic, !topic.isEmpty { return topic }
        return nil
    }

    /// Une série : ses documents (énoncé, corrigé), puis chaque exercice, ses
    /// sous-questions et sa correction.
    private func seriesBlock(_ series: ExerciseSeries) -> some View {
        let links = ExerciseLinks.seriesLinks(series)
        let required = series.requiredExercises
        return VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle(series.displayName + (series.topic.isEmpty ? "" : " · \(series.topic)")) {
                Text("\(series.doneCount)/\(required.count)")
            }
            if !links.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(links, id: \.url) { link in
                            Button { browsing = link } label: {
                                Label(link.title, systemImage: link.icon)
                                    .font(.subheadline)
                                    .foregroundStyle(Carnet.ink)
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: 34)
                                    .background(Carnet.sheet, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            CarnetSheet {
                if series.exercises.isEmpty {
                    CarnetRow(icon: SeriesAutoReader.shared.reading.contains(series.id) ? "hourglass" : "doc.text.magnifyingglass",
                              tint: Carnet.inkSecondary,
                              title: SeriesAutoReader.shared.reading.contains(series.id) ? "Lecture de l'énoncé…" : "Exercices pas encore lus")
                }
                ForEach(Array(series.sortedExercises.enumerated()), id: \.element.id) { index, exercise in
                    Button { openedExercise = exercise } label: {
                        CarnetExerciseLine(exercise: exercise)
                    }
                    .buttonStyle(.plain)
                    if index < series.exercises.count - 1 { CarnetRule(inset: 54) }
                }
            }
        }
    }

    /// La première ligne des notes, ou ce qu'on y met.
    private var notesPreview: String {
        let first = course.notes.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return first.map { MathMarkup.plain(String($0)).trimmingCharacters(in: CharacterSet(charactersIn: "#*- ")) }
            ?? "Ce que le prof a dit, le barème, une erreur du corrigé"
    }

    /// Ce qui accompagne le cours sans se suivre : notes, examens, documents, progression.
    private var besideLinks: some View {
        VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle("À côté")
            CarnetSheet {
                Button { showingNotes = true } label: {
                    CarnetRow(icon: "note.text", tint: Carnet.inkSecondary, title: "Notes",
                              subtitle: notesPreview) { chevron }
                }
                .buttonStyle(.plain)
                CarnetRule()
                Button { showingExams = true } label: {
                    CarnetRow(icon: "graduationcap", tint: Carnet.inkSecondary, title: "Examens et annales",
                              subtitle: examsDetail(course.nextExam)) { chevron }
                }
                .buttonStyle(.plain)
                if !course.documents.isEmpty {
                    CarnetRule()
                    Button { showingDocuments = true } label: {
                        CarnetRow(icon: "folder", tint: Carnet.inkSecondary, title: "Documents du cours",
                                  subtitle: course.documents.prefix(3).map(\.title).joined(separator: " · ")) { chevron }
                    }
                    .buttonStyle(.plain)
                }
                CarnetRule()
                Button { showingProgress = true } label: {
                    CarnetRow(icon: "chart.bar", tint: Carnet.inkSecondary, title: "Progression semaine par semaine") { chevron }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Carnet.inkTertiary)
    }

    // MARK: Tout le cours

    @ViewBuilder
    private var allContent: some View {
        Picker("Section", selection: $tab) {
            ForEach(Section.segments) { section in
                Text(section.title).tag(section)
            }
        }
        .pickerStyle(.segmented)

        switch tab {
        case .theory:
            // La révision Anki du cours (si AnkiWeb est relié) : une ligne.
            AnkiCourseRow(course: course)
            TheoryTabView(course: course)
        default:
            ExercisesTabView(course: course)
        }
        besideLinks
    }

    // MARK: Barre du haut

    // MARK: Cocher une semaine d'un geste

    /// Les semaines terminées qui ont encore quelque chose à cocher.
    private var pastWeeks: ClosedRange<Int>? {
        guard course.isTermRunning, course.currentWeek > 1 else { return nil }
        let range = 1...(course.currentWeek - 1)
        let pending = WeekCompletion.pending(in: range, of: course)
        return pending.theory + pending.exercises > 0 ? range : nil
    }

    /// Le menu « tout cocher » : faits, faits et corrigés, ou la théorie seule.
    private func completionMenu<Label: View>(_ weeks: ClosedRange<Int>, title: String,
                                             @ViewBuilder label: () -> Label) -> some View {
        let pending = WeekCompletion.pending(in: weeks, of: course)
        return Menu {
            SwiftUI.Section("\(title) : \(pending.theory) théorie, \(Plural.count(pending.exercises, "\(pending.exercises) exercice", "\(pending.exercises) exercices")) à cocher") {
                Button { complete(weeks, scope: .all, title: title) } label: {
                    SwiftUI.Label("Tout marquer fait", systemImage: "checkmark.circle")
                }
                Button { complete(weeks, scope: .allCorrected, title: title) } label: {
                    SwiftUI.Label("Fait et corrigé (juste)", systemImage: "checkmark.seal")
                }
                Button { complete(weeks, scope: .theoryOnly, title: title) } label: {
                    SwiftUI.Label("Seulement la théorie vue", systemImage: TaskType.theory.icon)
                }
            }
        } label: {
            label()
        }
        .accessibilityLabel("Cocher tout le contenu : \(title)")
    }

    private func complete(_ weeks: ClosedRange<Int>, scope: WeekCompletion.Scope, title: String) {
        let change = WeekCompletion.mark(weeks, of: course, scope: scope)
        try? context.save()
        Haptics.success()
        guard !change.isEmpty else { return }
        let undo = CompletionUndo(change: change, label: "\(title) : \(change.summary)")
        completion = undo
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            if completion == undo { completion = nil }
        }
    }

    @ViewBuilder
    private var completionBar: some View {
        if let completion {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Carnet.correct)
                Text(completion.label)
                    .font(.subheadline)
                    .foregroundStyle(Carnet.ink)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button("Annuler") {
                    WeekCompletion.undo(completion.change, in: course)
                    try? context.save()
                    self.completion = nil
                    Haptics.removed()
                }
                .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Carnet.sheetRaised, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .padding(.horizontal, Carnet.screenPadding)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Deux boutons, deux rôles : « + » ajoute **du contenu** au cours, « ⋯ »
    /// agit **sur le cours** lui-même. Tout était auparavant dans un seul menu,
    /// et importer une série se cherchait dans l'onglet Séries.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button {
                    app.router.openContentImport(courseID: course.id)
                } label: {
                    Label("Importer depuis Moodle, Courseware…", systemImage: "square.and.arrow.down.on.square")
                }
                Button {
                    showingSeriesImport = true
                } label: {
                    Label("Importer une série (PDF)", systemImage: "doc.badge.plus")
                }
                Divider()
                Button {
                    showingAddTheory = true
                } label: {
                    Label("Ajouter de la théorie", systemImage: TaskType.theory.icon)
                }
                Button {
                    showingAddExam = true
                } label: {
                    Label("Ajouter une évaluation", systemImage: "graduationcap")
                }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Ajouter au cours")

            Menu {
                Button {
                    showingEditor = true
                } label: {
                    Label("Modifier le cours", systemImage: "slider.horizontal.3")
                }
                if let url = course.moodleLink {
                    Link(destination: url) {
                        Label("Ouvrir la page du cours", systemImage: "safari")
                    }
                }
                Divider()
                Button { showingLate = true } label: {
                    Label("À rattraper", systemImage: "exclamationmark.circle")
                }
                Button { showingProgress = true } label: {
                    Label("Progression semaine par semaine", systemImage: "chart.bar.xaxis")
                }
                if pastWeeks != nil {
                    Divider()
                    completionMenu(pastWeeks!, title: "Semaines \(pastWeeks!.lowerBound) à \(pastWeeks!.upperBound)") {
                        Label("Marquer les semaines passées faites…", systemImage: "checklist.checked")
                    }
                }
                Divider()
                Button {
                    course.isTracked.toggle()
                    try? context.save()
                    Haptics.tap()
                } label: {
                    Label(course.isTracked ? "Archiver" : "Réactiver",
                          systemImage: course.isTracked ? "archivebox" : "arrow.uturn.backward")
                }
                Button(role: .destructive) {
                    showingDelete = true
                } label: {
                    Label("Supprimer le cours…", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("Actions sur le cours")
        }
    }

    private func deleteCourse() {
        for exam in course.exams { app.notifications.cancelExam(id: exam.id) }
        context.delete(course)
        try? context.save()
        Haptics.removed()
        dismiss()
    }

    private func seriesTitle(_ week: WeeklyProgress) -> String {
        switch week.seriesNumbers.count {
        case 0: return "Séries"
        case 1: return "Série \(week.seriesNumbers[0])"
        default: return "Séries " + week.seriesNumbers.map(String.init).joined(separator: ", ")
        }
    }

    private var metaLine: String {
        // Espaces insécables : « 2 h » ne se coupe pas en fin de ligne.
        var parts = ["\(fmt(course.credits))\u{00A0}ECTS"]
        parts.append(course.hasLectures
                     ? "\(fmt(course.weeklyLectureHours))\u{00A0}h de cours · \(fmt(course.weeklyExerciseHours))\u{00A0}h d'exercices"
                     : "\(fmt(course.weeklyExerciseHours))\u{00A0}h d'exercices, sans amphi")
        return parts.joined(separator: " · ")
    }

    private func examsDetail(_ next: Exam?) -> String {
        guard let next else {
            return course.exams.isEmpty ? "Ajoute le midterm et l'examen final" : "Évaluations passées et annales"
        }
        var parts = [DateUtils.fullDayLabel(next.date)]
        if !course.pastExams.isEmpty { parts.append(Plural.count(course.pastExams.count, "\(course.pastExams.count) annale", "\(course.pastExams.count) annales")) }
        return parts.joined(separator: " · ")
    }

    private func fmt(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// Les documents d'un cours, rangés par leur section d'origine sur Moodle.
struct CourseDocumentsView: View {
    let course: Course

    @Environment(\.modelContext) private var context
    @State private var browsing: BrowsedLink?

    private var groups: [(title: String, documents: [CourseDocument])] {
        var order: [String] = []
        var byGroup: [String: [CourseDocument]] = [:]
        for document in course.documents {
            let key = document.group.isEmpty ? "Autres" : document.group
            if byGroup[key] == nil { order.append(key) }
            byGroup[key, default: []].append(document)
        }
        return order.map { ($0, byGroup[$0] ?? []) }
    }

    var body: some View {
        List {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.documents) { document in
                        row(document)
                    }
                }
            }
        }
        .navigationTitle("Documents · \(course.displayCode)")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $browsing) { InAppBrowser(link: $0) }
    }

    private func row(_ document: CourseDocument) -> some View {
        Button {
            if let url = ExerciseLinks.web(document.url) {
                browsing = BrowsedLink(title: document.title, url: url, icon: document.kind.icon)
            }
        } label: {
            Label(document.title, systemImage: document.kind.icon)
                .foregroundStyle(Color.primary)
        }
        .swipeActions {
            Button(role: .destructive) { remove(document) } label: {
                Label("Retirer", systemImage: "trash")
            }
        }
    }

    private func remove(_ document: CourseDocument) {
        course.documents.removeAll { $0 == document }
        // Retiré à la main : une mise à jour automatique ne le remettra pas.
        var ignored = course.contentIgnored
        ignored.insert(document.url)
        course.contentIgnored = ignored
        try? context.save()
    }
}
