import SwiftUI
import SwiftData

/// Le cours, dans le bureau, en natif : ce que Polymestre en sait (semaine
/// par semaine, avec ce qui est vu et fait), le plan Moodle en direct (pages,
/// dossiers, devoirs, liens, annonces lus ici), Courseware (vidéos et textes)
/// et le site Botafogo lu comme un livre. PDF (PDFKit), autres fichiers
/// (Aperçu), vidéos MediaSpace (AVKit) : tout s'ouvre ici. Seuls GeoGebra et
/// les sites inconnus passent par l'onglet Web.
struct CoursePane: View {
    let course: Course?
    var desk: SiteHub
    var openWeb: (URL, String) -> Void
    /// Demander à Claude (le bureau du Mac ; l'app Claude sur l'iPhone).
    var ask: (String) -> Void = { _ in }
    /// L'iPhone : la liste, puis la lecture par-dessus (pas deux colonnes).
    var compact = false
    /// À côté de la série (côte à côte) : pour un cours Botafogo, le polycopié
    /// seul, ouvert sur la matière de la série en cours (`focus`).
    var paired = false
    /// La page Botafogo de la série en cours (`series/AN_serie_06`), pour le côte à côte.
    var focus: String?
    /// À côté d'un autre onglet : la place est comptée, la liste se replie d'office.
    var beside = false
    /// Garder un document à côté (le volet de droite du bureau du Mac).
    var sendBeside: ((Reading, String) -> Void)? = nil
    /// Un seul document, sans la liste ni son en-tête (un onglet du volet d'à côté).
    var document: Reading? = nil
    /// Tes notes ont leur propre outil (le Mac) : elles ne sont pas redites ici.
    var hasNotesTool = false
    /// Aller ailleurs dans le bureau (la série, tes notes) : la semaine y mène directement.
    var go: ((Destination) -> Void)? = nil

    enum Destination {
        /// Travailler cet exercice (l'onglet Série, sur lui).
        case exercise(Exercise)
        case notes
    }

    /// La liste de gauche, repliée pour lire en grand (une par disposition).
    @AppStorage("course.listHidden") private var listHiddenAlone = false
    @AppStorage("course.listHidden.beside") private var listHiddenBeside = true
    private var listHidden: Bool { beside ? listHiddenBeside : listHiddenAlone }
    private func toggleList() {
        withAnimation(.snappy(duration: 0.22)) {
            if beside { listHiddenBeside.toggle() } else { listHiddenAlone.toggle() }
        }
    }

    enum Source: String, CaseIterable, Identifiable {
        case polymestre, botafogo, sheet, saved, notes, moodle, courseware, ed
        var id: String { rawValue }
        var label: String {
            switch self {
            case .sheet: return "Fiche"
            case .saved: return String(localized: "Gardés")
            case .polymestre: return String(localized: "Semaine")
            case .notes: return "Mes notes"
            case .moodle: return "Moodle"
            case .courseware: return "Courseware"
            case .botafogo: return String(localized: "Le cours")
            case .ed: return "Ed"
            }
        }
        var icon: String {
            switch self {
            case .sheet: return "rectangle.stack"
            case .saved: return "bookmark"
            case .polymestre: return "calendar"
            case .notes: return "pencil.and.scribble"
            case .moodle: return "graduationcap"
            case .courseware: return "play.rectangle"
            case .botafogo: return "book"
            case .ed: return "bubble.left.and.bubble.right"
            }
        }
    }

    @State private var source: Source = .polymestre
    /// Le chapitre de la fiche demandé depuis la semaine.
    @State private var sheetChapter: String?
    @Query private var allCourses: [Course]
    @State private var coursewareFailed = false
    @State private var composingEd = false
    @State private var edLessonsShown = false
    @State private var edCategory: String?
    @State private var edReload = 0
    /// Ce qu'on lit à droite.
    @State private var reading: Reading?
    /// La partie du site Botafogo qu'on parcourt (comme les onglets du site).
    /// Les exercices n'y sont pas : ils sont dans l'onglet Série.
    @State private var botafogoPart: BotafogoPart = .sessions
    /// Les sections à lire de chaque semaine (citées par sa page), une fois lues.
    @State private var readings: [String: [BotafogoSite.Chapter.Section]] = [:]

