import SwiftUI
import SwiftData

/// Une ligne de théorie sur la feuille d'une semaine : la coche « vu », ce que
/// c'est (vidéo, transparents, section, leçon du MOOC), et le lien direct vers
/// le support — la vidéo elle-même quand il y en a une.
struct CarnetTheoryLine: View {
    @Bindable var item: TheoryItem
    /// Le détail commun à toute la section (« Lecture · Botafogo ») : dit une
    /// fois dans son titre, il n'est pas répété sur chaque ligne.
    var hiddenDetail: String? = nil
    var onOpen: () -> Void
    var onBrowse: (BrowsedLink) -> Void

    @Environment(\.modelContext) private var context

    var body: some View {
        HStack(spacing: 0) {
            CheckCircleButton(isOn: item.isWatched,
                              tint: Carnet.tint(item.course?.colorHex ?? "#6B655A"),
                              label: String(localized: "Marquer \(item.title) vu")) {
                item.watchedAt = item.isWatched ? nil : Date()
                if item.watchedAt == nil { item.summarizedAt = nil }
                try? context.save()
            }
            .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 6) {
                Button(action: onOpen) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(MathMarkup.plain(item.title.isEmpty ? item.number : item.title))
                            .font(.body)
                            .foregroundStyle(item.isWatched ? Carnet.inkSecondary : Carnet.ink)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if detail != hiddenDetail, resourceGroups.isEmpty {
                            Text(detail)
                                .font(.footnote)
                                .foregroundStyle(Carnet.inkSecondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // **Toutes** les ressources de la semaine, une pastille par
                // nature : les vidéos, les transparents, les notes… Avant, seul
                // le lien principal (la vidéo) était accessible d'ici.
                // Une seule rangée d'accès : pas de bouton en double à droite.
                if !resourceGroups.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(resourceGroups, id: \.kind) { group in
                                resourceChip(group)
                            }
                        }
                    }
                    .scrollClipDisabled()
                }
            }
            .padding(.vertical, resourceGroups.isEmpty ? 0 : 6)
            .padding(.trailing, 8)

        }
        .padding(.vertical, 2)
    }

    private struct ResourceGroup {
        let kind: ContentLink.Kind
        let links: [ContentLink]
    }

    /// Les liens rangés par nature, dans l'ordre où on les utilise.
    private var resourceGroups: [ResourceGroup] {
        let order: [ContentLink.Kind] = [.video, .slides, .notes, .pdf, .page, .solution]
        // Un élément sans liens rangés n'a que son adresse : une pastille quand même.
        let all = item.links.isEmpty && ExerciseLinks.web(item.urlString) != nil
            ? [ContentLink(title: item.title, url: item.urlString, kind: item.kind == .video ? .video : .page)]
            : item.links
        return order.compactMap { kind in
            let links = all.filter { $0.kind == kind && ExerciseLinks.web($0.url) != nil }
            return links.isEmpty ? nil : ResourceGroup(kind: kind, links: links)
        }
    }

    @ViewBuilder
    private func resourceChip(_ group: ResourceGroup) -> some View {
        let label = HStack(spacing: 4) {
            Image(systemName: group.kind.icon).font(.caption2.weight(.semibold))
            Text(group.links.count > 1 ? "\(group.links.count) \(group.kind.pluralLabel)" : group.kind.chipLabel)
                .font(.caption.weight(.medium))
            if group.links.count > 1 {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
        }
        .foregroundStyle(Carnet.ink)
        .padding(.horizontal, 10)
        .frame(minHeight: 30)
        .background(Carnet.sheetRaised, in: Capsule())
        if group.links.count == 1, let link = group.links.first, let browsed = browsed(link) {
            Button { onBrowse(browsed) } label: { label }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Ouvrir \(link.title)")
        } else {
            Menu {
                ForEach(Array(group.links.enumerated()), id: \.offset) { _, link in
                    if let browsed = browsed(link) {
                        Button { onBrowse(browsed) } label: {
                            Label(link.title.isEmpty ? group.kind.chipLabel : link.title, systemImage: group.kind.icon)
                        }
                    }
                }
            } label: { label }
            .accessibilityLabel("\(group.links.count) \(group.kind.pluralLabel)")
        }
    }

    private func browsed(_ link: ContentLink) -> BrowsedLink? {
        ExerciseLinks.web(link.url).map { BrowsedLink(title: link.title.isEmpty ? item.title : link.title, url: $0, icon: link.kind.icon) }
    }

    /// Le détail partagé par **toutes** les lignes, s'il y en a un.
    static func sharedDetail(_ items: [TheoryItem]) -> String? {
        let details = Set(items.map { CarnetTheoryLine.detail(for: $0) })
        return items.count > 1 && details.count == 1 ? details.first : nil
    }

    private var detail: String { Self.detail(for: item) }

    /// « Vidéo · 1 h 32 · MediaSpace » ; « 3 vidéos · Courseware ».
    static func detail(for item: TheoryItem) -> String {
        var parts: [String] = []
        let videos = item.links.filter { $0.kind == .video }.count
        if videos > 1 {
            parts.append(String(localized: "\(videos) vidéos"))
        } else if item.videoCount > 1 {
            parts.append(String(localized: "\(item.videoCount) vidéos"))
        } else {
            parts.append(item.kind.label)
        }
        if item.durationSeconds > 0 { parts.append(DateUtils.durationLabel(seconds: item.durationSeconds)) }
        let others = Set(item.links.map(\.kind)).subtracting([.video]).map { $0.shortLabel }.sorted()
        parts.append(contentsOf: others)
        if let host = URL(string: item.links.first?.url ?? item.urlString)?.host {
            parts.append(siteName(host))
        }
        return parts.joined(separator: " · ")
    }

    static func siteName(_ host: String) -> String {
        let host = host.lowercased()
        if host.contains("mediaspace") { return "MediaSpace" }
        if host.contains("courseware") { return "Courseware" }
        if host.contains("botafogo") { return "Botafogo" }
        if host.contains("moodle") { return "Moodle" }
        if host.contains("dropbox") { return "Dropbox" }
        if host.contains("github") { return "GitHub" }
        if host.contains("youtube") || host.contains("youtu.be") { return "YouTube" }
        return host.replacingOccurrences(of: "www.", with: "")
    }
}

