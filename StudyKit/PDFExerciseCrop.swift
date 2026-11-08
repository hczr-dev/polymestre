import CryptoKit
import PDFKit
import SwiftUI

/// Un PDF de série réduit à **un** exercice : de son titre au titre du
/// suivant, sur une ou plusieurs pages. Plus besoin de chercher 6.9 dans six
/// pages d'énoncé — ni dans le corrigé.
enum PDFExerciseCrop {

    /// Les mots qui retrouvent un exercice dans un PDF, du plus sûr au moins
    /// sûr : « Ex-03-02 », « Exercice 2 », « Problem 2 »… puis son **titre**
    /// (« Center of mass of a rod ») — beaucoup de séries numérotent « 1. Titre »
    /// sans le mot « Exercice ».
    static func terms(for exercise: Exercise) -> [String] {
        let number = exercise.exerciseNumber
        let last = number.split(separator: ".").last.map(String.init) ?? number
        var terms = ["Exercice \(number)", "Exercice \(last)", "Exercise \(last)", "Ex. \(last)", "Problème \(last)", "Problem \(last)"]
        if let series = exercise.series, let n = Int(last) {
            terms.insert(String(format: "Ex-%02d-%02d", series.seriesNumber, n), at: 0)
            terms.append(String(format: "Exercice %d.%d", series.seriesNumber, n))
        }
        let title = exercise.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.count >= 4, title != exercise.displayNumber { terms.append(title) }
        return terms
    }

    struct Place {
        var page: Int
        var bounds: CGRect
    }

    /// Ce que l'exercice occupe : une zone par page, de son titre au titre suivant.
    struct Region {
        var parts: [(page: Int, rect: CGRect)]
    }

    static func region(in document: PDFDocument, terms: [String], nextTerms: [String]) -> Region? {
        guard let start = find(terms, in: document, after: nil) else { return nil }
        return region(in: document, from: start, to: find(nextTerms, in: document, after: start))
    }

    static func region(in document: PDFDocument, from start: Place, to end: Place?) -> Region? {
        let lastPage = end?.page ?? min(start.page + 1, document.pageCount - 1)
        var parts: [(Int, CGRect)] = []
        for index in start.page...lastPage {
            guard let page = document.page(at: index) else { continue }
            let box = page.bounds(for: .cropBox)
            var top = box.maxY
            var bottom = box.minY
            if index == start.page { top = min(box.maxY, start.bounds.maxY + 10) }
            if let end, index == end.page { bottom = max(box.minY, end.bounds.maxY + 6) }
            guard top - bottom > 24 else { continue }
            parts.append((index, CGRect(x: box.minX, y: bottom, width: box.width, height: top - bottom)))
        }
        return parts.isEmpty ? nil : Region(parts: parts)
    }

    /// Le fichier réduit (gardé en cache), ou `nil` si l'exercice est introuvable.
    static func file(source: URL, exercise: Exercise, next: Exercise?) -> URL? {
        if let found = file(source: source, terms: terms(for: exercise), nextTerms: next.map(terms(for:)) ?? []) {
            return found
        }
        guard let document = PDFDocument(url: source),
              let region = region(in: document, exercise: exercise, next: next) else { return nil }
        return file(source: source, region: region, key: "rank|\(exercise.id)")
    }

    /// La zone de l'exercice : par ses mots (`terms`), sinon — exercice sans
    /// numéro imprimé, titré « Exercice » seul — par son **rang** : le n-ième
    /// titre « Exercice » du document.
    static func region(in document: PDFDocument, exercise: Exercise, next: Exercise?) -> Region? {
        if let found = region(in: document, terms: terms(for: exercise), nextTerms: next.map(terms(for:)) ?? []) {
            return found
        }
        guard let rank = exercise.series?.sortedExercises.firstIndex(where: { $0.id == exercise.id }) else { return nil }
        let headings = bareHeadings(in: document)
        guard rank < headings.count else { return nil }
        return region(in: document, from: headings[rank], to: rank + 1 < headings.count ? headings[rank + 1] : nil)
    }

    /// Les titres « Exercice », « Exercise », « Problème », « Problem », dans
    /// l'ordre du document — la famille la plus fournie, deux au moins.
    static func bareHeadings(in document: PDFDocument) -> [Place] {
        var best: [Place] = []
        for family in ["Exercice", "Exercise", "Problème", "Problem"] {
            var places: [Place] = []
            var previous: Place?
            while places.count < 40, let place = find([family], in: document, after: previous) {
                places.append(place)
                previous = place
            }
            if places.count > best.count { best = places }
        }
        return best.count >= 2 ? best : []
    }

