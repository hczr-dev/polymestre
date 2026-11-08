import Foundation
import Observation
import SwiftData

/// Ce que l'appareil fait quand le chrono change : îlot et présence sur
/// l'iPhone, barre des menus et sons sur le Mac.
@MainActor
protocol TimerEngineHost: AnyObject {
    /// Les durées du cycle réglées sur cet appareil : elles s'appliquent aux
    /// sessions qu'il démarre (une session garde les siennes, `FocusTimerState.cycle`).
    var localCycle: PomodoroSettings { get }
    /// Démarrer en Pomodoro par défaut.
    var pomodoroByDefault: Bool { get }
    /// Après chaque changement : un geste d'ici, un état venu d'ailleurs, une
    /// frontière du cycle franchie, une session fermée.
    func timerDidChange(_ change: TimerEngine.Change)
}

/// Le chrono, **le même** sur l'iPhone et le Mac.
///
/// Les deux appareils tenaient chacun leur moteur (`FocusController`,
/// `MacTimer`) autour du même état : deux façons de démarrer, d'enregistrer,
/// de publier aux autres appareils et d'attendre la fin d'un bloc — et chaque
/// correctif du chrono partagé était à faire deux fois. Ici, une seule : les
/// gestes, la persistance, l'enregistrement des sessions, l'échange entre
/// appareils et les frontières du cycle (un réveil à la prochaine, jamais un
/// battement par seconde). Chaque appareil n'ajoute que ses effets (`host`).
@MainActor
@Observable
final class TimerEngine {

    enum Change: Equatable {
        /// Un geste fait ici. `presence` : le cours ou la cible a changé (ou le
        /// chrono a démarré / s'est arrêté) — ce que les groupes voient.
        case gesture(presence: Bool)
        /// Un état venu d'un autre appareil, adopté.
        case remote
        /// L'horloge de la session de groupe a changé (un autre membre a agi).
        case group
        /// Une fin de bloc, de pause ou de mode étude, déduite de l'heure.
        case boundary(events: [PomodoroEvent], studyEnded: Bool)
        /// Rien n'a changé dans l'état, mais ce qu'il montre (une question cochée).
        case refresh
        /// Écrit et publié, sans rien de visible à republier (une note tapée).
        case saved
        /// La session est fermée (terminée, abandonnée, ou fermée ailleurs).
        case closed(session: Date?)
    }

    /// L'état du chrono ; `nil` quand aucune session n'est ouverte.
    private(set) var state: FocusTimerState?
    /// Le dernier événement du cycle, pour que l'écran puisse le saluer.
    private(set) var lastEvent: PomodoroEvent?
    /// Change à chaque frontière et à chaque geste : ce qui dépend de l'heure
    /// **et** de l'état (mode étude en vigueur, phase) se relit alors.
    private(set) var revision = 0

    @ObservationIgnored weak var host: TimerEngineHost?
    @ObservationIgnored var container: ModelContainer?
    /// Un chrono d'aperçu (débogage) : ni sauvegardé, ni partagé.
    @ObservationIgnored let isolated: Bool
    @ObservationIgnored private var applyingRemote = false
    @ObservationIgnored private var boundary: Task<Void, Never>?
    @ObservationIgnored private var relayObserver: NSObjectProtocol?

    /// Une session de moins d'une minute est un faux départ : rien n'est enregistré.
    static let minimumRecordedSeconds = 60

    init(isolated: Bool = false) {
        self.isolated = isolated
        if !isolated { state = FocusTimerStore.load() }
    }

    // MARK: Lecture

    /// Une session est ouverte : du temps compté, ou une pause en cours.
    var hasSession: Bool {
        guard let state else { return false }
        return state.isRunning || state.isRestorable()
    }

    var isRunning: Bool { state?.isRunning ?? false }

    /// Les durées du cycle en vigueur : celles de la session, sinon de l'appareil.
    var cycle: PomodoroSettings {
        let local = host?.localCycle ?? PomodoroSettings()
        return state?.cycle(or: local) ?? local
    }

