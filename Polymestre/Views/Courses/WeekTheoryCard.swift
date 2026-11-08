import SwiftUI

/// Un élément de théorie de la semaine, **avec tout ce qu'il faut regarder**.
///
/// La ligne compacte (titre + pastilles) suffit pour parcourir tout le cours ;
/// pour la semaine, on veut savoir quoi faire : chaque vidéo et chaque support
/// a sa ligne, nommée, ouvrable d'un toucher. « Cours de la semaine 3 » avec
/// une pastille « 5 vidéos ▾ » ne disait pas qu'il s'agissait d'un
/// enregistrement du cours et de deux chapitres du MOOC.
struct WeekTheoryCard: View {
    @Bindable var item: TheoryItem
    var onOpen: () -> Void
    var onBrowse: (BrowsedLink) -> Void

    @Environment(\.modelContext) private var context
    @State private var showsAll = false

    private var tint: Color { Carnet.tint(item.course?.colorHex ?? "#6B655A") }

    /// « Cours » ou « MOOC » : d'où vient ce travail.
    private var kicker: String {
        // Un élément fait seulement de liens vers le MOOC en vient, quel que soit son titre.
        if item.title.hasPrefix("MOOC") || (!links.isEmpty && links.allSatisfy(isMOOCLink)) { return "MOOC · à regarder" }
        let videos = links.filter { $0.kind == .video }.count
        let supports = links.count - videos
        switch (videos > 0, supports > 0) {
        case (true, true): return String(localized: "Cours · enregistrement et supports")
        case (true, false): return String(localized: "Cours · enregistrement")
        case (false, true): return String(localized: "Cours · supports")
        default: return String(localized: "Cours")
        }
    }

    private var title: String {
        let raw = item.title.isEmpty ? item.number : item.title
        return raw.hasPrefix("MOOC · ") ? String(raw.dropFirst("MOOC · ".count)) : raw
    }

    private var links: [ContentLink] {
        let all = item.links.isEmpty && ExerciseLinks.web(item.urlString) != nil
            ? [ContentLink(title: item.title, url: item.urlString, kind: item.kind == .video ? .video : .page)]
            : item.links
        // Les vidéos d'abord, puis les supports.
        let order: [ContentLink.Kind] = [.video, .slides, .notes, .pdf, .page, .solution]
        return all.filter { ExerciseLinks.web($0.url) != nil }
            .sorted { (order.firstIndex(of: $0.kind) ?? 9) < (order.firstIndex(of: $1.kind) ?? 9) }
    }

    /// Une ligne de ressource : une leçon de MOOC (ses vidéos réunies), un
    /// enregistrement, un support, le quiz du chapitre. Les doublons
    /// (transparents « 4 pages » et « 1 page ») n'en font qu'une ; l'aperçu et
    /// la conclusion d'un chapitre de MOOC sont réunis en une ligne, après le reste.
    struct Row: Identifiable {
        let id: String
        let title: String
        let kind: ContentLink.Kind
        let links: [ContentLink]
        var icon: String? = nil
        var detail: String? = nil
    }

