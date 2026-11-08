import ActivityKit
import Foundation
import SwiftData
import os

/// Pilote la Live Activity du chrono.
///
/// Volontairement tolérant : si les Live Activities sont désactivées dans les
/// réglages, refusées par le système, ou absentes de cette build, **le chrono
/// continue de fonctionner normalement**. Le suivi du temps ne doit jamais dépendre
/// d'un ornement d'écran verrouillé.
///
/// La source de vérité est `Activity.activities`, **pas** une variable de ce type.
/// Une variable ne survit pas à une relance de l'app ; l'activité, si. C'est ce
/// décalage qui laissait l'îlot afficher un chrono éteint : après un redémarrage,
/// `end()` ne trouvait plus rien à terminer et `sync()` créait une **seconde**
/// activité au lieu de mettre à jour la première.
/// Trace d'exécution de l'îlot, lisible dans le journal unifié.
private let activityTrace = Logger(subsystem: "ch.polymestre", category: "îlot")

@MainActor
enum StudyActivityController {

    /// Ce qui a empêché la dernière tentative, en clair.
    ///
    /// `try?` avalait l'erreur : une Live Activity qui ne s'affiche jamais et une
    /// Live Activity qui s'affiche donnent exactement le même résultat visible —
    /// rien. Un ornement d'écran verrouillé peut échouer sans gravité, mais il ne
    /// doit pas échouer **en silence**.
    private(set) static var lastError: String?

    static var isEnabledBySystem: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Les activités réellement vivantes sur le système.
    private static var live: [Activity<StudyActivityAttributes>] {
        Activity<StudyActivityAttributes>.activities
    }

    /// Démarre l'activité si besoin, la met à jour sinon.
    ///
    /// Appelée à chaque changement d'état du chrono (démarrage, reprise, pause) :
    /// une seule entrée pour les deux cas évite d'avoir à suivre si une activité
    /// est déjà en cours.
    static func sync(attributes: StudyActivityAttributes,
                     state: StudyActivityAttributes.ContentState) {
        // Retenu ici, et pas chez l'appelant : l'écran Focus publie aussi
        // directement, et un cache tenu ailleurs deviendrait faux dès qu'un
        // chemin l'oublierait.
        publishedQuestions = state.questionsLabel
        publishedTitle = state.title
        publishedSubtitle = state.subtitle
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            lastError = String(localized: "Les Live Activities sont désactivées pour Polymestre.")
            AppLog.record(.warning, "îlot", "Live Activities désactivées dans les réglages")
            return
        }

        // Une seule activité à la fois : on reprend celle qui existe, même si elle
        // a été créée par une exécution précédente de l'app.
        if let existing = dedupe() {
            if LiveActivityBuilder.isNewer(existing.content.state, than: state.sessionStartedAt) {
                activityTrace.notice("activité d'une session plus récente (poussée par un autre appareil) : laissée telle quelle")
                return
            }
            Task { await existing.update(content(state)) }
            lastError = nil
            return
        }

