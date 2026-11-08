import Foundation
import SwiftData
import Observation
import ActivityKit
import UIKit
import UserNotifications

/// L'accueil automatique : une connexion EPFL, et l'app fait le reste.
///
/// Une fois Moodle connecté :
///   1. les cours du semestre en cours sont lus dans les inscriptions Moodle et
///      créés (ou retrouvés) — reliés à leur page Moodle ;
///   2. Courseware, MediaSpace et Explique sont connectés en silence, s'ils le
///      peuvent (`SchoolConnect`) ;
///   3. chaque cours est importé : théorie, séries, échéances, consignes ;
///   4. les énoncés des séries se lisent en arrière-plan.
///
/// **Détenu par `AppContainer`, pas par l'écran** : l'import continue quand on
/// quitte l'accueil, quand l'app passe en arrière-plan (tant qu'iOS le permet),
/// et reprend tout seul au retour si iOS l'a suspendu. Une Live Activity montre
/// l'avancement dans l'îlot et sur l'écran verrouillé.
///
/// L'écran, lui, écoute : l'avancement pondéré (`ImportProgress`) et, cours par
/// cours, ce que l'import lit, ouvre et range (`ImportFeed`) — avec les vrais
/// noms des activités Moodle.
@MainActor
@Observable
final class OnboardingAutoSetup {

    enum Phase: Equatable {
        case idle
        case working
        case done
        case failed(String)
    }

    /// Un cours trouvé dans les inscriptions Moodle, à garder ou ignorer.
    struct CourseCard: Identifiable, Equatable {
        let id: String
        var code: String
        var name: String
        var colorHex: String
        var decided = false
        var kept = true
    }

    private(set) var phase: Phase = .idle
    private(set) var headline = String(localized: "Connexion à Moodle…")
    private(set) var progress = ImportProgress()
    private(set) var feed = ImportFeed()
    private(set) var weeks = 14
    /// La semaine du semestre, aujourd'hui.
    private(set) var currentWeek = 1
    private(set) var currentID: String?
    private(set) var totals = (courses: 0, series: 0, theory: 0, deadlines: 0)
    private(set) var extraSites: [String] = []
    private(set) var cards: [CourseCard] = []
    /// Vrai quand iOS a suspendu l'import (app en arrière-plan trop longtemps).
    private(set) var isPaused = false

    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var coursesByID: [String: Course] = [:]
    @ObservationIgnored private var skipped: Set<String> = []
    @ObservationIgnored private var activity: Activity<ImportActivityAttributes>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var resumeWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    var isWorking: Bool { phase == .working }

    func currentLine(at now: Date) -> (code: String, step: String)? {
        guard let id = currentID, let card = cards.first(where: { $0.id == id }),
              let course = progress.courses.first(where: { $0.id == id }) else { return nil }
        if isPaused { return (card.code, String(localized: "en pause")) }
        if course.stage == .activities, course.total > 0 {
            return (card.code, String(localized: "activités \(course.done) / \(course.total)"))
        }
        return (card.code, course.stage.label)
    }

    // MARK: Tri des cours

