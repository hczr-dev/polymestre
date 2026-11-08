import SwiftUI
import SwiftData

// Les pièces du chrono, partagées par la barre des menus et la page Chrono.

// MARK: - Les gestes

/// Démarrer / pause / reprendre en grand, terminer à côté ; pendant une pause,
/// « reprendre le travail ».
struct TimerControls: View {
    @Environment(MacTimer.self) private var timer
    var size: CGFloat = 56
    var tint: Color

    var body: some View {
        HStack(spacing: size * 0.32) {
            if timer.phase != .idle, !timer.isLocked {
                Button { timer.discard() } label: { Image(systemName: "xmark") }
                    .buttonStyle(RoundButtonStyle(size: size * 0.7))
                    .help("Abandonner")
            }
            Button { primary() } label: {
                Image(systemName: primaryIcon).contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(RoundButtonStyle(size: size, prominent: true, tint: timer.phase == .onBreak ? MacStyle.breakTint : tint))
            .help(primaryHelp)
            if timer.phase != .idle, !timer.isLocked {
                Button { timer.finish() } label: { Image(systemName: "checkmark") }
                    .buttonStyle(RoundButtonStyle(size: size * 0.7))
                    .help("Terminer (⇧⌘T)")
            }
        }
    }

    private func primary() {
        if timer.phase == .onBreak { timer.skipBreak() } else { timer.toggle() }
    }

    private var primaryIcon: String {
        switch timer.phase {
        case .running: return "pause.fill"
        case .onBreak: return "forward.fill"
        default: return "play.fill"
        }
    }

    private var primaryHelp: String {
        switch timer.phase {
        case .idle: return String(localized: "Démarrer (⌘T)")
        case .running: return "Pause (⌘T)"
        case .paused: return String(localized: "Reprendre (⌘T)")
        case .onBreak: return String(localized: "Reprendre")
        }
    }
}

// MARK: - Sur quoi

/// Au repos : le cours, le travail, la cible, le mode. Ce qui est choisi ici
/// est ce que « Démarrer » chronomètre.
struct TimerSetup: View {
    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings
    let courses: [Course]

    var body: some View {
        @Bindable var timer = timer
        VStack(alignment: .leading, spacing: 12) {
            TimerSetupRow(courses: courses)
            Toggle(isOn: $timer.pomodoro) {
                Text("Pomodoro · \(settings.focusMinutes)/\(settings.shortBreakMinutes) min")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }
}

/// Sur quoi chronométrer : le cours, le travail, la cible — un rang de
/// pastilles-menus (la barre des menus et la page Chrono). Les pastilles de
/// tous les cours, sur plusieurs lignes, prenaient la moitié du panneau.
struct TimerSetupRow: View {
    @Environment(MacTimer.self) private var timer
    let courses: [Course]
    /// Un choix fait à la main (le cours de l'horaire n'est plus « proposé »).
    var onChoice: () -> Void = {}

    private var course: Course? { courses.first { $0.id == timer.courseID } }

    var body: some View {
        @Bindable var timer = timer
        HStack(spacing: 6) {
            Menu {
                Button("Sans cours") { timer.courseID = nil; timer.targetID = nil; onChoice() }
                Divider()
                ForEach(courses) { item in
                    Button("\(item.displayCode) · \(item.name)") {
                        timer.courseID = item.id
                        timer.targetID = nil
                        onChoice()
                    }
                }
            } label: {
                PillLabel(dot: course.map { Carnet.tint($0.colorHex) }, title: course?.displayCode ?? String(localized: "Sans cours"))
            }
            .pillMenu()
            .help(course?.name ?? "Choisir un cours")

            Menu {
                ForEach(TaskType.choices) { type in
                    Button { timer.taskType = type; timer.targetID = nil } label: { Label(type.label, systemImage: type.icon) }
                }
            } label: {
                PillLabel(icon: timer.taskType.icon, title: timer.taskType.label)
            }
            .pillMenu()

            if let course {
                TargetMenu(course: course, taskType: timer.taskType, selection: $timer.targetID)
                    .pillMenu()
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Carnet.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Carnet.sheetRaised, in: Capsule())
            }
            Spacer(minLength: 0)
        }
    }
}

/// Une pastille-menu : un point de couleur ou une icône, un titre, ▾.
struct PillLabel: View {
    var dot: Color? = nil
    var icon: String? = nil
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
            if let icon { Image(systemName: icon).font(.caption) }
            Text(title).font(.callout.weight(.medium)).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Carnet.inkTertiary)
        }
        .foregroundStyle(Carnet.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Carnet.sheetRaised, in: Capsule())
        .contentShape(Capsule())
    }
}

