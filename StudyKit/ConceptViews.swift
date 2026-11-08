import SwiftUI

// MARK: - Où j'en suis

extension StudyMap.Mastery {
    var color: Color {
        switch self {
        case .unknown: return Carnet.inkTertiary
        case .shaky: return Carnet.review
        case .solid: return Carnet.correct
        }
    }

    var icon: String {
        switch self {
        case .unknown: return "circle.dotted"
        case .shaky: return "circle.lefthalf.filled"
        case .solid: return "checkmark.circle.fill"
        }
    }
}

/// Un point qui dit où l'on en est sur une notion : un trait pointillé (pas encore), à moitié
/// plein (fragile), plein (solide). La forme, pas seulement la couleur : jamais un verdict en couleur seule.
struct MasteryDot: View {
    let level: StudyMap.Mastery
    var size: CGFloat = 12

    var body: some View {
        Image(systemName: level.icon)
            .font(.system(size: size))
            .foregroundStyle(level.color)
            .accessibilityLabel(level.label)
    }
}

/// Les trois niveaux, à choisir.
struct MasteryPicker: View {
    let level: StudyMap.Mastery
    var set: (StudyMap.Mastery) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(StudyMap.Mastery.allCases, id: \.rawValue) { item in
                Button { set(item) } label: {
                    Label(item.label, systemImage: item.icon)
                        .font(.caption.weight(level == item ? .semibold : .regular))
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .foregroundStyle(level == item ? Carnet.ground : item.color)
                        .background(level == item ? item.color : item.color.opacity(0.14), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Une notion en une ligne, à toucher : où l'on en est, son titre.
struct ConceptChip: View {
    let title: String
    let level: StudyMap.Mastery
    var relation: StudyMap.Relation?
    var note: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                MasteryDot(level: level, size: 11)
                MacMathText(title, size: 13).foregroundStyle(Carnet.ink).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                if let relation { Image(systemName: relation.icon).font(.caption2).foregroundStyle(Carnet.inkTertiary) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Carnet.sheetRaised.opacity(0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(note ?? "")
    }
}

// MARK: - Une notion, pour la comprendre

/// La page d'une notion : l'idée en clair, à quoi elle sert, l'énoncé, ce qu'il faut comprendre
/// avant (et reprendre si c'est fragile), ce qui en découle, ce qu'il ne faut pas confondre avec
/// elle, un exemple, une question pour se tester, et sa note à soi.
struct ConceptDetailView: View {
    @Bindable var course: Course
    let key: String
    var select: (String) -> Void
    var openPoly: (String) -> Void = { _ in }
    var close: (() -> Void)?

    @State private var reveal = false
    @State private var note = ""
    @State private var linking = false
    private var store: StudyMapStore { .shared }
    private var tint: Color { Carnet.tint(course.colorHex) }

    var body: some View {
        let sheet = course.revisionSheet
        let map = store.map(course)
        if let sheet, let item = sheet.entry(forKey: key) {
            let keys = Set(sheet.keyed.map(\.key))
            let near = StudyLinks.neighbourhood(of: key, in: map, among: keys)
            let level = map.mastery(key)
            let extra = map.enrichment[key]
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(item.entry, chapter: item.chapterTitle)
                        .overlay(alignment: .topTrailing) {
                            if let close {
                                Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(Carnet.inkTertiary) }
                                    .buttonStyle(.plain).help("Fermer")
                            }
                        }
                    if let gist = extra?.gist {
                        VStack(alignment: .leading, spacing: 4) {
                            Kicker("En clair", color: tint)
                            Text(gist).font(.body).foregroundStyle(Carnet.ink).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    if let why = extra?.why {
                        Label { Text(why).foregroundStyle(Carnet.inkSecondary) } icon: { Image(systemName: "questionmark.circle").foregroundStyle(Carnet.inkTertiary) }
                            .font(.callout)
                    }
                    RichTextView(text: item.entry.body, size: 14).textSelection(.enabled)
                    if let example = extra?.example {
                        VStack(alignment: .leading, spacing: 4) {
                            Kicker("Exemple")
                            RichTextView(text: example, size: 13)
                        }
                    }
                    if !item.entry.link.isEmpty {
                        Button { openPoly(item.entry.link) } label: { Label("Relire dans le cours", systemImage: "book") }
                            .buttonStyle(.paper)
                    }

                    mastery(level)

                    let weak = LearningPath.shakyPrerequisites(of: key, map: map, among: keys)
                    if !weak.isEmpty, level != .solid {
                        Label("Reprends d'abord : " + weak.compactMap { sheet.entry(forKey: $0)?.entry.title }.prefix(2).joined(separator: ", "),
                              systemImage: "arrow.uturn.backward.circle")
                            .font(.callout)
                            .foregroundStyle(Carnet.review)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    related(String(localized: "À comprendre avant"), near.before, sheet: sheet, map: map)
                    related(String(localized: "Ce qui en découle"), near.after, sheet: sheet, map: map)
                    related(String(localized: "À ne pas confondre avec"), near.aside, sheet: sheet, map: map)
                    linksEditor(sheet: sheet, map: map)
                    if let check = extra?.check { selfTest(check) }
                    noteField
                }
                .padding(18)
            }
            .background(Carnet.ground)
            .id(key)
            .onAppear { note = map.notes[key] ?? "" }
            .onChange(of: key) { _, _ in
                note = store.map(course).notes[key] ?? ""
                reveal = false
            }
        } else {
            ContentUnavailableView("Cette notion n'est plus sur la fiche", systemImage: "questionmark.folder")
        }
    }

    private func header(_ entry: RevisionSheet.Entry, chapter: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: entry.kind.icon).font(.caption)
                Text(entry.kind.label.uppercased()).font(.caption2.weight(.semibold)).tracking(0.8)
                Text("· " + chapter).font(.caption2).lineLimit(1)
            }
            .foregroundStyle(Carnet.inkSecondary)
            MacMathText(entry.title, size: 22, design: .serif).foregroundStyle(Carnet.ink).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func mastery(_ level: StudyMap.Mastery) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Kicker("Où j'en suis")
            MasteryPicker(level: level) { store.setMastery($0, for: key, in: course) }
        }
    }

    @ViewBuilder
    private func related(_ title: String, _ items: [StudyLinks.Neighbourhood.Item], sheet: RevisionSheet, map: StudyMap) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Kicker(title)
                ForEach(items) { item in
                    if let target = sheet.entry(forKey: item.key) {
                        ConceptChip(title: target.entry.title, level: map.mastery(item.key), relation: item.relation, note: item.note) {
                            select(item.key)
                        }
                        if let note = item.note {
                            Text(note).font(.caption).foregroundStyle(Carnet.inkTertiary).padding(.leading, 10)
                        }
                    }
                }
            }
        }
    }

    // MARK: Mes liens

    private func linksEditor(sheet: RevisionSheet, map: StudyMap) -> some View {
        let mine = map.links.filter { $0.userMade && ($0.from == key || $0.to == key) }
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(mine) { link in
                HStack(spacing: 6) {
                    let other = link.from == key ? link.to : link.from
                    Image(systemName: link.relation.icon).font(.caption).foregroundStyle(Carnet.inkTertiary)
                    Text((link.from == key ? link.relation.label : link.relation.inverseLabel) + " " + (sheet.entry(forKey: other)?.entry.title ?? other))
                        .font(.caption).foregroundStyle(Carnet.inkSecondary).lineLimit(2)
                    Spacer(minLength: 4)
                    Button { store.update(course) { $0.links.removeAll { $0.id == link.id } } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).foregroundStyle(Carnet.inkTertiary).help("Retirer mon lien")
                }
            }
            Button { linking = true } label: { Label("Relier à une autre notion", systemImage: "link.badge.plus") }
                .buttonStyle(.paper)
                .popover(isPresented: $linking) { LinkEditor(course: course, from: key) { linking = false } }
        }
    }

    // MARK: Se tester

    private func selfTest(_ check: StudyMap.Check) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Kicker("Teste-toi", color: tint)
            RichTextView(text: check.question, size: 14)
            if reveal {
                RichTextView(text: check.answer, size: 14)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Carnet.correct.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                HStack(spacing: 8) {
                    Button { store.setMastery(.solid, for: key, in: course); reveal = false } label: { Label("Je savais", systemImage: "checkmark") }
                        .buttonStyle(.ink)
                    Button { store.setMastery(.shaky, for: key, in: course); reveal = false } label: { Label("À revoir", systemImage: "arrow.counterclockwise") }
                        .buttonStyle(.paper)
                }
            } else {
                Button { withAnimation(.snappy) { reveal = true } } label: { Label("Voir la réponse", systemImage: "eye") }
                    .buttonStyle(.paper)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Carnet.rule))
    }

    // MARK: Ma note

    private var noteField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Kicker("Ma note")
            TextEditor(text: $note)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 70)
                .padding(8)
                .background(Carnet.sheetRaised.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onChange(of: note) { _, text in store.setNote(text, for: key, in: course) }
        }
    }
}