    var rows: [Row] {
        var result: [Row] = []
        var extras: [ContentLink] = []
        for link in links {
            let cleaned = rowTitle(link)
            let lesson = cleaned.components(separatedBy: " — ").first ?? cleaned
            let folded = ContentDraftBuilder.fold(lesson)
            if link.kind == .page, isMOOCLink(link) {
                // « Exercices online (6 Questions) » → « Exercices online · 6 questions ».
                let count = lesson.range(of: #"(?i)\((\d+) questions?\)"#, options: .regularExpression)
                if count != nil || folded.contains("controle des connaissances") || folded.contains("quiz") {
                    let number = count.map { String(lesson[$0].filter(\.isNumber)) }
                    let name = lesson.replacingOccurrences(of: #"(?i)\s*\(\d+ questions?\)"#, with: "", options: .regularExpression)
                        .replacingOccurrences(of: #"^[\d.]+\s+"#, with: "", options: .regularExpression)
                    result.append(Row(id: "q:" + folded, title: name.isEmpty ? String(localized: "Quiz du chapitre") : name, kind: link.kind, links: [link],
                                      icon: "checklist",
                                      detail: number.map { "Quiz · \($0) questions · Courseware" } ?? "Quiz · Courseware"))
                } else {
                    extras.append(link)
                }
                continue
            }
            let key = (link.kind == .video ? "v:" : "d:") + folded
            if let index = result.firstIndex(where: { $0.id == key }) {
                let row = result[index]
                // Un support en double garde la version complète (« 1 page sur 1 »).
                if link.kind != .video { continue }
                result[index] = Row(id: key, title: row.title, kind: row.kind, links: row.links + [link])
            } else {
                result.append(Row(id: key, title: lesson, kind: link.kind, links: [link]))
            }
        }
        if !extras.isEmpty {
            let names = extras.map { rowTitle($0) }
            result.append(Row(id: "p:extras", title: extras.count == 1 ? names[0] : names.joined(separator: ", "),
                              kind: .page, links: extras, icon: "doc.text",
                              detail: extras.count == 1 ? "Page · Courseware" : "\(extras.count) pages · Courseware"))
        }
        return result
    }

    private func isMOOCLink(_ link: ContentLink) -> Bool {
        URL(string: link.url)?.host?.contains("courseware") == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !rows.isEmpty {
                CarnetRule(inset: 16)
                let all = rows
                let shown = showsAll ? all : Array(all.prefix(5))
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, row in
                    resourceRow(row)
                    if index < shown.count - 1 { CarnetRule(inset: 52) }
                }
                if all.count > 5 {
                    CarnetRule(inset: 16)
                    Button {
                        withAnimation(Motion.snappy) { showsAll.toggle() }
                    } label: {
                        Text(showsAll ? "Moins" : "Voir les \(rows.count) lignes")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Carnet.inkSecondary)
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: Carnet.sheetCorner, bottomLeadingRadius: Carnet.sheetCorner, style: .continuous)
                .fill(item.isWatched ? Carnet.correct.opacity(0.6) : tint)
                .frame(width: 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            CheckCircleButton(isOn: item.isWatched, tint: tint, label: "Marquer \(title) vu") {
                item.watchedAt = item.isWatched ? nil : Date()
                if item.watchedAt == nil { item.summarizedAt = nil }
                try? context.save()
                Haptics.soft()
            }
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 3) {
                    CarnetKicker(kicker, color: tint)
                    MathText(title, font: Carnet.serif(.headline))
                        .foregroundStyle(item.isWatched ? Carnet.inkSecondary : Carnet.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(Carnet.inkSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
    }

    /// « 2 vidéos · transparents · 1 h 32 ».
    private var summary: String {
        var parts: [String] = []
        let videos = links.filter { $0.kind == .video }.count
        if item.title.hasPrefix("MOOC") {
            // « 7 leçons · 16 vidéos · quiz » : ce que le chapitre demande.
            let lessons = rows.filter { $0.kind == .video }.count
            if lessons > 1 { parts.append(String(localized: "\(lessons) leçons")) }
            if videos > 0 { parts.append(videos == 1 ? String(localized: "1 vidéo") : String(localized: "\(videos) vidéos")) }
            if rows.contains(where: { $0.id.hasPrefix("q:") }) { parts.append("quiz") }
        } else {
            if videos > 0 { parts.append(videos == 1 ? String(localized: "1 vidéo") : String(localized: "\(videos) vidéos")) }
            let supports = Set(links.map(\.kind)).subtracting([.video]).map(\.shortLabel).sorted()
            parts.append(contentsOf: supports)
        }
        if item.durationSeconds > 0 { parts.append(DateUtils.durationLabel(seconds: item.durationSeconds)) }
        if item.isWatched { parts.append(String(localized: "vu")) }
        return parts.isEmpty ? item.kind.label : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func resourceRow(_ row: Row) -> some View {
        let label = HStack(spacing: 12) {
            Image(systemName: row.icon ?? (row.kind == .video ? "play.circle.fill" : row.kind.icon))
                .font(.body)
                .foregroundStyle(row.kind == .video ? tint : Carnet.inkSecondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.subheadline)
                    .foregroundStyle(Carnet.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(rowDetail(row))
                    .font(.caption)
                    .foregroundStyle(Carnet.inkTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: row.links.count > 1 ? "chevron.up.chevron.down" : "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Carnet.inkTertiary)
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .frame(minHeight: 48)
        .contentShape(Rectangle())

        if row.links.count > 1 {
            // Plusieurs vidéos dans une leçon (ou plusieurs pages) : un menu, chacune nommée.
            Menu {
                ForEach(Array(row.links.enumerated()), id: \.offset) { index, link in
                    Button { open(link) } label: {
                        if link.kind == .video {
                            Label(videoName(link, index: index), systemImage: "play.circle")
                        } else {
                            Label(rowTitle(link), systemImage: link.kind.icon)
                        }
                    }
                }
            } label: { label }
            .accessibilityLabel(row.kind == .video ? "\(row.title), \(row.links.count) vidéos" : row.title)
        } else if let link = row.links.first {
            Button { open(link) } label: { label }
                .buttonStyle(.plain)
                .accessibilityLabel("\(row.kind.chipLabel) : \(row.title)")
        }
    }

    private func open(_ link: ContentLink) {
        if let url = ExerciseLinks.web(link.url) {
            onBrowse(BrowsedLink(title: link.title.isEmpty ? title : link.title, url: url, icon: link.kind.icon))
        }
    }

    /// « Partie 2 », ou la fin du titre (« Variables — Déclaration » →
    /// « Déclaration »). Les vidéos du MOOC s'appellent toutes « Regardez: » :
    /// leur numéro vient de l'adresse (« …partie_2__ID-1275 »).
    private func videoName(_ link: ContentLink, index: Int) -> String {
        let parts = link.title.components(separatedBy: " — ")
        let suffix = parts.dropFirst().joined(separator: " — ").trimmingCharacters(in: .whitespaces)
        let generic = ContentDraftBuilder.fold(suffix).range(of: #"^(regardez|video|watch)?\s*:?$"#, options: .regularExpression) != nil
        if !suffix.isEmpty, !generic { return suffix }
        if let range = link.url.range(of: #"(?i)partie_?(\d+)"#, options: .regularExpression),
           let number = link.url[range].split(whereSeparator: { !$0.isNumber }).last {
            return String(localized: "Partie \(number)")
        }
        return String(localized: "Vidéo \(index + 1)")
    }

    /// « 2 vidéos · Courseware », « Transparents · proginsc ».
    private func rowDetail(_ row: Row) -> String {
        if let detail = row.detail { return detail }
        let site = URL(string: row.links.first?.url ?? "")?.host.map(CarnetTheoryLine.siteName) ?? ""
        let what = row.kind == .video
            ? (row.links.count > 1 ? "\(row.links.count) parties" : String(localized: "Vidéo"))
            : row.kind.chipLabel
        return [what, site].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func rowTitle(_ link: ContentLink) -> String {
        let text = link.title.isEmpty ? link.kind.chipLabel : link.title
        return text.replacingOccurrences(of: #"\s*\((?:\d+ pages? sur \d+|1 page sur 1)\)"#, with: "",
                                         options: [.regularExpression, .caseInsensitive])
    }
}
