import AppKit
import Observation
import SwiftData
import UserNotifications

/// Le chrono du Mac : le moteur commun (`TimerEngine`, le même que sur
/// l'iPhone) et ce que le Mac en fait — ce qui sera chronométré au prochain
/// démarrage, le récapitulatif après « Terminer », les notifications et les
/// sons. Démarré ici, le chrono tourne sur l'iPhone (et inversement) ; c'est
/// l'appareil qui le termine qui enregistre la session.
@MainActor
@Observable
final class MacTimer: TimerEngineHost {
    enum Phase: Equatable { case idle, running, paused, onBreak }

    @ObservationIgnored let engine: TimerEngine
    /// Ce qui sera chronométré au prochain démarrage.
    var courseID: UUID?
    var taskType: TaskType = .exercise
    var targetID: UUID?
    var pomodoro = false
    /// La session qu'on vient de terminer ici : le récapitulatif propose de
    /// cocher ce qui a été fait, et d'annuler un « Terminer » de trop.
    private(set) var recap: Recap?

    typealias Recap = TimerEngine.Finished

    @ObservationIgnored let settings: MacSettings
    /// Appelé à chaque changement d'état (widgets du bureau, barre des menus…).
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored weak var container: ModelContainer? {
        didSet { engine.container = container }
    }

    init(settings: MacSettings, isolated: Bool = false) {
        self.settings = settings
        engine = TimerEngine(isolated: isolated)
        pomodoro = settings.pomodoroDefault
        engine.host = self
    }

    /// Branche la base : la session laissée ouverte est relue (ou enregistrée,
    /// si elle est trop ancienne pour reprendre), puis le chrono suit les
    /// autres appareils.
    func attach(_ container: ModelContainer) {
        self.container = container
        guard !engine.isolated else { return }
        engine.reload()
        syncSelection()
        engine.startRelay()
    }

    // MARK: TimerEngineHost

    var localCycle: PomodoroSettings { settings.pomodoro }
    var pomodoroByDefault: Bool { pomodoro }

    func timerDidChange(_ change: TimerEngine.Change) {
        if change == .saved { return }
        // Les groupes : la session ensemble suit, la présence s'annonce.
        MacGroups.shared.timerDidChange(change)
        syncSelection()
        scheduleNotifications()
        if case .boundary(let events, let studyEnded) = change, settings.sounds {
            if studyEnded {
                NSSound(named: "Funk")?.play()
            } else if let last = events.last {
                switch last {
                case .blockEnded: NSSound(named: "Glass")?.play()
                case .breakEnded: NSSound(named: "Hero")?.play()
                }
            }
        }
        onChange?()
    }

    // MARK: Lecture

    var state: FocusTimerState? { engine.state }

    var phase: Phase {
        guard let state else { return .idle }
        if state.currentBreak != nil { return .onBreak }
        return state.isRunning ? .running : .paused
    }

    /// Les durées du cycle en vigueur (celles de la session ouverte).
    private var cycle: PomodoroSettings { engine.cycle }

    func elapsed(at now: Date = Date()) -> TimeInterval { engine.elapsed(at: now) }

    /// La phase fine (bloc prêt après une pause, etc.), déduite de l'état.
    func focusPhase(at now: Date = Date()) -> FocusPhase { engine.phase(at: now) }

    func pomodoroStatus(at now: Date = Date()) -> PomodoroStatus? {
        guard let state, state.pomodoro else { return nil }
        return engine.pomodoroStatus(at: now)
    }

    /// Le temps passé sur la cible actuelle (depuis « Passer à… »).
    func targetElapsed(at now: Date = Date()) -> TimeInterval { state?.currentTargetElapsed(at: now) ?? 0 }