        do {
            // `.token` : le Mac peut ensuite mettre l'îlot à jour par APNs
            // (via le relais), app de l'iPhone endormie.
            let created = try Activity.request(attributes: attributes,
                                               content: content(state),
                                               pushType: .token)
            observe(created)
            lastError = nil
            // Trace de vérification : c'est la seule façon de savoir, depuis un
            // terminal, si le **système** accepte l'activité — le simulateur ne
            // photographie pas l'îlot. `Logger` et non `print` : seule la sortie
            // unifiée est lisible depuis la ligne de commande.
            activityTrace.notice("activité créée \(created.id, privacy: .public) — \(self.live.count, privacy: .public) vivante(s)")
        } catch {
            // `\(…)` et non `\\(…)` : la seconde écrit un `\(` **littéral**, et le
            // message affichait le texte de l'expression au lieu de l'erreur.
            lastError = String(localized: "Démarrage impossible : \(error.localizedDescription)")
            AppLog.record(.error, "îlot", "Live Activity refusée par le système",
                          detail: error.localizedDescription)
        }
    }

    /// Termine **toutes** les activités du chrono.
    ///
    /// Toutes, et pas seulement celle dont ce processus se souvient : c'est la
    /// seule façon de garantir qu'aucun îlot ne survive à un chrono éteint.
    /// - Parameter session: la session qui se termine ici. Une activité d'une
    ///   session **plus récente** (démarrée ailleurs, poussée par APNs) reste.
    static func end(session: Date? = nil) {
        var ended = false
        for activity in live where !LiveActivityBuilder.isNewer(activity.content.state, than: session) {
            ended = true
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        if ended || live.isEmpty { TimerLink.shared.registerAPNs(kind: .update, token: nil) }
        lastError = nil
    }

    /// Ne garde qu'une activité : la plus récente, celle dont le relais
    /// détient le jeton.
    ///
    /// Deux chemins en créent : l'app (`Activity.request`) et le relais
    /// (démarrage par APNs quand le Mac lance le chrono). Ils se croisent —
    /// la notification silencieuse réveille l'app pendant que l'activité
    /// poussée s'installe — et l'îlot s'affichait en double.
    @discardableResult
    private static func dedupe() -> Activity<StudyActivityAttributes>? {
        let all = live
        guard let kept = all.last else { return nil }
        guard all.count > 1 else { return kept }
        activityTrace.notice("\(all.count, privacy: .public) activités vivantes : on n'en garde qu'une")
        for extra in all.dropLast() {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
        // Le jeton d'une activité terminée a pu passer en dernier au relais.
        if let token = kept.pushToken {
            TimerLink.shared.registerAPNs(kind: .update, token: token.hexString)
        }
        return kept
    }

    // MARK: Jetons APNs

    private static var observed: Set<String> = []

    /// Au lancement : suit les jetons des activités vivantes (y compris une
    /// activité démarrée par APNs pendant que l'app dormait) et le jeton de
    /// démarrage à distance (iOS 17.2+), et les donne au relais.
    static func observePushTokens() {
        for activity in live { observe(activity) }
        dedupe()
        Task { @MainActor in
            for await activity in Activity<StudyActivityAttributes>.activityUpdates {
                observe(activity)
                dedupe()
            }
        }
        if #available(iOS 17.2, *) {
            Task { @MainActor in
                for await token in Activity<StudyActivityAttributes>.pushToStartTokenUpdates {
                    TimerLink.shared.registerAPNs(kind: .start, token: token.hexString)
                }
            }
        }
    }

    private static func observe(_ activity: Activity<StudyActivityAttributes>) {
        guard observed.insert(activity.id).inserted else { return }
        Task { @MainActor in
            for await token in activity.pushTokenUpdates {
                TimerLink.shared.registerAPNs(kind: .update, token: token.hexString)
            }
        }
    }

    /// À appeler au lancement : l'activité doit refléter le chrono, ni plus ni moins.
    ///
    /// Sans ce raccord, une activité laissée par une exécution précédente — app
    /// quittée pendant une session, ou chrono abandonné — restait affichée pour
    /// toujours, y compris après que le chrono a été arrêté.
    static func reconcile(with state: FocusTimerState?) {
        let stillRunning = state?.isRestorable() == true
        guard !stillRunning else { return }
        // Une activité qui tourne pour une session venue d'ailleurs (poussée
        // par APNs pendant que l'app dormait) reste : le relais la terminera.
        for activity in live {
            let shown = activity.content.state
            if shown.sessionStartedAt != nil, shown.isRunning || shown.pomodoro?.isOnBreak == true { continue }
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Le nombre d'activités vivantes — pour le diagnostic.
    static var liveCount: Int { live.count }

    // MARK: Publier depuis le chrono persisté

    /// Le dernier compte de sous-questions publié.
    ///
    /// `ModelContext.didSave` se déclenche à chaque écriture — une série importée,
    /// une note modifiée. Republier l'activité à chaque fois enverrait des dizaines
    /// de mises à jour identiques à ActivityKit, qui les limite. On ne republie
    /// donc que si le compte affiché change réellement.
    private static var publishedQuestions: String?
    /// Les libellés publiés : un exercice renuméroté ou un cours renommé
    /// ailleurs dans l'app doit se voir sur l'écran verrouillé.
    private static var publishedTitle: String?
    private static var publishedSubtitle: String?

    /// Publie l'activité depuis l'état persisté du chrono.
    ///
    /// Le chemin unique : l'écran Focus, les commandes de l'écran verrouillé et le
    /// rafraîchissement sur écriture passent tous par ici.
    static func publish(_ state: FocusTimerState, container: AppContainer) {
        let context = ModelContext(container.modelContainer)
        let course = course(for: state, context: context)
        let exercise = exercise(for: state, course: course)
        let content = makeState(timer: state,
                                settings: container.settings.pomodoro,
                                exercise: exercise,
                                course: course)
        sync(attributes: attributes(for: state, course: course), state: content)
    }

    /// Republie l'activité si une case a été cochée ailleurs dans l'app.
    ///
    /// Cocher (a) dans la liste des exercices doit faire passer l'îlot de « 3/9 »
    /// à « 4/9 » : l'écran verrouillé et l'app ne peuvent pas montrer deux comptes
    /// différents de la même chose.
    static func refreshQuestions(container: AppContainer) {
        guard !live.isEmpty,
              let state = FocusTimerStore.load(),
              state.isRestorable() || state.isRunning else { return }
        let context = ModelContext(container.modelContainer)
        let course = course(for: state, context: context)
        let exercise = exercise(for: state, course: course)
        let content = makeState(timer: state,
                                settings: container.settings.pomodoro,
                                exercise: exercise,
                                course: course)
        guard content.questionsLabel != publishedQuestions
                || content.title != publishedTitle
                || content.subtitle != publishedSubtitle else { return }
        publish(state, container: container)
    }

    /// Le cours de la session, s'il y en a un.
    static func course(for state: FocusTimerState, context: ModelContext) -> Course? {
        TimerEngine.course(state.courseID, in: context)
    }

    /// L'exercice visé, s'il en existe un : seul porteur de sous-questions.
    static func exercise(for state: FocusTimerState, course: Course?) -> Exercise? {
        LiveActivityBuilder.exercise(for: state, course: course)
    }

    /// Ce qui ne change pas de la session : cours, type de travail, cible.
    static func attributes(for state: FocusTimerState,
                           course: Course?) -> StudyActivityAttributes {
        let value = LiveActivityBuilder.attributes(for: state, course: course)
        return StudyActivityAttributes(courseCode: value.courseCode, courseName: value.courseName,
                                       taskLabel: value.taskLabel, taskIcon: value.taskIcon, target: value.target)
    }

    static func targetLabel(_ state: FocusTimerState, course: Course?) -> String? {
        LiveActivityBuilder.targetLabel(state, course: course)
    }

    /// Construit l'état à publier (voir `LiveActivityBuilder`, partagé avec le Mac).
    static func makeState(timer: FocusTimerState,
                          settings: PomodoroSettings,
                          exercise: Exercise?,
                          course: Course? = nil,
                          now: Date = Date()) -> StudyActivityAttributes.ContentState {
        LiveActivityBuilder.state(timer: timer, settings: settings, exercise: exercise, course: course, now: now)
    }

    /// Lance une activité d'essai, pour vérifier l'îlot sans attendre un chrono.
    ///
    /// Le diagnostic avait un angle mort : impossible de distinguer « le système
    /// refuse l'activité » de « l'activité existe mais l'îlot ne l'affiche pas ».
    static func startTest() {
        sync(attributes: StudyActivityAttributes(courseCode: "TEST-100",
                                                  courseName: String(localized: "Essai"),
                                                  taskLabel: TaskType.theory.label,
                                                  taskIcon: TaskType.theory.icon,
                                                  target: String(localized: "Vérification")),
             state: StudyActivityAttributes.ContentState.make(elapsed: 90, running: true))
    }

    static let pausedFreshness = LiveActivityBuilder.pausedFreshness

    private static func content(_ state: StudyActivityAttributes.ContentState)
        -> ActivityContent<StudyActivityAttributes.ContentState> {
        ActivityContent(state: state, staleDate: LiveActivityBuilder.staleDate(for: state))
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