extension View {
    /// Un menu qui garde son étiquette telle quelle (pas de bouton système).
    func pillMenu() -> some View {
        self.menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}

/// Le menu des cibles d'un cours : ce qui est à faire d'abord.
struct TargetMenu: View {
    let course: Course
    let taskType: TaskType
    @Binding var selection: UUID?

    var body: some View {
        let label = MacTargets.label(selection, in: course) ?? String(localized: "Tout le cours")
        Menu {
            Button("Tout le cours") { selection = nil }
            Divider()
            if taskType.canonical == .theory {
                let items = FocusTargets.theory(course.sortedTheoryItems)
                ForEach(items.upNext.prefix(14)) { item in
                    Button(MacTargets.label(item.id, in: course) ?? item.kind.label) { selection = item.id }
                }
                if !items.done.isEmpty {
                    Menu("Déjà vus") {
                        ForEach(items.done.suffix(20)) { item in
                            Button(MacTargets.label(item.id, in: course) ?? item.kind.label) { selection = item.id }
                        }
                    }
                }
            } else {
                let ordered = FocusTargets.exercises(of: course.series, for: taskType)
                ForEach(ordered.upNext.prefix(14)) { exercise in
                    Button(exercise.displayNumber) { selection = exercise.id }
                }
                if !ordered.done.isEmpty {
                    Menu("Déjà faits") {
                        ForEach(ordered.done.suffix(24)) { exercise in
                            Button(exercise.displayNumber) { selection = exercise.id }
                        }
                    }
                }
            }
        } label: {
            Text(label).lineLimit(1)
        }
        .fixedSize()
        .help("Sur quoi")
    }
}

struct CourseChip: View {
    let title: String
    let color: Color
    let selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(Carnet.ink)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background {
                Capsule().fill(selected ? color.opacity(0.14) : (hovering ? Carnet.rule : Carnet.sheetRaised))
            }
            .overlay { Capsule().strokeBorder(selected ? color : .clear, lineWidth: 1) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Ensuite

/// Pendant une session : les exercices suivants du cours. Un clic y passe
/// sans couper le chrono — le temps déjà compté reste au précédent.
struct UpNextList: View {
    @Environment(MacTimer.self) private var timer
    let course: Course
    var limit = 5

    var body: some View {
        let items = upNext
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items, id: \.id) { item in
                    Button {
                        timer.retarget(courseID: course.id, taskType: item.type, targetID: item.id)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: item.type.icon)
                                .font(.caption)
                                .foregroundStyle(Carnet.tint(course.colorHex))
                                .frame(width: 16)
                            Text(item.title).lineLimit(1).foregroundStyle(Carnet.ink)
                            Spacer()
                            Text("Passer").font(.caption).foregroundStyle(Carnet.inkSecondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .hoverRow()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var upNext: [(id: UUID, title: String, type: TaskType)] {
        let type = timer.taskType
        if type.canonical == .theory {
            return FocusTargets.theory(course.sortedTheoryItems).upNext
                .filter { $0.id != timer.targetID }
                .prefix(limit)
                .map { ($0.id, MacTargets.label($0.id, in: course) ?? $0.kind.label, TaskType.theory) }
        }
        var pending = FocusTargets.exercises(of: course.series, for: type).upNext.filter { $0.id != timer.targetID }
        // D'abord la suite de la série en cours, dans l'ordre du polycopié.
        if let current = course.allExercises.first(where: { $0.id == timer.targetID }), let series = current.series {
            let after = pending.filter { $0.series?.id == series.id && $0.sortOrder > current.sortOrder }
                .sorted { $0.sortOrder < $1.sortOrder }
            let ids = Set(after.map(\.id))
            pending = after + pending.filter { !ids.contains($0.id) }
        }
        return pending
            .prefix(limit)
            .map { ($0.id, $0.displayNumber, type.canonical == .correction ? TaskType.correction : TaskType.exercise) }
    }
}

// MARK: - Récapitulatif

/// Après « Terminer » : ce qui a été compté, et de quoi cocher tout de suite
/// ce qui a été fait. « Annuler » retire les sessions.
struct RecapCard: View {
    @Environment(MacTimer.self) private var timer
    @Environment(\.modelContext) private var context
    let recap: MacTimer.Recap
    let courses: [Course]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: recap.discarded ? "xmark.circle" : "checkmark.circle.fill")
                    .foregroundStyle(recap.discarded ? Carnet.inkSecondary : Carnet.correct)
                Text(recap.discarded ? "Trop court, pas gardé" : "Enregistré")
                    .font(Carnet.serif(.headline))
                    .foregroundStyle(Carnet.ink)
                Spacer()
                if !recap.discarded {
                    Text(DateUtils.durationLabel(seconds: recap.totalSeconds))
                        .font(Carnet.serif(.headline).monospacedDigit())
                        .foregroundStyle(Carnet.ink)
                }
            }
            ForEach(recap.parts) { part in
                RecapRow(part: part, course: courses.first { $0.id == part.courseID })
            }
            HStack {
                if !recap.discarded {
                    Button("Annuler") { timer.undoRecap() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Carnet.inkSecondary)
                }
                Spacer()
                Button("OK") { timer.dismissRecap() }
                    .buttonStyle(.ink)
            }
            .font(.callout)
        }
        .onDisappear { try? context.save() }
    }
}

private struct RecapRow: View {
    let part: TimerEngine.RecordedPart
    let course: Course?

