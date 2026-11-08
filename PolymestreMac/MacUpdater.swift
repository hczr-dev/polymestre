import AppKit
import OSLog

/// « Une nouvelle version est disponible » : le Mac est distribué en Developer ID
/// (une image disque), sans App Store pour le dire. Une lecture de
/// `mac/latest.json` au lancement et au réveil, au plus une fois par jour ; la
/// dernière réponse est gardée, pour que l'annonce survive à un relancement
/// sans relire le réseau.
@MainActor @Observable
final class MacUpdater {
    static let shared = MacUpdater()

    /// La build plus récente que celle qui tourne (`nil` : à jour, ou pas su).
    private(set) var available: MacUpdateFeed?
    private(set) var checking = false
    /// « À jour » ou la raison d'un échec, après une recherche à la main.
    private(set) var status: String?

    private let log = Logger(subsystem: "ch.polymestre.mac", category: "update")
    private let lastCheckKey = "mac.update.lastCheck"
    private let cachedKey = "mac.update.feed"

    private init() {
        available = UserDefaults.standard.data(forKey: cachedKey)
            .flatMap(MacUpdateFeed.decode)
            .flatMap { $0.isNewer(thanBuild: AppDistribution.build) ? $0 : nil }
    }

    /// Au lancement et au réveil : rien si la dernière lecture date de moins d'un jour.
    func checkIfDue() {
        guard MacUpdateFeed.isDue(lastCheck: UserDefaults.standard.object(forKey: lastCheckKey) as? Date) else { return }
        Task { await check(manual: false) }
    }

    func check(manual: Bool) async {
        guard !checking, let host = AppDistribution.siteHost, let url = MacUpdateFeed.feedURL(siteHost: host) else { return }
        checking = true
        defer { checking = false }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Polymestre/\(AppDistribution.versionLabel)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let feed = MacUpdateFeed.decode(data) else {
                status = String(localized: "Le flux des mises à jour est illisible.")
                return
            }
            UserDefaults.standard.set(Date(), forKey: lastCheckKey)
            UserDefaults.standard.set(data, forKey: cachedKey)
            available = feed.isNewer(thanBuild: AppDistribution.build) ? feed : nil
            status = available == nil && manual ? String(localized: "Polymestre est à jour.") : nil
            if let available { log.notice("mise à jour disponible : \(available.version, privacy: .public) (\(available.build))") }
        } catch {
            status = manual ? String(localized: "Pas de réponse du site : \(error.localizedDescription)") : nil
        }
    }

    func download() {
        guard let available else { return }
        NSWorkspace.shared.open(available.url)
    }
}

/// Ce que dit le courriel « Signaler un problème » de la machine.
enum MacFeedback {
    static var device: String {
        "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    /// Le journal n'est lu qu'au geste, pas à chaque rendu du menu.
    @MainActor static func send() {
        guard let address = AppDistribution.feedbackAddress,
              let url = FeedbackMail.url(to: address, version: AppDistribution.versionLabel,
                                         device: device, entries: AppLog.load()) else { return }
        NSWorkspace.shared.open(url)
    }
}
