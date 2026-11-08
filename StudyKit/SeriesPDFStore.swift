import Foundation
import PDFKit
#if canImport(UIKit)
import UIKit
#endif

/// Le PDF de chaque série, gardé sur l'appareil, et l'énoncé de chaque
/// exercice découpé dedans.
///
/// L'énoncé « exercice par exercice » du chrono ne montrait rien quand
/// l'import n'avait pas extrait de texte — c'est-à-dire presque toujours pour
/// un PDF de maths, dont les formules ne survivent pas à l'extraction. Le PDF
/// lui-même les a : on en montre la bande qui correspond à l'exercice, telle
/// qu'imprimée. Le fichier est téléchargé une fois (avec la session Moodle au
/// besoin), puis lu depuis le cache.
@MainActor
final class SeriesPDFStore {
    static let shared = SeriesPDFStore()

    enum Failure: LocalizedError {
        case noDocument
        case notFound
        var errorDescription: String? {
            switch self {
            case .noDocument: return String(localized: "Cette série n'a pas de PDF associé.")
            case .notFound: return String(localized: "L'exercice n'a pas été retrouvé dans le PDF.")
            }
        }
    }

    private struct Entry {
        var document: PDFDocument
        var regions: [String: [ExerciseRegions.Slice]]
    }

    private var entries: [UUID: Entry] = [:]
    private var inFlight: [UUID: Task<Entry, Error>] = [:]

    private static var folder: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("SeriesPDF", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func file(for seriesID: UUID) -> URL {
        folder.appendingPathComponent(seriesID.uuidString + ".pdf")
    }

    /// Garde un PDF importé à la main : la série n'a pas d'adresse, mais son
    /// énoncé reste affichable dans le chrono.
    func keep(_ source: URL, for seriesID: UUID) {
        let needsScope = source.startAccessingSecurityScopedResource()
        defer { if needsScope { source.stopAccessingSecurityScopedResource() } }
        let destination = Self.file(for: seriesID)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: source, to: destination)
        entries[seriesID] = nil
    }

    /// L'énoncé a changé à la source : la copie gardée et ses découpes partent.
    func forget(_ seriesID: UUID) {
        entries[seriesID] = nil
        try? FileManager.default.removeItem(at: Self.file(for: seriesID))
    }

    #if canImport(UIKit)
    /// Les bandes de page de l'énoncé d'un exercice, rendues en images.
    func statementImages(for exercise: Exercise, width: CGFloat) async throws -> [UIImage] {
        guard let series = exercise.series else { throw Failure.noDocument }
        let entry = try await entry(for: series)
        guard let slices = entry.regions[ExerciseRegions.shortNumber(exercise.exerciseNumber)], !slices.isEmpty else {
            throw Failure.notFound
        }
        return slices.compactMap { render($0, of: entry.document, width: width) }
    }
    #endif

    /// Le PDF de cette série, **s'il est déjà sur l'appareil** (cache de la série
    /// ou copie hors ligne) : rien n'est téléchargé.
    func localFile(for series: ExerciseSeries) -> URL? {
        localFile(id: series.id, address: series.urlString)
    }

    func localFile(id: UUID, address: String) -> URL? {
        let local = Self.file(for: id)
        if FileManager.default.fileExists(atPath: local.path) { return local }
        #if os(iOS)
        if let remote = Self.documentURL(address) { return OfflineLibrary.shared.localFile(for: remote) }
        #endif
        return nil
    }

    /// Peut-on espérer un PDF pour cette série ?
    func hasDocument(for series: ExerciseSeries) -> Bool {
        if entries[series.id] != nil || FileManager.default.fileExists(atPath: Self.file(for: series.id).path) { return true }
        return Self.documentURL(series) != nil
    }

