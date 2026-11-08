import CryptoKit
import Foundation
import Observation
import PDFKit
#if os(macOS)
import CoreServices
#endif

/// Les notes de l'étudiant·e sur le Mac : le dossier où son app de notes
/// sauvegarde ses cahiers en PDF (GoodNotes → Google Drive, iCloud Drive,
/// Dropbox…), trouvé tout seul ou choisi dans les Réglages. Les cahiers sont
/// rangés par cours et par semaine (`NotesLibrary`, pur).
@MainActor
@Observable
final class NotesStore {
    static let shared = NotesStore()

    private(set) var root: URL?
    private(set) var documents: [NotesLibrary.Document] = []
    private(set) var scannedAt: Date?

    /// Ta façon de nommer et les cahiers rangés à la main.
    var rules: NotesLibrary.Rules = {
        guard let data = UserDefaults.standard.data(forKey: "notes.rules"),
              let rules = try? JSONDecoder().decode(NotesLibrary.Rules.self, from: data) else { return .standard }
        return rules
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(data, forKey: "notes.rules") }
            scannedAt = nil
        }
    }

    /// Les cahiers trouvés (pour les ranger à la main).
    var notebooks: [String] { Array(Set(documents.map(\.notebook))).filter { !$0.isEmpty }.sorted() }

    /// Le dossier choisi dans les Réglages (vide : trouvé automatiquement).
    var chosenFolder: String {
        get { UserDefaults.standard.string(forKey: "mac.notesFolder") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "mac.notesFolder"); scannedAt = nil }
    }

    /// Les endroits où GoodNotes (et les autres) sauvegardent d'habitude (Mac).
    static func candidates() -> [URL] {
        #if os(iOS)
        return []
        #else
        let home = FileManager.default.homeDirectoryForCurrentUser
        var result: [URL] = []
        let cloud = home.appendingPathComponent("Library/CloudStorage")
        for provider in (try? FileManager.default.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil)) ?? [] {
            let drive = provider.lastPathComponent.hasPrefix("GoogleDrive") ? provider.appendingPathComponent("My Drive") : provider
            for name in ["GoodNotes", "Goodnotes", "Notability", "Apps/GoodNotes 5", "Apps/Goodnotes"] {
                result.append(drive.appendingPathComponent(name))
            }
        }
        for name in ["GoodNotes", "Goodnotes", "Notability"] {
            result.append(home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/\(name)"))
            result.append(home.appendingPathComponent("Dropbox/Apps/\(name)"))
        }
        return result.filter { FileManager.default.fileExists(atPath: $0.path) }
        #endif
    }

    // MARK: Dossier choisi (iPhone : un dossier de Fichiers, gardé en signet)

    private static let bookmarkKey = "notes.folderBookmark"

    /// Retient un dossier choisi (Fichiers sur l'iPhone, Finder sur le Mac).
    func choose(_ url: URL) {
        #if os(iOS)
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        }
        #endif
        chosenFolder = url.path
    }

    private func bookmarkedFolder() -> URL? {
        #if os(iOS)
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        _ = url?.startAccessingSecurityScopedResource()
        return url
        #else
        return nil
        #endif
    }

    /// Relit le dossier (une fois toutes les deux minutes au plus).
    func refresh(force: Bool = false) async {
        if !force, let scannedAt, Date().timeIntervalSince(scannedAt) < 120 { return }
        let folder = bookmarkedFolder()
            ?? (chosenFolder.isEmpty ? Self.candidates().first : URL(fileURLWithPath: (chosenFolder as NSString).expandingTildeInPath))
        root = folder
        scannedAt = Date()
        guard let folder else { documents = []; return }
        #if os(macOS)
        // Le dossier surveillé : un cahier resauvegardé par GoodNotes est relu
        // dans la seconde, pas au prochain passage.
        if watcher?.folder != folder {
            watcher = FolderWatcher(folder: folder) { [weak self] in
                Task { @MainActor in await self?.refresh(force: true) }
            }
        }
        #endif
        let rules = rules
        let found = await Task.detached(priority: .utility) { Self.scan(folder, rules: rules) }.value
        // Rien de changé (Google Drive touche souvent le dossier sans changer
        // de cahier) : on ne redessine rien.
        if found != documents { documents = found }
    }

    nonisolated static func scan(_ folder: URL, rules: NotesLibrary.Rules = .standard) -> [NotesLibrary.Document] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var result: [NotesLibrary.Document] = []
        let base = folder.standardizedFileURL.path
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "pdf" {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            if let document = NotesLibrary.document(path: relative, modified: values?.contentModificationDate ?? .distantPast, rules: rules) {
                result.append(document)
            }
            if result.count > 5000 { break }
        }
        return result
    }

    func url(_ document: NotesLibrary.Document) -> URL? { root?.appendingPathComponent(document.path) }

    /// Le cours deviné (ou choisi) pour un cahier.
    func course(forNotebook notebook: String, among courses: [Course]) -> Course? {
        let keys = courses.map { NotesLibrary.CourseKey(code: $0.code, name: $0.name) }
        guard let key = NotesLibrary.course(forNotebook: notebook, among: keys, rules: rules) else { return nil }
        return courses.first { $0.code == key.code }
    }

    /// Les cahiers d'un cours.
    func documents(for course: Course, among courses: [Course]) -> [NotesLibrary.Document] {
        let keys = courses.map { NotesLibrary.CourseKey(code: $0.code, name: $0.name) }
        let mine = NotesLibrary.CourseKey(code: course.code, name: course.name)
        var cache: [String: Bool] = [:]
        return documents.filter { document in
            if let known = cache[document.notebook] { return known }
            let match = NotesLibrary.course(forNotebook: document.notebook, among: keys, rules: rules) == mine
            cache[document.notebook] = match
            return match
        }
    }

    /// La copie de l'étudiant·e pour une série.
    func copy(for series: ExerciseSeries, course: Course, among courses: [Course]) -> NotesLibrary.Document? {
        NotesLibrary.copy(seriesNumber: series.seriesNumber, week: series.plannedWeek > 0 ? series.plannedWeek : nil,
                          in: documents(for: course, among: courses))
    }

    #if os(macOS)
    private var watcher: FolderWatcher?
    #endif

    // MARK: Ce que Claude a déjà vu

    /// Les pages d'une copie à envoyer : seulement celles que la conversation
    /// n'a pas encore reçues (nouvelles ou modifiées), au plus les `lastPages`
    /// plus récentes.
    struct CopyDelta: Sendable {
        /// Le PDF des pages à envoyer (vide : rien de neuf).
        let data: Data
        /// Leurs numéros dans le cahier (depuis 1).
        let pages: [Int]
        let total: Int
        /// Leurs empreintes, à retenir une fois le message parti.
        let fingerprints: [String]

        var isEmpty: Bool { pages.isEmpty }

        /// Le titre du document pour Claude : quelles pages, et pourquoi elles seules.
        func title(_ notebook: String, firstTime: Bool) -> String {
            let list = Self.ranges(pages)
            if firstTime { return String(localized: "\(notebook) — pages \(list) sur \(total)") }
            return String(localized: "\(notebook) — pages \(list) sur \(total), nouvelles ou modifiées depuis le dernier envoi (les autres sont celles déjà envoyées)")
        }

        /// 3, 4, 5, 9 → « 3–5, 9 ».
        static func ranges(_ pages: [Int]) -> String {
            var parts: [String] = []
            var start: Int?, last: Int?
            for page in pages.sorted() {
                if let current = last, page == current + 1 { last = page; continue }
                if let start, let last { parts.append(start == last ? "\(start)" : "\(start)–\(last)") }
                start = page; last = page
            }
            if let start, let last { parts.append(start == last ? "\(start)" : "\(start)–\(last)") }
            return parts.joined(separator: ", ")
        }
    }

    /// À lancer hors du fil principal : rendre les pages prend un instant.
    nonisolated static func copyDelta(url: URL, alreadySent: Set<String>, lastPages: Int = 12) -> CopyDelta? {
        guard let pdf = PDFDocument(url: url) else { return nil }
        var changed: [(index: Int, print: String)] = []
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            let print = fingerprint(page)
            if !alreadySent.contains(print) { changed.append((index, print)) }
        }
        let kept = Array(changed.suffix(lastPages))
        let out = PDFDocument()
        for (offset, item) in kept.enumerated() {
            if let page = pdf.page(at: item.index)?.copy() as? PDFPage { out.insert(page, at: offset) }
        }
        return CopyDelta(data: kept.isEmpty ? Data() : (out.dataRepresentation() ?? Data()),
                         pages: kept.map { $0.index + 1 }, total: pdf.pageCount, fingerprints: kept.map(\.print))
    }

    /// Des pages précises (« regarde la page 4 ») : jointes même si la conversation les a déjà reçues —
    /// on les demande pour que Claude les regarde, et elles ont pu changer. Les numéros hors cahier sont ignorés.
    nonisolated static func copyPages(url: URL, pages: [Int]) -> CopyDelta? {
        guard let pdf = PDFDocument(url: url) else { return nil }
        let valid = Set(pages).filter { $0 >= 1 && $0 <= pdf.pageCount }.sorted()
        guard !valid.isEmpty else { return CopyDelta(data: Data(), pages: [], total: pdf.pageCount, fingerprints: []) }
        let out = PDFDocument()
        for (offset, number) in valid.enumerated() {
            if let page = pdf.page(at: number - 1)?.copy() as? PDFPage { out.insert(page, at: offset) }
        }
        let prints = valid.compactMap { pdf.page(at: $0 - 1).map(fingerprint) }
        return CopyDelta(data: out.dataRepresentation() ?? Data(), pages: valid, total: pdf.pageCount, fingerprints: prints)
    }

    /// Ce que la page montre, en empreinte : son rendu, réduit. Le rendu est
    /// gardé par le contenu brut de la page (ses traits, ses images) : une page
    /// inchangée d'une sauvegarde à l'autre ne se redessine pas.
    private nonisolated static let renderCache = NSCache<NSString, NSString>()

    nonisolated static func fingerprint(_ page: PDFPage) -> String {
        let raw = rawKey(page)
        if let raw, let known = renderCache.object(forKey: raw as NSString) { return known as String }
        let rendered = renderHash(page)
        if let raw { renderCache.setObject(rendered as NSString, forKey: raw as NSString) }
        return rendered
    }

    private nonisolated static func rawKey(_ page: PDFPage) -> String? {
        guard let dictionary = page.pageRef?.dictionary else { return nil }
        var hasher = SHA256()
        var any = false
        func add(_ stream: CGPDFStreamRef) {
            var format = CGPDFDataFormat.raw
            if let data = CGPDFStreamCopyData(stream, &format) { hasher.update(data: data as Data); any = true }
        }
        var stream: CGPDFStreamRef?
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetStream(dictionary, "Contents", &stream), let stream {
            add(stream)
        } else if CGPDFDictionaryGetArray(dictionary, "Contents", &array), let array {
            for index in 0..<CGPDFArrayGetCount(array) {
                var part: CGPDFStreamRef?
                if CGPDFArrayGetStream(array, index, &part), let part { add(part) }
            }
        }
        var resources: CGPDFDictionaryRef?
        var objects: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
           CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects {
            CGPDFDictionaryApplyBlock(objects, { _, object, _ in
                var image: CGPDFStreamRef?
                if CGPDFObjectGetValue(object, .stream, &image), let image { add(image) }
                return true
            }, nil)
        }
        guard any else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func renderHash(_ page: PDFPage) -> String {
        let box = page.bounds(for: .mediaBox)
        let width = 220
        let scale = CGFloat(width) / max(box.width, 1)
        let height = max(1, Int(box.height * scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let _ = context.data else { return UUID().uuidString }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .mediaBox, to: context)
        guard let bytes = context.data else { return UUID().uuidString }
        let data = Data(bytes: bytes, count: width * 4 * height)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Le PDF à montrer à Claude : entier s'il est court, sinon ses dernières
    /// pages (le travail le plus récent), pour rester léger.
    func attachmentData(_ document: NotesLibrary.Document, lastPages: Int = 12) -> Data? {
        guard let url = url(document), let pdf = PDFDocument(url: url) else { return nil }
        guard pdf.pageCount > lastPages else { return try? Data(contentsOf: url) }
        let trimmed = PDFDocument()
        for (offset, index) in ((pdf.pageCount - lastPages)..<pdf.pageCount).enumerated() {
            if let page = pdf.page(at: index) { trimmed.insert(page, at: offset) }
        }
        return trimmed.dataRepresentation()
    }
}

#if os(macOS)
/// Un dossier suivi par FSEvents (sous-dossiers compris), les changements
/// regroupés à la seconde.
final class FolderWatcher: @unchecked Sendable {
    let folder: URL
    private let onChange: @Sendable () -> Void
    private var stream: FSEventStreamRef?

    init(folder: URL, onChange: @escaping @Sendable () -> Void) {
        self.folder = folder
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        stream = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
#endif
