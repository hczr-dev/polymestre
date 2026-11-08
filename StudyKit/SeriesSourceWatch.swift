import CryptoKit
import Foundation
import PDFKit

/// Un énoncé qui change à la source est relu.
///
/// L'app lisait l'énoncé d'une série **une fois** : une série qui avait des
/// exercices n'était plus jamais relue. Quand l'enseignant révise son PDF — la
/// semaine 6 d'AICC, un exercice ajouté en tête et trois retirés après l'import —
/// l'app gardait l'ancienne liste, décalée d'un numéro par rapport au PDF que
/// lisait Claude.
///
/// À chaque mise à jour automatique, les séries **récentes** (la semaine en
/// cours et la précédente) sont vérifiées :
///   • par une requête conditionnelle (`ETag`, `Last-Modified`) : un énoncé
///     inchangé ne coûte qu'une réponse 304, sans téléchargement ;
///   • sinon par l'empreinte du fichier (SHA-256), gardée dans iCloud clé-valeur
///     pour que l'iPhone et le Mac ne relisent pas chacun la même révision.
/// Une série jamais vérifiée (avant cette version) n'est relue que si la
/// lecture gratuite (la mise en page, sans modèle de langage) ne trouve pas les
/// mêmes exercices que ceux enregistrés ; sinon on retient juste l'empreinte.
///
/// La relecture se fait en mode **révision** (`SeriesDraftWriter`) : les
/// exercices se retrouvent par leur contenu. Les copies de l'ancien PDF (lecteur
/// du cours, énoncés du chrono, bibliothèque hors ligne) sont oubliées.
@MainActor
enum SeriesSourceWatch {
    struct Fingerprint: Codable, Equatable {
        var hash: String
        var etag: String?
        var modified: String?
    }

    /// Une relecture commencée par un appareil : les autres attendent.
    private struct Claim: Codable {
        var device: String
        var at: Date
    }

    /// L'empreinte trouvée, retenue seulement une fois la relecture réussie.
    private static var pending: [UUID: Fingerprint] = [:]

    private static func key(_ id: UUID) -> String { "seriesSource.\(id.uuidString)" }
    private static func claimKey(_ id: UUID) -> String { "seriesSource.claim.\(id.uuidString)" }
    private static var store: NSUbiquitousKeyValueStore { .default }

    static func fingerprint(of id: UUID) -> Fingerprint? {
        store.data(forKey: key(id)).flatMap { try? JSONDecoder().decode(Fingerprint.self, from: $0) }
    }

    private static func save(_ fingerprint: Fingerprint, for id: UUID) {
        store.set(try? JSONEncoder().encode(fingerprint), forKey: key(id))
    }

    /// Les séries à surveiller : récentes, avec des exercices, publiées en ligne.
    static func watched(_ course: Course) -> [ExerciseSeries] {
        let week = course.currentWeek
        return course.sortedSeries.filter { series in
            guard !series.exercises.isEmpty, series.plannedWeek >= week - 1, series.plannedWeek <= week + 1,
                  let url = URL(string: series.urlString), url.scheme?.hasPrefix("http") == true else { return false }
            return true
        }
    }