// MARK: - Relier deux notions

/// Choisir une autre notion et la relation : un lien à soi, que rien n'écrase.
struct LinkEditor: View {
    @Bindable var course: Course
    let from: String
    var done: () -> Void

    @State private var query = ""
    @State private var relation: StudyMap.Relation = .needs

    private var candidates: [RevisionSheet.KeyedEntry] {
        let all = (course.revisionSheet?.keyed ?? []).filter { $0.key != from }
        let words = RevisionText.words(query, minimum: 1)
        guard !words.isEmpty else { return Array(all.prefix(30)) }
        return Array(all.filter { item in
            let haystack = RevisionText.fold(item.entry.title + " " + item.chapterTitle)
            return words.allSatisfy { haystack.contains($0) }
        }.prefix(30))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Relation", selection: $relation) {
                ForEach(StudyMap.Relation.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            TextField("Chercher une notion…", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(candidates) { item in
                        Button {
                            StudyMapStore.shared.update(course) { map in
                                let link = StudyMap.Link(from: from, to: item.key, relation: relation, note: nil, userMade: true)
                                if !map.links.contains(where: { $0.id == link.id }) { map.links.append(link) }
                            }
                            done()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: item.entry.kind.icon).font(.caption2).frame(width: 14)
                                MacMathText(item.entry.title, size: 13).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 220)
        }
        .padding(14)
        .frame(width: 330)
    }
}