    var body: some View {
        let tint = MacTargets.tint(course)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 3, height: 16)
                Text(course?.displayCode ?? "Libre").font(.callout.weight(.semibold)).foregroundStyle(Carnet.ink)
                Text(MacTargets.headline(course: course, taskType: part.taskType, targetID: part.targetID))
                    .lineLimit(1)
                    .foregroundStyle(Carnet.inkSecondary)
                Spacer()
                Text(DateUtils.durationLabel(seconds: part.seconds)).monospacedDigit().foregroundStyle(Carnet.inkSecondary)
            }
            .font(.callout)
            if let exercise = course?.allExercises.first(where: { $0.id == part.targetID }) {
                ExerciseQuickMark(exercise: exercise)
                    .padding(.leading, 11)
            } else if let item = course?.theoryItems.first(where: { $0.id == part.targetID }) {
                Toggle("Vu", isOn: Binding(get: { item.isWatched },
                                           set: { item.watchedAt = $0 ? (item.watchedAt ?? Date()) : nil }))
                    .toggleStyle(.checkbox)
                    .padding(.leading, 11)
            }
        }
    }
}

// MARK: - Objectif du jour

/// « 2 h 10 sur 3 h » et une barre.
struct GoalBar: View {
    let seconds: Int
    let goal: Int
    var tint: Color = MacStyle.goalTint

    var body: some View {
        let progress = min(1, Double(seconds) / Double(max(goal, 1)))
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("Aujourd'hui").foregroundStyle(Carnet.inkSecondary)
                Spacer()
                Text("\(DateUtils.hoursLabel(seconds: seconds)) / \(DateUtils.hoursLabel(seconds: goal))")
                    .monospacedDigit()
                    .foregroundStyle(progress >= 1 ? Carnet.correct : Carnet.inkSecondary)
            }
            .font(.caption)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Carnet.rule)
                    Capsule().fill(progress >= 1 ? Carnet.correct : tint)
                        .frame(width: max(4, proxy.size.width * progress))
                }
            }
            .frame(height: 5)
        }
    }
}

/// Le temps d'étude d'aujourd'hui, déjà enregistré (la session en cours
/// s'ajoute à la minute, `TodayStudyText`) — compté comme partout
/// (`StudyTime` : sessions et cours suivis).
@MainActor
enum TodayTotal {
    static func saved(in context: ModelContext) -> Int {
        StudyTime.today(in: context)
    }

    /// Le début du jour, pour borner les requêtes : la fenêtre ne relit plus
    /// tout l'historique pour un total du jour.
    static var startOfToday: Date { Calendar.current.startOfDay(for: Date()) }
}

/// L'objectif du jour, session en cours comprise, à la minute.
struct LiveGoalBar: View {
    /// Les sessions du jour : la barre se redessine quand elles changent.
    let sessions: [StudySession]
    @Environment(\.modelContext) private var context
    @Environment(MacSettings.self) private var settings

    var body: some View {
        let _ = sessions.count
        let goal = settings.dailyGoalSeconds(in: context)
        TodayStudyText(savedSeconds: TodayTotal.saved(in: context)) { seconds in
            AnyView(GoalBar(seconds: seconds, goal: goal))
        }
    }
}