    /// Ce que dessine l'anneau : le bloc ou la pause qui s'écoule ; l'heure
    /// entamée en session libre.
    func ringProgress(at now: Date = Date()) -> Double {
        guard let state else { return 0 }
        if let pause = state.currentBreak {
            let total = pause.endsAt.timeIntervalSince(pause.startedAt)
            return total > 0 ? min(1, max(0, 1 - pause.endsAt.timeIntervalSince(now) / total)) : 0
        }
        if case .readyForBlock = focusPhase(at: now) { return 1 }
        let block = state.pomodoro ? cycle.blockDuration : 3600
        let counted = state.pomodoro ? state.cycleElapsed(at: now) : elapsed(at: now)
        return counted.truncatingRemainder(dividingBy: block) / block
    }

    /// Ce qui s'affiche en grand : le temps compté, ce qui reste du bloc en
    /// Pomodoro, ou ce qui reste de la pause.
    func displayTime(at now: Date = Date()) -> TimeInterval {
        guard let state else { return 0 }
        // Comptes à rebours arrondis au-dessus, comme sur l'iPhone (« 25:00 »
        // au départ, « 00:01 » à la dernière seconde) : sinon une seconde d'écart.
        if let pause = state.currentBreak { return max(0, pause.endsAt.timeIntervalSince(now)).rounded(.up) }
        if state.pomodoro {
            let block = cycle.blockDuration
            let into = state.cycleElapsed(at: now).truncatingRemainder(dividingBy: block)
            return max(0, block - into).rounded(.up)
        }
        return elapsed(at: now)
    }

    /// Le chrono compte-t-il à rebours (pause, Pomodoro) ?
    var countsDown: Bool { phase == .onBreak || state?.pomodoro == true }

    func statusLabel(at now: Date = Date()) -> String? {
        guard let state else { return nil }
        if let pause = state.currentBreak { return pause.kind.label }
        if case .readyForBlock(let block) = focusPhase(at: now) { return String(localized: "Bloc \(block) prêt") }
        if !state.isRunning { return String(localized: "En pause") }
        if state.pomodoro {
            let block = Int(state.cycleElapsed(at: now) / cycle.blockDuration) + 1
            return "Bloc \(block)"
        }
        return nil
    }

    // MARK: Mode étude

    var isStudying: Bool { engine.isStudying }
    var studyIsOver: Bool { engine.studyIsOver }
    /// Le mode étude bloque-t-il le reste (apps fermées, sites filtrés) ?
    var studyLocks: Bool { StudyMode.blocks(state) }
    /// Sous verrou : rien ne termine la session, sauf la sortie d'urgence.
    var isLocked: Bool { engine.isLocked }

    /// Entre en mode étude pour `minutes` : démarre le chrono s'il dort, sinon
    /// verrouille la session en cours sur ce contexte.
    func enterStudy(minutes: Int?, courseID: UUID? = nil, taskType: TaskType? = nil, targetID: UUID? = nil, label: String = "",
                    locks: Bool = true) {
        recap = nil
        engine.enterStudy(minutes: minutes, courseID: courseID ?? self.courseID, taskType: taskType ?? self.taskType,
                          targetID: targetID ?? (courseID == nil ? self.targetID : nil), label: label, locks: locks)
    }

    func extendStudy(minutes: Int) { engine.extendStudy(minutes: minutes) }
    func leaveStudy(emergency: Bool = false) { engine.leaveStudy(emergency: emergency) }

    // MARK: Gestes

    func start(courseID: UUID? = nil, taskType: TaskType? = nil, targetID: UUID? = nil, label: String = "") {
        if let courseID { self.courseID = courseID }
        if let taskType { self.taskType = taskType }
        if targetID != nil || courseID != nil { self.targetID = targetID }
        recap = nil
        engine.start(courseID: self.courseID, taskType: self.taskType, targetID: self.targetID, label: label,
                     pomodoro: state == nil ? pomodoro : nil)
    }

    func pause() { engine.pause() }
    func resume() { engine.resume() }

    /// Le geste principal : démarrer, mettre en pause, reprendre.
    func toggle() {
        switch phase {
        case .idle: start()
        case .running: pause()
        case .paused, .onBreak: resume()
        }
    }

    func skipBreak() { engine.skipBreak() }

