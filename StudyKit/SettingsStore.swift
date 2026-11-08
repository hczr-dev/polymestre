import Foundation
import Observation

/// Réglages persistés dans `UserDefaults`. Observables par SwiftUI.
@Observable
final class SettingsStore {
    private enum Key {
        static let hoursPerCredit = "settings.hoursPerCredit"
        static let weeklyGoalMinutes = "settings.weeklyGoalMinutes"
        static let pomodoroFocusMinutes = "settings.pomodoroFocusMinutes"
        static let pomodoroBreakMinutes = "settings.pomodoroBreakMinutes"
        static let pomodoroLongBreakMinutes = "settings.pomodoroLongBreakMinutes"
        static let pomodoroLongBreakEvery = "settings.pomodoroLongBreakEvery"
        static let pomodoroAutoStartFocus = "settings.pomodoroAutoStartFocus"
        static let pomodoroDefault = "settings.pomodoroDefault"
        static let displayName = "settings.displayName"
        static let sectionCode = "settings.sectionCode"
        static let hasCompletedOnboarding = "settings.hasCompletedOnboarding"
        static let deviceHasOnboarded = "settings.deviceHasOnboarded"
        static let anonymousInLeaderboards = "settings.anonymousInLeaderboards"
        static let dailyReminderEnabled = "settings.dailyReminderEnabled"
        static let dailyReminderHour = "settings.dailyReminderHour"
        static let weeklyRecapEnabled = "settings.weeklyRecapEnabled"
        static let todoistToken = "settings.todoistToken"
        static let googleClientID = "settings.googleClientID"
        static let googleClientSecret = "settings.googleClientSecret"
        static let googleRefreshToken = "settings.googleRefreshToken"
        static let tickTickToken = "settings.tickTickToken"
        static let notionToken = "settings.notionToken"
        static let notionDatabaseID = "settings.notionDatabaseID"
        static let webhookURL = "settings.webhookURL"
        static let thingsEnabled = "settings.thingsEnabled"
        static let timetableURLString = "settings.timetableURLString"
        static let shareProgressWithGroups = "settings.shareProgressWithGroups"
        static let trackAttendance = "settings.trackAttendance"
        static let classStartNotice = "settings.classStartNotice"
        static let hasSeededSampleData = "settings.hasSeededSampleData"
        static let focusShortcuts = "settings.focusShortcuts"
        static let ankiLastSync = "settings.ankiLastSync"
        static let aiExtractionEnabled = "settings.aiExtractionEnabled"
        /// Anciennes clés du « service perso » (clé d'API saisie), retiré :
        /// effacées au lancement pour ne pas garder une clé en clair.
        static let legacyAI = ["settings.aiEndpoint", "settings.aiAPIKey", "settings.aiModel"]
        static let contentAutoRefresh = "settings.contentAutoRefresh"
        static let contentLastRefresh = "settings.contentLastRefresh"
        static let contentRefreshNews = "settings.contentRefreshNews"
        static let moodleNewsEnabled = "settings.moodleNewsEnabled"
        static let moodleNewsKinds = "settings.moodleNewsKinds"
        static let moodleNewsMuted = "settings.moodleNewsMuted"
        static let quietHoursEnabled = "settings.quietHoursEnabled"
        static let quietHoursStart = "settings.quietHoursStart"
        static let quietHoursEnd = "settings.quietHoursEnd"
        static let offlineEnabled = "settings.offlineEnabled"
        static let offlineSolutions = "settings.offlineSolutions"
        static let offlineWifiOnly = "settings.offlineWifiOnly"
        static let offlineLimitMB = "settings.offlineLimitMB"
        static let assistantToken = "settings.assistantToken"
        static let assistantFiles = "settings.assistantFiles"
        static let assistantLastSync = "settings.assistantLastSync"
    }

    private let defaults: UserDefaults

