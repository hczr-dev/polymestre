import SwiftUI
import EventKit

/// L'accueil par la connexion EPFL. Chaque écran montre **ce qui se passe
/// vraiment**, avec les vraies données de l'étudiant·e :
///
///   1. **Bienvenue** — une page Moodle s'ouvre, ses fichiers se retournent et
///      se rangent dans leur semaine : ce que l'app va faire, en huit secondes ;
///   2. **Tes cours** — ceux trouvés dans les inscriptions Moodle, à décocher ;
///   3. **L'import** — cours par cours : le plan lu (les vrais noms des
///      activités), chaque fichier ouvert et ce qu'il cachait, l'analyse, puis
///      chaque élément posé dans sa semaine ;
///   4. **Ton semestre** — toutes les semaines, à parcourir du doigt ;
///   5. **Tes to-do** — chacune d'un toucher.
struct OnboardingFlow: View {
    @Bindable var setup: OnboardingAutoSetup
    /// Lance l'import (une fois Moodle connecté).
    var start: () -> Void
    /// Le parcours sans Moodle (section et cours à la main).
    var goManual: () -> Void
    var finish: () -> Void

    enum Screen: Int { case welcome, courses, importing, semester, timetable, connections }

    @State private var screen: Screen = .welcome
    @State private var showingLogin = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Group {
                switch screen {
                case .welcome:
                    WelcomeScreen(connect: { showingLogin = true }, goManual: goManual)
                case .courses:
                    CoursesScreen(setup: setup, retry: { showingLogin = true }, goManual: goManual) {
                        advance(to: .importing)
                    }
                case .importing:
                    ImportScreen(setup: setup, retry: { showingLogin = true }, goManual: goManual) {
                        advance(to: .semester)
                    }
                case .semester:
                    SemesterScreen(setup: setup) { advance(to: .timetable) }
                case .timetable:
                    TimetableStepScreen { advance(to: .connections) }
                case .connections:
                    ConnectionsScreen(setup: setup, proceed: finish)
                }
            }
            .transition(reduceMotion ? .opacity : .asymmetric(
                insertion: .offset(x: 40).combined(with: .opacity),
                removal: .offset(x: -40).combined(with: .opacity)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { PaperAtmosphere(colors: atmosphere) }
        #if DEBUG
        .task {
            guard let demo = PreviewLaunch.int(PreviewLaunch.onboardingDemoFlag), demo > 0 else { return }
            screen = .courses
            let run = Task { await setup.runDemo(fast: demo > 1) }
            if demo == 1 {
                try? await Task.sleep(for: .seconds(7))
                screen = .importing
                return
            }
            await run.value
            screen = demo >= 3 ? .connections : .semester
        }
        #endif
        .sheet(isPresented: $showingLogin, onDismiss: {
            // Connexion faite (ou abandonnée) : l'import dit lui-même ce qu'il en est.
            if !setup.isWorking, setup.phase != .done {
                advance(to: .courses)
                start()
            }
        }) {
            ConnectionSheetContent(sheet: .moodle)
        }
    }

    /// Les lueurs du fond prennent la couleur du cours en cours, puis de tous.
    private var atmosphere: [Color] {
        if screen == .importing, let current = setup.feed.current {
            return [Carnet.tint(current.colorHex), Carnet.tint(current.colorHex)]
        }
        return setup.cards.map { Carnet.tint($0.colorHex) }
    }

    private func advance(to next: Screen) {
        Haptics.tap()
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.5)) { screen = next }
    }
}

// MARK: - Atmosphère

