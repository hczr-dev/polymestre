import Foundation
import CryptoKit
import UniformTypeIdentifiers

/// Les **fichiers** que l'app envoie à l'assistant : énoncés et corrigés de
/// séries déjà sur l'iPhone, fichiers ajoutés à un cours.
///
/// Ce que ce fichier **ne fait pas** : rien n'est téléchargé pour l'occasion.
/// Un PDF qui n'est pas encore sur l'appareil n'est pas envoyé — la
/// bibliothèque hors ligne (Réglages › Hors ligne) les rapatrie, et l'assistant
/// lit « pas encore envoyé » plutôt que d'attendre. Aucune interrogation
/// périodique : l'envoi se fait dans la synchronisation, qui suit les
/// enregistrements et l'ouverture de l'app.
///
/// Le serveur désigne les fichiers par leur SHA-256 ; il répond à chaque
/// synchronisation par la liste de ceux qui lui manquent (`wantedFiles`), et
/// efface ceux qu'on n'annonce plus.
@MainActor
enum AssistantFiles {

    /// Une réponse MCP plafonne à 16 Mo, base64 compris (le serveur refuse au-delà de 10 Mo).
    static let maxBytes = 10 * 1024 * 1024

    /// Une ligne de l'index, et d'où lire ses octets.
    struct Local {
        enum Source { case file(URL), data(Data) }
        var entry: [String: Any]
        var sha: String?
        var source: Source

        func bytes() -> Data? {
            switch source {
            case .file(let url): return try? Data(contentsOf: url, options: .mappedIfSafe)
            case .data(let data): return data
            }
        }
    }

    /// Empreinte d'un fichier déjà calculée (chemin + date + taille) : la même
    /// série n'est pas relue à chaque synchronisation.
    private static var shaCache: [String: String] = [:]

    // MARK: Index

    static func index(courses: [Course]) -> [Local] {
        var locals: [Local] = []
        for course in courses where course.isTracked {
            let base: [String: Any] = ["courseId": course.id.uuidString, "course": course.displayCode]
            for series in course.sortedSeries {
                let label = series.title.isEmpty ? series.displayName : "\(series.displayName) — \(series.title)"
                if let file = SeriesPDFStore.shared.localFile(for: series) {
                    locals.append(local(file, id: "serie:\(series.id.uuidString)", kind: "enonce", title: "\(label) (énoncé)",
                                        name: "\(slug(course.displayCode))-serie-\(series.seriesNumber).pdf", mime: "application/pdf",
                                        address: series.urlString, number: series.seriesNumber, base: base))
                }
                if let url = SeriesPDFStore.documentURL(series.solutionURLString),
                   let file = OfflineLibrary.shared.localFile(for: url) {
                    locals.append(local(file, id: "corrige:\(series.id.uuidString)", kind: "corrige", title: "\(label) (corrigé)",
                                        name: "\(slug(course.displayCode))-serie-\(series.seriesNumber)-corrige.pdf", mime: "application/pdf",
                                        address: series.solutionURLString, number: series.seriesNumber, base: base))
                }
            }
            for resource in course.sortedResources where !resource.fileName.isEmpty {
                guard let data = resource.fileData else { continue }
                let mime = UTType(filenameExtension: (resource.fileName as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                var entry = base.merging([
                    "id": "ressource:\(resource.id.uuidString)", "kind": "ressource", "title": resource.title.isEmpty ? resource.fileName : resource.title,
                    "name": resource.fileName, "mime": mime, "bytes": data.count,
                ]) { $1 }
                var sha: String?
                if data.count > maxBytes {
                    entry["skipped"] = tooBig(data.count)
                } else {
                    let key = "resource:\(resource.id.uuidString):\(data.count):\(resource.addedAt.timeIntervalSince1970)"
                    sha = shaCache[key] ?? digest(data)
                    shaCache[key] = sha
                    entry["sha"] = sha
                }
                locals.append(Local(entry: entry, sha: sha, source: .data(data)))
            }
        }
        return locals
    }

    private static func local(_ file: URL, id: String, kind: String, title: String, name: String, mime: String,
                              address: String, number: Int, base: [String: Any]) -> Local {
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        var entry = base.merging([
            "id": id, "kind": kind, "title": title, "name": name, "mime": mime, "bytes": size, "seriesNumber": number,
        ]) { $1 }
        if !address.isEmpty { entry["address"] = address }
        var sha: String?
        if size > maxBytes {
            entry["skipped"] = tooBig(size)
        } else {
            let key = "\(file.path):\(size):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            if let cached = shaCache[key] {
                sha = cached
            } else if let data = try? Data(contentsOf: file, options: .mappedIfSafe) {
                sha = digest(data)
                shaCache[key] = sha
            }
            if let sha { entry["sha"] = sha }
        }
        return Local(entry: entry, sha: sha, source: .file(file))
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func tooBig(_ bytes: Int) -> String {
        "trop volumineux (\(Int((Double(bytes) / 1_048_576).rounded(.up))) Mo, \(maxBytes / 1_048_576) Mo au plus)."
    }

    private static func slug(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let parts = folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return parts.isEmpty ? "cours" : parts.joined(separator: "-")
    }

    // MARK: Envoi

    /// Envoie les fichiers que le serveur réclame, un à un. Pas sur données
    /// réduites, ni en réseau payant si « Wi-Fi seulement » est demandé (le même
    /// réglage que les fichiers hors ligne). Renvoie `false` si un envoi a échoué.
    @discardableResult
    static func upload(wanted: [String], from locals: [Local], to base: URL, wifiOnly: Bool) async -> Bool {
        var sent = 0
        for sha in wanted {
            guard let local = locals.first(where: { $0.sha == sha }), let bytes = local.bytes() else { continue }
            var request = URLRequest(url: base.appendingPathComponent("files").appendingPathComponent(sha))
            request.httpMethod = "PUT"
            request.timeoutInterval = 120
            request.allowsConstrainedNetworkAccess = false
            request.allowsExpensiveNetworkAccess = !wifiOnly
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            do {
                let (data, response) = try await URLSession.shared.upload(for: request, from: bytes)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    let detail = String(decoding: data.prefix(200), as: UTF8.self)
                    AppLog.record(.warning, "assistant", "Envoi d'un fichier refusé", detail: detail)
                    return false
                }
                sent += 1
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { return false }
                AppLog.record(.info, "assistant", "Envoi des fichiers reporté", detail: error.localizedDescription)
                return false
            }
        }
        if sent > 0 { AppLog.record(.info, "assistant", "\(sent) fichier(s) envoyé(s) à l'assistant") }
        return true
    }
}