    /// Allume ou coupe le Pomodoro en cours de séance : le premier bloc part de maintenant.
    func setPomodoro(_ enabled: Bool) {
        engine.setPomodoro(enabled)
        pomodoro = enabled
    }

    /// Change ce qui est chronométré sans couper le chrono : le temps déjà
    /// compté reste à la cible précédente.
    func retarget(courseID: UUID?, taskType: TaskType, targetID: UUID? = nil) {
        self.courseID = courseID
        self.taskType = taskType
        self.targetID = targetID
        engine.updateContext(courseID: .some(courseID), taskType: taskType, targetID: .some(targetID))
    }

    /// Termine et enregistre — une session par cible, comme sur l'iPhone.
    @discardableResult
    func finish(emergency: Bool = false) -> Int? {
        guard emergency || !engine.isLocked else { return nil }
        let finished = engine.finish(emergency: emergency)
        recap = finished
        guard let finished, !finished.parts.isEmpty else { return nil }
        return finished.totalSeconds
    }

    /// « Annuler » dans le récapitulatif : les sessions enregistrées partent.
    func undoRecap() {
        guard let recap, let container else { self.recap = nil; return }
        let context = ModelContext(container)
        let ids = Set(recap.parts.map(\.sessionID))
        let since = recap.startedAt.addingTimeInterval(-1)
        let sessions = (try? context.fetch(FetchDescriptor<StudySession>(
            predicate: #Predicate { $0.startedAt >= since }))) ?? []
        for session in sessions where ids.contains(session.id) { context.delete(session) }
        try? context.save()
        self.recap = nil
    }

    func dismissRecap() { recap = nil }

    func discard(emergency: Bool = false) { engine.discard(emergency: emergency) }

    /// L'état publié par l'iPhone (ou un autre Mac).
    func applyRemote() { engine.applyRemote() }

    /// Les durées du cycle ont changé dans les réglages : la session ouverte suit.
    func cycleDidChange() { engine.cycleDidChange() }

    /// Le cours et le travail affichés suivent la session en cours.
    private func syncSelection() {
        guard let state else { return }
        courseID = state.courseID
        taskType = state.taskType
        targetID = state.targetID
        pomodoro = state.pomodoro
    }

    // MARK: Notifications

    private func scheduleNotifications() {
        cancelNotifications()
        guard let state, !engine.isolated else { return }
        let center = UNUserNotificationCenter.current()
        if let until = state.studyUntil, !StudyMode.isOpenEnded(state), until.timeIntervalSinceNow > 1 {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Mode étude terminé")
            content.body = String(localized: "Termine ta session, ou prolonge.")
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "mac.study", content: content,
                                             trigger: UNTimeIntervalNotificationTrigger(timeInterval: until.timeIntervalSinceNow, repeats: false)))
        }
        if let pause = state.currentBreak {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Fin de la pause")
            content.body = String(localized: "On s'y remet ?")
            content.sound = .default
            let interval = pause.endsAt.timeIntervalSinceNow
            if interval > 1 {
                center.add(UNNotificationRequest(identifier: "mac.break", content: content,
                                                 trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)))
            }
        } else if state.pomodoro, state.isRunning, let end = state.blockEndDate(settings: cycle) {
            let completed = Int((state.cycleAccumulated / cycle.blockDuration).rounded(.down)) + 1
            let kind = cycle.breakKind(afterBlock: completed)
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Bloc terminé")
            content.body = "\(cycle.focusMinutes) min de travail. \(kind.label) de \(Int(cycle.breakDuration(kind) / 60)) min."
            content.sound = .default
            let interval = end.timeIntervalSinceNow
            if interval > 1 {
                center.add(UNNotificationRequest(identifier: "mac.block", content: content,
                                                 trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)))
            }
        }
    }

    private func cancelNotifications() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["mac.break", "mac.block", "mac.study"])
    }
}

extension TimeInterval {
    /// « 24:13 », « 1:05:09 ».
    var clockLabel: String {
        let total = Int(self)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
