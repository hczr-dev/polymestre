import Foundation
import CryptoKit
import Network
import Observation
import SwiftData

/// Les énoncés et corrigés gardés sur l'iPhone, pour les ouvrir sans réseau
/// (métro, amphi saturé, avion).
///
/// Sur demande seulement (réglage éteint par défaut) et sous plafond : la
/// semaine en cours d'abord, puis le passé récent (`OfflinePlan`). En Wi-Fi
/// seulement si on le veut, jamais en mode données réduites. Les fichiers
/// vivent dans Application Support, hors sauvegarde iCloud (ils se
/// retéléchargent), nommés d'après leur adresse : pas d'index à tenir.
@MainActor
@Observable
final class OfflineLibrary {
    static let shared = OfflineLibrary()

    private(set) var usedBytes = 0
    private(set) var fileCount = 0
    private(set) var isSyncing = false
    /// Pourquoi rien n'a été téléchargé, quand c'est voulu (« en attente du Wi-Fi »).
    private(set) var waitingReason: String?

    /// Les adresses qui n'ont pas donné de PDF : pas de nouvel essai avant
    /// le prochain lancement.
    @ObservationIgnored private var failed = Set<String>()

    private init() {
        measure()
    }

    // MARK: Fichiers

    private static var folder: URL {
        var folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Offline", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
        }
        return folder
    }

    nonisolated static func key(for url: URL) -> String {
        SiteLinks.normalize(url).absoluteString
    }

    private static func file(forKey key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(digest + ".pdf")
    }

    /// L'énoncé a changé à la source : la copie hors ligne est reprise au
    /// prochain passage.
    func forget(_ url: URL) {
        try? FileManager.default.removeItem(at: Self.file(forKey: Self.key(for: url)))
        measure()
    }

    /// Le fichier gardé pour cette adresse, s'il existe.
    func localFile(for url: URL) -> URL? {
        let file = Self.file(forKey: Self.key(for: url))
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    private func size(of file: URL) -> Int {
        (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private func measure() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let pdfs = files.filter { $0.pathExtension == "pdf" }
        fileCount = pdfs.count
        usedBytes = pdfs.reduce(0) { $0 + size(of: $1) }
    }

    /// Tout effacer (le réglage éteint, ou « Supprimer les fichiers »).
    func removeAll() {
        try? FileManager.default.removeItem(at: Self.folder)
        failed.removeAll()
        measure()
    }

    // MARK: Synchronisation

    /// Télécharge ce qui manque, dans l'ordre, jusqu'au plafond ; retire ce qui
    /// n'est plus voulu ou ne tient plus.
    func sync(context: ModelContext, settings: SettingsStore) async {
        guard settings.offlineEnabled, !isSyncing else { return }
        let path = await Self.currentPath()
        guard path.status == .satisfied else { waitingReason = String(localized: "pas de réseau"); return }
        if path.isConstrained { waitingReason = String(localized: "mode données réduites"); return }
        if settings.offlineWifiOnly, path.isExpensive { waitingReason = String(localized: "en attente du Wi-Fi"); return }
        waitingReason = nil
        isSyncing = true
        defer { isSyncing = false; measure() }

        let ordered = Self.candidates(context: context, includeSolutions: settings.offlineSolutions)
        let limit = settings.offlineLimitMB * 1_000_000
        var sizes: [String: Int] = [:]
        var total = 0
        for (candidate, url) in ordered {
            let destination = Self.file(forKey: candidate.key)
            if FileManager.default.fileExists(atPath: destination.path) {
                let bytes = size(of: destination)
                guard total + bytes <= limit else { break }
                sizes[candidate.key] = bytes
                total += bytes
                continue
            }
            guard !failed.contains(candidate.key) else { continue }
            guard let downloaded = try? await SeriesPDFStore.download(url) else {
                failed.insert(candidate.key)
                continue
            }
            let bytes = size(of: downloaded)
            guard total + bytes <= limit else {
                try? FileManager.default.removeItem(at: downloaded)
                break
            }
            try? FileManager.default.removeItem(at: destination)
            guard (try? FileManager.default.moveItem(at: downloaded, to: destination)) != nil else { continue }
            sizes[candidate.key] = bytes
            total += bytes
            measure()
        }

        // Ce qui n'est plus dans la liste (série supprimée, corrigés décochés,
        // plafond baissé) s'en va.
        let kept = Set(OfflinePlan.kept(ordered.map(\.0.key), sizes: sizes, limit: limit).map { Self.file(forKey: $0).lastPathComponent })
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where !kept.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
        AppLog.record(.info, "import", "Hors ligne", detail: "\(sizes.count) document(s) · \(OfflinePlan.label(bytes: total))")
    }

    /// Les énoncés et corrigés des cours suivis, du plus utile au moins utile.
    private static func candidates(context: ModelContext, includeSolutions: Bool) -> [(OfflinePlan.Candidate, URL)] {
        let courses = ((try? context.fetch(FetchDescriptor<Course>())) ?? []).filter(\.isTracked)
        var urls: [String: URL] = [:]
        var list: [OfflinePlan.Candidate] = []
        for course in courses {
            let current = course.currentWeek
            for series in course.series {
                if let url = SeriesPDFStore.documentURL(series.urlString) {
                    let key = key(for: url)
                    urls[key] = url
                    list.append(.init(key: key, week: series.plannedWeek, isSolution: false, currentWeek: current))
                }
                // Un corrigé pas encore publié n'est pas téléchargé en avance.
                if series.solutionsAt.map({ $0 <= Date() }) ?? true,
                   let url = SeriesPDFStore.documentURL(series.solutionURLString) {
                    let key = key(for: url)
                    urls[key] = url
                    list.append(.init(key: key, week: series.plannedWeek, isSolution: true, currentWeek: current))
                }
            }
        }
        return OfflinePlan.order(list, includeSolutions: includeSolutions).compactMap { candidate in
            urls[candidate.key].map { (candidate, $0) }
        }
    }

    /// L'état du réseau, une fois.
    private static func currentPath() async -> NWPath {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                continuation.resume(returning: path)
            }
            monitor.start(queue: DispatchQueue(label: "offline.path"))
        }
    }
}