    func elapsed(at now: Date = Date()) -> TimeInterval { state?.elapsed(at: now) ?? 0 }

    func phase(at now: Date = Date()) -> FocusPhase {
        state?.phase(settings: cycle, at: now) ?? .idle
    }

    /// Où en est le bloc de travail à l'instant `now`.
    func pomodoroStatus(at now: Date = Date()) -> PomodoroStatus {
        PomodoroEngine.status(elapsed: elapsed(at: now), focusMinutes: cycle.focusMinutes, origin: state?.cycleOriginSeconds ?? 0)
    }

    var isStudying: Bool {
        _ = revision
        return StudyMode.isActive(state)
    }

    var studyIsOver: Bool {
        _ = revision
        return StudyMode.isOver(state)
    }

    /// Le verrou tient : terminer, abandonner ou sortir du mode étude ne passe
    /// que par la sortie d'urgence (`emergency: true`). Ni un bouton du Dock, ni
    /// un widget, ni Siri, ni ⌘Q ne le lèvent — la règle est ici, une fois.
    var isLocked: Bool {
        _ = revision
        return StudyMode.locks(state)
    }

    // MARK: Cycle de vie

    /// Relit l'état persisté et rattrape le temps passé app fermée.
    ///
    /// Une session trop ancienne (chrono oublié la veille) n'est pas reprise :
    /// elle est enregistrée telle quelle, bornée, avec une note pour qu'on la
    /// corrige dans le journal.
    func reload() {
        guard !isolated else { return }
        guard var saved = FocusTimerStore.load() else {
            if state != nil { state = nil; lastEvent = nil }
            scheduleBoundary()
            return
        }
        guard saved.isRestorable() else {
            FocusTimerStore.save(nil)
            state = nil
            let seconds = min(Int(saved.elapsed()), Int(FocusTimerState.maxRestorableAge))
            if seconds >= Self.minimumRecordedSeconds, let container {
                let context = ModelContext(container)
                let course = Self.course(saved.courseID, in: context)
                context.insert(StudySession(course: course,
                                            taskType: saved.taskType,
                                            startedAt: saved.sessionStartedAt,
                                            durationSeconds: seconds,
                                            isManual: false,
                                            note: saved.note.isEmpty
                                                ? String(localized: "Chrono resté ouvert — durée à vérifier")
                                                : saved.note + String(localized: " · chrono resté ouvert")))
                try? context.save()
            }
            scheduleBoundary()
            host?.timerDidChange(.closed(session: saved.sessionStartedAt))
            return
        }
        let events = saved.advance(settings: saved.cycle(or: host?.localCycle ?? PomodoroSettings()))
        let changed = saved != state
        state = saved
        if !events.isEmpty {
            lastEvent = events.last
            FocusTimerStore.save(state)
        }
        scheduleBoundary()
        if changed || !events.isEmpty { host?.timerDidChange(.boundary(events: events, studyEnded: false)) }
    }

    // MARK: Gestes

    /// Démarre une session — ou, si elle est ouverte, la reprend sur ce
    /// contexte (le temps déjà compté reste à la cible précédente).
    ///
    /// - Parameter pomodoro: `nil` garde le réglage de la session ouverte, ou
    ///   celui de l'appareil pour une nouvelle.
    func start(courseID: UUID?, taskType: TaskType, targetID: UUID? = nil,
               label: String = "", pomodoro: Bool? = nil) {
        if var current = state, hasSession {
            current.switchContext(courseID: courseID, taskTypeRaw: taskType.rawValue, targetID: targetID)
            if !label.isEmpty { current.contextLabel = label }
            if let pomodoro { current.pomodoro = pomodoro }
            current.start()
            state = current
        } else {
            var fresh = FocusTimerState(sessionStartedAt: Date(),
                                        courseID: courseID,
                                        taskTypeRaw: taskType.rawValue,
                                        targetID: targetID,
                                        contextLabel: label,
                                        pomodoro: pomodoro ?? (host?.pomodoroByDefault ?? false))
            fresh.cycle = host?.localCycle
            fresh.start()
            state = fresh
        }
        lastEvent = nil
        commit(presence: true)
    }