    /// Garder un cours.
    func keep(_ id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].decided = true
        cards[index].kept = true
        skipped.remove(id)
        coursesByID[id]?.isTracked = true
        try? context?.save()
    }

    /// Ignorer un cours : il n'est pas importé s'il ne l'est pas encore, et ne
    /// sera pas suivi.
    func skip(_ id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].decided = true
        cards[index].kept = false
        skipped.insert(id)
        coursesByID[id]?.isTracked = false
        try? context?.save()
        feed.remove(id)
    }

    /// Les deux à la fois : la progression pondérée et ce que l'écran raconte.
    private func enter(_ stage: ImportProgress.Stage, course id: String) {
        progress.enter(stage, course: id, now: Date())
        feed.setStage(stage, course: id)
    }

    // MARK: Import

    func run(context: ModelContext, settings: SettingsStore, term: AcademicTerm) async {
        guard !isWorking else { return }
        self.context = context
        phase = .working
        isPaused = false
        headline = String(localized: "Connexion à Moodle…")
        observeLifecycle()
        let client = MoodleClient.background
        guard await client.ensureSignedIn() else {
            phase = .failed(String(localized: "Moodle ne te reconnaît pas encore. Réessaie la connexion, ou continue sans Moodle."))
            return
        }
        // Les autres sites de l'école (Courseware, MediaSpace, Ed, Explique) par
        // la même connexion, pendant la lecture des cours.
        let others = Task { @MainActor in await SchoolConnect.shared.connectAll() }

        headline = String(localized: "Lecture de tes cours…")
        var refs = (try? await client.enrolled(classification: "inprogress")) ?? []
        if MoodleOnboarding.courses(from: refs).isEmpty {
            refs = (try? await client.enrolled()) ?? []
        }
        let planned = MoodleOnboarding.courses(from: refs)
        guard !planned.isEmpty else {
            phase = .failed(String(localized: "Aucun cours EPFL trouvé dans tes inscriptions Moodle. Ajoute-les depuis ton horaire ou à la main."))
            return
        }

        // 1. Les cours, créés ou retrouvés.
        let existing = (try? context.fetch(FetchDescriptor<Course>())) ?? []
        let palette = Theme.coursePalette
        var targets: [(Course, MoodleCourseRef)] = []
        for (index, plan) in planned.enumerated() {
            let course: Course
            if let known = existing.first(where: { MoodleCourseMatcher.baseCode($0.code) == plan.code }) {
                course = known
            } else {
                course = Course(code: plan.code, name: plan.name,
                                colorHex: palette[(existing.count + index) % palette.count],
                                term: term, sectionCode: settings.sectionCode)
                context.insert(course)
            }
            if course.term == nil { course.term = term }
            course.isTracked = true
            if !course.contentSources.contains(plan.ref.url.absoluteString) {
                course.contentSources = course.contentSources + [plan.ref.url.absoluteString]
            }
            targets.append((course, plan.ref))
            coursesByID[course.id.uuidString] = course
        }
        try? context.save()

        weeks = max(term.totalWeeks, 1)
        currentWeek = min(max(term.currentWeek, 1), weeks)
        cards = targets.map { course, _ in
            CourseCard(id: course.id.uuidString, code: course.displayCode, name: course.name, colorHex: course.colorHex)
        }
        feed.reset(cards.map { (id: $0.id, code: $0.code, name: $0.name, colorHex: $0.colorHex) })
        progress.reset(courseIDs: cards.map(\.id), now: Date())
        totals.courses = targets.count
        headline = String(localized: "Ton semestre se construit")
        startActivity()

        // 2. Le contenu, cours par cours.
        var imported: [Course] = []
        for (course, ref) in targets {
            let id = course.id.uuidString
            if skipped.contains(id) {
                progress.fail(course: id, now: Date())
                continue
            }
            currentID = id
            feed.currentID = id
            await waitIfSuspended()
            var attempt = 0
            while true {
                attempt += 1
                let wasInBackground = UIApplication.shared.applicationState != .active
                do {
                    try await importCourse(course, ref: ref, client: client, settings: settings,
                                           term: term, context: context, imported: &imported)
                    break
                } catch {
                    // Échec pendant qu'iOS suspendait l'app : on réessaie au
                    // retour, plutôt que de perdre le cours.
                    let suspended = wasInBackground || UIApplication.shared.applicationState != .active || isPaused
                    if suspended, attempt < 3 {
                        await waitIfSuspended(force: true)
                        continue
                    }
                    progress.fail(course: id, now: Date())
                    break
                }
            }
            updateActivity()
        }
        totals.courses = targets.count - skipped.count

        if !imported.isEmpty {
            SeriesAutoReading.start(courses: imported, context: context, settings: settings)
        }
        settings.contentLastRefresh = Date()
        await others.value
        extraSites = SchoolConnect.shared.sites
            .filter { $0 != .moodle && SchoolConnect.shared.state($0) == .connected }
            .map(\.title).sorted()
        headline = String(localized: "C'est prêt")
        phase = .done
        finishActivity()
        notifyIfBackground()
        endBackgroundTask()
    }

    /// Un cours : sa page Moodle, ses activités, ses sources, le rangement.
    private func importCourse(_ course: Course, ref: MoodleCourseRef, client: MoodleClient,
                              settings: SettingsStore, term: AcademicTerm, context: ModelContext,
                              imported: inout [Course]) async throws {
        let id = course.id.uuidString
        beginBackgroundTask()
        enter(.outline, course: id)
        let snapshot = try await client.snapshot(of: ref, onActivities: { [weak self] done, total in
            guard let self else { return }
            self.progress.activities(done: done, total: total, course: id, now: Date())
            self.feed.setStage(.activities, course: id)
            self.feed.setOpenTotal(total, course: id)
            self.updateActivity()
        }, onSections: { [weak self] sections in
            self?.feed.outline(sections, course: id)
        }, onOpened: { [weak self] labels in
            self?.feed.opened(labels, course: id)
        })
        enter(.sources, course: id)
        updateActivity()
        let outcome = await CourseImportPipeline.draft(from: snapshot,
                                                       termStart: course.term?.startDate ?? term.startDate,
                                                       totalWeeks: course.term?.totalWeeks ?? term.totalWeeks,
                                                       settings: settings) { [weak self] message in
            self?.feed.note(message, course: id)
            guard let stage = ImportProgress.stage(forMessage: message) else { return }
            self?.enter(stage, course: id)
            self?.updateActivity()
        }
        enter(.writing, course: id)
        let draft = outcome.draft
        if !draft.isEmpty, !skipped.contains(id) {
            ContentDraftWriter.apply(draft, to: course, context: context)
            try? context.save()
            imported.append(course)
            totals.series += draft.seriesCount
            totals.theory += draft.theoryCount
            totals.deadlines += draft.deadlineCount
            feed.place(draft, course: id)
        }
        enter(.done, course: id)
    }

    // MARK: Arrière-plan

    /// Suit l'app : au retour au premier plan, l'import suspendu reprend.
    private func observeLifecycle() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resumeIfPaused() }
        })
    }

    private func resumeIfPaused() {
        guard isPaused || !resumeWaiters.isEmpty else { return }
        isPaused = false
        let waiters = resumeWaiters
        resumeWaiters = []
        waiters.forEach { $0.resume() }
        updateActivity()
    }

    /// Attend le retour au premier plan si iOS a suspendu l'import, ou s'il ne
    /// reste plus assez de temps d'arrière-plan pour lire un cours.
    private func waitIfSuspended(force: Bool = false) async {
        let app = UIApplication.shared
        if app.applicationState == .active {
            isPaused = false
            return
        }
        let lowTime = app.backgroundTimeRemaining < 25
        guard isPaused || force || lowTime else { return }
        isPaused = true
        updateActivity()
        await withCheckedContinuation { resumeWaiters.append($0) }
    }

    /// Demande à iOS le temps de finir le cours en cours (une trentaine de
    /// secondes après la fermeture). À expiration : pause, dite partout.
    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Import du semestre") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isPaused = true
                self.updateActivity()
                self.notifyPaused()
                self.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: Live Activity

    private func activityState() -> ImportActivityAttributes.ContentState {
        let now = Date()
        let line = currentLine(at: now)
        let remaining = progress.remainingSeconds(at: now)
        return .init(fraction: phase == .done ? 1 : progress.fraction(at: now),
                     courseCode: line?.code ?? "",
                     step: line?.step ?? "",
                     coursesDone: progress.courses.filter { $0.stage == .done }.count,
                     coursesTotal: progress.courses.count,
                     estimatedEnd: remaining.map { now.addingTimeInterval($0) },
                     phase: phase == .done ? .done : (isPaused ? .paused : .running))
    }

    private func startActivity() {
        guard activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled,
              UIApplication.shared.applicationState == .active else { return }
        let attributes = ImportActivityAttributes(colors: cards.map(\.colorHex))
        activity = try? Activity.request(attributes: attributes,
                                         content: .init(state: activityState(), staleDate: nil),
                                         pushType: nil)
        // L'anneau suit le temps : une mise à jour par seconde suffit.
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.phase == .working else { return }
                self.updateActivity()
            }
        }
    }

    private func updateActivity() {
        guard let activity else { return }
        let state = activityState()
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    private func finishActivity() {
        ticker?.cancel()
        guard let activity else { return }
        let state = activityState()
        Task { await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(60 * 10))) }
        self.activity = nil
    }

    // MARK: Notifications

    private func notifyIfBackground() {
        guard UIApplication.shared.applicationState != .active else { return }
        post(String(localized: "Ton semestre est prêt"),
             String(localized: "\(totals.courses) cours, \(totals.series) séries et \(totals.theory) éléments de théorie rangés semaine par semaine."))
    }

    private func notifyPaused() {
        post(String(localized: "Import en pause"), String(localized: "iOS a mis Polymestre en pause. Rouvre l'app : l'import reprend là où il s'est arrêté."))
    }

    private func post(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "onboarding-import-\(title.hashValue)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    #if DEBUG
    /// Un import simulé (quatre cours au contenu vraisemblable), pour voir
    /// l'accueil sans Moodle.
    func runDemo(fast: Bool = false) async {
        phase = .working
        headline = String(localized: "Ton semestre se construit")
        let courses = DemoSemester.courses
        weeks = 14
        currentWeek = 4
        cards = courses.map { CourseCard(id: $0.code, code: $0.code, name: $0.name, colorHex: $0.color) }
        feed.reset(cards.map { (id: $0.id, code: $0.code, name: $0.name, colorHex: $0.colorHex) })
        progress.reset(courseIDs: cards.map(\.id), now: Date())
        totals.courses = courses.count
        startActivity()
        let pace = fast ? 0.04 : 1.0
        for course in courses {
            let id = course.code
            if skipped.contains(id) { progress.fail(course: id, now: Date()); continue }
            currentID = id
            feed.currentID = id
            enter(.outline, course: id)
            try? await Task.sleep(for: .seconds(1.6 * pace))
            let sections = course.sections
            feed.outline(sections, course: id)
            try? await Task.sleep(for: .seconds(1.8 * pace))
            let openable = sections.flatMap(\.activities).filter { ImportFeed.openedModules.contains($0.module) }
            progress.activities(done: 0, total: openable.count, course: id, now: Date())
            feed.setStage(.activities, course: id)
            for start in stride(from: 0, to: openable.count, by: 18) {
                try? await Task.sleep(for: .seconds(1.6 * pace))
                let chunk = openable[start..<min(start + 18, openable.count)]
                feed.opened(Dictionary(uniqueKeysWithValues: chunk.map { ($0.id, DemoSemester.label(for: $0)) }), course: id)
                progress.activities(done: min(start + 18, openable.count), total: openable.count, course: id, now: Date())
            }
            enter(.sources, course: id)
            for message in [String(localized: "lecture du plan du cours…"), String(localized: "vidéos MediaSpace…")] {
                feed.note(message, course: id)
                try? await Task.sleep(for: .seconds(1.0 * pace))
            }
            enter(.analysis, course: id)
            try? await Task.sleep(for: .seconds(4.5 * pace))
            enter(.writing, course: id)
            let draft = course.draft
            totals.series += draft.seriesCount
            totals.theory += draft.theoryCount
            feed.place(draft, course: id)
            try? await Task.sleep(for: .seconds(3.2 * pace))
            enter(.done, course: id)
            updateActivity()
            try? await Task.sleep(for: .seconds(0.6 * pace))
        }
        extraSites = ["Courseware", "MediaSpace"]
        headline = String(localized: "C'est prêt")
        phase = .done
        finishActivity()
    }
    #endif
}