    /// Marque `needsReread` sur les séries dont l'énoncé a changé.
    /// - Returns: le nombre de séries à relire.
    @discardableResult
    static func flagChanged(courses: [Course], moodleReady: Bool) async -> Int {
        var flagged = 0
        for course in courses {
            for series in watched(course) where !series.needsReread {
                guard let url = URL(string: series.urlString) else { continue }
                let isMoodle = url.host?.contains("moodle") == true
                if isMoodle, !moodleReady { continue }
                if let claim = claim(of: series.id), claim.device != CloudRelay.deviceID,
                   Date().timeIntervalSince(claim.at) < 15 * 60 { continue }
                let stored = fingerprint(of: series.id)
                guard let fetched = await fetch(url, isMoodle: isMoodle, stored: stored) else { continue }
                guard let (data, fresh) = fetched else { continue } // 304 : inchangé
                if let stored {
                    if stored.hash == fresh.hash {
                        if stored != fresh { save(fresh, for: series.id) }
                        continue
                    }
                } else if !disagrees(data, with: series) {
                    // Première vérification, et l'énoncé donne les mêmes exercices.
                    save(fresh, for: series.id)
                    continue
                }
                pending[series.id] = fresh
                store.set(try? JSONEncoder().encode(Claim(device: CloudRelay.deviceID, at: Date())), forKey: claimKey(series.id))
                series.needsReread = true
                flagged += 1
                AppLog.record(.info, "import", "Énoncé modifié à la source",
                              detail: "\(course.displayCode) série \(series.seriesNumber) — relu")
            }
        }
        return flagged
    }

    /// La relecture a réussi : l'empreinte est retenue, les vieilles copies oubliées.
    static func commit(_ series: ExerciseSeries) {
        if let fresh = pending.removeValue(forKey: series.id) { save(fresh, for: series.id) }
        store.removeObject(forKey: claimKey(series.id))
        SeriesPDFStore.shared.forget(series.id)
        SiteHub.shared.forget(series.urlString)
        #if os(iOS)
        if let url = URL(string: series.urlString) { OfflineLibrary.shared.forget(url) }
        #endif
    }

    private static func claim(of id: UUID) -> Claim? {
        store.data(forKey: claimKey(id)).flatMap { try? JSONDecoder().decode(Claim.self, from: $0) }
    }

    /// `nil` : rien de lisible ; `.some(nil)` : inchangé (304) ; sinon le
    /// contenu et son empreinte.
    private static func fetch(_ url: URL, isMoodle: Bool, stored: Fingerprint?) async -> (Data, Fingerprint)?? {
        if isMoodle {
            guard let file = try? await AuthenticatedDownloader.download(url),
                  let data = try? Data(contentsOf: file) else { return nil }
            try? FileManager.default.removeItem(at: file)
            return .some((data, Fingerprint(hash: digest(data))))
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        if let etag = stored?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let modified = stored?.modified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 304 { return .some(nil) }
        guard http.statusCode == 200, !data.isEmpty else { return nil }
        return .some((data, Fingerprint(hash: digest(data),
                                        etag: http.value(forHTTPHeaderField: "ETag"),
                                        modified: http.value(forHTTPHeaderField: "Last-Modified"))))
    }

    /// La lecture gratuite d'un PDF ne trouve-t-elle pas les mêmes exercices ?
    /// (Une page web n'est pas comparée : sa première empreinte est retenue.)
    private static func disagrees(_ data: Data, with series: ExerciseSeries) -> Bool {
        guard data.starts(with: Data("%PDF".utf8)), let document = PDFDocument(data: data) else { return false }
        let lines = PDFLayoutExtractor.lines(from: document)
        let detected = SeriesLayoutParser.fillingStatements(SeriesLayoutParser.parse(lines, defaultSeries: series.seriesNumber), from: lines)
        guard let exercises = (detected.first { $0.key == series.key }
                                ?? detected.first { $0.number == series.seriesNumber } ?? detected.first)?.exercises,
              !exercises.isEmpty else { return false }
        let current = series.exercises.filter { !$0.title.contains(SeriesDraftWriter.removedMark) }
        guard exercises.count == current.count else { return true }
        let incoming = exercises.map { SeriesReconciler.Item(number: $0.number, title: $0.title, statement: $0.statement) }
        let olds = current.sorted { $0.sortOrder < $1.sortOrder }
            .map { SeriesReconciler.Item(number: $0.exerciseNumber, title: $0.title, statement: $0.statement) }
        // Même nombre : relire seulement si l'ordre ne retrouve pas la moitié.
        let found = SeriesReconciler.match(existing: olds, incoming: incoming).compactMap { $0 }
        return found.count * 2 < incoming.count
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