    /// Relance le chrono : reprise après une pause, ou bloc suivant.
    func resume() {
        guard var current = state else { return }
        current.start()
        state = current
        lastEvent = nil
        commit(presence: true)
    }

    func pause() {
        guard var current = state, current.isRunning else { return }
        current.pause()
        state = current
        commit(presence: true)
    }

    /// Termine la pause Pomodoro et relance le travail.
    func skipBreak() {
        guard var current = state, current.currentBreak != nil else { return }
        current.skipBreak()
        state = current
        lastEvent = nil
        commit(presence: true)
    }

    /// Allonge la pause en cours.
    func extendBreak(minutes: Int = 5) {
        guard var current = state, current.currentBreak != nil else { return }
        current.extendBreak(by: TimeInterval(minutes * 60))
        state = current
        commit(presence: false)
    }

    /// Active ou coupe le Pomodoro de la session ouverte. Le couper pendant une
    /// pause la termine : sans cycle, il n'y a plus de pause à décompter.
    func setPomodoro(_ enabled: Bool) {
        guard var current = state else { return }
        if current.cycle == nil { current.cycle = host?.localCycle }
        current.setPomodoro(enabled)
        current.advance(settings: current.cycle(or: cycle))
        state = current
        commit(presence: false)
    }

    /// Les durées du cycle ont changé sur cet appareil : la session ouverte les
    /// prend (et les publie — l'autre appareil coupe le bloc au même instant).
    func cycleDidChange() {
        guard var current = state, let local = host?.localCycle, current.cycle != local else { return }
        current.cycle = local
        let events = current.advance(settings: local)
        state = current
        if !events.isEmpty { lastEvent = events.last }
        commit(presence: false)
    }

    /// Change le cours, le type, la cible, la note ou le libellé de la session
    /// ouverte. Cours, type et cible passent par un **segment** : changer
    /// d'exercice en pleine session ne réattribue pas le temps déjà passé.
    func updateContext(courseID: UUID?? = nil,
                       taskType: TaskType? = nil,
                       targetID: UUID?? = nil,
                       note: String? = nil,
                       label: String? = nil) {
        guard var current = state else { return }
        current.switchContext(courseID: courseID ?? current.courseID,
                              taskTypeRaw: taskType?.rawValue ?? current.taskTypeRaw,
                              targetID: targetID ?? current.targetID)
        if let note { current.note = note }
        if let label { current.contextLabel = label }
        guard current != state else { return }
        let contextChanged = current.courseID != state?.courseID
            || current.taskTypeRaw != state?.taskTypeRaw
            || current.targetID != state?.targetID
        state = current
        // La note s'écrit à chaque frappe : elle n'a pas à republier l'îlot.
        commit(presence: contextChanged, publishesActivity: contextChanged)
    }

    /// Fixe le temps compté **absolu** (corriger un oubli, l'anneau).
    func setElapsed(_ total: TimeInterval) {
        let bounded = max(0, total)
        if state == nil {
            guard bounded >= 1 else { return }
            var fresh = FocusTimerState(sessionStartedAt: Date(), pomodoro: host?.pomodoroByDefault ?? false)
            fresh.cycle = host?.localCycle
            state = fresh
        }
        guard var current = state, abs(bounded - current.elapsed()) >= 0.5 else { return }
        current.accumulated = bounded
        // La période en cours repart de maintenant : le chrono continue de
        // tourner à partir du nouveau total.
        current.runningSince = current.isRunning ? Date() : nil
        state = current
        commit(presence: false)
    }

    /// Une session enregistrée par `finish`, cible par cible.
    struct RecordedPart: Equatable, Identifiable {
        var sessionID: UUID
        var id: UUID { sessionID }
        var courseID: UUID?
        var taskType: TaskType
        var targetID: UUID?
        var seconds: Int
    }