    private func entry(for series: ExerciseSeries) async throws -> Entry {
        if let entry = entries[series.id] { return entry }
        if let task = inFlight[series.id] { return try await task.value }
        let id = series.id
        let number = series.seriesNumber
        let remote = Self.documentURL(series)
        let task = Task<Entry, Error> { @MainActor in
            let local = Self.file(for: id)
            #if os(iOS)
            // Gardé hors ligne : pas de réseau à attendre.
            if !FileManager.default.fileExists(atPath: local.path), let remote,
               let offline = OfflineLibrary.shared.localFile(for: remote) {
                try? FileManager.default.copyItem(at: offline, to: local)
            }
            #endif
            if !FileManager.default.fileExists(atPath: local.path) {
                guard let remote else { throw Failure.noDocument }
                let downloaded = try await Self.download(remote)
                try? FileManager.default.removeItem(at: local)
                try FileManager.default.moveItem(at: downloaded, to: local)
            }
            guard let document = PDFDocument(url: local) else { throw Failure.noDocument }
            let regions = await Task.detached(priority: .userInitiated) {
                Self.regions(of: document, series: number)
            }.value
            return Entry(document: document, regions: regions)
        }
        inFlight[id] = task
        defer { inFlight[id] = nil }
        let entry = try await task.value
        entries[id] = entry
        return entry
    }

    /// Où commence chaque exercice, lu dans la mise en page du PDF.
    nonisolated private static func regions(of document: PDFDocument, series: Int) -> [String: [ExerciseRegions.Slice]] {
        let lines = PDFLayoutExtractor.lines(from: document)
        let detected = SeriesLayoutParser.parse(lines, defaultSeries: series)
        let exercises = (detected.first { $0.number == series } ?? detected.first)?.exercises ?? []
        let headings = exercises.compactMap { exercise -> ExerciseRegions.Heading? in
            guard let page = exercise.pageIndex, let top = exercise.verticalPosition else { return nil }
            return ExerciseRegions.Heading(number: exercise.number, page: page, top: top)
        }
        return ExerciseRegions.slices(for: headings, pageCount: document.pageCount)
    }

    /// L'adresse d'un PDF : un fichier, ou une activité Moodle qui en porte un.
    /// Une page web de série (Botafogo, proginsc) n'en est pas un.
    private static func documentURL(_ series: ExerciseSeries) -> URL? {
        documentURL(series.urlString)
    }

    static func documentURL(_ address: String) -> URL? {
        guard let url = URL(string: address), url.scheme?.hasPrefix("http") == true else { return nil }
        if MoodleLinks.activityModule(of: url) != nil || MoodleLinks.isDocument(url.absoluteString) { return url }
        if url.host?.contains("dropbox.com") == true { return url }
        return nil
    }

    static func download(_ url: URL) async throws -> URL {
        if url.host?.contains("moodle") == true {
            return try await AuthenticatedDownloader.download(url)
        }
        var address = url
        if url.host?.contains("dropbox.com") == true, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            var items = (components.queryItems ?? []).filter { $0.name != "dl" }
            items.append(URLQueryItem(name: "dl", value: "1"))
            components.queryItems = items
            address = components.url ?? url
        }
        let (temporary, response) = try await URLSession.shared.download(from: address)
        let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard type.contains("pdf") || address.pathExtension.lowercased() == "pdf" else {
            throw Failure.noDocument
        }
        return temporary
    }

    #if canImport(UIKit)
    /// Une bande de page, à la largeur voulue (en points, rendue en @3x).
    private func render(_ slice: ExerciseRegions.Slice, of document: PDFDocument, width: CGFloat) -> UIImage? {
        guard let page = document.page(at: slice.page) else { return nil }
        // Le même cadre que la lecture de la mise en page (`PDFLayoutExtractor`),
        // pour que les positions des titres tombent juste.
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = 3 * width / bounds.width
        let band = CGRect(x: 0, y: bounds.height * slice.top,
                          width: bounds.width, height: bounds.height * (slice.bottom - slice.top))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: band.width * scale, height: band.height * scale)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let cg = context.cgContext
            cg.scaleBy(x: scale, y: scale)
            // PDF : origine en bas, y vers le haut. On retourne la page et on la
            // remonte pour que la bande voulue tombe dans le cadre.
            cg.translateBy(x: 0, y: bounds.height - band.minY)
            cg.scaleBy(x: 1, y: -1)
            page.draw(with: .mediaBox, to: cg)
        }
    }
    #endif
}
