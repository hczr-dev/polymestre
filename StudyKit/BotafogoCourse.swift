import SwiftUI

/// Où l'on est dans un cours Botafogo : un document du site (séance,
/// programme, infos) ou une section du polycopié.
struct BotafogoLocation: Equatable, Hashable {
    var title: String
    var url: String
}

// MARK: - Le cours, comme sur le site

/// Un cours Botafogo en entier, sur le Mac : à gauche le sommaire (les
/// semaines, le polycopié, les infos ; une recherche ; ce qu'on a lu), au
/// centre la page avec son fil d'Ariane, précédent / suivant et l'historique
/// (⌘[ ⌘]), à droite « Sur cette page », qui suit la lecture. Sans page
/// ouverte, la semaine en cours : ce qu'il y a à lire, et où reprendre.
struct BotafogoCourseView: View {
    var book: BotafogoBook
    let site: URL
    let tint: Color
    var desk: SiteHub
    var openWeb: (URL, String) -> Void
    var ask: (String) -> Void
    @Binding var location: BotafogoLocation?
    /// Le choix des sources du cours (le cours, mes notes, Moodle…), en tête de la colonne.
    var sources: AnyView?
    /// Les sections vues d'après le cours (cochées sur n'importe quel appareil).
    var studied: Set<String> = []
    /// En haut de chaque page, à côté de « Claude » (le signet « garder »).
    var accessory: ((BotafogoLocation) -> AnyView)? = nil

    @Environment(\.markStudied) private var markStudied