    /// Ce que `finish` a enregistré.
    struct Finished: Equatable, Identifiable {
        var id = UUID()
        var startedAt: Date
        var endedAt: Date
        var totalSeconds: Int
        /// Vide : moins d'une minute, rien n'a été enregistré.
        var parts: [RecordedPart]
        var discarded: Bool { parts.isEmpty }
    }

    /// Enregistre la session et libère le chrono. Une session passée sur
    /// plusieurs cibles (3.2, puis 3.3) est enregistrée en **une session par
    /// cible**, bout à bout : le temps de chaque exercice se lit sur l'exercice.
    @discardableResult
    func finish(emergency: Bool = false) -> Finished? {
        guard var current = state, emergency || !StudyMode.locks(current) else { return nil }
        if emergency, StudyMode.locks(current) { current.note = StudyMode.emergencyNote(current.note) }
        defer { close() }
        // Dans une session de groupe rejointe en cours de route, le temps d'avant
        // l'arrivée est compté par l'horloge commune mais n'est pas le sien.
        let parts = current.allocatedSeconds()
        let own = parts.filter { $0.segment.excluded != true }.reduce(0) { $0 + $1.seconds }
        var result = Finished(startedAt: current.sessionStartedAt, endedAt: Date(), totalSeconds: own, parts: [])
        guard !isolated, own >= Self.minimumRecordedSeconds, let container else { return result }
        let context = ModelContext(container)
        var start = current.sessionStartedAt
        var courses: [UUID: Course] = [:]
        for (index, part) in parts.enumerated() {
            guard part.segment.excluded != true else {
                start = start.addingTimeInterval(TimeInterval(part.seconds))
                continue
            }
            let course = part.segment.courseID.flatMap { id in
                courses[id] ?? Self.course(id, in: context).map { courses[id] = $0; return $0 }
            }
            let target = Self.target(of: part.segment.targetID, in: course)
            let session = StudySession(course: course,
                                       taskType: part.segment.taskType,
                                       startedAt: start,
                                       durationSeconds: part.seconds,
                                       isManual: false,
                                       note: current.groupSession.map { String(localized: "Session « \($0.groupName) »") + (index == 0 && !current.note.isEmpty ? " · " + current.note : "") }
                                           ?? (index == 0 ? current.note : ""),
                                       exercise: target.exercise,
                                       theoryItem: target.theoryItem)
            context.insert(session)
            result.parts.append(RecordedPart(sessionID: session.id, courseID: course?.id, taskType: part.segment.taskType,
                                             targetID: part.segment.targetID, seconds: part.seconds))
            start = start.addingTimeInterval(TimeInterval(part.seconds))
        }
        try? context.save()
        return result
    }

    /// Abandonne la session sans l'enregistrer.
    func discard(emergency: Bool = false) {
        guard emergency || !StudyMode.locks(state) else { return }
        close()
    }

    /// Republie ce que montre la session sans toucher à l'état (une question
    /// cochée change « 3/9 » sur l'îlot).
    func refresh() {
        host?.timerDidChange(.refresh)
    }

    // MARK: Session de groupe

    /// Lie le chrono à une session de groupe qu'on vient de **lancer** : son
    /// horloge devient celle du groupe (elle démarre si rien ne tournait).
    func hostGroupSession(_ link: GroupSessionLink, courseID: UUID?, taskType: TaskType, targetID: UUID?) {
        if !hasSession { start(courseID: courseID, taskType: taskType, targetID: targetID) }
        guard var current = state else { return }
        current.groupSession = link
        state = current
        commit(presence: true)
    }