    // MARK: Charge EPFL
    /// Heures de travail attendues par crédit ECTS (EPFL : ~25–30 h).
    var hoursPerCredit: Double { didSet { defaults.set(hoursPerCredit, forKey: Key.hoursPerCredit); share(Key.hoursPerCredit, hoursPerCredit) } }
    /// L'objectif d'étude de la semaine, en minutes — **un seul**, sur tous les
    /// appareils (le jour en vise le septième). 0 : celui de la charge EPFL des
    /// cours suivis (`WorkloadEngine`).
    var weeklyGoalMinutes: Int { didSet { defaults.set(weeklyGoalMinutes, forKey: Key.weeklyGoalMinutes); share(Key.weeklyGoalMinutes, weeklyGoalMinutes) } }

    // MARK: Identité académique
    var displayName: String { didSet { defaults.set(displayName, forKey: Key.displayName); share(Key.displayName, displayName) } }
    /// Section EPFL choisie (code, ex : « IN »).
    var sectionCode: String { didSet { defaults.set(sectionCode, forKey: Key.sectionCode); share(Key.sectionCode, sectionCode) } }
    var hasCompletedOnboarding: Bool {
        didSet {
            defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding)
            if hasCompletedOnboarding { deviceHasOnboarded = true }
        }
    }
    /// Cet appareil a déjà fini l'accueil une fois. « Revoir l'accueil » ne
    /// le remet pas à faux : seul un **nouvel** appareil saute l'accueil quand
    /// ses cours arrivent par iCloud.
    var deviceHasOnboarded: Bool { didSet { defaults.set(deviceHasOnboarded, forKey: Key.deviceHasOnboarded) } }

    var section: EPFLSection? { EPFLCatalog.section(code: sectionCode) }

    // MARK: Pomodoro
    var pomodoroFocusMinutes: Int { didSet { defaults.set(pomodoroFocusMinutes, forKey: Key.pomodoroFocusMinutes); share(Key.pomodoroFocusMinutes, pomodoroFocusMinutes) } }
    /// La pause courte. La clé historique est conservée : les réglages déjà
    /// faits ne sont pas perdus.
    var pomodoroBreakMinutes: Int { didSet { defaults.set(pomodoroBreakMinutes, forKey: Key.pomodoroBreakMinutes); share(Key.pomodoroBreakMinutes, pomodoroBreakMinutes) } }
    var pomodoroLongBreakMinutes: Int { didSet { defaults.set(pomodoroLongBreakMinutes, forKey: Key.pomodoroLongBreakMinutes); share(Key.pomodoroLongBreakMinutes, pomodoroLongBreakMinutes) } }
    var pomodoroLongBreakEvery: Int { didSet { defaults.set(pomodoroLongBreakEvery, forKey: Key.pomodoroLongBreakEvery); share(Key.pomodoroLongBreakEvery, pomodoroLongBreakEvery) } }
    var pomodoroAutoStartFocus: Bool { didSet { defaults.set(pomodoroAutoStartFocus, forKey: Key.pomodoroAutoStartFocus); share(Key.pomodoroAutoStartFocus, pomodoroAutoStartFocus) } }
    /// Une nouvelle session démarre-t-elle en Pomodoro ?
    var pomodoroDefault: Bool { didSet { defaults.set(pomodoroDefault, forKey: Key.pomodoroDefault); share(Key.pomodoroDefault, pomodoroDefault) } }

    /// Le cycle tel que la logique pure l'attend.
    var pomodoro: PomodoroSettings {
        PomodoroSettings(focusMinutes: pomodoroFocusMinutes,
                         shortBreakMinutes: pomodoroBreakMinutes,
                         longBreakMinutes: pomodoroLongBreakMinutes,
                         longBreakEvery: pomodoroLongBreakEvery,
                         autoStartFocus: pomodoroAutoStartFocus)
    }

    // MARK: Suivi
    /// Suivre la présence en amphi (heures de cours réelles).
    var trackAttendance: Bool { didSet { defaults.set(trackAttendance, forKey: Key.trackAttendance) } }
    /// « Le cours commence » : une notification qui ouvre le bureau du cours.
    var classStartNotice: Bool { didSet { defaults.set(classStartNotice, forKey: Key.classStartNotice) } }

    // MARK: Vie privée
    var anonymousInLeaderboards: Bool { didSet { defaults.set(anonymousInLeaderboards, forKey: Key.anonymousInLeaderboards) } }
    var shareProgressWithGroups: Bool { didSet { defaults.set(shareProgressWithGroups, forKey: Key.shareProgressWithGroups) } }

    // MARK: Notifications
    var dailyReminderEnabled: Bool { didSet { defaults.set(dailyReminderEnabled, forKey: Key.dailyReminderEnabled) } }
    var dailyReminderHour: Int { didSet { defaults.set(dailyReminderHour, forKey: Key.dailyReminderHour) } }
    var weeklyRecapEnabled: Bool { didSet { defaults.set(weeklyRecapEnabled, forKey: Key.weeklyRecapEnabled) } }

    // MARK: Intégrations — tâches
    var todoistToken: String { didSet { defaults.set(todoistToken, forKey: Key.todoistToken) } }
    var googleClientID: String { didSet { defaults.set(googleClientID, forKey: Key.googleClientID) } }
    var googleClientSecret: String { didSet { defaults.set(googleClientSecret, forKey: Key.googleClientSecret) } }
    var googleRefreshToken: String { didSet { defaults.set(googleRefreshToken, forKey: Key.googleRefreshToken) } }
    var tickTickToken: String { didSet { defaults.set(tickTickToken, forKey: Key.tickTickToken) } }
    var notionToken: String { didSet { defaults.set(notionToken, forKey: Key.notionToken) } }
    var notionDatabaseID: String { didSet { defaults.set(notionDatabaseID, forKey: Key.notionDatabaseID) } }
    var webhookURL: String { didSet { defaults.set(webhookURL, forKey: Key.webhookURL) } }
    var thingsEnabled: Bool { didSet { defaults.set(thingsEnabled, forKey: Key.thingsEnabled) } }

    // MARK: Intégrations — calendrier & social
    /// URL du flux iCalendar « Mon horaire » (EPFL) ou de tout autre calendrier.
    var timetableURLString: String { didSet { defaults.set(timetableURLString, forKey: Key.timetableURLString) } }

    // MARK: Import intelligent (analyse des PDF)
    /// Proposer l'analyse par modèle de langage à l'import d'un PDF.
    var aiExtractionEnabled: Bool { didSet { defaults.set(aiExtractionEnabled, forKey: Key.aiExtractionEnabled) } }

    // MARK: Anki
    /// Dernier relevé réussi du temps Anki.
    var ankiLastSync: Date? { didSet { defaults.set(ankiLastSync, forKey: Key.ankiLastSync) } }

    // MARK: Contenu des cours
    /// Relire Moodle et Botafogo tout seul (au plus deux fois par jour) pour
    /// ajouter la série de la semaine dès qu'elle est publiée.
    var contentAutoRefresh: Bool { didSet { defaults.set(contentAutoRefresh, forKey: Key.contentAutoRefresh) } }
    var contentLastRefresh: Date? { didSet { defaults.set(contentLastRefresh, forKey: Key.contentLastRefresh) } }
    /// « Moodle : Série 4 ajoutée en MATH-101 » — affiché sur l'accueil
    /// jusqu'à ce qu'on le ferme ; vide quand il n'y a rien de neuf.
    ///
    /// **Partagé** par iCloud (clé-valeur) : la relecture se fait sur un seul
    /// appareil, ce qu'elle trouve s'annonce sur tous, et le fermer sur l'un le
    /// ferme sur les autres.
    var contentRefreshNews: String {
        didSet {
            defaults.set(contentRefreshNews, forKey: Key.contentRefreshNews)
            guard !applyingShared, contentRefreshNews != oldValue else { return }
            NSUbiquitousKeyValueStore.default.set(contentRefreshNews, forKey: Self.sharedNewsKey)
            NSUbiquitousKeyValueStore.default.synchronize()
        }
    }

    private static let sharedNewsKey = "content.news"
    @ObservationIgnored private var applyingShared = false
    @ObservationIgnored private var sharedObserver: NSObjectProtocol?

    /// Les réglages d'étude **partagés** par iCloud (clé-valeur) : nom,
    /// section, cycle Pomodoro, objectif de la semaine, charge par crédit.
    /// Réglés sur l'iPhone, ils valent sur le Mac (et inversement).
    private func share(_ key: String, _ value: Any) {
        guard !applyingShared else { return }
        NSUbiquitousKeyValueStore.default.set(value, forKey: "pref." + key)
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    /// Reprend ce qu'un autre appareil a écrit.
    private func applyShared() {
        let store = NSUbiquitousKeyValueStore.default
        applyingShared = true
        defer { applyingShared = false }
        if let news = store.string(forKey: Self.sharedNewsKey), news != contentRefreshNews { contentRefreshNews = news }
        func value<T: Equatable>(_ key: String, _ current: T) -> T? {
            guard let shared = store.object(forKey: "pref." + key) as? T, shared != current else { return nil }
            return shared
        }
        if let v = value(Key.hoursPerCredit, hoursPerCredit) { hoursPerCredit = v }
        if let v = value(Key.weeklyGoalMinutes, weeklyGoalMinutes) { weeklyGoalMinutes = v }
        if let v = value(Key.displayName, displayName) { displayName = v }
        if let v = value(Key.sectionCode, sectionCode) { sectionCode = v }
        if let v = value(Key.pomodoroFocusMinutes, pomodoroFocusMinutes) { pomodoroFocusMinutes = v }
        if let v = value(Key.pomodoroBreakMinutes, pomodoroBreakMinutes) { pomodoroBreakMinutes = v }
        if let v = value(Key.pomodoroLongBreakMinutes, pomodoroLongBreakMinutes) { pomodoroLongBreakMinutes = v }
        if let v = value(Key.pomodoroLongBreakEvery, pomodoroLongBreakEvery) { pomodoroLongBreakEvery = v }
        if let v = value(Key.pomodoroAutoStartFocus, pomodoroAutoStartFocus) { pomodoroAutoStartFocus = v }
        if let v = value(Key.pomodoroDefault, pomodoroDefault) { pomodoroDefault = v }
    }

    // MARK: Nouveautés Moodle
    /// Prévenir d'une série, d'un corrigé, d'un rendu publiés sur Moodle, même
    /// app fermée (relevé en arrière-plan).
    var moodleNewsEnabled: Bool { didSet { defaults.set(moodleNewsEnabled, forKey: Key.moodleNewsEnabled) } }
    var moodleNewsKindsRaw: String { didSet { defaults.set(moodleNewsKindsRaw, forKey: Key.moodleNewsKinds) } }
    var moodleNewsKinds: Set<MoodleNews.Kind> {
        get { MoodleNews.Kind.decode(moodleNewsKindsRaw) }
        set { moodleNewsKindsRaw = MoodleNews.Kind.encode(newValue) }
    }
    /// Les cours tus (identifiants, séparés par des virgules).
    var moodleNewsMutedRaw: String { didSet { defaults.set(moodleNewsMutedRaw, forKey: Key.moodleNewsMuted) } }
    var moodleNewsMuted: Set<UUID> {
        get { Set(moodleNewsMutedRaw.split(separator: ",").compactMap { UUID(uuidString: String($0)) }) }
        set { moodleNewsMutedRaw = newValue.map(\.uuidString).sorted().joined(separator: ",") }
    }
    /// Pas de nouvelle la nuit : elle attend la fin des heures calmes.
    var quietHoursEnabled: Bool { didSet { defaults.set(quietHoursEnabled, forKey: Key.quietHoursEnabled) } }
    var quietHoursStart: Int { didSet { defaults.set(quietHoursStart, forKey: Key.quietHoursStart) } }
    var quietHoursEnd: Int { didSet { defaults.set(quietHoursEnd, forKey: Key.quietHoursEnd) } }

    // MARK: Hors ligne
    /// Garder les énoncés (et les corrigés) sur l'iPhone. Éteint par défaut :
    /// c'est de la place.
    var offlineEnabled: Bool { didSet { defaults.set(offlineEnabled, forKey: Key.offlineEnabled) } }
    var offlineSolutions: Bool { didSet { defaults.set(offlineSolutions, forKey: Key.offlineSolutions) } }
    var offlineWifiOnly: Bool { didSet { defaults.set(offlineWifiOnly, forKey: Key.offlineWifiOnly) } }
    /// Plafond, en mégaoctets.
    var offlineLimitMB: Int { didSet { defaults.set(offlineLimitMB, forKey: Key.offlineLimitMB) } }

    // MARK: Assistant IA (MCP)
    /// Jeton secret qui relie l'app à son serveur MCP. Vide = pas relié.
    var assistantToken: String { didSet { defaults.set(assistantToken, forKey: Key.assistantToken) } }
    var assistantLastSync: Date? { didSet { defaults.set(assistantLastSync, forKey: Key.assistantLastSync) } }
    /// Envoyer aussi à l'assistant les **fichiers** (énoncés et corrigés déjà sur
    /// l'iPhone, fichiers ajoutés) et les **notes** (notes de cours, fiche,
    /// corrigés rédigés). Éteint par défaut : c'est ce qui sort le plus de
    /// l'appareil. Coupé, le serveur efface ce qu'il avait reçu.
    var assistantFiles: Bool { didSet { defaults.set(assistantFiles, forKey: Key.assistantFiles) } }

    // MARK: Chrono
    /// Raccourcis du chrono, composés par l'étudiant·e.
    ///
    /// Stockés en JSON plutôt qu'en liste de clés : l'ordre compte, et un tableau
    /// se relit d'un coup.
    var focusShortcutsRaw: String { didSet { defaults.set(focusShortcutsRaw, forKey: Key.focusShortcuts) } }

    var focusShortcuts: [FocusShortcut] {
        get { FocusShortcut.decode(focusShortcutsRaw) }
        set { focusShortcutsRaw = FocusShortcut.encode(newValue) }
    }

    // MARK: État interne
    var hasSeededSampleData: Bool { didSet { defaults.set(hasSeededSampleData, forKey: Key.hasSeededSampleData) } }

    /// « Nouveau dans tes cours » : une ligne de plus, sans répéter ce qui y est
    /// déjà — une série n'y figure qu'une fois, sa dernière nouvelle (`NewsLines`).
    static func mergedNews(_ existing: String, adding line: String) -> String {
        NewsLines.merged(existing, adding: line)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hoursPerCredit = defaults.object(forKey: Key.hoursPerCredit) as? Double ?? 30
        self.weeklyGoalMinutes = defaults.integer(forKey: Key.weeklyGoalMinutes)
        self.pomodoroFocusMinutes = defaults.object(forKey: Key.pomodoroFocusMinutes) as? Int ?? 25
        self.pomodoroBreakMinutes = defaults.object(forKey: Key.pomodoroBreakMinutes) as? Int ?? 5
        self.pomodoroLongBreakMinutes = defaults.object(forKey: Key.pomodoroLongBreakMinutes) as? Int ?? 15
        self.pomodoroLongBreakEvery = defaults.object(forKey: Key.pomodoroLongBreakEvery) as? Int ?? 4
        self.pomodoroAutoStartFocus = defaults.object(forKey: Key.pomodoroAutoStartFocus) as? Bool ?? false
        self.pomodoroDefault = defaults.object(forKey: Key.pomodoroDefault) as? Bool ?? false
        self.displayName = defaults.string(forKey: Key.displayName) ?? ""
        self.sectionCode = defaults.string(forKey: Key.sectionCode) ?? ""
        self.hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
        self.deviceHasOnboarded = defaults.bool(forKey: Key.deviceHasOnboarded) || defaults.bool(forKey: Key.hasCompletedOnboarding)
        self.trackAttendance = defaults.object(forKey: Key.trackAttendance) as? Bool ?? true
        self.classStartNotice = defaults.object(forKey: Key.classStartNotice) as? Bool ?? true
        self.anonymousInLeaderboards = defaults.bool(forKey: Key.anonymousInLeaderboards)
        self.shareProgressWithGroups = defaults.object(forKey: Key.shareProgressWithGroups) as? Bool ?? true
        self.dailyReminderEnabled = defaults.object(forKey: Key.dailyReminderEnabled) as? Bool ?? true
        self.dailyReminderHour = defaults.object(forKey: Key.dailyReminderHour) as? Int ?? 19
        self.weeklyRecapEnabled = defaults.object(forKey: Key.weeklyRecapEnabled) as? Bool ?? true
        self.todoistToken = defaults.string(forKey: Key.todoistToken) ?? ""
        self.googleClientID = defaults.string(forKey: Key.googleClientID) ?? ""
        self.googleClientSecret = defaults.string(forKey: Key.googleClientSecret) ?? ""
        self.googleRefreshToken = defaults.string(forKey: Key.googleRefreshToken) ?? ""
        self.tickTickToken = defaults.string(forKey: Key.tickTickToken) ?? ""
        self.notionToken = defaults.string(forKey: Key.notionToken) ?? ""
        self.notionDatabaseID = defaults.string(forKey: Key.notionDatabaseID) ?? ""
        self.webhookURL = defaults.string(forKey: Key.webhookURL) ?? ""
        self.thingsEnabled = defaults.bool(forKey: Key.thingsEnabled)
        self.timetableURLString = defaults.string(forKey: Key.timetableURLString) ?? ""
        self.hasSeededSampleData = defaults.bool(forKey: Key.hasSeededSampleData)
        self.focusShortcutsRaw = defaults.string(forKey: Key.focusShortcuts) ?? ""
        self.ankiLastSync = defaults.object(forKey: Key.ankiLastSync) as? Date
        self.contentAutoRefresh = defaults.object(forKey: Key.contentAutoRefresh) as? Bool ?? true
        self.contentLastRefresh = defaults.object(forKey: Key.contentLastRefresh) as? Date
        self.contentRefreshNews = defaults.string(forKey: Key.contentRefreshNews) ?? ""
        self.moodleNewsEnabled = defaults.object(forKey: Key.moodleNewsEnabled) as? Bool ?? true
        self.moodleNewsKindsRaw = defaults.string(forKey: Key.moodleNewsKinds) ?? MoodleNews.Kind.encode(MoodleNews.Kind.defaults)
        self.moodleNewsMutedRaw = defaults.string(forKey: Key.moodleNewsMuted) ?? ""
        self.quietHoursEnabled = defaults.object(forKey: Key.quietHoursEnabled) as? Bool ?? true
        self.quietHoursStart = defaults.object(forKey: Key.quietHoursStart) as? Int ?? 22
        self.quietHoursEnd = defaults.object(forKey: Key.quietHoursEnd) as? Int ?? 8
        self.offlineEnabled = defaults.bool(forKey: Key.offlineEnabled)
        self.offlineSolutions = defaults.object(forKey: Key.offlineSolutions) as? Bool ?? true
        self.offlineWifiOnly = defaults.object(forKey: Key.offlineWifiOnly) as? Bool ?? true
        self.offlineLimitMB = defaults.object(forKey: Key.offlineLimitMB) as? Int ?? 500
        self.assistantToken = defaults.string(forKey: Key.assistantToken) ?? ""
        self.assistantLastSync = defaults.object(forKey: Key.assistantLastSync) as? Date
        self.assistantFiles = defaults.bool(forKey: Key.assistantFiles)
        self.aiExtractionEnabled = defaults.object(forKey: Key.aiExtractionEnabled) as? Bool ?? true
        for key in Key.legacyAI { defaults.removeObject(forKey: key) }
        // Ce qu'iCloud ne connaît pas encore part d'ici ; ce qu'il connaît
        // l'emporte (le réglage fait sur l'autre appareil).
        let store = NSUbiquitousKeyValueStore.default
        let local: [String: Any] = [Key.hoursPerCredit: hoursPerCredit, Key.weeklyGoalMinutes: weeklyGoalMinutes,
                                    Key.displayName: displayName, Key.sectionCode: sectionCode,
                                    Key.pomodoroFocusMinutes: pomodoroFocusMinutes, Key.pomodoroBreakMinutes: pomodoroBreakMinutes,
                                    Key.pomodoroLongBreakMinutes: pomodoroLongBreakMinutes,
                                    Key.pomodoroLongBreakEvery: pomodoroLongBreakEvery,
                                    Key.pomodoroAutoStartFocus: pomodoroAutoStartFocus, Key.pomodoroDefault: pomodoroDefault]
        for (key, value) in local where store.object(forKey: "pref." + key) == nil
            && defaults.object(forKey: key) != nil {
            store.set(value, forKey: "pref." + key)
        }
        applyShared()
        sharedObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyShared()
        }
    }

}
