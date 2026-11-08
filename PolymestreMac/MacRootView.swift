import SwiftUI
import CoreSpotlight
import SwiftData

/// La fenêtre : à gauche Aujourd'hui, le Chrono, l'Agenda, le Bilan et les
/// cours ; à droite la page, sur papier. ⌘K (ou ⌘F) ouvre la palette :
/// chercher, ouvrir, chronométrer. ⇧⌘E entre en mode étude.
struct MacRootView: View {
    enum Page: Hashable {
        case today, focus, agenda, stats, groups, claude
        case course(UUID)
    }

    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \Course.code) private var courses: [Course]
    @SceneStorage("mac.page") private var storedPage: String = "today"
    @State private var page: Page? = .today
    @State private var showingPalette = false
    @State private var addingCourse = false
    @State private var quickNote = false
    /// L'exercice ou l'élément de théorie à montrer à l'ouverture d'un cours
    /// (un résultat de recherche, une ligne « À faire »).
    @State private var focusTarget: UUID?

    private var tracked: [Course] { courses.filter(\.isTracked) }

    static let selection = Color.paper(light: "#6B5F4E", dark: "#463E31")

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Section {
                    SidebarLabel(title: "Aujourd'hui", icon: "sun.max").tag(Page.today)
                    Label {
                        HStack {
                            Text("Chrono")
                            Spacer()
                            if timer.phase != .idle {
                                TimerClockText(font: .caption.monospacedDigit())
                            }
                        }
                    } icon: {
                        Image(systemName: "timer").foregroundStyle(Carnet.inkSecondary)
                    }
                    .tag(Page.focus)
                    SidebarLabel(title: "Agenda", icon: "calendar").tag(Page.agenda)
                    SidebarLabel(title: "Bilan", icon: "chart.bar.xaxis").tag(Page.stats)
                    SidebarLabel(title: "Groupes", icon: "person.2").tag(Page.groups)
                    // La conversation « EPFL » (brief, semaine, revue…), quand le
                    // projet Claude a des commandes pour le système.
                    if settings.claudeProject {
                        SidebarLabel(title: "Claude", icon: "sparkle").tag(Page.claude)
                    }
                }
                Section {
                    ForEach(tracked) { course in
                        CourseSidebarRow(course: course, isTimed: timer.phase != .idle && timer.courseID == course.id)
                            .tag(Page.course(course.id))
                            .contextMenu {
                                Button("Chronométrer") { time(course) }
                                Button("Mode étude…") { StudyModeController.shared.presentSetup(courseID: course.id) }
                                Button("Ouvrir") { page = .course(course.id) }
                                Divider()
                                Button("Archiver") {
                                    course.isTracked = false
                                    if page == .course(course.id) { page = .today }
                                }
                            }
                    }
                } header: {
                    HStack {
                        Text("Cours")
                        Spacer()
                        Button { addingCourse = true } label: { Image(systemName: "plus") }
                            .buttonStyle(.plain)
                            .help("Ajouter un cours")
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    StudyModeSidebarButton()
                    SyncFooter()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        } detail: {
            Group {
                switch page ?? .today {
                // Les tableaux de bord se recalculent à chaque enregistrement (et à
                // chaque synchronisation iCloud) : rien tant que la fenêtre est
                // cachée — derrière le mode étude, réduite, sur un autre bureau.
                case .today:
                    MacTodayView(open: open, goFocus: { page = .focus }).pausedWhenHidden()
                case .focus:
                    MacFocusView()
                case .agenda:
                    MacAgendaView(open: open).pausedWhenHidden()
                case .stats:
                    MacStatsView().pausedWhenHidden()
                case .groups:
                    MacGroupsView().background(Carnet.ground)
                case .claude:
                    ClaudePane(course: nil, courses: courses, desk: StudyModeController.shared.desk, onlySystem: true)
                        .background(Carnet.ground)
                case .course(let id):
                    if let course = courses.first(where: { $0.id == id }) {
                        MacCourseView(course: course, focusTarget: $focusTarget)
                            .id(course.id)
                    } else {
                        ContentUnavailableView("Cours introuvable", systemImage: "books.vertical")
                    }
                }
            }
            .paperPage()
            // L'encre pour la page ; la barre latérale garde la teinte de sélection.
            .tint(Carnet.ink)
            // Sans cours, seule la page change : la barre latérale (chrono,
            // agenda, bilan, réglages) reste utilisable.
            .overlay {
                if tracked.isEmpty, page == .today || page == nil {
                    ContentUnavailableView {
                        Label("Pas encore de cours", systemImage: "icloud.and.arrow.down")
                    } description: {
                        Text("Importe-les sur ton iPhone : ils arrivent ici par iCloud. Le chrono marche déjà.")
                    }
                    .background(Carnet.ground)
                }
            }
            // Le chrono et le mode étude sont déjà dans la barre latérale : la
            // barre d'outils ne garde que la recherche.
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingPalette = true } label: {
                        Label("Rechercher", systemImage: "magnifyingglass")
                    }
                    .help("Chercher (⌘K)")
                }
            }
            // Pas de bande propre à la barre d'outils : chaque colonne monte
            // jusqu'en haut avec son fond (une bande grise, puis noire, coupait
            // la fenêtre en deux couleurs).
            .toolbarBackground(.hidden, for: .windowToolbar)
        }
        // La sélection de la barre latérale prend cette teinte, avec un texte
        // blanc : un brun sombre, et non la crème de l'encre (illisible).
        .tint(Self.selection)
        .overlay {
            if showingPalette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.12)
                        .ignoresSafeArea()
                        .onTapGesture { showingPalette = false }
                    CommandPalette(navigate: navigate, dismiss: { showingPalette = false })
                        .tint(Carnet.ink)
                        .padding(.top, 70)
                        .transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(duration: 0.22, bounce: 0.1), value: showingPalette)
        .sheet(isPresented: $quickNote) {
            QuickNoteSheet(preferredCourseID: currentCourseID).tint(Carnet.ink)
        }
        .onReceive(NotificationCenter.default.publisher(for: .macQuickNote)) { _ in quickNote = true }
        // Un résultat Spotlight : le cours, et l'exercice ou la théorie visés.
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                  let destination = SpotlightIndexer.destination(of: identifier) else { return }
            open(destination.courseID, destination.targetID)
        }
        .sheet(isPresented: $addingCourse) {
            CourseFormView(course: nil, defaultSectionCode: settings.shared.sectionCode).tint(Carnet.ink)
        }
        .onReceive(NotificationCenter.default.publisher(for: .macFocusSearch)) { _ in showingPalette = true }
        .onReceive(NotificationCenter.default.publisher(for: .macGoTo)) { note in
            guard let raw = note.object as? String else { return }
            if raw.hasPrefix("code:"), let course = tracked.first(where: { $0.displayCode == raw.dropFirst(5) }) {
                page = .course(course.id)
            } else {
                page = Self.decode(raw)
            }
        }
        .onAppear {
            page = Self.decode(storedPage)
            NSApp.setActivationPolicy(.regular)
            #if DEBUG
            if CommandLine.arguments.contains("-debugPanel") { openWindow(id: "debugPanel") }
            #endif
        }
        .onDisappear {
            // Fenêtre fermée : Polymestre vit dans la barre des menus.
            if !settings.keepInDock { NSApp.setActivationPolicy(.accessory) }
        }
        .onChange(of: page) { _, value in storedPage = Self.encode(value) }
    }

    /// Le cours affiché, sinon celui du chrono : la note rapide le propose.
    private var currentCourseID: UUID? {
        if case .course(let id)? = page { return id }
        return timer.courseID
    }

    private func open(_ courseID: UUID, _ target: UUID?) {
        focusTarget = target
        page = .course(courseID)
    }

    private func navigate(_ destination: CommandPalette.Destination) {
        switch destination {
        case .page(let value): page = value
        case .target(let course, let item): open(course, item)
        }
    }

    private func time(_ course: Course) {
        if timer.phase == .idle {
            timer.start(courseID: course.id, taskType: .exercise)
        } else {
            timer.retarget(courseID: course.id, taskType: timer.taskType)
        }
    }

    static func encode(_ page: Page?) -> String {
        switch page {
        case .stats?: return "stats"
        case .focus?: return "focus"
        case .agenda?: return "agenda"
        case .groups?: return "groups"
        case .claude?: return "claude"
        case .course(let id)?: return id.uuidString
        default: return "today"
        }
    }

    static func decode(_ raw: String) -> Page {
        if raw == "stats" { return .stats }
        if raw == "focus" { return .focus }
        if raw == "agenda" { return .agenda }
        if raw == "groups" { return .groups }
        if raw == "claude" { return .claude }
        if let id = UUID(uuidString: raw) { return .course(id) }
        return .today
    }
}