    /// Un PDF réduit à une zone déjà trouvée (gardé en cache sous `key`).
    static func file(source: URL, region: Region, key: String) -> URL? {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let digest = SHA256.hash(data: Data(("v2|" + source.path + "|\(stamp)|" + key).utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Polymestre/crops", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(digest + ".pdf")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        guard let document = PDFDocument(url: source) else { return nil }
        let cropped = PDFDocument()
        for part in region.parts {
            guard let page = document.page(at: part.page)?.copy() as? PDFPage else { continue }
            page.setBounds(part.rect, for: .cropBox)
            cropped.insert(page, at: cropped.pageCount)
        }
        guard cropped.pageCount > 0, cropped.write(to: target) else { return nil }
        return target
    }

    /// Un PDF réduit à ce qui va d'un titre (`terms`) au suivant (`nextTerms`).
    static func file(source: URL, terms: [String], nextTerms: [String]) -> URL? {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let digest = SHA256.hash(data: Data(("v2|" + source.path + "|\(stamp)|" + terms.joined(separator: ",") + "|" + nextTerms.joined(separator: ",")).utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Polymestre/crops", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(digest + ".pdf")
        if FileManager.default.fileExists(atPath: target.path) { return target }

        guard let document = PDFDocument(url: source),
              let region = region(in: document, terms: terms, nextTerms: nextTerms) else { return nil }
        let cropped = PDFDocument()
        for part in region.parts {
            guard let page = document.page(at: part.page)?.copy() as? PDFPage else { continue }
            page.setBounds(part.rect, for: .cropBox)
            cropped.insert(page, at: cropped.pageCount)
        }
        guard cropped.pageCount > 0, cropped.write(to: target) else { return nil }
        return target
    }

    /// Les parties d'un sujet d'examen : la numérotation qu'il emploie
    /// (« Question 1, 2… », « Exercice 1, 2… », « Problème… »), suivie dans
    /// l'ordre du document. Au moins deux, sinon rien (le sujet se lit entier).
    static func questions(in document: PDFDocument) -> [String] {
        let families = ["Question", "Exercice", "Exercise", "Problème", "Problem", "Partie", "Part"]
        var best: [String] = []
        for family in families {
            var labels: [String] = []
            var previous: Place?
            for number in 1...30 {
                guard let place = find(["\(family) \(number)"], in: document, after: previous) else { break }
                labels.append("\(family) \(number)")
                previous = place
            }
            if labels.count > best.count { best = labels }
        }
        return best.count >= 2 ? best : []
    }

    /// Le premier **titre** trouvé (dans l'ordre des mots), après `after` : la
    /// ligne doit commencer par le mot (après un éventuel numéro « 1. »), sinon
    /// « utilise l'Exercise 1 » dans l'énoncé du 2 serait pris pour le titre du 1.
    /// Et « Exercice 1 » ne trouve pas « Exercice 10 ».
    static func find(_ terms: [String], in document: PDFDocument, after: Place?) -> Place? {
        for term in terms {
            let matches = document.findString(term, withOptions: [.caseInsensitive])
            for selection in matches {
                guard let page = selection.pages.first else { continue }
                let index = document.index(for: page)
                let bounds = selection.bounds(for: page)
                if let after {
                    if index < after.page || (index == after.page && bounds.maxY >= after.bounds.minY - 2) { continue }
                }
                guard isHeading(selection, term: term) else { continue }
                return Place(page: index, bounds: bounds)
            }
        }
        return nil
    }

    private static func isHeading(_ selection: PDFSelection, term: String) -> Bool {
        guard let line = selection.copy() as? PDFSelection else { return true }
        line.extendForLineBoundaries()
        let fold: (String) -> String = { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces) }
        var text = fold(line.string ?? "")
        let wanted = fold(term)
        // « 1. Titre », « 1) Titre », « (1) Titre », « 1 Titre » : le numéro s'ôte.
        if !text.hasPrefix(wanted) {
            text = text.replacingOccurrences(of: #"^\(?\d{1,2}[.)]?\)?\s*"#, with: "", options: .regularExpression)
        }
        guard text.hasPrefix(wanted) else { return false }
        let rest = text.dropFirst(wanted.count)
        return term.last?.isNumber != true || !(rest.first?.isNumber ?? false)
    }
}

/// L'énoncé (ou le corrigé) d'un exercice dans son PDF : l'exercice seul
/// quand on le retrouve ; sur demande, le PDF entier, ouvert à l'exercice et
/// l'exercice surligné.
struct ExercisePDFView: View {
    let file: URL
    let exercise: Exercise
    let next: Exercise?
    /// L'adresse du PDF entier (pour reprendre à sa page).
    var memory: String?

    @AppStorage("exercise.cropped") private var cropped = true
    @State private var crop: URL?
    @State private var region: PDFExerciseCrop.Region?
    @State private var searched = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if cropped, let crop {
                PDFPane(url: crop)
            } else if !searched {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PDFPane(url: file, search: region == nil ? PDFExerciseCrop.terms(for: exercise) : [],
                        memory: region == nil ? memory : nil, highlight: region)
            }
            if searched, crop != nil {
                Button { cropped.toggle() } label: {
                    Label(cropped ? "Tout le PDF" : "Cet exercice seul",
                          systemImage: cropped ? "doc.on.doc" : "rectangle.dashed")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(10)
                .help(cropped ? "Le PDF entier, l'exercice surligné" : "Ne montrer que cet exercice")
            }
        }
        .task(id: "\(file.path)|\(exercise.id)") {
            searched = false
            let terms = PDFExerciseCrop.terms(for: exercise)
            let nextTerms = next.map(PDFExerciseCrop.terms(for:)) ?? []
            region = PDFDocument(url: file).flatMap { PDFExerciseCrop.region(in: $0, exercise: exercise, next: next) }
            if let region {
                crop = PDFExerciseCrop.file(source: file, terms: terms, nextTerms: nextTerms)
                    ?? PDFExerciseCrop.file(source: file, region: region, key: "rank|\(exercise.id)")
            } else {
                crop = nil
            }
            searched = true
        }
    }
}
