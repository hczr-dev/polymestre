import SwiftUI
import SwiftData

/// La barre du bas, **en deux** : les quatre onglets dans une capsule de verre,
/// et le chrono à part, dans un rond.
///
/// La barre système mettait le chrono au milieu des onglets, et le mini-lecteur
/// restait posé au-dessus même quand rien ne tournait — il proposait « la
/// prochaine chose à faire », qu'on connaît déjà, et masquait le bas de chaque
/// écran. Désormais :
///   • **au repos**, le rond montre un chrono ; le toucher ouvre Focus ;
///   • **pendant une session**, le rond devient un petit cadran qui avance, et
///     le mini-lecteur (temps, pause, terminer) apparaît au-dessus de la barre.
struct CarnetTabBar: View {
    @Environment(AppContainer.self) private var app
    @Namespace private var glass

    static let tabs: [AppRouter.Tab] = [.today, .courses, .groups]

    var body: some View {
        VStack(spacing: 8) {
            if app.focus.hasSession {
                FocusMiniPlayer()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: 10) {
                tabCapsule
                ChronoDot()
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .animation(Motion.snappy, value: app.focus.hasSession)
    }

    private var tabCapsule: some View {
        HStack(spacing: 0) {
            ForEach(Self.tabs, id: \.self) { tab in
                tabButton(tab)
            }
        }
        .padding(4)
        .carnetGlass(in: Capsule(), interactive: true)
    }

    private func tabButton(_ tab: AppRouter.Tab) -> some View {
        let selected = app.router.selectedTab == tab
        return Button {
            app.router.selectedTab = tab
            Haptics.soft()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: tab.icon)
                    .font(.system(size: 18, weight: selected ? .semibold : .regular))
                    .symbolVariant(selected ? .fill : .none)
                    .frame(height: 22)
                Text(tab.title)
                    .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? Carnet.ink : Carnet.inkSecondary)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background {
                if selected {
                    Capsule().fill(Carnet.ink.opacity(0.09))
                        .matchedGeometryEffect(id: "selection", in: glass)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.96))
        .animation(Motion.snappy, value: selected)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Le rond du chrono, à droite de la barre.
///
/// Au repos, un chrono ; pendant une session, l'anneau avance (d'un tour par
/// heure en chrono libre, d'un tour par bloc en Pomodoro) autour d'un point à
/// la couleur du cours — ambre en pause, turquoise pendant une pause Pomodoro.
struct ChronoDot: View {
    @Environment(AppContainer.self) private var app
    @Query(sort: \Course.code) private var courses: [Course]

    private var focus: FocusController { app.focus }

    var body: some View {
        Button {
            app.router.openFocus()
            Haptics.tap()
        } label: {
            ZStack {
                if focus.hasSession, let state = focus.state {
                    TimelineView(.periodic(from: FocusTimerState.tickAnchor(state), by: 1)) { context in
                        running(state: state, now: context.date)
                    }
                } else {
                    Image(systemName: "timer")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(Carnet.ink)
                }
            }
            .frame(width: 58, height: 58)
            .carnetGlass(in: Circle(), interactive: true)
            .contentShape(Circle())
        }
        .buttonStyle(PressableStyle(scale: 0.94))
        .accessibilityLabel(focus.hasSession ? "Chrono en cours, ouvrir" : "Ouvrir le chrono")
    }

    private func running(state: FocusTimerState, now: Date) -> some View {
        let phase = focus.phase(at: now)
        let course = courses.first { $0.id == state.courseID }
        let tint: Color = {
            if phase.isBreak { return Color.teal }
            if phase == .paused { return Carnet.review }
            return course.map { Carnet.tint($0.colorHex) } ?? Carnet.ink
        }()
        let progress: Double = {
            if case .onBreak(_, let start, let end) = phase {
                let total = max(1, end.timeIntervalSince(start))
                return max(0, end.timeIntervalSince(now)) / total
            }
            if focus.isPomodoro { return focus.pomodoroStatus(at: now).progress }
            return state.elapsed(at: now).truncatingRemainder(dividingBy: 3600) / 3600
        }()
        return ZStack {
            Circle().stroke(Carnet.rule, lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(TimerText.compact(state.elapsed(at: now)))
                .font(Carnet.mono(.caption2, weight: .semibold))
                .foregroundStyle(Carnet.ink)
                .minimumScaleFactor(0.7)
        }
        .padding(9)
    }
}

/// Le mini-lecteur, **seulement pendant une session** : sur quoi, où on en est,
/// pause et terminer. Le toucher ouvre Focus.
struct FocusMiniPlayer: View {
    /// Dans l'accessoire de la barre système : pas de verre à nous, et une forme
    /// réduite quand la barre se replie.
    var inAccessory = false
    @Environment(AppContainer.self) private var app
    @State private var isInline = false
    @Query(sort: \Course.code) private var courses: [Course]

    private var focus: FocusController { app.focus }

    var body: some View {
        if let state = focus.state {
            let course = courses.first { $0.id == state.courseID }
            let tint = course.map { Carnet.tint($0.colorHex) } ?? Carnet.ink
            TimelineView(.periodic(from: FocusTimerState.tickAnchor(state), by: 1)) { context in
                let phase = focus.phase(at: context.date)
                HStack(spacing: 10) {
                    Button {
                        app.router.openFocus()
                    } label: {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(phase.isBreak ? Color.teal : tint)
                                .frame(width: 4, height: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(title(state, course: course))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Carnet.ink)
                                    .lineLimit(1)
                                Text(statusText(phase))
                                    .font(.caption)
                                    .foregroundStyle(phase == .paused ? Carnet.review : Carnet.inkSecondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Text(clock(phase: phase, state: state, now: context.date))
                                .font(Carnet.mono(.body, weight: .medium))
                                .foregroundStyle(Carnet.ink)
                                .contentTransition(.numericText())
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title(state, course: course)), \(statusText(phase)). Ouvrir le chrono")

                    primaryButton(phase: phase)

                    if !isInline, !focus.isLocked {
                    Button {
                        focus.finish()
                        Haptics.success()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Carnet.ink)
                            .frame(width: inAccessory ? 34 : 40, height: inAccessory ? 34 : 40)
                            .background(Carnet.ink.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Terminer et enregistrer la session")
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 8)
                .padding(.vertical, inAccessory ? 0 : 8)
                .modifier(PlayerGlass(enabled: !inAccessory))
                .modifier(AccessoryPlacementReader(isInline: $isInline))
            }
        }
    }

    @ViewBuilder
    private func primaryButton(phase: FocusPhase) -> some View {
        let (icon, label): (String, String) = {
            switch phase {
            case .working: return ("pause.fill", String(localized: "Mettre en pause"))
            case .onBreak: return ("forward.fill", String(localized: "Terminer la pause"))
            default: return ("play.fill", String(localized: "Reprendre"))
            }
        }()
        Button {
            switch phase {
            case .working: focus.pause()
            case .onBreak: focus.skipBreak()
            default: focus.resume()
            }
            Haptics.tap()
        } label: {
            Image(systemName: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Carnet.ground)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: inAccessory ? 34 : 40, height: inAccessory ? 34 : 40)
                .background(Carnet.ink, in: Circle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }

    private func statusText(_ phase: FocusPhase) -> String {
        switch phase {
        case .working: return focus.isPomodoro ? String(localized: "Bloc \(focus.pomodoroStatus().blockNumber) en cours") : String(localized: "En cours")
        case .paused: return String(localized: "En pause")
        case .onBreak(let kind, _, _): return kind.label
        case .readyForBlock(let block): return String(localized: "Bloc \(block) prêt")
        case .idle: return String(localized: "Prêt")
        }
    }

    /// Le temps travaillé — ou, pendant une pause, ce qu'il en reste ; en
    /// Pomodoro, ce qu'il reste du bloc.
    private func clock(phase: FocusPhase, state: FocusTimerState, now: Date) -> String {
        if case .onBreak(_, _, let end) = phase {
            return TimerText.clock(max(0, end.timeIntervalSince(now)).rounded(.up))
        }
        if focus.isPomodoro, phase == .working || phase == .paused {
            return TimerText.clock(focus.pomodoroStatus(at: now).remaining.rounded(.up))
        }
        return TimerText.clock(state.elapsed(at: now))
    }

    private func title(_ state: FocusTimerState, course: Course?) -> String {
        FocusLabels.title(state: state, course: course)
    }
}

/// Le mini-lecteur en accessoire de la barre système : présent **seulement**
/// pendant une session. Le verre est celui de la barre, pas le nôtre.
@available(iOS 26.0, *)
struct FocusAccessory: ViewModifier {
    @Environment(AppContainer.self) private var app

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: app.focus.hasSession && app.router.selectedTab != .focus) {
                FocusMiniPlayer(inAccessory: true)
            }
        } else {
            content.tabViewBottomAccessory {
                if app.focus.hasSession, app.router.selectedTab != .focus { FocusMiniPlayer(inAccessory: true) }
            }
        }
    }
}

/// Lit si l'accessoire est « en ligne » (barre repliée) : le lecteur s'y réduit.
private struct AccessoryPlacementReader: ViewModifier {
    @Binding var isInline: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.modifier(Reader26(isInline: $isInline))
        } else {
            content
        }
    }

    @available(iOS 26.0, *)
    private struct Reader26: ViewModifier {
        @Binding var isInline: Bool
        @Environment(\.tabViewBottomAccessoryPlacement) private var placement

        func body(content: Content) -> some View {
            content
                .onAppear { isInline = placement == .inline }
                .onChange(of: placement) { _, value in isInline = value == .inline }
        }
    }
}

private struct PlayerGlass: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.carnetGlass(in: Capsule(), interactive: true) } else { content }
    }
}

/// Ce que dit une session, partout où elle s'affiche : « CS-250 · Exercice 2.1 ».
@MainActor
enum FocusLabels {
    static func title(state: FocusTimerState, course: Course?) -> String {
        if !state.contextLabel.isEmpty { return MathMarkup.plain(state.contextLabel) }
        let target = FocusController.target(of: state, in: course)
        let what: String = {
            if let exercise = target.exercise { return exercise.displayNumber }
            if let item = target.theoryItem { return MathMarkup.plain(item.title.isEmpty ? item.displayNumber : item.title) }
            return state.taskType.label
        }()
        return [course?.displayCode ?? String(localized: "Session libre"), what].joined(separator: " · ")
    }
}

/// Place la barre du bas sous chaque onglet : la barre système est masquée, le
/// contenu défile au-dessus de la nôtre sans passer dessous.
struct CarnetTabBarInset: ViewModifier {
    @State private var keyboardShown = false

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !keyboardShown {
                    CarnetTabBar()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardShown = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardShown = false
            }
    }
}