/// Une ligne de la barre latérale : l'icône dans l'encre du carnet — sans
/// couleur explicite, macOS la peint du bleu du système.
private struct SidebarLabel: View {
    let title: LocalizedStringKey
    let icon: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: icon).foregroundStyle(Carnet.inkSecondary)
        }
    }
}

/// Au pied de la barre latérale : entrer en mode étude (ou y revenir).
private struct StudyModeSidebarButton: View {
    @Environment(MacTimer.self) private var timer

    var body: some View {
        Button {
            StudyModeController.shared.presentSetup()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "moon.stars.fill")
                Text(timer.isStudying ? "Revenir au mode étude" : "Mode étude")
                Spacer(minLength: 0)
                Text("⇧⌘E").font(.caption).foregroundStyle(Carnet.ground.opacity(0.6))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(InkButtonStyle())
        .help("Mode étude")
    }
}

private struct CourseSidebarRow: View {
    let course: Course
    var isTimed = false

    var body: some View {
        let progress = ProgressEngine.progress(for: course)
        let late = ProgressEngine.lateCount(for: course)
        let tint = Carnet.tint(course.colorHex)
        HStack(spacing: 8) {
            ProgressRingMini(value: progress.completion, tint: tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(course.displayCode).font(.callout.weight(.semibold))
                Text(course.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if isTimed {
                // Statique : un symbole qui pulse en continu redessine la barre
                // latérale à chaque image, pendant toute la session.
                Image(systemName: "timer")
                    .font(.caption)
                    .foregroundStyle(tint)
                    .help("En cours")
            }
            if late > 0 {
                Text("\(late)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Carnet.wrong.opacity(0.14), in: Capsule())
                    .foregroundStyle(Carnet.wrong)
                    .help("\(late) en retard")
            }
        }
        .padding(.vertical, 2)
    }
}

struct ProgressRingMini: View {
    let value: Double
    let tint: Color
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle().stroke(Carnet.rule, lineWidth: lineWidth)
            Circle().trim(from: 0, to: value).stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 18, height: 18)
        .help("\(Int((value * 100).rounded())) %")
    }
}

/// L'état d'iCloud, en une ligne au pied de la barre latérale.
struct SyncFooter: View {
    @Environment(MacStore.self) private var store

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Label(store.storeError ?? Self.describe(store.syncState, synced: store.isCloudSynced, now: context.date),
                  systemImage: icon)
                .font(.caption)
                .foregroundStyle(isFailure ? AnyShapeStyle(Carnet.wrong) : AnyShapeStyle(.secondary))
                .lineLimit(3)
        }
    }

    private var isFailure: Bool {
        if store.storeError != nil { return true }
        if case .failed = store.syncState { return true }
        return false
    }

    private var icon: String {
        guard store.isCloudSynced else { return "icloud.slash" }
        switch store.syncState {
        case .working: return "arrow.triangle.2.circlepath.icloud"
        case .failed: return "exclamationmark.icloud"
        default: return "checkmark.icloud"
        }
    }

    static func describe(_ state: MacStore.SyncState, synced: Bool, now: Date) -> String {
        guard synced else { return String(localized: "iCloud coupé") }
        switch state {
        case .idle: return "iCloud"
        case .working(let kind): return "iCloud : \(kind)…"
        case .failed(let message): return "iCloud : \(message)"
        case .synced(let date):
            let ago = now.timeIntervalSince(date)
            if ago < 60 { return String(localized: "Synchronisé à l'instant") }
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = DateUtils.appLocale
            return String(localized: "Synchronisé \(formatter.localizedString(for: date, relativeTo: now))")
        }
    }
}

// MARK: - Fenêtre cachée

extension View {
    /// Rien n'est dessiné ni recalculé tant que la fenêtre n'est pas à l'écran ;
    /// la vue revient telle quelle quand elle y revient.
    func pausedWhenHidden() -> some View { modifier(PausedWhenHidden()) }
}

private struct PausedWhenHidden: ViewModifier {
    @State private var visible = true

    func body(content: Content) -> some View {
        Group {
            if visible { content } else { Color.clear }
        }
        .background(WindowVisibilityReader(visible: $visible))
    }
}

/// L'état d'occultation de la fenêtre qui l'accueille (AppKit le tient à jour).
private struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.changed = { visible = $0 }
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.changed = { visible = $0 }
    }

    final class ReaderView: NSView {
        var changed: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                              object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        private func report() {
            guard let window else { return }
            let visible = window.occlusionState.contains(.visible)
            DispatchQueue.main.async { [changed] in changed?(visible) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