extension ContentLink.Kind {
    /// « Transparents », « Vidéo » : la pastille d'un seul lien.
    var chipLabel: String {
        switch self {
        case .video: return String(localized: "Vidéo")
        case .slides: return "Transparents"
        case .notes: return "Notes"
        case .pdf: return "PDF"
        case .page: return "Page"
        case .solution: return String(localized: "Corrigé")
        }
    }

    /// « 5 vidéos », « 2 transparents ».
    var pluralLabel: String {
        switch self {
        case .video: return String(localized: "vidéos")
        case .slides: return "transparents"
        case .notes: return "notes"
        case .pdf: return "PDF"
        case .page: return "pages"
        case .solution: return String(localized: "corrigés")
        }
    }

    /// « transparents », « notes » : le mot d'une ligne de détail.
    var shortLabel: String {
        switch self {
        case .video: return String(localized: "vidéo")
        case .slides: return "transparents"
        case .notes: return "notes"
        case .pdf: return "PDF"
        case .page: return "page"
        case .solution: return String(localized: "corrigé")
        }
    }
}

/// Une ligne d'exercice sur la feuille d'une semaine : son état, son numéro, son
/// titre, ses sous-questions en pastilles et sa correction.
struct CarnetExerciseLine: View {
    let exercise: Exercise

    var body: some View {
        let stage = ExerciseStage(exercise)
        HStack(spacing: 12) {
            ExerciseStageMark(stage: stage, size: 24)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(exercise.exerciseNumber)
                        .font(Carnet.mono(.footnote))
                        .foregroundStyle(Carnet.inkSecondary)
                    Text(MathMarkup.plain(exercise.title.isEmpty ? exercise.displayNumber : exercise.title))
                        .font(.body)
                        .foregroundStyle(Carnet.ink)
                        .lineLimit(1)
                    if exercise.isBonus {
                        Text("bonus").font(.caption).foregroundStyle(Carnet.inkTertiary)
                    }
                }
                let leaves = exercise.leafSubQuestions
                if !leaves.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(leaves.prefix(10)) { question in
                            Text(question.displayLabel)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(question.isDone ? Carnet.ground : Carnet.inkSecondary)
                                .frame(minWidth: 20, minHeight: 20)
                                .padding(.horizontal, 2)
                                .background(question.isDone ? Carnet.ink : Carnet.sheetRaised,
                                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        if leaves.count > 10 {
                            Text("+\(leaves.count - 10)").font(.caption2).foregroundStyle(Carnet.inkTertiary)
                        }
                    }
                    .accessibilityElement()
                    .accessibilityLabel("\(exercise.subQuestionDoneCount) sous-questions sur \(leaves.count)")
                }
            }
            Spacer(minLength: 4)
            stageLabel(stage)
        }
        .padding(.horizontal, Carnet.rowInset)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func stageLabel(_ stage: ExerciseStage) -> some View {
        switch stage {
        case .corrected(let result):
            Text(result.lineLabel).font(.footnote.weight(.semibold)).foregroundStyle(Carnet.color(for: result))
        case .redo:
            Text("à refaire").font(.footnote.weight(.semibold)).foregroundStyle(Carnet.wrong)
        case .toCorrect:
            Text("à corriger").font(.footnote).foregroundStyle(Carnet.inkSecondary)
        case .inProgress(let done, let total):
            Text("\(done)/\(total)").font(Carnet.mono(.footnote)).foregroundStyle(Carnet.inkSecondary)
        case .toDo:
            EmptyView()
        }
    }
}

extension Correctness {
    /// « juste », « à revoir », « faux » : le mot d'une ligne d'exercice.
    var lineLabel: String {
        switch self {
        case .correct: return "juste"
        case .partial: return String(localized: "à revoir")
        case .wrong: return "faux"
        }
    }
}