    enum Part: String, CaseIterable, Identifiable {
        case sessions, handout, infos
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .sessions: return "Semaines"
            case .handout: return "Polycopié"
            case .infos: return "Infos"
            }
        }
    }

    @State private var part: Part = .sessions
    /// Le sommaire replié : la page en grand.
    @AppStorage("botafogo.sidebarHidden") private var sidebarHidden = false
    @State private var query = ""
    @State private var back: [BotafogoLocation] = []
    @State private var forward: [BotafogoLocation] = []
    /// Un pas dans l'historique : ne pas l'y remettre.
    @State private var travelling = false
    @State private var read: Set<String> = []
    @State private var openWeeks: Set<Int> = []
    @State private var openChapters: Set<String> = []
    /// Les sections que chaque semaine fait lire (citées par sa page).
    @State private var readings: [String: [BotafogoSite.Chapter.Section]] = [:]

    var body: some View {
        HStack(spacing: 0) {
            if !sidebarHidden || location == nil {
                sidebar
                    .frame(width: 290)
                    .background(Carnet.sheet.opacity(0.35))
                Rectangle().fill(Carnet.rule).frame(width: 1)
            }
            Group {
                if let location {
                    BotafogoPageView(book: book, location: location, tint: tint, desk: desk,
                                     trail: trail(location.url),
                                     neighbours: neighbours(location.url),
                                     canGoBack: !back.isEmpty, canGoForward: !forward.isEmpty,
                                     isRead: read.contains(location.url),
                                     goBack: goBack, goForward: goForward,
                                     open: { self.location = $0 },
                                     openPoly: openPoly, openWeb: openWeb, ask: ask,
                                     setRead: { setRead(location.url, $0) },
                                     accessory: accessory?(location))
                        .id(location.url)
                } else {
                    BotafogoWeekHome(book: book, tint: tint, read: read, readings: readings,
                                     open: { self.location = $0 }, load: loadReadings)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomLeading) {
                if location != nil {
                    Button { withAnimation(.snappy(duration: 0.22)) { sidebarHidden.toggle() } } label: {
                        Image(systemName: sidebarHidden ? "sidebar.left" : "arrow.left.to.line")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .background(.regularMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(Carnet.rule))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Carnet.ink)
                    .padding(12)
                    .keyboardShortcut("s", modifiers: [.control, .command])
                    .help(sidebarHidden ? "Montrer le sommaire (⌃⌘S)" : "Replier le sommaire (⌃⌘S)")
                }
            }
        }
        .background(Carnet.ground)
        .environment(\.botafogoTint, tint)
        .task(id: site) {
            read = Set(UserDefaults.standard.stringArray(forKey: BotafogoNavigation.readKey(site: site)) ?? []).union(studied)
            await book.load(site)
            if let current = BotafogoSite.currentWeek(book.weeks) { openWeeks.insert(current) }
            reveal(location?.url)
        }
        .onChange(of: location) { old, new in
            if travelling { travelling = false } else if let old, old != new {
                back.append(old)
                if back.count > 50 { back.removeFirst() }
                forward.removeAll()
            }
            reveal(new?.url)
        }
    }

    // MARK: Historique

    private func goBack() {
        guard let previous = back.popLast() else { return }
        if let location { forward.append(location) }
        travelling = true
        location = previous
    }

    private func goForward() {
        guard let next = forward.popLast() else { return }
        if let location { back.append(location) }
        travelling = true
        location = next
    }

    /// Le sommaire suit la page : sa semaine ou son chapitre s'ouvre.
    private func reveal(_ url: String?) {
        guard let url, book.ready else { return }
        if BotafogoSite.isHandout(url), let chapter = book.chapter(of: url) {
            openChapters.insert(chapter.title)
        } else if let week = book.week(containing: url), let index = book.weeks.firstIndex(of: week) {
            openWeeks.insert(index)
        }
    }

    private func openPoly(_ path: String) {
        location = BotafogoLocation(title: book.section(path)?.title ?? path, url: path)
    }

    private func setRead(_ url: String, _ value: Bool) {
        guard value != read.contains(url) else { return }
        if value { read.insert(url) } else { read.remove(url) }
        UserDefaults.standard.set(Array(read).sorted(), forKey: BotafogoNavigation.readKey(site: site))
        // Lu ici, coché dans le cours : la théorie de la semaine avance.
        if value { markStudied?(url) }
    }

    private func loadReadings(_ weekContent: String) async {
        guard readings[weekContent] == nil else { return }
        readings[weekContent] = await book.readings(of: weekContent)
    }

    // MARK: Fil d'Ariane, précédent, suivant

    private func trail(_ url: String) -> [String] {
        if BotafogoSite.isHandout(url) {
            return [String(localized: "Polycopié"), book.chapter(of: url).map { BotafogoNavigation.plainTitle($0.title) }].compactMap { $0 }
        }
        if let week = book.week(containing: url), let index = book.weeks.firstIndex(of: week) {
            return [String(localized: "Semaine \(index + 1)"), week.name.map(BotafogoNavigation.plainTitle)].compactMap { $0 }
        }
        return [String(localized: "Infos")]
    }

    private func neighbours(_ url: String) -> (previous: BotafogoLocation?, next: BotafogoLocation?) {
        if BotafogoSite.isHandout(url) {
            let found = BotafogoNavigation.neighbours(of: url, in: book.chapters)
            return (found.previous.map { .init(title: $0.title, url: $0.path) }, found.next.map { .init(title: $0.title, url: $0.path) })
        }
        // Les documents des semaines, dans l'ordre du programme.
        let documents = book.weeks.flatMap { week in
            (week.children ?? []).filter { BotafogoSite.isSessionPart($0) && $0.url != nil }.map { node in
                BotafogoLocation(title: node.type == "weekContent" ? (week.name ?? node.displayName) : node.displayName, url: node.url ?? "")
            }
        }
        guard let index = documents.firstIndex(where: { $0.url == url }) else { return (nil, nil) }
        return (index > 0 ? documents[index - 1] : nil, index + 1 < documents.count ? documents[index + 1] : nil)
    }

    // MARK: Sommaire

    private var sidebar: some View {
        VStack(spacing: 0) {
            if let sources {
                sources.padding(.horizontal, 12).padding(.top, 12)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Carnet.inkTertiary)
                TextField("Rechercher dans le cours", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Carnet.inkTertiary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Carnet.sheetRaised.opacity(0.7), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.top, 12)

            if query.isEmpty {
                HStack(spacing: 4) {
                    ForEach(parts) { item in
                        Button { withAnimation(.snappy(duration: 0.2)) { part = item } } label: {
                            Text(item.title)
                                .font(.callout.weight(part == item ? .semibold : .regular))
                                .foregroundStyle(part == item ? Carnet.ink : Carnet.inkSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(part == item ? Carnet.sheetRaised : .clear, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }

            switch book.state {
            case .ready:
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            if !query.isEmpty {
                                searchResults
                            } else {
                                switch part {
                                case .sessions: weeks
                                case .handout: handout
                                case .infos: infos
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 16)
                    }
                    .task(id: part) {
                        try? await Task.sleep(for: .milliseconds(60))
                        if part == .sessions, let current = BotafogoSite.currentWeek(book.weeks) {
                            proxy.scrollTo("week-\(current)", anchor: .top)
                        } else if let url = location?.url {
                            proxy.scrollTo(url, anchor: .center)
                        }
                    }
                }
            case .failed(let message):
                VStack(spacing: 10) {
                    Text(message).foregroundStyle(Carnet.inkSecondary)
                    Button("Réessayer") { book.reset(); Task { await book.load(site) } }.buttonStyle(.paper)
                }
                .frame(maxHeight: .infinity)
            case .idle, .loading:
                ProgressView().frame(maxHeight: .infinity)
            }
        }
    }

    private var parts: [Part] {
        Part.allCases.filter { ($0 != .handout || !book.chapters.isEmpty) && ($0 != .infos || !book.infos.isEmpty) }
    }

    private func row(icon: String, title: String, detail: String? = nil, url: String, readingTitle: String? = nil) -> some View {
        let selected = location?.url == url
        return Button { location = BotafogoLocation(title: readingTitle ?? title, url: url) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? tint : Carnet.inkTertiary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    MacMathText(title, size: 13)
                        .foregroundStyle(selected ? Carnet.ink : Carnet.ink.opacity(0.88))
                        .lineLimit(2)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(Carnet.inkTertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if read.contains(url) {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(tint.opacity(0.8))
                        .help("Lu")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(selected ? tint.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(url)
    }

    private func disclosure(title: String, isOpen: Bool, accessory: some View, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Carnet.inkTertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 12)
                MacMathText(title, size: 14, design: .serif)
                    .foregroundStyle(Carnet.ink)
                    .lineLimit(2)
                Spacer(minLength: 4)
                accessory
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Les semaines.
    @ViewBuilder
    private var weeks: some View {
        let current = BotafogoSite.currentWeek(book.weeks)
        ForEach(Array(book.weeks.enumerated()), id: \.offset) { index, week in
            let parts = (week.children ?? []).filter { BotafogoSite.isSessionPart($0) && $0.url != nil }
            let weekContent = parts.first { $0.type == "weekContent" }?.url
            if !parts.isEmpty {
                let isOpen = openWeeks.contains(index)
                let sections = readings[weekContent ?? ""] ?? []
                disclosure(title: week.name ?? String(localized: "Semaine \(index + 1)"), isOpen: isOpen, accessory: weekAccessory(week, index: index, current: current, sections: sections)) {
                    withAnimation(.snappy(duration: 0.2)) {
                        if isOpen { openWeeks.remove(index) } else { openWeeks.insert(index) }
                    }
                }
                .id("week-\(index)")
                .task(id: weekContent) { if let weekContent { await loadReadings(weekContent) } }
                if isOpen {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(parts.enumerated()), id: \.offset) { _, node in
                            row(icon: CoursePane.botafogoIcon(node.type),
                                title: node.type == "weekContent" ? String(localized: "Programme de la semaine") : node.displayName,
                                detail: BotafogoProgram.date(node.meta("date")).map { $0.formatted(.dateTime.weekday(.wide).day().month(.wide)) },
                                url: node.url ?? "", readingTitle: node.type == "weekContent" ? week.name : node.displayName)
                        }
                        ForEach(sections, id: \.path) { section in
                            row(icon: "text.book.closed", title: section.title, url: section.path)
                        }
                    }
                    .padding(.leading, 12)
                    .padding(.bottom, 6)
                }
            }
        }
    }

    @ViewBuilder
    private func weekAccessory(_ week: BotafogoNode, index: Int, current: Int?, sections: [BotafogoSite.Chapter.Section]) -> some View {
        HStack(spacing: 6) {
            if !sections.isEmpty {
                let done = sections.filter { read.contains($0.path) }.count
                Text("\(done)/\(sections.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(done == sections.count ? tint : Carnet.inkTertiary)
            }
            if index == current {
                Text("Cette semaine")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(tint.opacity(0.14), in: Capsule())
            } else if let date = (week.children ?? []).compactMap({ BotafogoProgram.date($0.meta("date")) }).min() {
                Text(date.formatted(.dateTime.day().month(.abbreviated))).font(.caption2).foregroundStyle(Carnet.inkTertiary)
            }
        }
    }

    // Le polycopié.
    @ViewBuilder
    private var handout: some View {
        ForEach(Array(book.chapters.enumerated()), id: \.offset) { _, chapter in
            let isOpen = openChapters.contains(chapter.title)
            let progress = BotafogoNavigation.progress(chapter, read: read)
            disclosure(title: chapter.title, isOpen: isOpen, accessory: HStack(spacing: 5) {
                ThinRing(fraction: progress.total == 0 ? 0 : Double(progress.read) / Double(progress.total), tint: tint)
                    .frame(width: 12, height: 12)
                Text("\(progress.read)/\(progress.total)").font(.caption2.monospacedDigit()).foregroundStyle(Carnet.inkTertiary)
            }) {
                withAnimation(.snappy(duration: 0.2)) {
                    if isOpen { openChapters.remove(chapter.title) } else { openChapters.insert(chapter.title) }
                }
            }
            if isOpen {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(chapter.sections, id: \.path) { section in
                        row(icon: "text.book.closed", title: section.title, url: section.path)
                    }
                }
                .padding(.leading, 12)
                .padding(.bottom, 6)
            }
        }
    }

    @ViewBuilder
    private var infos: some View {
        ForEach(Array(book.infos.enumerated()), id: \.offset) { _, group in
            Text(MathMarkup.plain(group.name ?? "Infos"))
                .font(Carnet.serif(14, weight: .medium))
                .foregroundStyle(Carnet.ink)
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 2)
            ForEach(Array((group.children ?? []).filter { $0.url != nil }.enumerated()), id: \.offset) { _, node in
                row(icon: "info.circle", title: node.displayName, url: node.url ?? "")
            }
        }
    }

    // La recherche : les titres du polycopié et des semaines.
    @ViewBuilder
    private var searchResults: some View {
        let needle = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let matches = { (text: String) in
            MathMarkup.plain(text).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(needle)
        }
        let sections = BotafogoNavigation.order(book.chapters).filter { matches($0.title) }
        let documents = book.weeks.flatMap { week in
            (week.children ?? []).filter { BotafogoSite.isSessionPart($0) && $0.url != nil && (matches($0.displayName) || matches(week.name ?? "")) }
                .map { (week, $0) }
        }
        if sections.isEmpty && documents.isEmpty {
            Text("Rien ne correspond.").font(.callout).foregroundStyle(Carnet.inkTertiary).padding(12)
        }
        if !sections.isEmpty {
            Kicker("Polycopié").padding(.horizontal, 8).padding(.top, 6)
            ForEach(sections, id: \.path) { section in
                row(icon: "text.book.closed", title: section.title, url: section.path)
            }
        }
        if !documents.isEmpty {
            Kicker("Semaines").padding(.horizontal, 8).padding(.top, 10)
            ForEach(Array(documents.enumerated()), id: \.offset) { _, pair in
                row(icon: CoursePane.botafogoIcon(pair.1.type),
                    title: pair.1.type == "weekContent" ? (pair.0.name ?? pair.1.displayName) : pair.1.displayName,
                    detail: pair.0.name.map(MathMarkup.plain), url: pair.1.url ?? "")
            }
        }
    }
}

// MARK: - Une page

/// Une page du cours : le fil d'Ariane et l'historique en haut, le document,
/// « Sur cette page » à droite (quand la place le permet), précédent et
/// suivant en bas. Arriver au bout de la page la marque lue.
struct BotafogoPageView: View {
    var book: BotafogoBook
    let location: BotafogoLocation
    let tint: Color
    var desk: SiteHub
    let trail: [String]
    let neighbours: (previous: BotafogoLocation?, next: BotafogoLocation?)
    let canGoBack: Bool
    let canGoForward: Bool
    let isRead: Bool
    var goBack: () -> Void
    var goForward: () -> Void
    var open: (BotafogoLocation) -> Void
    var openPoly: (String) -> Void
    var openWeb: (URL, String) -> Void
    var ask: (String) -> Void
    var setRead: (Bool) -> Void
    var accessory: AnyView? = nil

    @State private var blocks: [BotafogoBlock]?
    @State private var tops: [Int: Double] = [:]
    @State private var viewport: CGFloat = 800
    /// Trop étroit pour la colonne « Sur cette page » : un menu en haut.
    @State private var narrow = false
    @State private var jump: Int?
    @State private var remembered: Int?

    private var outline: [BotafogoNavigation.OutlineItem] { blocks.map(BotafogoNavigation.outline) ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(Carnet.rule).frame(height: 1)
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    HStack(spacing: 0) {
                        ScrollView {
                            content
                        }
                        .coordinateSpace(name: "botafogo-page")
                        .onPreferenceChange(BotafogoBlockTops.self) { value in
                            tops = value
                            // La place, pour reprendre ici la prochaine fois.
                            if let current = BotafogoNavigation.current(outline, tops: value), current != remembered {
                                remembered = current
                                ReadingMemory.setBlock(location.url, current == outline.first?.index ? nil : current)
                            }
                            // Le bas de la page est à l'écran : lue.
                            if let end = value[-1], end < viewport, !isRead, blocks?.isEmpty == false { setRead(true) }
                        }
                        #if DEBUG
                        .task(id: blocks?.count) { debugScroll(proxy) }
                        #endif
                        if geometry.size.width >= 1000, outline.count >= 2 {
                            outlineColumn(proxy)
                                .frame(width: 220)
                                .padding(.trailing, 12)
                        }
                    }
                    .onChange(of: jump) { _, target in
                        guard let target else { return }
                        withAnimation(.snappy) { proxy.scrollTo("block-\(target)", anchor: .top) }
                        jump = nil
                    }
                }
                .onAppear { narrow = geometry.size.width < 1000 }
                .onChange(of: geometry.size.width) { _, width in narrow = width < 1000 }
                .onAppear { viewport = geometry.size.height }
                .onChange(of: geometry.size.height) { _, height in viewport = height }
            }
        }
        .botafogoLinks(openPoly: openPoly, openWeb: openWeb)
        .task(id: location.url) {
            blocks = await book.page(location.url) ?? []
            // Reprendre au passage où l'on lisait.
            if let saved = ReadingMemory.block(location.url), blocks?.indices.contains(saved) == true {
                try? await Task.sleep(for: .milliseconds(150))
                jump = saved
            }
        }
    }

    // MARK: En haut

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                Button(action: goBack) { Image(systemName: "chevron.left") }
                    .disabled(!canGoBack)
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Précédent dans l'historique (⌘[)")
                Button(action: goForward) { Image(systemName: "chevron.right") }
                    .disabled(!canGoForward)
                    .keyboardShortcut("]", modifiers: .command)
                    .help("Suivant dans l'historique (⌘])")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Carnet.inkSecondary)
            HStack(spacing: 6) {
                ForEach(Array(trail.enumerated()), id: \.offset) { _, step in
                    Text(step).lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Carnet.inkTertiary)
                }
                MacMathText(location.title, size: 12).foregroundStyle(Carnet.ink).lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(Carnet.inkSecondary)
            Spacer(minLength: 8)
            if narrow, outline.count >= 2 {
                Menu {
                    ForEach(outline, id: \.index) { item in
                        Button { jump = item.index } label: {
                            Label(MathMarkup.plain(item.title), systemImage: Self.icon(item.kind))
                        }
                    }
                } label: {
                    Image(systemName: "list.bullet.indent")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Sur cette page")
            }
            Button { setRead(!isRead) } label: {
                Label(isRead ? "Lu" : "Marquer lu", systemImage: isRead ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isRead ? tint : Carnet.inkSecondary)
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .help("Marqué lu tout seul quand tu arrives en bas de la page")
            if let accessory { accessory }
            Button { ask(String(localized: "J'ai une question sur « \(location.title) » (Botafogo).")) } label: {
                Label("Claude", systemImage: "sparkle")
            }
            .buttonStyle(.paper)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    // MARK: La page

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let kicker = trail.last {
                Kicker(kicker, color: tint)
            }
            MacMathText(location.title, size: 32, design: .serif)
                .foregroundStyle(Carnet.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let blocks {
                if blocks.isEmpty {
                    Text("Rien à lire ici.").foregroundStyle(Carnet.inkSecondary)
                } else {
                    BotafogoBlocksView(blocks: blocks, book: book, desk: desk, openWeb: openWeb, anchored: true,
                                       tracked: Set(outline.map(\.index)))
                    footer
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 22)
        .padding(.bottom, 56)
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 14) {
            Rectangle().fill(Carnet.rule).frame(height: 1).padding(.top, 24)
            HStack(spacing: 12) {
                if let previous = neighbours.previous {
                    neighbourCard(previous, label: "Précédent", leading: true)
                } else {
                    Spacer().frame(maxWidth: .infinity)
                }
                if let next = neighbours.next {
                    neighbourCard(next, label: "Suivant", leading: false)
                } else {
                    Spacer().frame(maxWidth: .infinity)
                }
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: BotafogoBlockTops.self, value: [-1: proxy.frame(in: .named("botafogo-page")).minY])
            }
        }
    }

    private func neighbourCard(_ target: BotafogoLocation, label: LocalizedStringKey, leading: Bool) -> some View {
        Button { open(target) } label: {
            HStack(spacing: 10) {
                if leading { Image(systemName: "arrow.left").foregroundStyle(tint) }
                VStack(alignment: leading ? .leading : .trailing, spacing: 3) {
                    Text(label).font(.caption.weight(.semibold)).foregroundStyle(Carnet.inkTertiary).textCase(.uppercase)
                    MacMathText(target.title, size: 14, design: .serif)
                        .foregroundStyle(Carnet.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(leading ? .leading : .trailing)
                }
                .frame(maxWidth: .infinity, alignment: leading ? .leading : .trailing)
                if !leading { Image(systemName: "arrow.right").foregroundStyle(tint) }
            }
            .padding(14)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Carnet.rule))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(leading ? .leftArrow : .rightArrow, modifiers: [.command, .option])
        .frame(maxWidth: .infinity)
    }

    // MARK: Sur cette page

    private func outlineColumn(_ proxy: ScrollViewProxy) -> some View {
        let current = BotafogoNavigation.current(outline, tops: tops)
        return VStack(alignment: .leading, spacing: 2) {
            Kicker("Sur cette page").padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(outline, id: \.index) { item in
                        let active = item.index == current
                        Button {
                            withAnimation(.snappy) { proxy.scrollTo("block-\(item.index)", anchor: .top) }
                        } label: {
                            HStack(spacing: 7) {
                                RoundedRectangle(cornerRadius: 1).fill(active ? tint : Carnet.rule).frame(width: 2)
                                Image(systemName: Self.icon(item.kind)).font(.system(size: 9)).foregroundStyle(active ? tint : Carnet.inkTertiary)
                                    .frame(width: 12)
                                MacMathText(item.title, size: 12)
                                    .foregroundStyle(active ? Carnet.ink : Carnet.inkSecondary)
                                    .lineLimit(2)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.top, 22)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    static func icon(_ kind: BotafogoNavigation.OutlineItem.Kind) -> String {
        switch kind {
        case .heading: return "number"
        case .statement: return "seal"
        case .example: return "lightbulb"
        case .exercise: return "pencil"
        case .quiz: return "questionmark.circle"
        case .video: return "play.rectangle"
        }
    }

    #if DEBUG
    /// `-botafogoFind <texte>` / `-botafogoFirstQuiz` : défiler pour une capture.
    private func debugScroll(_ proxy: ScrollViewProxy) {
        let arguments = CommandLine.arguments
        let phrase = arguments.firstIndex(of: "-botafogoFind").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        let target: Int?
        if let phrase { target = blocks?.firstIndex { String(describing: $0).contains(phrase) } }
        else if arguments.contains("-botafogoFirstQuiz") { target = blocks?.firstIndex(where: BotafogoDocumentView.holdsQuiz) }
        else { target = nil }
        guard let target else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            proxy.scrollTo("block-\(target)", anchor: .top)
        }
    }
    #endif
}

// MARK: - La semaine

/// Le cours sans page ouverte : la semaine en cours, ce qu'il y a à lire et
/// où reprendre — l'envie d'ouvrir le polycopié, plutôt que « Choisis à gauche ».
struct BotafogoWeekHome: View {
    var book: BotafogoBook
    let tint: Color
    let read: Set<String>
    let readings: [String: [BotafogoSite.Chapter.Section]]
    var open: (BotafogoLocation) -> Void
    var load: (String) async -> Void

    private var index: Int? { BotafogoSite.currentWeek(book.weeks) }
    private var week: BotafogoNode? { index.flatMap { book.weeks.indices.contains($0) ? book.weeks[$0] : nil } }

    var body: some View {
        ScrollView {
            if let week, let index {
                let parts = (week.children ?? []).filter { BotafogoSite.isSessionPart($0) && $0.url != nil }
                let weekContent = parts.first { $0.type == "weekContent" }?.url
                let sections = readings[weekContent ?? ""] ?? []
                let done = sections.filter { read.contains($0.path) }.count
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Kicker("Cette semaine · semaine \(index + 1)", color: tint)
                        MacMathText(week.name ?? "Semaine \(index + 1)", size: 36, design: .serif)
                            .foregroundStyle(Carnet.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        if !sections.isEmpty {
                            HStack(spacing: 10) {
                                GeometryReader { proxy in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Carnet.rule)
                                        Capsule().fill(tint).frame(width: max(6, proxy.size.width * CGFloat(done) / CGFloat(sections.count)))
                                    }
                                }
                                .frame(height: 6)
                                Text("\(done) sur \(sections.count) lues").font(.callout).foregroundStyle(Carnet.inkSecondary).fixedSize()
                            }
                            .padding(.top, 4)
                        }
                    }

                    if let next = BotafogoNavigation.nextUnread(in: sections, read: read) {
                        Button { open(.init(title: next.title, url: next.path)) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(done == 0 ? "Commencer la lecture" : "Continuer la lecture")
                                        .font(.caption.weight(.semibold)).textCase(.uppercase).opacity(0.85)
                                    MacMathText(next.title, size: 19, design: .serif)
                                }
                                Spacer()
                                Image(systemName: "arrow.right").font(.title3.weight(.semibold))
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 16)
                            .foregroundStyle(Carnet.ground)
                            .background(tint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else if !sections.isEmpty {
                        Label("Tout est lu pour cette semaine.", systemImage: "checkmark.seal")
                            .font(Carnet.serif(18)).foregroundStyle(Carnet.correct)
                    }

                    // La séance, le programme.
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(parts.enumerated()), id: \.offset) { _, node in
                            let title = node.type == "weekContent" ? String(localized: "Programme de la semaine") : node.displayName
                            card(icon: CoursePane.botafogoIcon(node.type), title: title,
                                 detail: BotafogoProgram.date(node.meta("date")).map { $0.formatted(.dateTime.weekday(.wide).day().month(.wide)) }) {
                                open(.init(title: node.type == "weekContent" ? (week.name ?? title) : title, url: node.url ?? ""))
                            }
                        }
                    }

                    if !sections.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Kicker("À lire dans le polycopié")
                            ForEach(sections, id: \.path) { section in
                                Button { open(.init(title: section.title, url: section.path)) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: read.contains(section.path) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(read.contains(section.path) ? tint : Carnet.inkTertiary)
                                        MacMathText(section.title, size: 15).foregroundStyle(Carnet.ink)
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Carnet.inkTertiary)
                                    }
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 12)
                                    .background(Carnet.sheet.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if book.weeks.indices.contains(index + 1), let upcoming = book.weeks[index + 1].name {
                        HStack(spacing: 6) {
                            Text("La semaine prochaine :").foregroundStyle(Carnet.inkTertiary)
                            MacMathText(upcoming, size: 13).foregroundStyle(Carnet.inkSecondary)
                        }
                        .font(.callout)
                    }
                }
                .padding(40)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
                .task(id: weekContent) { if let weekContent { await load(weekContent) } }
            } else if book.ready {
                ContentUnavailableView("Le cours", systemImage: "books.vertical", description: Text("Choisis une page à gauche."))
                    .padding(.top, 80)
            } else {
                ProgressView().padding(.top, 120).frame(maxWidth: .infinity)
            }
        }
    }

    private func card(icon: String, title: String, detail: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title3).foregroundStyle(tint).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    MacMathText(title, size: 16, design: .serif).foregroundStyle(Carnet.ink)
                    if let detail { Text(detail).font(.caption).foregroundStyle(Carnet.inkSecondary) }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Carnet.inkTertiary)
            }
            .padding(14)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Carnet.rule))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
