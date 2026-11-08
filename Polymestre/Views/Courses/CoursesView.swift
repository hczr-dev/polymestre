import SwiftUI
import SwiftData

/// « Mes cours » : le plan du semestre, une carte par cours.
struct CoursesView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query(sort: \Course.code) private var courses: [Course]

    @State private var showingForm = false
    /// La recherche de tout ce que l'app contient (tirer la liste vers le bas).
    @State private var query = ""
    /// Construit à la première lettre tapée, refait à chaque nouvelle recherche.
    @State private var searchIndex: [SearchDocument] = []
    /// Une page ouverte depuis un résultat (historique, tâches, groupe…).
    @State private var searchPage: SearchDestination?
    @State private var showingImport = false
    /// Cours sélectionné dans la barre latérale (iPad).
    @State private var selectedCourseID: UUID?
    /// Cours dont la suppression attend confirmation.
    ///
    /// Supprimer un cours emporte ses vidéos, ses séries, ses évaluations **et ses
    /// sessions de travail** : un semestre de temps enregistré. Un menu contextuel
    /// sans confirmation était une perte de données à un doigt près.
    @State private var courseToDelete: Course?
    /// Cours poussé dans la pile iPhone (capture `-course`, lien profond).
    @State private var pushedCourse: Course?
    /// Import de série lancé depuis l'appui long sur un cours.
    @State private var seriesImportCourse: Course?
    /// Segment à ouvrir sur le cours poussé par un autre onglet.
    @State private var pushedSection: CourseDetailView.Section = .exercises
    /// L'exercice ou la théorie à ouvrir sur ce cours (recherche, Spotlight).
    @State private var pushedTarget: UUID?

    private var tracked: [Course] { courses.filter(\.isTracked) }
    private var archived: [Course] { courses.sorted { $0.code < $1.code }.filter { !$0.isTracked } }
    private var selectedCourse: Course? { courses.first { $0.id == selectedCourseID } }

    /// Deux volets sur iPad, une colonne ailleurs.
    ///
    /// Décidé par la classe de taille : en Split View ou en Slide Over la fenêtre
    /// redevient compacte et l'écran retombe sur la mise en page iPhone, au lieu
    /// d'écraser deux volets dans une largeur de téléphone.
    private var isWide: Bool { sizeClass == .regular }

    var body: some View {
        Group {
            if isWide { split } else { column }
        }
        .sheet(isPresented: $showingForm) {
            CourseFormView(course: nil, defaultSectionCode: app.settings.sectionCode)
        }
        .sheet(isPresented: $showingImport) {
            ImportSheet(defaultSectionCode: app.settings.sectionCode)
        }
        .confirmationDialog("Supprimer « \(courseToDelete?.displayCode ?? "") » ?",
                            isPresented: Binding(get: { courseToDelete != nil },
                                                 set: { if !$0 { courseToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Supprimer le cours et son historique", role: .destructive) {
                if let course = courseToDelete { delete(course) }
                courseToDelete = nil
            }
            Button("Archiver plutôt") {
                courseToDelete?.isTracked = false
                try? context.save()
                courseToDelete = nil
            }
            Button("Annuler", role: .cancel) { courseToDelete = nil }
        } message: {
            Text(deleteMessage)
        }
        .sheet(item: $seriesImportCourse) { course in
            SeriesImportSheet(course: course)
        }
        .onChange(of: query.isEmpty) { _, empty in
            if empty { searchIndex = [] } else if searchIndex.isEmpty { searchIndex = SearchIndex.build(context: context) }
        }
        .task {
            applyPreviewCourse()
            applyRoute()
            #if DEBUG
            if let preset = PreviewLaunch.string(PreviewLaunch.searchFlag) { query = preset }
            #endif
        }
        .onChange(of: app.router.courseRoute) { _, _ in applyRoute() }
        // Les cours arrivent parfois après la première passe : `@Query` rend une
        // liste vide, puis la remplit. Sans ce second essai, le drapeau de
        // prévisualisation ne trouvait rien et la capture montrait la liste.
        .onChange(of: courses.count) { _, _ in applyPreviewCourse() }
    }

    // MARK: Recherche

    /// Un résultat : l'élément lui-même (l'exercice, la théorie) dans son cours,
    /// ou la page qui le porte.
    private func openSearch(_ hit: SearchHit) {
        guard let destination = SearchDestination.of(hit, courses: courses) else { return }
        Haptics.tap()
        switch destination {
        case .course(let id, let section, let target):
            guard let match = courses.first(where: { $0.id == id }) else { return }
            pushedSection = section
            pushedTarget = target
            selectedCourseID = match.id
            if isWide {
                query = ""
            } else {
                pushedCourse = nil
                Task { @MainActor in pushedCourse = match }
            }
        case .tasks:
            query = ""
            app.router.selectedTab = .today
            app.router.showingTasks = true
        default:
            searchPage = destination
        }
    }

    @ViewBuilder
    private func searchPageView(_ destination: SearchDestination) -> some View {
        switch destination {
        case .history: SessionHistoryView()
        case .life: EPFLLifeView()
        case .group(let id):
            if let group = try? context.fetch(FetchDescriptor<StudyGroup>(predicate: #Predicate { $0.id == id })).first {
                GroupSettingsView(group: group)
            }
        case .course, .tasks: EmptyView()
        }
    }

    /// Un cours demandé par un autre onglet : sélectionné (iPad) ou poussé (iPhone).
    private func applyRoute() {
        guard let route = app.router.courseRoute,
              let match = courses.first(where: { $0.id == route.id }) else { return }
        app.router.courseRoute = nil
        pushedSection = route.section
        pushedTarget = route.targetID
        selectedCourseID = match.id
        if !isWide {
            pushedCourse = nil
            Task { @MainActor in pushedCourse = match }
        }
    }

    /// `-course CS-250` présélectionne un cours : `xcrun simctl` ne sait pas taper
    /// dans la liste, c'est le seul moyen de capturer le volet de détail.
    private func applyPreviewCourse() {
        #if DEBUG
        guard selectedCourseID == nil,
              let code = PreviewLaunch.string(PreviewLaunch.courseFlag),
              let match = courses.first(where: { $0.code.caseInsensitiveCompare(code) == .orderedSame })
        else { return }
        selectedCourseID = match.id
        if !isWide { pushedCourse = match }
        #endif
    }

    private var deleteMessage: String {
        guard let course = courseToDelete else { return "" }
        let hours = DateUtils.hoursLabel(seconds: WorkloadEngine.studySeconds(for: course))
        return String(localized: "Théorie, séries, évaluations et \(hours) de sessions enregistrées seront effacées. Archiver garde tout, hors de la vue.")
    }

    private func delete(_ course: Course) {
        for exam in course.exams { app.notifications.cancelExam(id: exam.id) }
        if selectedCourseID == course.id { selectedCourseID = nil }
        context.delete(course)
        try? context.save()
        Haptics.removed()
    }

    // MARK: iPad — maître / détail

    /// La liste des cours à gauche, le cours choisi à droite.
    ///
    /// « Mes cours » est le seul écran à deux niveaux de l'app : en colonne unique,
    /// passer d'un cours à l'autre obligeait à revenir en arrière à chaque fois.
    private var split: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            NavigationStack {
                if !query.isEmpty {
                    CarnetScroll {
                        SearchResultsList(query: query, index: searchIndex, open: openSearch)
                    }
                    .navigationTitle("Recherche")
                    .navigationDestination(item: $searchPage) { searchPageView($0) }
                } else if let course = selectedCourse {
                    CourseDetailView(course: course, initialSection: pushedSection, initialTargetID: pushedTarget)
                        .id("\(course.id)-\(pushedSection.rawValue)-\(pushedTarget?.uuidString ?? "")")
                } else {
                    semesterOverview
                }
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selectedCourseID) {
            if courses.isEmpty {
                Text("Aucun cours. Importe ton horaire ou ajoute un cours.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !tracked.isEmpty {
                Section("Cours suivis") {
                    ForEach(tracked) { course in
                        CourseSidebarRow(course: course)
                            .tag(course.id)
                            .contextMenu {
                                Button {
                                    course.isTracked = false
                                    try? context.save()
                                } label: {
                                    Label("Archiver", systemImage: "archivebox")
                                }
                                Button(role: .destructive) {
                                    courseToDelete = course
                                } label: {
                                    Label("Supprimer", systemImage: "trash")
                                }
                            }
                    }
                }
            }
            if !archived.isEmpty {
                Section("Archivés") {
                    ForEach(archived) { course in
                        CourseSidebarRow(course: course)
                            .tag(course.id)
                            .swipeActions {
                                Button("Réactiver") {
                                    course.isTracked = true
                                    try? context.save()
                                    Haptics.tap()
                                }
                                .tint(Theme.accent)
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .carnetBackground()
        .navigationTitle("Cours")
        .searchable(text: $query, prompt: "Exercice, énoncé, théorie, annale…")
        .toolbar { toolbarItems }
    }

    /// Le volet de droite au repos : le récapitulatif du semestre, qui n'a plus sa
    /// place en pleine largeur une fois la liste détachée.
    private var semesterOverview: some View {
        CarnetScroll {
            newsBanner
            courseGrid
        }
        .navigationTitle("Cours")
        .carnetSubtitle(subtitle)
    }

    // MARK: iPhone — une grille

    private var column: some View {
        NavigationStack {
            CarnetScroll {
                if courses.isEmpty {
                    CarnetEmpty(icon: "books.vertical",
                                title: String(localized: "Aucun cours"),
                                message: String(localized: "Depuis Moodle ou ton horaire IS-Academia."),
                                actionTitle: String(localized: "Importer depuis Moodle")) {
                        app.router.openContentImport()
                    }
                    HStack(spacing: 10) {
                        Button("Mon horaire (.ics)") { showingImport = true }
                            .buttonStyle(.carnetSecondaryWide)
                        Button("À la main") { showingForm = true }
                            .buttonStyle(.carnetSecondaryWide)
                    }
                } else if !query.isEmpty {
                    SearchResultsList(query: query, index: searchIndex, open: openSearch)
                } else {
                    newsBanner
                    courseGrid
                    if !archived.isEmpty { archivedSection }
                }
            }
            .navigationTitle("Cours")
            .carnetSubtitle(subtitle)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Exercice, énoncé, théorie, annale…")
            .toolbar { toolbarItems }
            .navigationDestination(item: $pushedCourse) { course in
                CourseDetailView(course: course, initialSection: pushedSection, initialTargetID: pushedTarget)
            }
            .navigationDestination(item: $searchPage) { searchPageView($0) }
        }
    }

    private var subtitle: String {
        let credits = tracked.reduce(0) { $0 + Int($1.credits) }
        var parts = [term?.displayName ?? String(localized: "Semestre"), String(localized: "\(tracked.count) cours"), "\(credits) ECTS"]
        if let term, !term.hasEnded, !term.hasNotStarted { parts.insert(String(localized: "semaine \(term.currentWeek)"), at: 1) }
        return parts.joined(separator: " · ")
    }

    /// « Série 5 publiée sur Moodle · CS-107 » — ce que la mise à jour
    /// automatique vient d'apporter.
    @ViewBuilder
    private var newsBanner: some View {
        let news = app.settings.contentRefreshNews
        if !news.isEmpty {
            HStack(spacing: 10) {
                Circle().fill(Carnet.ink).frame(width: 7, height: 7)
                Text(news).font(.subheadline).foregroundStyle(Carnet.ink).lineLimit(2)
                Spacer(minLength: 0)
                Button {
                    withAnimation(Motion.snappy) { app.settings.contentRefreshNews = "" }
                } label: {
                    Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(Carnet.inkSecondary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Masquer")
            }
            .padding(.leading, 14)
            .padding(.vertical, 6)
            .carnetGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var courseGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
            ForEach(tracked) { course in
                NavigationLink {
                    CourseDetailView(course: course)
                } label: {
                    CarnetCourseCard(course: course)
                }
                .buttonStyle(PressableStyle(scale: 0.98))
                .contextMenu { courseMenu(course) }
            }
            Button {
                app.router.openContentImport()
            } label: {
                VStack(spacing: 8) {
                    Image(systemName: "plus").font(.title3)
                    Text("Importer un cours").font(.subheadline)
                }
                .foregroundStyle(Carnet.inkSecondary)
                .frame(maxWidth: .infinity, minHeight: 170)
                .overlay(RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous)
                    .strokeBorder(Carnet.rule, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func courseMenu(_ course: Course) -> some View {
        // Les gestes fréquents d'abord : s'y mettre, ajouter la série de la
        // semaine. Archiver et supprimer ensuite.
        Button {
            app.router.startFocus(courseID: course.id, courseCode: course.code,
                                  taskType: .exercise, label: String(localized: "\(course.displayCode) · Séries"))
        } label: {
            Label("Démarrer un chrono", systemImage: "play.fill")
        }
        Button {
            app.router.openContentImport(courseID: course.id)
        } label: {
            Label("Importer du contenu", systemImage: "square.and.arrow.down.on.square")
        }
        Button {
            seriesImportCourse = course
        } label: {
            Label("Importer une série (PDF)", systemImage: "doc.badge.plus")
        }
        Divider()
        Button {
            course.isTracked = false
            try? context.save()
        } label: {
            Label("Archiver", systemImage: "archivebox")
        }
        Button(role: .destructive) {
            courseToDelete = course
        } label: {
            Label("Supprimer", systemImage: "trash")
        }
    }

    /// « + » : un cours à la main, son contenu depuis Moodle / Courseware /
    /// Botafogo, ou l'horaire IS-Academia. (La recherche est la barre de la liste.)
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button {
                    app.router.openContentImport()
                } label: {
                    Label("Importer du contenu (Moodle, Courseware, Botafogo)", systemImage: "square.and.arrow.down.on.square")
                }
                Button {
                    showingImport = true
                } label: {
                    Label("Importer mon horaire (.ics)", systemImage: "calendar.badge.plus")
                }
                Divider()
                Button {
                    showingForm = true
                } label: {
                    Label("Ajouter un cours à la main", systemImage: "plus")
                }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Ajouter")
        }
    }

    /// Le semestre affiché : celui des cours suivis, ou le plus proche.
    private var term: AcademicTerm? {
        AcademicTerm.resolve(from: courses.compactMap(\.term))
    }

    private var archivedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle(String(localized: "Archivés")) { Text("\(archived.count)") }
            CarnetSheet {
                ForEach(Array(archived.enumerated()), id: \.element.id) { index, course in
                    CarnetRow(title: course.name, subtitle: course.displayCode) {
                        Button("Réactiver") {
                            course.isTracked = true
                            try? context.save()
                            Haptics.tap()
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Carnet.ink)
                    }
                    if index < archived.count - 1 { CarnetRule(inset: Carnet.rowInset) }
                }
            }
        }
    }
}

/// La carte d'un cours sur la grille : sa couleur en tête, son code, son nom
/// en serif, où il en est (un grand pourcentage), son rythme et sa source.
struct CarnetCourseCard: View {
    let course: Course

    var body: some View {
        let tint = Carnet.tint(course.colorHex)
        let progress = ProgressEngine.progress(for: course)
        let late = ProgressEngine.lateCount(for: course)
        let ahead = ProgressEngine.aheadCount(for: course)
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(tint).frame(height: 5)
            VStack(alignment: .leading, spacing: 6) {
                Text(course.displayCode)
                    .font(.caption.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(tint)
                Text(course.name)
                    .font(Carnet.serif(.headline))
                    .foregroundStyle(Carnet.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(minHeight: 44, alignment: .topLeading)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int((progress.completion * 100).rounded()))")
                        .font(Carnet.serif(.title))
                    Text("%").font(Carnet.serif(.subheadline))
                }
                .foregroundStyle(Carnet.ink)
                Text(ProgressEngine.standingLabel(late: late, ahead: ahead))
                    .font(.footnote.weight(late > 0 ? .semibold : .regular))
                    .foregroundStyle(late > 0 ? Carnet.wrong : Carnet.inkSecondary)
                if let source = CarnetCourseCard.sourceLabel(course) {
                    Text(source)
                        .font(.caption)
                        .foregroundStyle(Carnet.inkTertiary)
                        .lineLimit(1)
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Carnet.sheet)
        .clipShape(RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// « Moodle · Botafogo » : d'où vient le contenu du cours.
    static func sourceLabel(_ course: Course) -> String? {
        let hosts = course.contentSources.compactMap { URL(string: $0)?.host?.lowercased() }
        var names: [String] = []
        if hosts.contains(where: { $0.contains("moodle") }) { names.append("Moodle") }
        if hosts.contains(where: { $0.contains("courseware") }) { names.append("Courseware") }
        if hosts.contains(where: { $0.contains("botafogo") }) { names.append("Botafogo") }
        return names.isEmpty ? nil : names.joined(separator: " · ")
    }
}

/// Ligne de la barre latérale iPad : code, nom, anneau de progression.
///
/// Volontairement plus dense que `CourseCardRow` : dans un volet permanent, une
/// liste qu'on balaie des yeux bat une pile de cartes.
struct CourseSidebarRow: View {
    let course: Course

    var body: some View {
        let progress = ProgressEngine.progress(for: course)
        return HStack(spacing: Layout.block) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Carnet.tint(course.colorHex))
                .frame(width: 4, height: 34)

            VStack(alignment: .leading, spacing: Layout.micro) {
                Text(course.displayCode).font(.subheadline.weight(.semibold))
                Text(course.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Layout.inline)

            ProgressRing(progress: progress.completion,
                         color: Carnet.tint(course.colorHex),
                         size: 38,
                         lineWidth: 4)
        }
        .padding(.vertical, 2)
    }
}

/// Carte d'un cours : identité, avancement global, et **ce qu'il reste cette
/// semaine** — la seule information qui appelle une action depuis la liste.
///
/// Les trois pourcentages (théorie / exos / corrections) ont quitté la carte :
/// trois chiffres colorés par cours, c'est douze chiffres à balayer pour choisir
/// où aller. Ils vivent dans la fiche, onglet Progression.
struct CourseCardRow: View {
    let course: Course

    var body: some View {
        let progress = ProgressEngine.progress(for: course)
        let week = course.currentWeek
        let redo = course.allExercises.filter(\.redoRequired).count
        return Card {
            VStack(alignment: .leading, spacing: Layout.block) {
                HStack(alignment: .center, spacing: Layout.block) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Carnet.tint(course.colorHex))
                        .frame(width: 5, height: 44)

                    VStack(alignment: .leading, spacing: Layout.tight) {
                        HStack(spacing: Layout.snug) {
                            Text(course.displayCode).font(.subheadline.weight(.bold))
                            if course.displayCode != course.code {
                                Text(course.code).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text(course.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        HStack(spacing: Layout.snug) {
                            Pill(text: "\(Int(course.credits)) ECTS", color: Carnet.tint(course.colorHex))
                            if let exam = course.nextExam, exam.daysUntil <= 21 {
                                Pill(text: "\(exam.kind.label) \(DateUtils.countdownLabel(to: exam.date))",
                                     color: exam.kind.color, icon: exam.kind.icon)
                            }
                        }
                    }

                    Spacer(minLength: Layout.inline)

                    ProgressRing(progress: progress.completion,
                                 color: Carnet.tint(course.colorHex),
                                 size: 52,
                                 lineWidth: 6)
                }

                Divider()

                // La semaine en cours sur les deux axes, côte à côte : c'est
                // ce que la liste doit dire d'un coup d'œil, cours par cours.
                if !course.isTermRunning {
                    Text("Semestre en pause")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if weekProgress.hasItems {
                    HStack(alignment: .top, spacing: Layout.gutter) {
                        compactAxis(String(localized: "Théorie"), weekProgress.watchedCount, weekProgress.videoCount, TaskType.theory.tint)
                        compactAxis(weekProgress.seriesNumbers.count == 1 ? String(localized: "Série \(weekProgress.seriesNumbers[0])") : String(localized: "Séries"),
                                    weekProgress.doneCount, weekProgress.exerciseCount, TaskType.exercise.tint)
                    }
                    if redo > 0 {
                        Label("\(Plural.count(redo, "\(redo) exercice", "\(redo) exercices")) à refaire", systemImage: "arrow.counterclockwise")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.red.accessibleInk)
                    }
                } else {
                    Text(course.theoryItems.isEmpty && course.series.isEmpty
                         ? "Pas encore de contenu · importe-le depuis Moodle"
                         : "Rien de planifié en semaine \(week)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var weekProgress: WeeklyProgress {
        ProgressEngine.weekProgress(for: course, week: course.currentWeek)
    }

    private func compactAxis(_ title: String, _ done: Int, _ total: Int, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: Layout.tight) {
            HStack(alignment: .firstTextBaseline) {
                Text(ui: title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: Layout.tight)
                Text(total == 0 ? "—" : "\(done)/\(total)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(total > 0 && done == total ? Color.green.accessibleInk : .primary)
            }
            ProgressBar(progress: CourseProgress.ratio(done, total), color: tint, height: 5)
                .opacity(total == 0 ? 0.3 : 1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }



}
