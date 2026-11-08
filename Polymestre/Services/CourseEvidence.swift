import Foundation

/// Ce qu'il y a derrière les liens d'un cours, regardé avant de le ranger.
///
/// Un nom d'activité ne dit pas tout : « Série 4 » peut mener à un chapitre de
/// MOOC sans exercices, « Corrigé » à une page qui porte aussi l'énoncé, un
/// lien « Semaine 3 » à un PDF d'exercices. L'app ouvre donc chaque cible
/// (sans rien enregistrer) et en garde la nature et le début du texte : les
/// règles et le modèle rangent le cours d'après ce contenu, quel que soit le
/// cours et sa forme.
@MainActor
enum CourseEvidence {

    /// La nature d'une adresse, sans l'ouvrir : un MOOC Open edX, une vidéo, un PDF.
    nonisolated static func linkKind(_ address: String) -> ContentLink.Kind {
        let lower = address.lowercased()
        if lower.range(of: #"(mediaspace|youtube\.com|youtu\.be|vimeo|tube\.switch|kaltura|/video/|\.mp4)"#, options: .regularExpression) != nil {
            return .video
        }
        if URL(string: address)?.pathExtension.lowercased() == "pdf" || lower.contains("pluginfile.php") { return .pdf }
        return .page
    }

    /// `mooc`, `vidéo`, `pdf`, `page` : ce qu'une adresse est, sans l'ouvrir.
    nonisolated static func destination(of address: String) -> String? {
        if MoocReference.courseKey(in: address) != nil { return "mooc" }
        switch linkKind(address) {
        case .video: return String(localized: "vidéo")
        case .pdf: return URL(string: address)?.pathExtension.lowercased() == "pdf" ? "pdf" : nil
        default: return nil
        }
    }

    /// Ouvre les cibles externes des activités (sites de cours, GitHub,
    /// pages d'exercices) et note leur nature et le début de leur texte.
    static func peekTargets(in snapshot: inout MoodleCourseSnapshot, limit: Int = 60) async {
        var jobs: [(section: Int, activity: Int, url: URL)] = []
        for (s, section) in snapshot.sections.enumerated() {
            for (a, activity) in section.activities.enumerated() where activity.isVisible {
                if activity.destination == nil, let known = destination(of: activity.link) {
                    snapshot.sections[s].activities[a].destination = known
                }
                guard activity.preview == nil,
                      let url = URL(string: activity.link), url.scheme?.hasPrefix("http") == true,
                      url.host?.contains("moodle") != true,
                      MoocReference.courseKey(in: activity.link) == nil,
                      linkKind(activity.link) != .video else { continue }
                jobs.append((s, a, url))
            }
        }
        for batch in stride(from: 0, to: min(jobs.count, limit), by: 6) {
            let slice = jobs[batch..<min(batch + 6, jobs.count, limit)]
            let results = await withTaskGroup(of: (Int, Peek?).self) { group in
                for (offset, job) in slice.enumerated() {
                    group.addTask { @MainActor in (offset, await peek(job.url)) }
                }
                var found: [Int: Peek] = [:]
                for await (offset, value) in group { if let value { found[offset] = value } }
                return found
            }
            for (offset, job) in slice.enumerated() {
                guard let peek = results[offset] else { continue }
                snapshot.sections[job.section].activities[job.activity].destination = peek.kind
                snapshot.sections[job.section].activities[job.activity].preview = peek.text
            }
        }
    }

    struct Peek: Codable { var kind: String; var text: String }

    /// Ce que montre une adresse : sa nature et ses premières lignes. Gardé
    /// trois jours, pour que la mise à jour automatique ne rouvre pas tout.
    static func peek(_ url: URL) async -> Peek? {
        let key = url.absoluteString
        var cache = loadCache()
        if let entry = cache[key], Date().timeIntervalSince1970 - entry.at < 3 * 86_400 { return entry.peek }
        guard let text = await AuthenticatedDownloader.document(at: url, timeout: 10, pages: 2) else { return nil }
        let kind = text.isPDF ? "pdf" : "page web"
        // Un PDF trop lourd pour l'aperçu : sa nature suffit, et rien n'est gardé.
        if text.body.isEmpty { return Peek(kind: kind, text: "") }
        let flat = text.body.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let peek = Peek(kind: kind, text: String(flat.prefix(500)))
        cache[key] = CacheEntry(at: Date().timeIntervalSince1970, peek: peek)
        if cache.count > 500 {
            for old in cache.sorted(by: { $0.value.at < $1.value.at }).prefix(cache.count - 400) { cache[old.key] = nil }
        }
        saveCache(cache)
        return peek
    }

    private struct CacheEntry: Codable { var at: Double; var peek: Peek }
    private static let cacheKey = "courseEvidence.peeks"

    private static func loadCache() -> [String: CacheEntry] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return [:] }
        return (try? JSONDecoder().decode([String: CacheEntry].self, from: data)) ?? [:]
    }

    private static func saveCache(_ cache: [String: CacheEntry]) {
        if let data = try? JSONEncoder().encode(cache) { UserDefaults.standard.set(data, forKey: cacheKey) }
    }
}