/// Le papier, éclairé : deux lueurs très douces qui dérivent lentement, aux
/// couleurs des cours dès qu'on les connaît.
struct PaperAtmosphere: View {
    var colors: [Color]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let first = colors.first ?? Carnet.review
            let second = colors.dropFirst().first ?? Carnet.correct
            // Des disques flous plutôt que des dégradés radiaux : un dégradé
            // décalé laisse voir le bord de son cadre.
            Carnet.ground.overlay {
                Circle().fill(first.opacity(0.22))
                    .frame(width: 420, height: 420)
                    .blur(radius: 110)
                    .offset(x: -110 + 40 * sin(t * 0.12), y: -280 + 30 * cos(t * 0.1))
                Circle().fill(second.opacity(0.16))
                    .frame(width: 460, height: 460)
                    .blur(radius: 120)
                    .offset(x: 140 + 40 * cos(t * 0.09), y: 320 + 40 * sin(t * 0.11))
            }
            .clipped()
            .animation(.smooth(duration: 1.2), value: colors.count)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - 1. Bienvenue

private struct WelcomeScreen: View {
    var connect: () -> Void
    var goManual: () -> Void

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            MoodleExplainer()
                .frame(maxWidth: 360)
                .frame(height: 420)
                .opacity(appeared ? 1 : 0)
                .animation(.smooth(duration: 0.8), value: appeared)
            Spacer(minLength: 16)
            VStack(alignment: .leading, spacing: 10) {
                Text("Polymestre")
                    .font(Carnet.serif(.largeTitle, weight: .semibold))
                    .foregroundStyle(Carnet.ink)
                Text("Connecte ton compte EPFL : l'app lit tes cours Moodle et range chaque série, vidéo et échéance dans sa semaine.")
                    .font(.body)
                    .foregroundStyle(Carnet.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .rise(appeared, delay: 0.3)
            Spacer(minLength: 24)
            VStack(spacing: 12) {
                Button(action: connect) {
                    Label("Se connecter avec EPFL", systemImage: "person.badge.key.fill")
                }
                .buttonStyle(.carnetPrimaryWide)
                Text("Ton mot de passe se tape sur la page de l'EPFL, pas dans l'app.")
                    .font(.caption)
                    .foregroundStyle(Carnet.inkTertiary)
                    .multilineTextAlignment(.center)
                Button("Je n'utilise pas Moodle", action: goManual)
                    .font(.subheadline)
                    .foregroundStyle(Carnet.inkSecondary)
                    .frame(minHeight: 40)
            }
            .rise(appeared, delay: 0.45)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
        .frame(maxWidth: Layout.readableWidth)
        .frame(maxWidth: .infinity)
        .onAppear { appeared = true }
    }
}

// MARK: - 2. Tes cours

/// Les cours trouvés dans les inscriptions Moodle, qui arrivent en cascade.
/// L'import a déjà commencé derrière : décocher un cours le retire avant qu'il
/// soit lu.
private struct CoursesScreen: View {
    @Bindable var setup: OnboardingAutoSetup
    var retry: () -> Void
    var goManual: () -> Void
    var proceed: () -> Void

    @State private var unchecked: Set<String> = []
    @State private var shown = 0

    private var failure: String? {
        if case .failed(let message) = setup.phase { return message }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(setup.cards.isEmpty ? "Connexion à Moodle" : "Tes cours ce semestre")
                    .font(Carnet.serif(.largeTitle, weight: .semibold))
                    .foregroundStyle(Carnet.ink)
                    .contentTransition(.opacity)
                Text(setup.cards.isEmpty ? "Lecture de tes inscriptions…" : "Trouvés dans tes inscriptions Moodle. Décoche ceux que tu ne suis pas.")
                    .font(.subheadline)
                    .foregroundStyle(Carnet.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            .padding(.top, 28)
            .animation(.smooth, value: setup.cards.isEmpty)

            if let failure {
                failureCard(failure).padding(.top, 28)
                Spacer()
            } else if setup.cards.isEmpty {
                Spacer()
                ProgressView().controlSize(.large).frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Array(setup.cards.enumerated()), id: \.element.id) { index, card in
                            row(card)
                                .rotation3DEffect(.degrees(index < shown ? 0 : -75), axis: (x: 1, y: 0, z: 0),
                                                  anchor: .top, perspective: 0.6)
                                .opacity(index < shown ? 1 : 0)
                                .offset(y: index < shown ? 0 : 30)
                        }
                    }
                    .padding(.vertical, 24)
                }
                .scrollIndicators(.hidden)
                Button(action: start) {
                    Label(importLabel, systemImage: "arrow.down.doc.fill")
                }
                .buttonStyle(.carnetPrimaryWide)
                .disabled(kept == 0)
                .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: Layout.readableWidth)
        .frame(maxWidth: .infinity)
        .task(id: setup.cards.count) {
            // En cascade : chaque carte bascule vers l'avant, l'une après l'autre.
            while shown < setup.cards.count {
                try? await Task.sleep(for: .seconds(0.09))
                withAnimation(.spring(duration: 0.6, bounce: 0.28)) { shown += 1 }
                Haptics.soft()
            }
        }
    }

    private var kept: Int { setup.cards.count - unchecked.count }
    private var importLabel: String { kept == 1 ? String(localized: "Importer 1 cours") : String(localized: "Importer \(kept) cours") }

