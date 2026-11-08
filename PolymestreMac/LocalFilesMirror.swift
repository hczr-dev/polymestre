import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Les fichiers d'étude **copiés sur le disque** du Mac, dans un dossier que
/// l'assistant peut ouvrir (`<projet Claude>/cours/<CODE>/…`).
///
/// Rien n'est copié avant qu'on le demande : `ensure` télécharge (avec la
/// session Moodle de l'app), copie ou écrit le fichier, puis rend son chemin.
/// Un PDF de 80 Mo passe donc comme un de 80 Ko : l'assistant reçoit un chemin,
/// pas des octets, et l'ouvre avec son outil de lecture.
@MainActor
final class LocalFilesMirror {

    enum Failure: LocalizedError {
        case notADocument
        case download(String)
        case missing
        var errorDescription: String? {
            switch self {
            case .notADocument: return String(localized: "l'adresse ne mène pas à un document (une page web, ou la session Moodle a expiré : reconnecte-toi dans Polymestre).")
            case .download(let reason): return String(localized: "téléchargement impossible : \(reason)")
            case .missing: return String(localized: "le fichier n'existe plus à sa source.")
            }
        }
    }

    let root: URL

    init(root: URL) { self.root = root }

    private func folder(_ entry: LocalFileCatalog.Entry) -> URL {
        root.appendingPathComponent(LocalFileCatalog.slug(entry.courseCode), isDirectory: true)
    }

    private static func hasExtension(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        return (1...5).contains(ext.count) && ext.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// Le fichier déjà copié pour cette ligne, s'il y en a un.
    func existing(_ entry: LocalFileCatalog.Entry) -> URL? {
        let directory = folder(entry)
        if Self.hasExtension(entry.baseName) {
            let file = directory.appendingPathComponent(entry.baseName)
            return FileManager.default.fileExists(atPath: file.path) ? file : nil
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.first { $0.hasPrefix(entry.baseName + ".") && !$0.hasSuffix(".part") }.map { directory.appendingPathComponent($0) }
    }

    private func destination(_ entry: LocalFileCatalog.Entry, ext: String) -> URL {
        let directory = folder(entry)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = Self.hasExtension(entry.baseName) ? entry.baseName : "\(entry.baseName).\(ext.isEmpty ? "bin" : ext)"
        return directory.appendingPathComponent(name)
    }

    /// Met le fichier en place : écrit d'abord à côté, puis remplace (jamais un fichier à moitié écrit).
    private func place(_ source: URL, at destination: URL, move: Bool) throws {
        let part = destination.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: part)
        if move { try FileManager.default.moveItem(at: source, to: part) } else { try FileManager.default.copyItem(at: source, to: part) }
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: part)
    }

    private static func attributes(_ url: URL) -> (size: Int, modified: Date?) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return (values?.fileSize ?? -1, values?.contentModificationDate)
    }

    // MARK: Mise à disposition

    /// Le chemin du fichier, copié ou téléchargé si besoin.
    func ensure(_ entry: LocalFileCatalog.Entry) async throws -> URL {
        switch entry.source {
        case .text(let text):
            let target = destination(entry, ext: "md")
            if (try? String(contentsOf: target, encoding: .utf8)) != text { try text.write(to: target, atomically: true, encoding: .utf8) }
            return target

        case .data(let data, let fileName):
            let target = destination(entry, ext: (fileName as NSString).pathExtension)
            if Self.attributes(target).size != data.count { try data.write(to: target, options: .atomic) }
            return target

        case .disk(let url):
            guard FileManager.default.fileExists(atPath: url.path) else { throw Failure.missing }
            let target = destination(entry, ext: url.pathExtension)
            let source = Self.attributes(url), copy = Self.attributes(target)
            if copy.size != source.size || copy.modified != source.modified { try place(url, at: target, move: false) }
            return target

        case .remote(let url):
            // Le PDF d'une série que l'app a déjà : sa copie sert d'abord, et suit les révisions.
            if let id = entry.seriesID.flatMap(UUID.init(uuidString:)), entry.type == "enonce",
               let cached = SeriesPDFStore.shared.localFile(id: id, address: entry.address ?? "") {
                let target = destination(entry, ext: "pdf")
                if Self.attributes(target).size != Self.attributes(cached).size { try place(cached, at: target, move: false) }
                return target
            }
            if let present = existing(entry) { return present }
            let (file, ext) = try await download(url)
            let target = destination(entry, ext: ext)
            if let id = entry.seriesID.flatMap(UUID.init(uuidString:)), entry.type == "enonce", ext == "pdf" {
                SeriesPDFStore.shared.keep(file, for: id)
            }
            try place(file, at: target, move: true)
            return target
        }
    }

    private func download(_ url: URL) async throws -> (file: URL, ext: String) {
        if url.isFileURL {
            guard FileManager.default.fileExists(atPath: url.path) else { throw Failure.missing }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: temporary)
            return (temporary, url.pathExtension)
        }
        do {
            return (try await SeriesPDFStore.download(url), "pdf")
        } catch {
            // Pas un PDF : slides, archive, image… avec les mêmes cookies.
            do {
                let (file, type) = try await AuthenticatedDownloader.file(url)
                if type?.lowercased().contains("html") == true { try? FileManager.default.removeItem(at: file); throw Failure.notADocument }
                return (file, Self.extension(of: file, mime: type, address: url))
            } catch let failure as Failure {
                throw failure
            } catch {
                throw Failure.download(error.localizedDescription)
            }
        }
    }

    private static func `extension`(of file: URL, mime: String?, address: URL) -> String {
        if hasExtension(file.lastPathComponent), !file.pathExtension.isEmpty { return file.pathExtension.lowercased() }
        if let mime, let ext = UTType(mimeType: mime.components(separatedBy: ";")[0])?.preferredFilenameExtension { return ext }
        return address.pathExtension.isEmpty ? "bin" : address.pathExtension.lowercased()
    }

    // MARK: Description d'un fichier

    struct Info {
        var bytes: Int
        var mime: String
        var pages: Int?
        var text: String?
    }

    /// Taille, type, nombre de pages d'un PDF, et le texte d'un petit fichier texte.
    static func info(_ url: URL) -> Info {
        let ext = url.pathExtension.lowercased()
        let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        let bytes = attributes(url).size
        let pages = ext == "pdf" ? PDFDocument(url: url)?.pageCount : nil
        var text: String?
        if ["md", "txt", "tex", "csv", "json", "ipynb", "html"].contains(ext), bytes <= 200_000 {
            text = try? String(contentsOf: url, encoding: .utf8)
        }
        return Info(bytes: bytes, mime: mime, pages: pages, text: text)
    }
}
