import SwiftUI

/// La fiche de révision d'un cours : chaque chapitre, ses définitions,
/// théorèmes, formules, méthodes et pièges ; une recherche qui en fait
/// l'index ; et, à la fin, ce que tes séries ont appris (erreurs notées,
/// exercices à refaire). « Relire » ouvre la section du polycopié.
struct RevisionSheetView: View {
    @Bindable var course: Course
    var desk: SiteHub
    /// Ouvrir une section du polycopié (son chemin `/handout/…`).
    var openPoly: (String) -> Void
    var compact = false
    /// Un chapitre à ouvrir d'emblée (depuis la semaine : « Fiche · chapitre »).
    var openChapter: String? = nil

    enum Filter: String, CaseIterable, Identifiable {
        case all, statements, methods
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .all: return "Tout"
            case .statements: return "Énoncés"
            case .methods: return "Méthodes"
            }
        }

        func keeps(_ kind: RevisionSheet.Entry.Kind) -> Bool {
            switch self {
            case .all: return true
            case .statements: return [.definition, .theorem, .proposition, .lemma, .corollary, .formula].contains(kind)
            case .methods: return [.method, .pitfall, .example].contains(kind)
            }
        }
    }

    /// Les façons de travailler la fiche : la relire, la voir en carte, en schémas, dans l'ordre
    /// où la comprendre, ou l'écouter (NotebookLM, si c'est allumé dans les Réglages).
    enum Tab: String, CaseIterable, Identifiable {
        case fiche, carte, schemas, parcours, ecouter
        var id: String { rawValue }
        var title: String {
            switch self {
            case .fiche: return String(localized: "Fiche")
            case .carte: return String(localized: "Carte")
            case .schemas: return String(localized: "Schémas")
            case .parcours: return String(localized: "Parcours")
            case .ecouter: return String(localized: "Écouter")
            }
        }
        var icon: String {
            switch self {
            case .fiche: return "doc.text"
            case .carte: return "point.3.connected.trianglepath.dotted"
            case .schemas: return "arrow.triangle.branch"
            case .parcours: return "list.number"
            case .ecouter: return "waveform"
            }
        }
    }

    @State private var tab: Tab = .fiche
    /// Le chapitre regardé, dans tous les onglets (`nil` : le cours entier). Un chapitre qui n'existe
    /// plus (fiche refaite) revient au cours entier.
    @State private var chapterScope: String?
    private var scope: String? { sheet?.chapter(chapterScope) == nil ? nil : chapterScope }
    /// La notion dont on voit la page (à côté, ou en feuille dans un volet étroit).
    @State private var concept: String?
    @AppStorage("notebooklm.enabled") private var notebookOn = false
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var jump: String?
    @State private var openChapters: Set<String> = []
    private var maker: RevisionSheetMaker { .shared }
    private var tint: Color { Carnet.tint(course.colorHex) }

    private var sheet: RevisionSheet? { course.revisionSheet }

    private var chapters: [RevisionSheet.Chapter] {
        (sheet?.filtered(query) ?? []).compactMap { chapter in
            if let scope, chapter.id != scope { return nil }
            let kept = chapter.entries.filter { filter.keeps($0.kind) }
            return kept.isEmpty ? nil : RevisionSheet.Chapter(id: chapter.id, title: chapter.title, entries: kept)
        }
    }

    /// Ce que tes séries ont laissé : les erreurs notées, les exercices à refaire.
    private var mistakes: [(exercise: Exercise, mistake: Mistake)] {
        course.sortedSeries.flatMap { series in
            series.sortedExercises.flatMap { exercise in exercise.mistakes.map { (exercise, $0) } }
        }
    }

    private var redo: [Exercise] {
        course.sortedSeries.flatMap(\.sortedExercises).filter { $0.redoRequired || $0.isQueuedForRedo }
    }

    private var hasPersonal: Bool { scope == nil && query.isEmpty && filter != .statements && (!mistakes.isEmpty || !redo.isEmpty) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(Carnet.rule).frame(height: 1)
            // Quel que soit l'onglet, le contenu prend toute la place : sinon la pile se centre et le haut descend.
            content.id(scope ?? "tout").frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Carnet.ground)
        .modifier(ConceptPresenter(course: course, concept: $concept, compact: compact, openPoly: openPoly))
        .onAppear {
            #if DEBUG
            // `-ficheTab carte|schemas|parcours|ecouter` et `-ficheConcept` : ouvrir directement un onglet, une notion.
            if let index = CommandLine.arguments.firstIndex(of: "-ficheTab"), index + 1 < CommandLine.arguments.count,
               let chosen = Tab(rawValue: CommandLine.arguments[index + 1]) { tab = chosen }
            // `-ficheChapter <id>` : ne regarder que ce chapitre (c0, c1, c2 dans la fiche d'essai).
            if let index = CommandLine.arguments.firstIndex(of: "-ficheChapter"), index + 1 < CommandLine.arguments.count { chapterScope = CommandLine.arguments[index + 1] }
            if CommandLine.arguments.contains("-ficheConcept") { concept = sheet?.keyed.dropFirst(2).first?.key }
            #endif
            if let openChapter, sheet?.chapter(openChapter) != nil { chapterScope = openChapter; tab = .fiche }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .fiche: ficheTab
        case .carte: MindMapView(course: course, concept: $concept, chapter: scope)
        case .schemas: DiagramsView(course: course, concept: $concept, chapter: scope)
        case .parcours: LearningPathView(course: course, concept: $concept, chapter: scope, select: { chapterScope = $0 })
        case .ecouter: NotebookLMPanel(course: course, chapter: scope)
        }
    }

    // MARK: Le haut : le cours, ce qu'on peut en faire

    private var tabs: [Tab] { Tab.allCases.filter { $0 != .ecouter || notebookOn } }

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Kicker(String(localized: "Fiche de révision · \(course.displayCode)"), color: tint)
                    Text(course.name).font(Carnet.serif(compact ? 20 : 26)).foregroundStyle(Carnet.ink).lineLimit(2)
                }
                Spacer(minLength: 8)
                if sheet != nil {
                    if StudyMapStore.shared.canEnrich {
                        Button { Task { await StudyMapStore.shared.enrich(course, chapter: scope) } } label: {
                            Label(StudyMapStore.enrichLabel(StudyMapStore.shared.map(course), chapter: scope), systemImage: "sparkles")
                        }
                        .buttonStyle(.paper)
                        .disabled(isEnriching)
                        .help(scope == nil ? "Claude relie les notions, écrit l'idée de chacune, dessine les schémas" : "Pareil, mais pour ce chapitre seulement")
                    }
                    remake(title: "Refaire")
                }
            }
            if let sheet { Text(summary(sheet)).font(.caption).foregroundStyle(Carnet.inkSecondary) }
            if let state = maker.state(course) { status(state) }
            if let state = StudyMapStore.shared.state(course, chapter: scope) { mapStatus(state) }
            tabBar
            if sheet.map({ $0.chapters.filter { !$0.entries.isEmpty }.count > 1 }) == true { scopeBar }
        }
        .padding(.horizontal, compact ? 14 : 20)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(tabs) { item in
                Button { tab = item } label: {
                    Label(item.title, systemImage: item.icon)
                        .labelStyle(.titleAndIcon)
                        .font(.callout.weight(tab == item ? .semibold : .regular))
                        .lineLimit(1)
                        .padding(.horizontal, compact ? 9 : 13)
                        .frame(height: 32)
                        .foregroundStyle(tab == item ? Carnet.ground : Carnet.ink)
                        .background(tab == item ? Carnet.ink : Carnet.sheetRaised.opacity(0.8), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    /// Tout le cours, ou un chapitre : ce qui est regardé dans tous les onglets.
    private var scopeBar: some View {
        let list = sheet?.chapters.filter { !$0.entries.isEmpty } ?? []
        let index = list.firstIndex { $0.id == scope }
        return HStack(spacing: 8) {
            Menu {
                Button { chapterScope = nil } label: { Label("Tout le cours", systemImage: scope == nil ? "checkmark" : "books.vertical") }
                Divider()
                ForEach(list) { chapter in
                    Button { chapterScope = chapter.id } label: {
                        Label(MathMarkup.plain(chapter.title), systemImage: scope == chapter.id ? "checkmark" : "bookmark")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: scope == nil ? "books.vertical" : "bookmark.fill").foregroundStyle(tint)
                    Text(scope == nil ? String(localized: "Tout le cours") : MathMarkup.plain(sheet?.chapter(scope)?.title ?? "")).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(Carnet.inkTertiary)
                }
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12).frame(height: 30)
                .background(Carnet.sheetRaised.opacity(0.8), in: Capsule())
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
            if let index {
                Button { chapterScope = index > 0 ? list[index - 1].id : nil } label: { Image(systemName: "chevron.left") }
                    .help("Chapitre précédent")
                Button { if index + 1 < list.count { chapterScope = list[index + 1].id } } label: { Image(systemName: "chevron.right") }
                    .disabled(index + 1 >= list.count).help("Chapitre suivant")
                Button { chapterScope = nil } label: { Label("Tout le cours", systemImage: "xmark").labelStyle(.titleAndIcon) }
                    .font(.caption).foregroundStyle(Carnet.inkSecondary)
            } else if let first = list.first {
                Button { chapterScope = first.id } label: { Image(systemName: "chevron.right") }.help("Premier chapitre")
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Carnet.ink)
    }

    private var isEnriching: Bool {
        if case .working? = StudyMapStore.shared.state(course, chapter: scope) { return true }
        return false
    }

    @ViewBuilder
    private func mapStatus(_ state: StudyMapStore.State) -> some View {
        switch state {
        case .working(let message):
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(message).font(.callout).foregroundStyle(Carnet.inkSecondary) }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Carnet.wrong).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: La fiche, relue

    @ViewBuilder
    private var ficheTab: some View {
        if compact {
            VStack(spacing: 0) {
                controls.padding(12)
                document
            }
        } else {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    controls.padding(12)
                    index
                }
                .frame(width: 280)
                .background(Carnet.sheet.opacity(0.35))
                Rectangle().fill(Carnet.rule).frame(width: 1)
                document
            }
        }
    }

    // MARK: Recherche et filtre

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Carnet.inkTertiary)
                TextField("Chercher un théorème, une notion…", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Carnet.inkTertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Carnet.sheetRaised.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Picker("Montrer", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
    }

    /// Le sommaire : chaque chapitre, et dedans chaque énoncé — survolé, il
    /// montre son énoncé ; cliqué, la fiche y va.
    private var index: some View {
        List {
            ForEach(chapters) { chapter in
                DisclosureGroup(isExpanded: Binding(get: { openChapters.contains(chapter.id) || !query.isEmpty },
                                                    set: { open in
                                                        if open { openChapters.insert(chapter.id) } else { openChapters.remove(chapter.id) }
                                                    })) {
                    ForEach(chapter.entries) { entry in
                        Button { jump = entry.id } label: {
                            HStack(spacing: 6) {
                                Image(systemName: entry.kind.icon).font(.caption2).foregroundStyle(color(entry.kind)).frame(width: 14)
                                MacMathText(entry.title, size: 12).foregroundStyle(Carnet.ink).lineLimit(1)
                                Spacer(minLength: 0)
                                if let key = keyByID[entry.id] { MasteryDot(level: StudyMapStore.shared.map(course).mastery(key), size: 9) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(MathMarkup.plain(entry.body))
                    }
                } label: {
                    Button { jump = chapter.id } label: {
                        HStack {
                            MacMathText(chapter.title, size: 13).foregroundStyle(Carnet.ink).lineLimit(2)
                            Spacer(minLength: 4)
                            Text("\(chapter.entries.count)").font(.caption.monospacedDigit()).foregroundStyle(Carnet.inkTertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if hasPersonal {
                Button { jump = "personal" } label: {
                    Label("De tes séries", systemImage: "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(Carnet.ink)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    // MARK: La fiche

    private var document: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if sheet == nil {
                        empty
                    } else if chapters.isEmpty && !hasPersonal {
                        Text(query.isEmpty ? "Rien dans cette partie." : "Rien ne correspond à « \(query) ».")
                            .foregroundStyle(Carnet.inkSecondary)
                            .padding(.top, 20)
                    }
                    ForEach(chapters) { chapter in
                        VStack(alignment: .leading, spacing: 10) {
                            MacMathText(chapter.title, size: 22, design: .serif)
                                .foregroundStyle(Carnet.ink)
                                .padding(.top, 14)
                            ForEach(chapter.entries) { entry in card(entry).id(entry.id) }
                        }
                        .id(chapter.id)
                    }
                    if hasPersonal { personal.id("personal") }
                }
                .padding(.horizontal, compact ? 16 : 40)
                .padding(.vertical, 24)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: jump) { _, target in
                guard let target else { return }
                jump = nil
                // Un énoncé d'un chapitre pas encore dessiné : son chapitre d'abord.
                if let chapter = chapters.first(where: { $0.entries.contains { $0.id == target } }) {
                    proxy.scrollTo(chapter.id, anchor: .top)
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(60))
                        withAnimation(.snappy) { proxy.scrollTo(target, anchor: .top) }
                    }
                } else {
                    withAnimation(.snappy) { proxy.scrollTo(target, anchor: .top) }
                }
            }
        }
        .background(Carnet.ground)
    }

    private func summary(_ sheet: RevisionSheet) -> String {
        if let scope, let chapter = sheet.chapter(scope) {
            let counts = LearningPath.counts(sheet: sheet, map: StudyMapStore.shared.map(course), chapter: scope)
            return String(localized: "\(chapter.entries.count) entrées dans ce chapitre · \(counts.solid) solides")
        }
        let count = sheet.entries.count
        let origin = sheet.origin == .handout ? String(localized: "tirés du polycopié") : String(localized: "écrits par Claude d'après le cours")
        return String(localized: "\(count) entrées, \(origin) · \(sheet.generatedAt.formatted(.dateTime.day().month(.abbreviated)))")
    }

    @ViewBuilder
    private func remake(title: LocalizedStringKey) -> some View {
        if maker.canMake(course) {
            Button { Task { await maker.make(course, hub: desk) } } label: {
                Label(title, systemImage: "arrow.clockwise")
            }
            .buttonStyle(.paper)
            .disabled(isWorking)
        }
    }

    private var isWorking: Bool {
        if case .working? = maker.state(course) { return true }
        return false
    }

    @ViewBuilder
    private func status(_ state: RevisionSheetMaker.State) -> some View {
        switch state {
        case .working(let message):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(message).font(.callout).foregroundStyle(Carnet.inkSecondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(Carnet.wrong)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(RevisionSheetMaker.botafogoSite(of: course) != nil
                 ? "Tous les énoncés du polycopié — définitions, théorèmes, propositions — chapitre par chapitre, sans les preuves."
                 : "Claude lit tout le cours — diapositives, notes, séries et corrigés — et en écrit la fiche : définitions, théorèmes, formules, méthodes, pièges.")
                .font(.title3)
                .foregroundStyle(Carnet.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if maker.canMake(course) {
                Button { Task { await maker.make(course, hub: desk) } } label: {
                    Label("Faire la fiche", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.ink)
                .disabled(isWorking)
            } else {
                Label("Elle se fait sur le Mac, puis arrive ici par iCloud.", systemImage: "desktopcomputer")
                    .foregroundStyle(Carnet.inkSecondary)
            }
        }
        .padding(.top, 8)
    }

    // MARK: Une entrée

    private func color(_ kind: RevisionSheet.Entry.Kind) -> Color {
        switch kind {
        case .definition: return Carnet.review
        case .theorem, .proposition, .lemma, .corollary, .formula: return tint
        case .method: return Carnet.correct
        case .pitfall: return Carnet.wrong
        case .example, .remark: return Carnet.inkTertiary
        }
    }

    /// La clé de chaque notion (pour sa maîtrise, ses liens, sa page).
    private var keyByID: [String: String] {
        Dictionary(uniqueKeysWithValues: (sheet?.keyed ?? []).map { ($0.entry.id, $0.key) })
    }

    private func card(_ entry: RevisionSheet.Entry) -> some View {
        let accent = color(entry.kind)
        let key = keyByID[entry.id]
        let map = StudyMapStore.shared.map(course)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let key { MasteryDot(level: map.mastery(key), size: 11) }
                Image(systemName: entry.kind.icon).font(.caption)
                Text(entry.kind.label.uppercased()).font(.caption2.weight(.semibold)).tracking(0.8)
                Spacer(minLength: 6)
                if !entry.link.isEmpty {
                    Button { openPoly(entry.link) } label: {
                        Label("Relire", systemImage: "book")
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Carnet.inkSecondary)
                    .help(entry.source)
                }
            }
            .foregroundStyle(accent)
            if entry.title != entry.kind.label {
                MacMathText(entry.title, size: 16, design: .serif).foregroundStyle(Carnet.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let key, let gist = map.enrichment[key]?.gist {
                Text(gist).font(.callout).foregroundStyle(Carnet.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
            RichTextView(text: entry.body, size: 14)
                .textSelection(.enabled)
            if !entry.source.isEmpty, entry.link.isEmpty || compact {
                Text(entry.source).font(.caption).foregroundStyle(Carnet.inkTertiary)
            }
            if let key { cardFooter(key: key, map: map) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12, style: .continuous)
                .fill(accent.opacity(0.8))
                .frame(width: 3)
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Carnet.rule))
    }

    /// Sous une notion : où j'en suis, ce qui la précède, et sa page.
    private func cardFooter(key: String, map: StudyMap) -> some View {
        let keys = Set((sheet?.keyed ?? []).map(\.key))
        let before = StudyLinks.neighbourhood(of: key, in: map, among: keys).before
        return HStack(spacing: 8) {
            Menu {
                ForEach(StudyMap.Mastery.allCases, id: \.rawValue) { level in
                    Button { StudyMapStore.shared.setMastery(level, for: key, in: course) } label: { Label(level.label, systemImage: level.icon) }
                }
            } label: {
                Label(map.mastery(key).label, systemImage: map.mastery(key).icon)
                    .font(.caption).foregroundStyle(map.mastery(key).color)
            }
            .menuStyle(.borderlessButton).fixedSize()
            if let first = before.first, let item = sheet?.entry(forKey: first.key) {
                Button { concept = first.key } label: {
                    Label("Avant : " + item.entry.title, systemImage: "arrow.turn.up.left").font(.caption).lineLimit(1)
                }
                .buttonStyle(.plain).foregroundStyle(Carnet.inkSecondary)
            }
            Spacer(minLength: 4)
            Button { concept = key } label: { Label("Comprendre", systemImage: "lightbulb") }
                .buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(tint)
        }
    }

    // MARK: De tes séries

    private var personal: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("De tes séries").font(Carnet.serif(22)).foregroundStyle(Carnet.ink).padding(.top, 14)
            Text("Ce que tu as noté en corrigeant : à relire avant l'examen.")
                .font(.callout).foregroundStyle(Carnet.inkSecondary)
            ForEach(Array(mistakes.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: item.mistake.kind.icon).font(.caption)
                        Text("\(item.exercise.displayNumber) · \(item.mistake.kind.label)").font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(Carnet.wrong)
                    MacMathText(item.mistake.summary, size: 14).foregroundStyle(Carnet.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if !item.mistake.correction.isEmpty {
                        MacMathText("→ " + item.mistake.correction, size: 13).foregroundStyle(Carnet.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Carnet.wrong.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if !redo.isEmpty {
                Kicker("À refaire").padding(.top, 6)
                ForEach(redo) { exercise in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "arrow.counterclockwise").foregroundStyle(Carnet.review)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(exercise.displayNumber + (exercise.title.isEmpty ? "" : " · " + exercise.title))
                                .foregroundStyle(Carnet.ink)
                            if !exercise.redoWhy.isEmpty {
                                MacMathText(exercise.redoWhy, size: 13).foregroundStyle(Carnet.inkSecondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - À savoir, pour un exercice

/// Sous un exercice : les définitions, théorèmes et méthodes de la fiche qui
/// lui servent — l'énoncé seul, jamais la solution. Ce qu'on cherchait dans
/// le cours quand on bloquait.
struct ExerciseKnowHow: View {
    let exercise: Exercise
    let tint: Color
    /// « Relire » : la section du polycopié.
    var openPoly: ((String) -> Void)? = nil

    @State private var expanded: Set<String> = []

    private var text: String {
        ([exercise.title, exercise.statement, exercise.hint, exercise.solution]
            + exercise.detectedSubQuestions.map(\.text)).joined(separator: "\n")
    }

    /// Les sections lues la semaine de la série : celles que l'exercice met en pratique.
    private func preferred(_ course: Course) -> Set<String> {
        let week = exercise.series?.plannedWeek ?? -1
        return Set(course.theoryItems.filter { $0.plannedWeek == week || $0.plannedWeek == week - 1 }
            .compactMap { TheoryTracking.handoutPath($0.urlString) })
    }

    var body: some View {
        if let course = exercise.series?.course {
            if let sheet = course.revisionSheet {
                let entries = sheet.relevant(to: text, preferred: preferred(course))
                if !entries.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Kicker("À savoir", color: tint)
                        ForEach(entries) { entry in row(entry) }
                    }
                }
            } else if RevisionSheetMaker.shared.canMake(course) {
                Button {
                    Task { await RevisionSheetMaker.shared.make(course, hub: .shared) }
                } label: {
                    Label("Faire la fiche du cours : ce qu'il faut savoir pour chaque exercice s'affichera ici",
                          systemImage: "doc.text.magnifyingglass")
                        .font(.caption)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Carnet.inkSecondary)
                .disabled(RevisionSheetMaker.shared.state(course) != nil)
            }
        }
    }

    private func row(_ entry: RevisionSheet.Entry) -> some View {
        let open = expanded.contains(entry.id)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    if open { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: entry.kind.icon).font(.caption).foregroundStyle(tint).frame(width: 14)
                    MacMathText(entry.title == entry.kind.label ? entry.kind.label : entry.title, size: 13)
                        .foregroundStyle(Carnet.ink)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(Carnet.inkTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                RichTextView(text: entry.body, size: 13)
                    .textSelection(.enabled)
                    .padding(.leading, 21)
                if !entry.link.isEmpty, let openPoly {
                    Button { openPoly(entry.link) } label: { Label("Relire · \(entry.source)", systemImage: "book") }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Carnet.inkSecondary)
                        .padding(.leading, 21)
                }
            }
        }
        .padding(10)
        .background(Carnet.sheetRaised.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}


// MARK: - La page d'une notion, à côté ou en feuille

/// Où s'ouvre la page d'une notion : à côté de la fiche (volet) quand il y a la place, en feuille
/// dans un volet étroit ou sur l'iPhone.
private struct ConceptPresenter: ViewModifier {
    let course: Course
    @Binding var concept: String?
    let compact: Bool
    var openPoly: (String) -> Void

    private var shown: Binding<Bool> {
        Binding(get: { concept != nil }, set: { if !$0 { concept = nil } })
    }

    private var detail: some View {
        Group {
            if let key = concept {
                ConceptDetailView(course: course, key: key, select: { concept = $0 }, openPoly: openPoly, close: { concept = nil })
            }
        }
    }

    func body(content: Content) -> some View {
        if compact {
            content.sheet(isPresented: shown) {
                detail.presentationDetents([.medium, .large]).presentationBackground(Carnet.ground)
            }
        } else {
            // Une colonne à côté, à nous : `.inspector` s'accroche au conteneur le plus proche (la fenêtre
            // entière, ici) et déplaçait toute la page.
            HStack(spacing: 0) {
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                if concept != nil {
                    Rectangle().fill(Carnet.rule).frame(width: 1)
                    detail.frame(width: 400).frame(maxHeight: .infinity).background(Carnet.ground)
                }
            }
        }
    }
}