    enum BotafogoPart: String, CaseIterable, Identifiable {
        case handout, sessions, infos
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .handout: return "Polycopié"
            case .sessions: return "Séances"
            case .infos: return "Infos"
            }
        }
    }

    /// Le livre du site Botafogo du cours, partagé avec la série.
    private var book: BotafogoBook { desk.botafogo(botafogoURL ?? BotafogoParser.home) }

    enum Reading: Equatable {
        case pdf(title: String, address: String)
        case botafogo(title: String, url: String)
        case theory(UUID)
        case moodle(module: String, id: Int, title: String)
        case video(title: String, address: String)
        case file(title: String, address: String)
        case edx(EdXOutline.Unit)
        /// Une vidéo Courseware à un instant (un passage trouvé dans sa transcription).
        case edxMoment(EdXOutline.Unit, block: String, start: Double)
        /// Les vidéos d'un chapitre, à la suite.
        case edxPlaylist(String)
        /// Une annale, question par question avec son corrigé.
        case pastExam(UUID)
        case edThread(id: Int, title: String)
        case moodleSection(Int)
        case edLesson(EdDiscussion.Lesson)
    }

    /// Le cours Ed de ce cours (par son code), une fois les cours Ed lus.
    private var edCourse: EdDiscussion.Course? {
        guard let course, let courses = desk.edCourses else { return nil }
        return EdDiscussion.match(code: course.code, in: courses)
    }

    private var moodleID: Int? {
        guard let course else { return nil }
        return MoodleCourseMatcher.linkedID(in: course.contentSources + [course.moodleURLString])
    }

    private var botafogoURL: URL? {
        course?.contentSources.compactMap(URL.init(string:)).first { ContentSource.detect(host: $0.host) == .botafogo }
    }

    /// Le MOOC Courseware du cours, s'il en cite un.
    private var coursewareKey: String? {
        guard let course else { return nil }
        return (course.contentSources + course.theoryItems.map(\.urlString)).lazy.compactMap(MoocReference.courseKey(in:)).first
    }

    private var sources: [Source] {
        Source.allCases.filter {
            // La semaine d'abord, pour tous les cours (Botafogo compris) : ce
            // qu'il y a à voir et à lire, d'où que ça vienne.
            ($0 == .polymestre && (course.map { !$0.theoryItems.isEmpty || !$0.series.isEmpty } ?? false)) || $0 == .sheet || $0 == .saved || ($0 == .notes && !hasNotesTool && !notes.isEmpty) || ($0 == .moodle && moodleID != nil) || ($0 == .courseware && coursewareKey != nil)
                || ($0 == .botafogo && botafogoURL != nil)
                || ($0 == .ed && (edCourse != nil || desk.edNeedsLogin))
        }
    }

    var body: some View {
        content
            // Lire, regarder jusqu'au bout : l'élément de la semaine se coche.
            .environment(\.markStudied) { [course] address in
                guard let course else { return }
                TheoryTracking.mark(address, in: course)
            }
            .onChange(of: source) { _, new in if new != .sheet { sheetChapter = nil } }
    }

    @ViewBuilder
    private var content: some View {
        if let course, document != nil {
            reader(course)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let course, compact {
            // L'iPhone : la même liste, la lecture poussée par-dessus.
            NavigationStack {
                sourceColumn(course)
                    .navigationTitle(course.displayCode)
                    .navigationBarTitleDisplayModeInline()
                    .navigationDestination(isPresented: Binding(get: { reading != nil }, set: { if !$0 { reading = nil } })) {
                        reader(course)
                            .background(Carnet.ground)
                    }
            }
            .task { await desk.loadEdCourses() }
            .onAppear { consumeRequest() }
            .onChange(of: desk.request) { _, _ in consumeRequest() }
            .task { await NotesStore.shared.refresh() }
        } else if let course, source == .sheet {
            // La fiche prend toute la place : son sommaire est sa colonne.
            VStack(spacing: 0) {
                if sources.count > 1 {
                    sourcePicker.padding(.horizontal, 12).padding(.vertical, 10)
                    Rectangle().fill(Carnet.rule).frame(height: 1)
                }
                RevisionSheetView(course: course, desk: desk, openPoly: openSheetLink, openChapter: sheetChapter)
            }
            .onAppear { consumeRequest() }
            .onChange(of: desk.request) { _, _ in consumeRequest() }
        } else if let course, paired, let site = botafogoURL {
            BotafogoPairedPoly(book: book, site: site, focus: focus, desk: desk, openWeb: openWeb, ask: ask,
                               tint: Carnet.tint(course.colorHex))
        } else if let course, source == .botafogo, let site = botafogoURL {
            // Un cours Botafogo : le site entier, comme sur le web (sommaire,
            // fil d'Ariane, « Sur cette page »), les autres sources en tête.
            BotafogoCourseView(book: book, site: site, tint: Carnet.tint(course.colorHex), desk: desk, openWeb: openWeb, ask: ask,
                               location: Binding(get: {
                                   if case .botafogo(let title, let url)? = reading { return BotafogoLocation(title: title, url: url) }
                                   return nil
                               }, set: { reading = $0.map { .botafogo(title: $0.title, url: $0.url) } }),
                               sources: sources.count > 1 ? AnyView(sourcePicker) : nil,
                               studied: TheoryTracking.readHandoutPaths(in: course),
                               accessory: { location in AnyView(HStack(spacing: 8) {
                                   saveButton(location.title, location.url, .poly)
                                   besideButton(.botafogo(title: location.title, url: location.url), location.title)
                               }) })
                .task { await desk.loadEdCourses() }
                .onAppear { consumeRequest() }
                .onChange(of: desk.request) { _, _ in consumeRequest() }
                .task { await NotesStore.shared.refresh() }
                #if DEBUG
                .onChange(of: book.ready) { _, ready in
                    guard ready, CommandLine.arguments.contains("-botafogo"),
                          let index = CommandLine.arguments.firstIndex(of: "-botafogoOpen"), index + 1 < CommandLine.arguments.count else { return }
                    let path = CommandLine.arguments[index + 1]
                    reading = .botafogo(title: book.section(path)?.title ?? path, url: path)
                }
                .onAppear { if CommandLine.arguments.contains("-botafogo") { source = .botafogo } }
                #endif
        } else if let course {
            HStack(spacing: 0) {
                if !listHidden || reading == nil {
                sourceColumn(course)
                .frame(width: beside ? 280 : 320)
                .clipped()
                #if DEBUG
                .onAppear {
                    if CommandLine.arguments.contains("-botafogo") { source = .botafogo }
                    if let index = CommandLine.arguments.firstIndex(of: "-courseSource"), index + 1 < CommandLine.arguments.count,
                       let chosen = Source(rawValue: CommandLine.arguments[index + 1]) { source = chosen }
                    // `-botafogoPart handout|sessions|exercises|infos` : la partie montrée.
                    if let index = CommandLine.arguments.firstIndex(of: "-botafogoPart"), index + 1 < CommandLine.arguments.count,
                       let part = BotafogoPart(rawValue: CommandLine.arguments[index + 1]) { botafogoPart = part }
                }
                .onChange(of: book.ready) { _, ready in
                    // `-botafogo` : ouvrir un document (`-botafogoOpen <chemin>`, sinon une section du polycopié).
                    guard ready, CommandLine.arguments.contains("-botafogo") else { return }
                    if let index = CommandLine.arguments.firstIndex(of: "-botafogoOpen"), index + 1 < CommandLine.arguments.count {
                        let path = CommandLine.arguments[index + 1]
                        reading = .botafogo(title: book.section(path)?.title ?? path, url: path)
                    } else if let section = book.chapters.dropFirst(3).first?.sections.first {
                        reading = .botafogo(title: section.title, url: section.path)
                    }
                }
                #endif
                Rectangle().fill(Carnet.rule).frame(width: 1)
                }
                reader(course)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottomLeading) {
                        if reading != nil { listToggle }
                    }
            }
            .background {
                Button("", action: toggleList).keyboardShortcut("s", modifiers: [.control, .command]).opacity(0)
            }
            // Les cours Ed, une fois : la source « Ed » n'apparaît que pour un
            // cours qui y est (ou pour se connecter).
            .task { await desk.loadEdCourses() }
            .task(id: course.id) { if !sources.contains(source), let first = sources.first { source = first } }
            #if DEBUG
            .onAppear { if CommandLine.arguments.contains("-botafogo"), botafogoURL != nil { source = .botafogo } }
            #endif
            .onAppear { consumeRequest() }
            .onChange(of: desk.request) { _, _ in consumeRequest() }
            .task { await NotesStore.shared.refresh() }
        } else {
            ContentUnavailableView("Pas de cours", systemImage: "books.vertical",
                                   description: Text("Choisis-en un pour la session."))
        }
    }

    /// Les sources du cours (le cours, mes notes, Moodle…) et la liste choisie.
    @ViewBuilder
    private func sourceColumn(_ course: Course) -> some View {
        VStack(spacing: 0) {
            if sources.count > 1 {
                sourcePicker
                    .padding(.horizontal, 12).padding(.vertical, compact ? 8 : 12)
            }
            switch source {
            case .polymestre: polymestreList(course)
            case .moodle: moodleList(course)
            case .courseware: coursewareList
            case .botafogo: botafogoList
            case .sheet: RevisionSheetView(course: course, desk: desk, openPoly: openSheetLink, compact: true, openChapter: sheetChapter)
            case .saved:
                SavedResourcesList(course: course, selected: openResourceID, open: { openResource($0, course: course) })
            case .ed: edList
            case .notes: notesList
            }
        }
    }

    /// Replier ou rouvrir la liste : lire un PDF en grand, puis revenir choisir.
    private var listToggle: some View {
        Button(action: toggleList) {
            Image(systemName: listHidden ? "sidebar.left" : "arrow.left.to.line")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Carnet.rule))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Carnet.ink)
        .padding(12)
        .help(listHidden ? "Montrer la liste (⌃⌘S)" : "Replier la liste pour lire en grand (⌃⌘S)")
    }

    /// Les onglets des sources quand ils tiennent ; sinon un menu (la colonne
    /// est étroite à côté de la série) — un contrôle segmenté du Mac ne
    /// rétrécit pas et débordait sur la barre latérale.
    private var sourcePicker: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(sources.filter { $0 != .saved }) { item in
                    Button { source = item } label: {
                        Label(item.label, systemImage: item.icon)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: source.icon).foregroundStyle(Carnet.inkSecondary)
                    Text(source.label).font(.body.weight(.medium))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(Carnet.inkSecondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Carnet.sheetRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .foregroundStyle(Carnet.ink)
            .accessibilityLabel("Source")
            savedButton
        }
    }

    /// Les gardés ne sont pas une source parmi d'autres : ce sont **tes** documents, d'où ce signet à
    /// côté du menu, toujours sous la main, avec leur nombre.
    @ViewBuilder
    private var savedButton: some View {
        let count = course?.savedResources.count ?? 0
        let active = source == .saved
        Button { source = active ? (sources.first { $0 != .saved } ?? .polymestre) : .saved } label: {
            HStack(spacing: 5) {
                Image(systemName: active || count > 0 ? "bookmark.fill" : "bookmark")
                if count > 0 { Text("\(count)").font(.caption.weight(.semibold).monospacedDigit()) }
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(active ? Carnet.ink : Carnet.sheetRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .foregroundStyle(active ? Carnet.ground : Carnet.ink)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(active ? "Revenir au cours" : "Tes documents gardés (le signet en haut d'un document)")
        .accessibilityLabel("Gardés")
    }

    // MARK: Polymestre

    /// La semaine choisie (`nil` : celle en cours).
    @State private var week: Int?

    /// Les semaines qui ont quelque chose, dans l'ordre (sans semaine à la fin).
    private func weeks(_ course: Course) -> [Int] {
        Array(Set(course.theoryItems.map(\.plannedWeek) + course.series.filter { !$0.exercises.isEmpty }.map(\.plannedWeek))).sorted {
            ($0 == 0 ? Int.max : $0) < ($1 == 0 ? Int.max : $1)
        }
    }

    private func shownWeek(_ course: Course, in weeks: [Int]) -> Int {
        if let week, weeks.contains(week) { return week }
        let current = course.currentWeek
        return weeks.first { $0 >= current && $0 > 0 } ?? weeks.last ?? current
    }

    /// La semaine : où reprendre, puis à regarder, à lire, les documents et la série — chacun
    /// s'ouvre ici, se coche quand on arrive au bout, et mène à la fiche (le chapitre qu'il couvre),
    /// à la série (l'exercice) et à tes notes.
    private func polymestreList(_ course: Course) -> some View {
        let tint = Carnet.tint(course.colorHex)
        let all = weeks(course)
        let shown = shownWeek(course, in: all)
        let items = course.sortedTheoryItems.filter { $0.plannedWeek == shown }
        let videos = items.filter { $0.kind == .video && !Self.isDocumentLink($0.urlString) }
        let slides = items.filter { $0.kind == .slides || ($0.kind == .video && Self.isDocumentLink($0.urlString)) }
        let readings = items.filter { $0.kind == .reading || $0.kind == .chapter }
        let series = course.sortedSeries.filter { $0.plannedWeek == shown && !$0.exercises.isEmpty }
        return VStack(spacing: 0) {
            weekStrip(course, weeks: all, shown: shown, tint: tint)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    weekSummary(course, week: shown, items: items, videos: videos, series: series, tint: tint)
                    if !videos.isEmpty { weekCard(String(localized: "À regarder"), icon: "play.rectangle", videos, course: course, tint: tint) }
                    if !readings.isEmpty { weekCard(String(localized: "À lire"), icon: "book", readings, course: course, tint: tint) }
                    if !slides.isEmpty { weekCard(String(localized: "Diapositives et notes"), icon: "rectangle.on.rectangle", slides, course: course, tint: tint) }
                    ForEach(series) { seriesCard($0, course: course, tint: tint) }
                    if shown == all.last, !course.documents.isEmpty {
                        card(String(localized: "Documents du cours"), icon: "folder") {
                            ForEach(course.documents) { document in
                                Button { openLink(document.url, title: document.title, kind: document.kind) } label: {
                                    Label(document.title, systemImage: document.kind.icon)
                                        .foregroundStyle(Carnet.ink)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 12).padding(.vertical, 9)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    /// Une carte de la semaine : un titre discret, ses lignes séparées d'un trait fin.
    private func card<Content: View>(_ title: String, icon: String, detail: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption)
                Text(title).font(.caption.weight(.semibold)).textCase(.uppercase).tracking(0.6)
                Spacer(minLength: 0)
                if let detail { Text(detail).font(.caption.monospacedDigit()) }
            }
            .foregroundStyle(Carnet.inkSecondary)
            .padding(.horizontal, 4)
            VStack(spacing: 0, content: content)
                .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Carnet.rule))
        }
    }

    private func weekCard(_ title: String, icon: String, _ items: [TheoryItem], course: Course, tint: Color) -> some View {
        card(title, icon: icon, detail: "\(items.filter(\.isWatched).count)/\(items.count)") {
            ForEach(items) { item in
                if item.id != items.first?.id { Rectangle().fill(Carnet.rule).frame(height: 1).padding(.leading, 12) }
                theoryRow(item, course: course, tint: tint)
            }
        }
    }

    /// Les semaines en pastilles : un anneau par semaine (sa théorie vue), la
    /// semaine en cours marquée.
    private func weekStrip(_ course: Course, weeks: [Int], shown: Int, tint: Color) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(weeks, id: \.self) { value in
                        let items = course.theoryItems.filter { $0.plannedWeek == value }
                        let fraction = items.isEmpty ? 0 : Double(items.filter(\.isWatched).count) / Double(items.count)
                        Button { withAnimation(.snappy) { week = value } } label: {
                            VStack(spacing: 3) {
                                ZStack {
                                    ThinRing(fraction: fraction, tint: tint).frame(width: 22, height: 22)
                                    Text(value == 0 ? "–" : "\(value)").font(.caption2.weight(value == shown ? .bold : .medium).monospacedDigit())
                                }
                                Circle().fill(value == course.currentWeek ? tint : .clear).frame(width: 4, height: 4)
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 5)
                            .background(value == shown ? tint.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .foregroundStyle(Carnet.ink)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(value == 0 ? "Sans semaine" : "Semaine \(value)")
                        .id(value)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .onAppear { proxy.scrollTo(shown, anchor: .center) }
        }
    }

    /// En tête de la semaine : son nom, la consigne du cours, ce qu'il reste — et **où reprendre**.
    private func weekSummary(_ course: Course, week: Int, items: [TheoryItem], videos: [TheoryItem], series: [ExerciseSeries], tint: Color) -> some View {
        let left = items.filter { !$0.isWatched }
        let seconds = videos.filter { !$0.isWatched }.reduce(0) { total, item in
            let resume = ReadingMemory.video(item.urlString)
            return total + max(0, item.durationSeconds - Int(resume?.position ?? 0))
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(week > 0 ? "Semaine \(week)" : "Sans semaine").font(Carnet.serif(24)).foregroundStyle(Carnet.ink)
                if week == course.currentWeek { Kicker("en cours", color: tint) }
                Spacer()
                if week != course.currentWeek, weeks(course).contains(course.currentWeek) {
                    Button("Cette semaine") { withAnimation(.snappy) { self.week = nil } }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(Carnet.inkSecondary)
                }
            }
            if let guide = course.weekGuide[week], !guide.isEmpty {
                Text(guide).font(.callout).foregroundStyle(Carnet.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
            if !items.isEmpty {
                HStack(spacing: 8) {
                    ProgressView(value: Double(items.count - left.count), total: Double(items.count)).tint(tint)
                    Text(left.isEmpty ? "Tout est vu" : "\(left.count) sur \(items.count) à faire")
                        .font(.caption).foregroundStyle(Carnet.inkSecondary).fixedSize()
                }
                if seconds > 0 {
                    Label("\(DateUtils.durationLabel(seconds: seconds)) de vidéo à regarder", systemImage: "play.rectangle")
                        .font(.caption).foregroundStyle(Carnet.inkSecondary)
                }
            }
            if let next = nextUp(course, items: items, series: series) {
                Button(action: next.action) {
                    HStack(spacing: 8) {
                        Image(systemName: next.icon)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(next.verb).font(.caption.weight(.semibold)).opacity(0.75)
                            Text(next.title).font(.callout.weight(.semibold)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.right")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(Carnet.ink, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(Carnet.ground)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Carnet.rule))
    }

    /// Le prochain geste de la semaine : reprendre ce qui est commencé, sinon le premier élément pas
    /// encore vu, sinon la série — sur son premier exercice à faire.
    private func nextUp(_ course: Course, items: [TheoryItem], series: [ExerciseSeries]) -> (verb: String, title: String, icon: String, action: () -> Void)? {
        let todo = items.filter { !$0.isWatched }
        let started = todo.first { ReadingMemory.video($0.urlString) != nil || ReadingMemory.page($0.urlString) != nil }
        if let item = started ?? todo.first {
            let title = item.title.isEmpty ? item.kind.label : item.title
            return (started != nil ? String(localized: "Reprendre") : String(localized: "Commencer"), title, item.kind.icon,
                    { openTheory(item, course: course) })
        }
        if let go, let pending = series.first(where: { !$0.isComplete }), let exercise = pending.sortedExercises.first(where: { !$0.isDone }) {
            let name = pending.title.isEmpty ? String(localized: "Série \(pending.seriesNumber)") : pending.title
            return (String(localized: "Faire la série"), "\(name) · \(exercise.displayNumber)", "list.number", { go(.exercise(exercise)) })
        }
        return nil
    }

    private static func isDocumentLink(_ address: String) -> Bool {
        guard let url = URL(string: address) else { return false }
        return isDocument(url)
    }

    /// Un élément de la semaine : le cocher, l'ouvrir (là où il mène), ses
    /// autres liens, et où l'on en était.
    private func theoryRow(_ item: TheoryItem, course: Course, tint: Color) -> some View {
        let selected = isOpen(item)
        let chapter = item.urlString.isEmpty ? nil : TheoryTracking.handoutPath(item.urlString).flatMap { course.revisionSheet?.chapters(forPath: $0).first }
        return HStack(spacing: 8) {
            Button {
                item.watchedAt = item.isWatched ? nil : Date()
            } label: {
                Image(systemName: item.isWatched ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isWatched ? tint : Carnet.inkTertiary)
            }
            .buttonStyle(.plain)
            .help(item.isWatched ? "Marquer non vu" : "Marquer vu")
            Button { openTheory(item, course: course) } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        MacMathText(item.title.isEmpty ? item.kind.label : item.title, size: 13)
                            .foregroundStyle(item.isWatched ? Carnet.inkSecondary : Carnet.ink)
                            .lineLimit(2)
                        if let detail = detail(item) {
                            Text(detail).font(.caption).foregroundStyle(Carnet.inkTertiary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // La fiche : le chapitre que cette section couvre.
            if let chapter {
                Button { sheetChapter = chapter.id; source = .sheet } label: {
                    Image(systemName: "rectangle.stack").font(.caption)
                        .padding(6)
                        .background(tint.opacity(0.14), in: Circle())
                        .foregroundStyle(tint)
                }
                .buttonStyle(.plain)
                .help("Fiche · \(chapter.title)")
            }
            // Les autres liens (l'enregistrement, les notes annotées) en icônes.
            ForEach(Array(item.links.filter { $0.url != item.urlString }.prefix(3).enumerated()), id: \.offset) { _, link in
                Button { openLink(link.url, title: link.title, kind: link.kind) } label: {
                    Image(systemName: link.kind.icon).font(.caption)
                        .foregroundStyle(TheoryTracking.isPartWatched(link.url) ? Carnet.correct : Carnet.inkSecondary)
                }
                .buttonStyle(.plain)
                .help(link.title)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(selected ? tint.opacity(0.12) : Color.clear)
    }

    /// « Reprendre à 12:40 », « p. 5 / 30 », « 25 min » — ce qu'il faut savoir avant d'ouvrir.
    private func detail(_ item: TheoryItem) -> String? {
        if let resume = ReadingMemory.video(item.urlString), !item.isWatched {
            return String(localized: "reprendre à \(NativeVideo.clock(resume.position))")
        }
        if let page = ReadingMemory.page(item.urlString), !item.isWatched {
            return String(localized: "p. \(page.page + 1) / \(page.count)")
        }
        if let path = TheoryTracking.handoutPath(item.urlString), ReadingMemory.block(path) != nil, !item.isWatched {
            return String(localized: "lecture en cours")
        }
        if item.hasDuration { return item.durationLabel }
        if item.links.count > 1 { return Plural.count(item.links.count, "\(item.links.count) lien", "\(item.links.count) liens") }
        return nil
    }

    private func isOpen(_ item: TheoryItem) -> Bool {
        switch reading {
        case .theory(let id)?: return id == item.id
        case .botafogo(_, let url)?: return TheoryTracking.handoutPath(item.urlString) == url
        case .video(_, let address)?, .pdf(_, let address)?, .file(_, let address)?: return address == item.urlString
        default: return false
        }
    }

    /// Ouvrir un élément **là où il mène** : la section du polycopié, la vidéo,
    /// les diapositives, l'unité Courseware — plus de page intermédiaire.
    private func openTheory(_ item: TheoryItem, course: Course) {
        let title = item.title.isEmpty ? item.kind.label : item.title
        if let path = TheoryTracking.handoutPath(item.urlString), let site = botafogoURL {
            Task {
                await book.load(site)
                reading = .botafogo(title: book.section(path)?.title ?? title, url: path)
            }
        } else if TheoryTracking.coursewareBlock(item.urlString) != nil, let key = coursewareKey {
            Task { await openCourseware(item.urlString, key: key) }
        } else if item.urlString.isEmpty {
            reading = .theory(item.id)
        } else {
            openLink(item.urlString, title: title, kind: item.kind == .slides ? .slides : nil)
        }
    }

    /// Une adresse Courseware (une leçon, une unité) : son unité, ouverte ici.
    private func openCourseware(_ address: String, key: String) async {
        if desk.edxOutlines[key] == nil, let outline = try? await desk.courseware.outline(of: key) {
            desk.edxOutlines[key] = outline
        }
        guard let outline = desk.edxOutlines[key], let block = TheoryTracking.coursewareBlock(address) else {
            source = .courseware
            return
        }
        let units = outline.units
        let unit = units.first { $0.id == block }
            ?? outline.chapters.flatMap(\.sequences).first { $0.id == block }.flatMap { sequence in
                sequence.units.first { !$0.completed } ?? sequence.units.first
            }
            ?? units.first { $0.blocks.contains { $0.id == block } }
        if let unit { reading = .edx(unit) } else { source = .courseware }
    }

    /// Une série : où tu en es exercice par exercice (un clic ouvre l'exercice dans l'onglet Série), son
    /// énoncé, et ta copie.
    private func seriesCard(_ series: ExerciseSeries, course: Course, tint: Color) -> some View {
        let name = series.title.isEmpty ? series.displayName : series.title
        let exercises = series.sortedExercises
        let firstOpen = exercises.first { !$0.isDone }
        let copy = hasNotesTool ? NotesStore.shared.copy(for: series, course: course, among: allCourses) : nil
        return card(name, icon: "list.number", detail: "\(series.doneCount)/\(series.requiredExercises.count)") {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 30, maximum: 38), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(exercises) { exercise in
                        Button { go?(.exercise(exercise)) } label: {
                            Text(exercise.exerciseNumber.split(separator: ".").last.map(String.init) ?? exercise.exerciseNumber)
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .frame(minWidth: 28, minHeight: 28)
                                .background(exerciseColor(exercise, tint: tint), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .foregroundStyle(exercise.isDone || exercise.correctness != nil ? Carnet.ink : Carnet.inkSecondary)
                                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(exercise.id == firstOpen?.id ? tint : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .disabled(go == nil)
                        .help("\(exercise.displayNumber)\(exercise.isBonus ? " (bonus)" : "")")
                    }
                }
                ViewThatFits(in: .horizontal) {
                    seriesActions(series, name: name, firstOpen: firstOpen, copy: copy, tint: tint)
                    seriesActions(series, name: name, firstOpen: firstOpen, copy: copy, tint: tint, short: true)
                }
            }
            .padding(12)
        }
    }

    private func exerciseColor(_ exercise: Exercise, tint: Color) -> Color {
        switch exercise.correctness {
        case .correct?: return Carnet.correct.opacity(0.35)
        case .partial?: return Carnet.review.opacity(0.35)
        case .wrong?: return Carnet.wrong.opacity(0.35)
        case nil: return exercise.isDone ? tint.opacity(0.25) : Carnet.sheetRaised
        }
    }

    private func seriesActions(_ series: ExerciseSeries, name: String, firstOpen: Exercise?, copy: NotesLibrary.Document?, tint: Color, short: Bool = false) -> some View {
        HStack(spacing: 8) {
            if let go, let target = firstOpen ?? series.sortedExercises.first {
                Button { go(.exercise(target)) } label: {
                    Label(short ? "Faire" : (firstOpen == nil ? String(localized: "Revoir la série") : String(localized: "Faire la série")), systemImage: "pencil.and.list.clipboard")
                }
                .buttonStyle(.ink)
            }
            if !series.urlString.isEmpty {
                Button { openSeriesStatement(series, title: name) } label: { Label(short ? "Énoncé" : "L'énoncé", systemImage: "doc.text") }
                    .buttonStyle(.paper)
            }
            if copy != nil, let go {
                Button { go(.notes) } label: { Label(short ? "Copie" : "Ma copie", systemImage: "pencil.and.scribble") }
                    .buttonStyle(.paper)
            }
            Spacer(minLength: 0)
        }
        .labelStyle(.titleAndIcon)
    }

    private func openSeriesStatement(_ series: ExerciseSeries, title: String) {
        if let path = BotafogoLinks.coursPath(series.urlString), let site = botafogoURL {
            Task {
                await book.load(site)
                reading = .botafogo(title: title, url: path)
            }
        } else if !series.urlString.isEmpty, !BotafogoLinks.isPage(series.urlString) {
            reading = .pdf(title: title, address: series.urlString)
        }
    }

    private func open(_ item: TheoryItem) {
        reading = .theory(item.id)
    }

    /// Un lien du cours, ouvert en natif selon où il mène (`SiteRouter`) ;
    /// l'onglet Web seulement pour GeoGebra et les sites qu'on ne sait pas lire.
    private func openLink(_ address: String, title: String, kind: ContentLink.Kind? = nil) {
        guard let url = URL(string: address), url.scheme?.hasPrefix("http") == true else { return }
        if kind == .pdf || kind == .slides || kind == .notes || kind == .solution { reading = .pdf(title: title, address: address); return }
        switch SiteRouter.route(address) {
        case .pdf:
            reading = .pdf(title: title, address: address)
        case .file:
            reading = .file(title: title, address: address)
        case .moodle(let module, let id):
            reading = .moodle(module: module, id: id, title: title)
        case .mediaspace, .youtube, .video:
            reading = .video(title: title, address: address)
        case .courseware:
            source = .courseware
        case .botafogo:
            source = .botafogo
        case .geogebra, .web:
            if Self.isDocument(url) { reading = .pdf(title: title, address: address) } else { openWeb(url, title) }
        }
    }

    static func isDocument(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.hasSuffix(".pdf") || path.contains("/pluginfile.php/") || path.contains("/mod/resource/")
    }

    // MARK: Moodle

    @ViewBuilder
    private func moodleList(_ course: Course) -> some View {
        if let id = moodleID {
            if let page = desk.moodlePages[id] {
                MoodleCourseList(page: page, tint: Carnet.tint(course.colorHex),
                                 selectedSection: { if case .moodleSection(let n)? = reading { return n }; return nil }(),
                                 selectedActivity: { if case .moodle(_, let a, _)? = reading { return a }; return nil }(),
                                 openSection: { reading = .moodleSection($0.number) },
                                 openActivity: { openMoodle($0) })
                    .onAppear {
                        if !compact, reading == nil, let current = page.currentSection() { reading = .moodleSection(current.number) }
                    }
            } else if let error = desk.moodleError[id] {
                VStack(spacing: 12) {
                    Text(error).foregroundStyle(Carnet.inkSecondary).multilineTextAlignment(.center)
                    Button("Se connecter") { desk.signIn = .moodle }.buttonStyle(.ink)
                    Button("Réessayer") { loadMoodle(id, course: course) }.buttonStyle(.paper)
                }
                .padding(20)
                .frame(maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxHeight: .infinity)
                    .onAppear { loadMoodle(id, course: course) }
            }
        }
    }

    /// Une demande venue d'ailleurs (l'accueil « En cours ») : la source, la lecture.
    private func consumeRequest() {
        guard let request = desk.request, request.courseID == course?.id else { return }
        desk.request = nil
        source = request.source
        guard let wanted = request.reading else { return }
        // Une section du polycopié se lit dans le livre du site : chargé d'abord.
        if case .botafogo = wanted, let site = botafogoURL {
            Task {
                await book.load(site)
                reading = wanted
            }
        } else {
            reading = wanted
        }
    }

    private func loadMoodle(_ id: Int, course: Course) {
        Task { await desk.loadMoodlePage(id, title: course.name) }
    }

    /// Une activité de la page du cours, ouverte au bon endroit.
    private func openMoodle(_ activity: MoodleCoursePage.Activity) {
        switch activity.module {
        case "resource":
            reading = .pdf(title: activity.name, address: activity.url)
        case "lti" where activity.name.lowercased().contains("ed"):
            source = .ed
        default:
            reading = .moodle(module: activity.module, id: activity.id, title: activity.name)
        }
    }

    private func openActivity(_ activity: MoodleActivity) {
        if activity.module == "resource" {
            reading = .pdf(title: activity.name, address: activity.link)
        } else if let id = Int(activity.id) ?? URLComponents(string: activity.link)?.queryItems?.first(where: { $0.name == "id" })?.value.flatMap(Int.init) {
            reading = .moodle(module: activity.module, id: id, title: activity.name)
        } else {
            openLink(activity.link, title: activity.name)
        }
    }

    // MARK: Mes notes

    /// Tes cahiers de ce cours (GoodNotes → Google Drive…), par semaine.
    private var notes: [NotesLibrary.Document] {
        guard let course else { return [] }
        return NotesStore.shared.documents(for: course, among: allCourses)
    }

    private var notesList: some View {
        let documents = notes
        let weeks = Array(Set(documents.map { $0.week ?? 0 })).sorted { ($0 == 0 ? -1 : $0) > ($1 == 0 ? -1 : $1) }
        return List {
            ForEach(weeks, id: \.self) { week in
                Section {
                    ForEach(documents.filter { ($0.week ?? 0) == week }.sorted { $0.modified > $1.modified }) { document in
                        Button {
                            if let url = NotesStore.shared.url(document) { reading = .pdf(title: document.title, address: url.absoluteString) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: document.isSolution ? "checkmark.seal" : (document.seriesNumber != nil ? "list.number" : "pencil.and.scribble"))
                                    .foregroundStyle(Carnet.tint(course?.colorHex ?? "")).frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(document.title).foregroundStyle(Carnet.ink).lineLimit(2)
                                    Text(document.modified.formatted(.relative(presentation: .named).locale(DateUtils.appLocale)))
                                        .font(.caption2).foregroundStyle(Carnet.inkTertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(week > 0 ? "Semaine \(week)" : "Autres").font(Carnet.serif(.headline)).foregroundStyle(Carnet.ink)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    // MARK: Ed

    @ViewBuilder
    private var edList: some View {
        if let ed = edCourse {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if !(desk.edLessons[ed.id] ?? []).isEmpty {
                        Picker("Ed", selection: $edLessonsShown) {
                            Text("Fils").tag(false)
                            Text("Leçons").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    Menu {
                        Button("Toutes") { edCategory = nil }
                        ForEach(Array(Set((desk.edThreads[ed.id] ?? []).compactMap(\.category))).sorted(), id: \.self) { name in
                            Button(name) { edCategory = name }
                        }
                    } label: {
                        Label(edCategory ?? "Toutes", systemImage: "line.3.horizontal.decrease")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Spacer()
                    Button { composingEd = true } label: { Label("Question", systemImage: "square.and.pencil") }
                        .buttonStyle(.paper)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                if edLessonsShown, let lessons = desk.edLessons[ed.id] {
                    List(lessons) { lesson in
                        Button { reading = .edLesson(lesson) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(lesson.title).foregroundStyle(Carnet.ink).lineLimit(2)
                                if let module = lesson.module { Text(module).font(.caption).foregroundStyle(Carnet.inkTertiary) }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                } else if let threads = desk.edThreads[ed.id] {
                    List {
                        ForEach(threads.filter { edCategory == nil || $0.category == edCategory }) { thread in
                            Button { reading = .edThread(id: thread.id, title: thread.title) } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: thread.isPinned == true ? "pin.fill"
                                          : (thread.type == "announcement" ? "megaphone" : (thread.isAnswered == true ? "checkmark.bubble" : "bubble.left")))
                                        .foregroundStyle(Carnet.tint(course?.colorHex ?? "")).frame(width: 18)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(thread.title).foregroundStyle(Carnet.ink).lineLimit(2)
                                        Text([thread.category, thread.replyCount.map { "\($0) rép." }].compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(Carnet.inkTertiary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground({ if case .edThread(let id, _)? = reading, id == thread.id { return Carnet.tint(course?.colorHex ?? "").opacity(0.12) }; return Color.clear }())
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                } else {
                    ProgressView().frame(maxHeight: .infinity)
                }
            }
            .task(id: "\(ed.id)|\(desk.signInRevision)|\(edReload)") {
                await SchoolConnect.shared.ensure(.ed)
                do {
                    desk.edThreads[ed.id] = try await desk.ed.threads(course: ed.id)
                    // Les fils sont lus : le mode étude du Mac retire son point « nouveau ».
                    if let course { NotificationCenter.default.post(name: .studyEdThreadsRead, object: course.id) }
                }
                catch HiddenSiteSession.SiteError.notSignedIn { desk.edNeedsLogin = true }
                catch {}
                if desk.edLessons[ed.id] == nil { desk.edLessons[ed.id] = (try? await desk.ed.lessons(course: ed.id)) ?? [] }
            }
            .sheet(isPresented: $composingEd) {
                EdComposeSheet(courseID: ed.id, desk: desk) { id in
                    edReload += 1
                    if let id { reading = .edThread(id: id, title: String(localized: "Ta question")) }
                }
            }
        } else {
            VStack(spacing: 12) {
                Text("Connecte-toi à Ed.").foregroundStyle(Carnet.inkSecondary)
                Button("Se connecter") { desk.signIn = .ed }.buttonStyle(.ink)
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: Courseware

    @ViewBuilder
    private var coursewareList: some View {
        if let key = coursewareKey {
            if let outline = desk.edxOutlines[key] {
                CoursewareList(outline: outline, tint: Carnet.tint(course?.colorHex ?? ""),
                               selected: {
                                   if case .edx(let unit)? = reading { return unit.id }
                                   if case .edxMoment(let unit, _, _)? = reading { return unit.id }
                                   return nil
                               }(),
                               open: { reading = .edx($0) },
                               search: { query in
                                   AnyView(CoursewareSearchResults(outline: outline, key: key, query: query, tint: Carnet.tint(course?.colorHex ?? ""),
                                                                   desk: desk) { unit, block, start in
                                       reading = .edxMoment(unit, block: block, start: start)
                                   })
                               },
                               playChapter: { reading = .edxPlaylist($0.id) })
                    .onAppear { if !compact, reading == nil, let resume = outline.resumeUnit { reading = .edx(resume) } }
            } else if coursewareFailed {
                VStack(spacing: 12) {
                    Text("Connecte-toi à Courseware.").foregroundStyle(Carnet.inkSecondary)
                    Button("Se connecter") { desk.signIn = .courseware }.buttonStyle(.ink)
                }
                .frame(maxHeight: .infinity)
                .onChange(of: desk.signInRevision) { _, _ in coursewareFailed = false }
            } else {
                ProgressView()
                    .frame(maxHeight: .infinity)
                    .task(id: desk.signInRevision) {
                        await SchoolConnect.shared.ensure(.courseware)
                        do { desk.edxOutlines[key] = try await desk.courseware.outline(of: key) } catch { coursewareFailed = true }
                    }
            }
        }
    }

    static func botafogoIcon(_ type: String) -> String {
        switch type {
        case "series": return "list.number"
        case "session": return "person.2"
        case "weekContent": return "calendar"
        case "exam": return "doc.text.magnifyingglass"
        case "lecture": return "play.rectangle"
        default: return "book.pages"
        }
    }

    static func icon(for module: String) -> String {
        switch module {
        case "resource": return "doc.richtext"
        case "folder": return "folder"
        case "url": return "link"
        case "page": return "doc.text"
        case "assign": return "tray.and.arrow.up"
        case "forum": return "bubble.left.and.bubble.right"
        case "quiz": return "checklist"
        default: return "square.grid.2x2"
        }
    }

    // MARK: Botafogo

    @ViewBuilder
    private var botafogoList: some View {
        if let url = botafogoURL {
            switch book.state {
            case .ready(let weeks):
                VStack(spacing: 0) {
                    Picker("Partie", selection: $botafogoPart) {
                        ForEach(BotafogoPart.allCases.filter { part in
                            (part != .handout || !book.chapters.isEmpty) && (part != .infos || !book.infos.isEmpty)
                        }) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    ScrollViewReader { proxy in
                        List {
                            switch botafogoPart {
                            case .handout: botafogoHandout
                            case .sessions: botafogoSessions(weeks)
                            case .infos: botafogoInfos
                            }
                        }
                        .listStyle(.sidebar)
                        .scrollContentBackground(.hidden)
                        .task(id: botafogoPart) {
                            // La semaine en cours (ou le chapitre qu'on lit), sous les yeux.
                            try? await Task.sleep(for: .milliseconds(80))
                            if botafogoPart == .sessions, let current = BotafogoSite.currentWeek(weeks) {
                                proxy.scrollTo("week-\(current)", anchor: .top)
                            } else if botafogoPart == .handout, case .botafogo(_, let path)? = reading, BotafogoSite.isHandout(path) {
                                proxy.scrollTo(path, anchor: .center)
                            }
                        }
                    }
                }
            case .failed(let message):
                VStack(spacing: 10) {
                    Text(message).foregroundStyle(Carnet.inkSecondary)
                    Button("Réessayer") { book.reset(); Task { await book.load(url) } }.buttonStyle(.paper)
                }
                .frame(maxHeight: .infinity)
            case .idle, .loading:
                ProgressView()
                    .frame(maxHeight: .infinity)
                    .task { await book.load(url) }
            }
        }
    }

    private var botafogoTint: Color { Carnet.tint(course?.colorHex ?? "") }

    private func isReading(_ url: String?) -> Bool {
        guard let url, case .botafogo(_, let current)? = reading else { return false }
        return current == url
    }

    /// Une ligne : icône, titre (avec ses formules), détail ; surlignée quand on la lit.
    private func botafogoRow(icon: String, title: String, detail: String? = nil, url: String, readingTitle: String? = nil) -> some View {
        Button { reading = .botafogo(title: readingTitle ?? title, url: url) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: icon).font(.callout).foregroundStyle(botafogoTint).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    MacMathText(title, size: 13).foregroundStyle(Carnet.ink).lineLimit(2)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(Carnet.inkSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isReading(url) ? botafogoTint.opacity(0.14) : Color.clear)
        .id(url)
    }

    private func weekHeader(_ week: BotafogoNode, index: Int, current: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            MacMathText(week.name ?? "Semaine \(index + 1)", size: 14, design: .serif).foregroundStyle(Carnet.ink)
            Spacer(minLength: 4)
            if index == current {
                Text("Cette semaine").font(.caption2.weight(.semibold)).foregroundStyle(botafogoTint)
            } else if let date = (week.children ?? []).compactMap({ BotafogoProgram.date($0.meta("date")) }).min() {
                Text(date.formatted(.dateTime.day().month(.abbreviated))).font(.caption2).foregroundStyle(Carnet.inkTertiary)
            }
        }
        .id("week-\(index)")
    }

    /// Le polycopié : chapitres et sections numérotés, comme la colonne de droite du site.
    @ViewBuilder
    private var botafogoHandout: some View {
        ForEach(Array(book.chapters.enumerated()), id: \.offset) { _, chapter in
            Section {
                ForEach(chapter.sections, id: \.path) { section in
                    botafogoRow(icon: "text.book.closed", title: section.title, url: section.path)
                }
            } header: {
                MacMathText(chapter.title, size: 14, design: .serif).foregroundStyle(Carnet.ink)
            }
        }
    }

    /// Les séances : pour chaque thème, la séance (ses quiz et exercices de
    /// classe), le programme de la semaine, et les sections du polycopié à lire.
    @ViewBuilder
    private func botafogoSessions(_ weeks: [BotafogoNode]) -> some View {
        let current = BotafogoSite.currentWeek(weeks)
        ForEach(Array(weeks.enumerated()), id: \.offset) { index, week in
            let parts = (week.children ?? []).filter { BotafogoSite.isSessionPart($0) && $0.url != nil }
            let weekContent = parts.first { $0.type == "weekContent" }?.url
            if !parts.isEmpty {
                Section {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, node in
                        botafogoRow(icon: Self.botafogoIcon(node.type),
                                    title: node.type == "weekContent" ? String(localized: "Programme de la semaine") : node.displayName,
                                    detail: BotafogoProgram.date(node.meta("date")).map { $0.formatted(.dateTime.weekday(.wide).day().month(.wide)) },
                                    url: node.url ?? "", readingTitle: node.type == "weekContent" ? week.name : node.displayName)
                    }
                    ForEach(readings[weekContent ?? ""] ?? [], id: \.path) { section in
                        botafogoRow(icon: "text.book.closed", title: section.title, url: section.path)
                    }
                } header: { weekHeader(week, index: index, current: current) }
                .task(id: weekContent) {
                    // Ce qu'il faut lire cette semaine-là, lu dans sa page (une fois).
                    guard let weekContent, readings[weekContent] == nil else { return }
                    readings[weekContent] = await book.readings(of: weekContent)
                }
            }
        }
    }

    /// Les infos générales : présentation du cours, forum, enregistrements.
    @ViewBuilder
    private var botafogoInfos: some View {
        ForEach(Array(book.infos.enumerated()), id: \.offset) { _, group in
            Section {
                ForEach(Array((group.children ?? []).filter { $0.url != nil }.enumerated()), id: \.offset) { _, node in
                    botafogoRow(icon: "info.circle", title: node.displayName, url: node.url ?? "")
                }
            } header: {
                MacMathText(group.name ?? "Infos", size: 14, design: .serif).foregroundStyle(Carnet.ink)
            }
        }
    }

    /// Le contexte d'un document : « Polycopié · 3 Suites réelles », « Séance 5 · Complexes ».
    private func botafogoContext(_ url: String) -> String? {
        if BotafogoSite.isHandout(url) {
            return [String(localized: "Polycopié"), book.chapter(of: url)?.title].compactMap { $0 }.joined(separator: " · ")
        }
        guard let week = book.week(containing: url) else { return nil }
        return week.name.map { MathMarkup.plain($0) }
    }

    /// La ressource ouverte (pour la surligner dans « Gardés »).
    @State private var openResourceID: String?

    /// Une ressource gardée : son fichier, son document, sa section, ou le Web.
    private func openResource(_ resource: SavedResource, course: Course) {
        openResourceID = resource.id.uuidString
        if resource.kind == .web, !resource.isFile {
            openLink(resource.address, title: resource.title)
        } else if resource.kind == .poly, let site = botafogoURL {
            Task {
                await book.load(site)
                reading = .botafogo(title: resource.title, url: resource.address)
            }
        } else if let target = ResourceLibrary.reading(for: resource) {
            reading = target
        }
    }

    /// Le signet d'en-tête : pas pour un fichier déjà à soi.
    @ViewBuilder
    private func saveButton(_ title: String, _ address: String, _ kind: SavedResource.Kind) -> some View {
        if let course, !address.hasPrefix("file:") {
            SaveResourceButton(course: course, title: title, address: address, kind: kind)
        }
    }

    /// « Relire » sur la fiche : la section du polycopié, dans le cours.
    private func openSheetLink(_ link: String) {
        if BotafogoSite.isHandout(link), let site = botafogoURL {
            Task {
                await book.load(site)
                source = .botafogo
                reading = .botafogo(title: book.section(link)?.title ?? link, url: link)
            }
        } else {
            openLink(link, title: "")
        }
    }

    /// Ouvrir une section du polycopié (un renvoi dans un document).
    private func openPoly(_ path: String) {
        reading = .botafogo(title: book.section(path)?.title ?? path, url: path)
        if botafogoPart != .sessions { botafogoPart = .handout }
    }

    // MARK: Lecture

    @ViewBuilder
    private func reader(_ course: Course) -> some View {
        switch reading ?? document {
        case .pdf(let title, let address)?:
            VStack(spacing: 0) {
                readerHeader(title, address: address)
                switch desk.document(address) {
                case .ready(let file)?:
                    PDFPane(url: file, memory: address, markStudied: { address in
                        TheoryTracking.mark(address, in: course)
                    })
                case .needsLogin?:
                    VStack(spacing: 10) {
                        Text("Connecte-toi à Moodle.").foregroundStyle(Carnet.inkSecondary)
                        HStack {
                            Button("Se connecter") { desk.signIn = .moodle }.buttonStyle(.ink)
                            Button("Réessayer") { desk.retry(address) }.buttonStyle(.paper)
                        }
                    }
                    .frame(maxHeight: .infinity)
                case .failed(let message)?:
                    VStack(spacing: 10) {
                        Text(message).foregroundStyle(Carnet.inkSecondary)
                        Button("Réessayer") { desk.retry(address) }.buttonStyle(.paper)
                    }
                    .frame(maxHeight: .infinity)
                case .loading?, nil:
                    ProgressView().frame(maxHeight: .infinity).onAppear { desk.loadPDF(address) }
                }
            }
            .id(address)
        case .botafogo(let title, let url)?:
            BotafogoDocumentView(book: book, url: url, title: title, context: botafogoContext(url), desk: desk,
                                 openPoly: openPoly, openWeb: openWeb, ask: ask,
                                 accessory: AnyView(HStack(spacing: 8) {
                                     saveButton(title, url, .poly)
                                     besideButton(.botafogo(title: title, url: url), title)
                                 }))
                .environment(\.botafogoTint, botafogoTint)
                .id(url)
        case .moodle(let module, let id, let title)?:
            VStack(spacing: 0) {
                plainHeader(title)
                MoodleActivityReader(module: module, id: id, title: title, desk: desk,
                                     open: { openLink($0, title: $1) }, openWeb: openWeb)
            }
            .id("\(module)\(id)")
        case .video(let title, let address)?:
            VStack(spacing: 0) {
                plainHeader(title, save: (address, .video))
                ScrollView {
                    NativeVideo(title: title, address: address, desk: desk, openWeb: openWeb)
                        .padding(32)
                        .frame(maxWidth: 960)
                        .frame(maxWidth: .infinity)
                }
            }
            .id(address)
        case .file(let title, let address)?:
            VStack(spacing: 0) {
                plainHeader(title, save: (address, .file))
                FileReader(title: title, address: address, desk: desk)
            }
            .id(address)
        case .moodleSection(let number)?:
            if let id = moodleID, let section = desk.moodlePages[id]?.sections.first(where: { $0.number == number }) {
                MoodleSectionPage(section: section, tint: Carnet.tint(course.colorHex), desk: desk,
                                  openActivity: { openMoodle($0) }, openLink: { openLink($0, title: $1) }, openWeb: openWeb)
                    .id("section\(number)")
            }
        case .edLesson(let lesson)?:
            VStack(spacing: 0) {
                plainHeader(lesson.title)
                EdLessonReader(lesson: lesson, desk: desk, open: { openLink($0, title: $1) }, openWeb: openWeb)
            }
            .id("lesson\(lesson.id)")
        case .edThread(let id, let title)?:
            VStack(spacing: 0) {
                plainHeader(title)
                EdThreadReader(id: id, title: title, desk: desk, open: { openLink($0, title: $1) }, openWeb: openWeb)
            }
            .id("ed\(id)")
        case .edx(let unit)?:
            if let key = coursewareKey, let outline = desk.edxOutlines[key] {
                CoursewareUnitPage(outline: outline, unit: unit, key: key, tint: Carnet.tint(course.colorHex), desk: desk,
                                   go: { reading = .edx($0) }, open: { openLink($0, title: $1) }, openWeb: openWeb)
                    .id(unit.id)
            }
        case .edxMoment(let unit, let block, let start)?:
            if let key = coursewareKey, let outline = desk.edxOutlines[key] {
                CoursewareUnitPage(outline: outline, unit: unit, key: key, tint: Carnet.tint(course.colorHex), desk: desk,
                                   start: (block, start),
                                   go: { reading = .edx($0) }, open: { openLink($0, title: $1) }, openWeb: openWeb)
                    .id("\(unit.id)@\(Int(start))")
            }
        case .pastExam(let id)?:
            if let exam = course.pastExams.first(where: { $0.id == id }) {
                PastExamWorkView(exam: exam, desk: desk, ask: ask).id(id)
            }
        case .edxPlaylist(let chapter)?:
            if let key = coursewareKey, let outline = desk.edxOutlines[key] {
                CoursewarePlaylistPage(outline: outline, chapterID: chapter, key: key, tint: Carnet.tint(course.colorHex),
                                       desk: desk, openWeb: openWeb)
                    .id(chapter)
            }
        case .theory(let id)?:
            if let item = course.theoryItems.first(where: { $0.id == id }) {
                TheoryDetail(item: item, tint: Carnet.tint(course.colorHex), openLink: { openLink($0, title: $1, kind: $2) })
            }
        case nil:
            ContentUnavailableView {
                Label(course.name, systemImage: "books.vertical")
            } description: {
                Text("Choisis à gauche.")
            }
        }
    }

    @ViewBuilder
    private func readerHeader(_ title: String, address: String) -> some View {
        if document == nil {
            HStack {
                Text(title).font(Carnet.serif(.title3)).foregroundStyle(Carnet.ink).lineLimit(1)
                Spacer()
                saveButton(title, address, .pdf)
                if let reading { besideButton(reading, title) }
                Button { ask(String(localized: "J'ai une question sur ce document (« \(title) »).")) } label: {
                    Label("Claude", systemImage: "sparkle")
                }
                .buttonStyle(.paper)
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func plainHeader(_ title: String, save: (address: String, kind: SavedResource.Kind)? = nil) -> some View {
        if document == nil {
            HStack {
                Text(title).font(Carnet.serif(.title3)).foregroundStyle(Carnet.ink).lineLimit(1)
                Spacer()
                if let save { saveButton(title, save.address, save.kind) }
                if let reading { besideButton(reading, title) }
                Button { ask(String(localized: "J'ai une question sur « \(title) ».")) } label: {
                    Label("Claude", systemImage: "sparkle")
                }
                .buttonStyle(.paper)
            }
            .padding(12)
        }
    }

    /// Garder ce document à côté : on continue de parcourir le cours au centre.
    @ViewBuilder
    private func besideButton(_ reading: Reading, _ title: String) -> some View {
        if let sendBeside, document == nil {
            Button { sendBeside(reading, title) } label: {
                Label("À côté", systemImage: "sidebar.right")
            }
            .buttonStyle(.paper)
            .help("Garder ce document dans le volet d'à côté")
        }
    }
}

private struct TheoryLine: View {
    @Bindable var item: TheoryItem
    let tint: Color
    let selected: Bool
    var open: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                item.watchedAt = item.isWatched ? nil : Date()
            } label: {
                Image(systemName: item.isWatched ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isWatched ? tint : Carnet.inkTertiary)
            }
            .buttonStyle(.plain)
            Button(action: open) {
                HStack(spacing: 6) {
                    Image(systemName: item.kind.icon).foregroundStyle(tint).frame(width: 16)
                    Text(item.title.isEmpty ? item.kind.label : item.numberAndTitle)
                        .foregroundStyle(item.isWatched ? Carnet.inkSecondary : Carnet.ink)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .listRowBackground(selected ? tint.opacity(0.12) : Color.clear)
    }
}

/// Une vidéo, une section : ses liens, son résumé, le cocher.
private struct TheoryDetail: View {
    @Bindable var item: TheoryItem
    let tint: Color
    var openLink: (String, String, ContentLink.Kind?) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Kicker([item.kind.label, item.plannedWeek > 0 ? "semaine \(item.plannedWeek)" : nil].compactMap { $0 }.joined(separator: " · "), color: tint)
                Text(item.title.isEmpty ? item.kind.label : item.numberAndTitle).font(Carnet.serif(30)).foregroundStyle(Carnet.ink)
                Toggle("Vu", isOn: Binding(get: { item.isWatched }, set: { item.watchedAt = $0 ? (item.watchedAt ?? Date()) : nil }))
                    .studyCheckbox()
                if let summary = item.summaryText, !summary.isEmpty {
                    RichTextView(text: summary, size: 15)
                }
                VStack(alignment: .leading, spacing: 8) {
                    if !item.urlString.isEmpty {
                        Button { openLink(item.urlString, item.title, nil) } label: {
                            Label("Ouvrir", systemImage: item.kind.icon)
                        }
                        .buttonStyle(.ink)
                    }
                    ForEach(item.links, id: \.url) { link in
                        Button { openLink(link.url, link.title, link.kind) } label: { Label(link.title, systemImage: link.kind.icon) }
                            .buttonStyle(.paper)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension Notification.Name {
    /// La liste des fils Ed d'un cours vient d'être lue (l'objet : l'identifiant du cours).
    static let studyEdThreadsRead = Notification.Name("study.edThreadsRead")
}
