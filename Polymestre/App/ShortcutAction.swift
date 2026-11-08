import UIKit
import UserNotifications

/// Les raccourcis de l'**écran d'accueil d'iOS** — appui long sur l'icône.
///
/// Ils doublent les tuiles de « Aujourd'hui », mais répondent à un autre moment :
/// on est sur l'écran d'accueil, pas dans l'app. « Importer une série » est le
/// geste de la semaine — un PDF reçu par mail ou Moodle, à ranger tout de suite.
///
/// Les types sont construits à partir de l'identifiant de bundle, comme le reste
/// du projet : renommer la cible ne casse donc pas les raccourcis en silence.
enum ShortcutAction: String {
    case importSeries
    case startTimer

    var type: String { "\(Bundle.main.bundleIdentifier ?? "").\(rawValue)" }

    init?(type: String) {
        guard let last = type.split(separator: ".").last,
              let value = ShortcutAction(rawValue: String(last)) else { return nil }
        self = value
    }

    var title: String {
        switch self {
        case .importSeries: return String(localized: "Importer une série")
        case .startTimer: return String(localized: "Lancer le chrono")
        }
    }
}

/// Reçoit le raccourci et le traduit en intention pour l'app.
///
/// SwiftUI n'expose pas `performActionFor` : il faut un délégué. Celui-ci ne fait
/// que déposer l'intention sur le routeur, que les écrans observent — aucun travail
/// de données ici, donc aucun risque d'agir avant que l'app soit prête.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Avant la fin du lancement : un tap sur une notification qui a lancé
        // l'app arrive juste après.
        UNUserNotificationCenter.current().delegate = self
        // Le jeton de l'appareil : un verrou lancé sur un autre appareil le
        // réveille (notification silencieuse du relais).
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        MainActor.assumeIsolated { TimerLink.shared.registerAPNs(kind: .device, token: hex) }
    }

    /// Le relais : un verrou a commencé ou fini ailleurs. L'état (chiffré) est
    /// dans la notification ; il s'applique comme s'il arrivait par la
    /// WebSocket, et le bouclier du Temps d'écran suit (`StudyLock.sync`).
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await MainActor.run {
            if let wake = userInfo["st"] as? [String: Any], let sealed = wake["m"] as? String,
               let music = TimerLink.shared.openMusicWake(sealed) {
                // La musique passée depuis le Mac : elle reprend ici, même app fermée.
                StudyMusic.shared.receive(music)
            } else if let wake = userInfo["st"] as? [String: Any], let sealed = wake["d"] as? String,
               let snapshot = TimerLink.shared.openWake(sealed) {
                CloudRelay.receivedFromLink(snapshot)
            } else {
                NSUbiquitousKeyValueStore.default.synchronize()
            }
            AppRuntime.container?.focus.applyRemote()
        }
        return .newData
    }

    /// Une nouveauté Moodle ouvre son cours, sur la bonne page.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        // « Le cours commence » : le bureau du cours, en direct.
        if let raw = info["lectureCourseID"] as? String, let id = UUID(uuidString: raw) {
            await MainActor.run { AppRuntime.container?.router.openLectureDesk(courseID: id) }
            return
        }
        guard let raw = info["courseID"] as? String, let id = UUID(uuidString: raw) else { return }
        let section: CourseDetailView.Section = (info["section"] as? String) == "theory" ? .theory : .exercises
        await MainActor.run {
            guard let container = AppRuntime.container else { return }
            container.router.showingProfile = false
            container.router.showingStats = false
            container.router.showingFocus = false
            container.router.showingAgenda = false
            container.router.openCourse(id, section: section)
        }
    }

    /// App ouverte : une nouveauté Moodle s'affiche quand même (bannière) ; les
    /// autres rappels (chrono, échéances) gardent leur comportement d'avant —
    /// l'écran les montre déjà.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        notification.request.content.categoryIdentifier == "moodle-news" ? [.banner, .list, .sound] : []
    }

    func application(_ application: UIApplication,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        guard let shortcut = ShortcutAction(type: shortcutItem.type),
              let container = AppRuntime.container else {
            completionHandler(false)
            return
        }
        MainActor.assumeIsolated {
            container.router.shortcut = shortcut
        }
        completionHandler(true)
    }
}