    private func row(_ card: OnboardingAutoSetup.CourseCard) -> some View {
        let on = !unchecked.contains(card.id)
        let tint = Carnet.tint(card.colorHex)
        return Button {
            Haptics.tap()
            withAnimation(.snappy(duration: 0.25)) {
                if on { unchecked.insert(card.id) } else { unchecked.remove(card.id) }
            }
        } label: {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(tint)
                    .frame(width: 6, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.code).font(.caption.weight(.bold)).foregroundStyle(tint.accessibleInk)
                    Text(card.name).font(.body.weight(.medium)).foregroundStyle(Carnet.ink)
                        .lineLimit(2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(on ? tint : Carnet.inkTertiary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(14)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .opacity(on ? 1 : 0.55)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .accessibilityLabel("\(card.code), \(card.name)")
        .accessibilityValue(on ? "importé" : "ignoré")
    }

    private func start() {
        for id in unchecked { setup.skip(id) }
        for card in setup.cards where !unchecked.contains(card.id) { setup.keep(card.id) }
        proceed()
    }

    private func failureCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(Carnet.ink)
                .fixedSize(horizontal: false, vertical: true)
            Button("Réessayer la connexion", action: retry)
                .buttonStyle(.carnetPrimaryWide)
            Button("Continuer sans Moodle", action: goManual)
                .buttonStyle(.carnetSecondaryWide)
        }
        .padding(18)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

// MARK: - 5. Tes to-do

private struct ConnectionsScreen: View {
    @Bindable var setup: OnboardingAutoSetup
    var proceed: () -> Void

    @Environment(AppContainer.self) private var app
    @State private var appeared = false
    @State private var working: TaskProvider?
    @State private var message: String?
    @State private var sheet: ConnectionSheet?
    @State private var showingTasks = false
    @State private var calendarGranted = false
    @State private var refresh = 0

    private static let providers: [TaskProvider] = [.reminders, .todoist, .googleTasks, .notion, .tickTick, .things]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tes to-do")
                        .font(Carnet.serif(.largeTitle, weight: .semibold))
                        .foregroundStyle(Carnet.ink)
                    Text("Elles apparaissent dans ton agenda. Facultatif.")
                        .font(.subheadline)
                        .foregroundStyle(Carnet.inkSecondary)
                }
                .rise(appeared, delay: 0.05)

                VStack(alignment: .leading, spacing: 10) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10),
                                        GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(Self.providers) { provider in
                            providerTile(provider)
                        }
                    }
                    if let message {
                        Text(message).font(.footnote).foregroundStyle(Carnet.inkSecondary)
                            .transition(.opacity)
                    }
                }
                .rise(appeared, delay: 0.12)

                VStack(spacing: 10) {
                    row(icon: "person.2", title: String(localized: "Compte Polymestre"),
                        detail: String(localized: "Pour étudier en groupe"),
                        connected: app.social.isSignedIn) { sheet = .groups }
                }
                .rise(appeared, delay: 0.22)
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 110)
            .frame(maxWidth: Layout.readableWidth)
            .frame(maxWidth: .infinity)
            .id(refresh)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            Button(action: proceed) {
                Label("Ouvrir Polymestre", systemImage: "arrow.right")
            }
            .buttonStyle(.carnetPrimaryWide)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .sheet(item: $sheet, onDismiss: { refresh += 1 }) { ConnectionSheetContent(sheet: $0) }
        .sheet(isPresented: $showingTasks, onDismiss: { refresh += 1 }) {
            NavigationStack {
                TaskIntegrationsView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { showingTasks = false } } }
            }
        }
        .onAppear {
            calendarGranted = app.calendar.hasAccess
            appeared = true
        }
    }

    private func providerTile(_ provider: TaskProvider) -> some View {
        let connected = TaskConnector.isConnected(provider, settings: app.settings)
        return Button {
            Task { await connect(provider) }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    if working == provider {
                        ProgressView()
                    } else {
                        Image(systemName: connected ? "checkmark.circle.fill" : provider.icon)
                            .font(.title2)
                            .foregroundStyle(connected ? Carnet.correct : Carnet.ink)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(height: 30)
                Text(provider.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Carnet.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 92)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(connected ? Carnet.correct.opacity(0.6) : Carnet.rule, lineWidth: connected ? 1.5 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .disabled(connected || working != nil)
        .accessibilityLabel("\(provider.label), \(connected ? "connecté" : "relier")")
        .animation(.snappy, value: connected)
    }

    private func connect(_ provider: TaskProvider) async {
        if provider == .reminders {
            working = provider
            message = await TaskConnector.authorizeReminders(settings: app.settings)
            working = nil
            refresh += 1
            return
        }
        guard let oauth = TaskConnector.oauth(for: provider) else {
            // Pas encore d'OAuth dans cette build : la page complète, avec la
            // configuration manuelle et l'aide.
            showingTasks = true
            return
        }
        working = provider
        let outcome = await TaskConnector.connect(provider, via: oauth, settings: app.settings)
        working = nil
        withAnimation(.snappy) { message = outcome.message }
        if !outcome.notionDatabases.isEmpty { showingTasks = true }
        refresh += 1
    }

    private func row(icon: String, title: String, detail: String, connected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: connected ? "checkmark.circle.fill" : icon)
                    .font(.title3)
                    .foregroundStyle(connected ? Carnet.correct : Carnet.ink)
                    .frame(width: 30)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(Carnet.ink)
                    Text(detail).font(.footnote).foregroundStyle(Carnet.inkSecondary)
                }
                Spacer()
                if !connected {
                    Text("Relier").font(.subheadline.weight(.semibold)).foregroundStyle(Carnet.ink)
                }
            }
            .padding(16)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .disabled(connected)
    }
}

// MARK: - Outils

/// Un bouton qui s'enfonce sous le doigt, haptique à l'appui.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(duration: 0.16, bounce: 0), value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed) { _, pressed in pressed }
    }
}

extension View {
    /// Monte et apparaît, en décalé : les éléments d'un écran arrivent en vague.
    func rise(_ visible: Bool, delay: Double) -> some View {
        self
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 14)
            .animation(.spring(duration: 0.6, bounce: 0.15).delay(delay), value: visible)
    }
}