    /// **Rejoint** une session de groupe en cours : la session personnelle
    /// ouverte est d'abord enregistrée, puis le chrono prend l'horloge du
    /// groupe en gardant son propre cours et sa cible.
    func joinGroupSession(_ link: GroupSessionLink, clock: GroupClock,
                          courseID: UUID?, taskType: TaskType, targetID: UUID?) {
        if hasSession, state?.groupSession?.sessionID != link.sessionID { finish() }
        state = clock.joining(link: link, courseID: courseID, taskTypeRaw: taskType.rawValue, targetID: targetID)
        lastEvent = nil
        commit(presence: true)
    }

    /// La session de groupe est finie mais le verrou tient : le chrono reste,
    /// à soi, sans l'horloge commune.
    func detachGroup() {
        guard var current = state, current.groupSession != nil else { return }
        current.groupSession = nil
        state = current
        commit(presence: false)
    }

    /// L'horloge du groupe a changé ailleurs (un membre a mis en pause, repris,
    /// écourté la pause) : elle se pose ici, sans être renvoyée au groupe.
    func applyGroupClock(_ clock: GroupClock) {
        guard var current = state, current.groupSession != nil, GroupClock(current) != clock else { return }
        clock.apply(to: &current)
        state = current
        lastEvent = nil
        if !isolated {
            FocusTimerStore.save(state)
            if !applyingRemote, let state { CloudRelay.publishTimer(state) }
        }
        scheduleBoundary()
        host?.timerDidChange(.group)
    }

    // MARK: Mode étude

    /// Entre en mode étude : démarre la session si besoin, sinon la verrouille
    /// sur ce contexte. Publié comme un geste : l'autre appareil suit.
    func enterStudy(minutes: Int?, courseID: UUID?, taskType: TaskType, targetID: UUID? = nil,
                    label: String = "", locks: Bool = true) {
        if !hasSession {
            start(courseID: courseID, taskType: taskType, targetID: targetID, label: label)
        } else if courseID != nil || targetID != nil {
            updateContext(courseID: .some(courseID ?? state?.courseID), taskType: taskType, targetID: .some(targetID))
        }
        guard var current = state else { return }
        StudyMode.enter(&current, minutes: minutes, locks: locks)
        if !current.isRunning, current.currentBreak == nil { current.start() }
        state = current
        commit(presence: false)
    }

    func extendStudy(minutes: Int) {
        guard var current = state else { return }
        // Prolonger après l'échéance repart d'un anneau vide.
        if current.studySince == nil || StudyMode.isOver(current) { current.studySince = Date() }
        current.studyUntil = StudyMode.extended(current.studyUntil, by: minutes)
        if !current.isRunning, current.currentBreak == nil { current.start() }
        state = current
        commit(presence: false)
    }

    /// Sortir du mode étude sans terminer la session.
    func leaveStudy(emergency: Bool = false) {
        guard var current = state, current.studyUntil != nil, emergency || !StudyMode.locks(current) else { return }
        StudyMode.leave(&current)
        state = current
        commit(presence: false)
    }

    // MARK: Entre appareils

    /// Écoute les autres appareils **au niveau de l'app** : lancée en
    /// arrière-plan, l'app suit quand même le chrono de l'autre appareil.
    ///
    /// Deux voies : le relais (instantané, apps ouvertes) et le magasin
    /// clé-valeur d'iCloud (rattrapage, apps fermées ou hors ligne). Les deux
    /// annoncent par `CloudRelay.changed`.
    func startRelay() {
        guard !isolated, relayObserver == nil else { return }
        relayObserver = NotificationCenter.default.addObserver(forName: CloudRelay.changed, object: nil,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyRemote() }
        }
        NSUbiquitousKeyValueStore.default.synchronize()
        applyRemote()
    }

    /// Reprend l'état publié par un autre appareil. Rien n'est enregistré ici :
    /// c'est l'appareil qui termine qui enregistre.
    func applyRemote() {
        guard !isolated, let remote = CloudRelay.remoteTimer() else { return }
        CloudRelay.noteShared(local: state, remote: remote)
        let decision = CloudRelay.decide(local: state, remote: remote,
                                         lastApplied: CloudRelay.lastAppliedTimer, device: CloudRelay.deviceID,
                                         shared: CloudRelay.sharedSession)
        guard decision != .ignore else { return }
        applyingRemote = true
        defer { applyingRemote = false }
        CloudRelay.lastAppliedTimer = remote.updatedAt
        switch decision {
        case .adopt(let remoteState):
            CloudRelay.noteAdopted(remoteState)
            state = remoteState
            lastEvent = nil
            FocusTimerStore.save(state)
            scheduleBoundary()
            host?.timerDidChange(.remote)
        case .close:
            close()
        case .ignore:
            break
        }
    }

    // MARK: Publication

    /// Ferme la session : plus d'état, et les autres appareils la ferment aussi.
    private func close() {
        let ended = state?.sessionStartedAt
        if !applyingRemote, !isolated, let ended { CloudRelay.publishTimer(nil, ended: ended) }
        state = nil
        lastEvent = nil
        if !isolated { FocusTimerStore.save(nil) }
        scheduleBoundary()
        host?.timerDidChange(.closed(session: ended))
    }

    /// Un geste : l'état est écrit, publié aux autres appareils, et l'appareil
    /// en tire ses effets.
    ///
    /// Seuls les **gestes** se publient. La fin d'un bloc ou d'une pause se
    /// déduit des dates, pareil sur chaque appareil : la republier, c'était
    /// dater de « maintenant » un état périmé et écraser le « play » donné
    /// entre-temps sur l'autre appareil.
    private func commit(presence: Bool, publishesActivity: Bool = true) {
        if !isolated {
            FocusTimerStore.save(state)
            if !applyingRemote, let state { CloudRelay.publishTimer(state) }
        }
        scheduleBoundary()
        host?.timerDidChange(publishesActivity ? .gesture(presence: presence) : .saved)
    }

    // MARK: Frontières

    /// La prochaine date où l'état change de lui-même : fin du bloc, de la
    /// pause, du mode étude. Un seul réveil, à cet instant.
    func nextBoundary(after now: Date = Date()) -> Date? {
        guard let state else { return nil }
        var dates: [Date] = []
        if let pause = state.currentBreak { dates.append(pause.endsAt) }
        if let end = state.blockEndDate(settings: cycle) { dates.append(end) }
        if let until = state.studyUntil, !StudyMode.isOpenEnded(state) { dates.append(until) }
        return dates.filter { $0 > now }.min()
    }

    private func scheduleBoundary() {
        boundary?.cancel()
        boundary = nil
        revision &+= 1
        guard let date = nextBoundary() else { return }
        boundary = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow) + 0.05))
            guard !Task.isCancelled else { return }
            self?.reachBoundary()
        }
    }

    private func reachBoundary() {
        guard var current = state else { scheduleBoundary(); return }
        let now = Date()
        let studyEnded = current.studyUntil.map { abs($0.timeIntervalSince(now)) < 1.5 } ?? false
        let events = current.advance(settings: cycle, to: now)
        if !events.isEmpty {
            state = current
            lastEvent = events.last
            if !isolated { FocusTimerStore.save(state) }
        }
        scheduleBoundary()
        host?.timerDidChange(.boundary(events: events, studyEnded: studyEnded))
    }

    // MARK: Outils

    static func course(_ id: UUID?, in context: ModelContext) -> Course? {
        guard let id else { return nil }
        return try? context.fetch(FetchDescriptor<Course>(predicate: #Predicate { $0.id == id })).first
    }

    /// La cible d'une session : un exercice ou un élément de théorie.
    static func target(of targetID: UUID?, in course: Course?) -> (exercise: Exercise?, theoryItem: TheoryItem?) {
        guard let course, let targetID else { return (nil, nil) }
        for series in course.series {
            if let exercise = series.exercises.first(where: { $0.id == targetID }) { return (exercise, nil) }
        }
        if let item = course.theoryItems.first(where: { $0.id == targetID }) {
            return (nil, item)
        }
        return (nil, nil)
    }
}
