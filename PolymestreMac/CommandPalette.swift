import SwiftUI
import SwiftData

/// ⌘K : tout l'app au clavier. Taper un cours, une série, un exercice, une
/// action ; ↩ ouvre, ⌘↩ chronomètre, Échap ferme.
struct CommandPalette: View {
    enum Destination {
        case page(MacRootView.Page)
        case target(course: UUID, item: UUID?)
    }

    var navigate: (Destination) -> Void
    var dismiss: () -> Void

    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings
    @Environment(\.openSettings) private var openSettings
    @Query(sort: \Course.code) private var courses: [Course]
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    typealias Item = PaletteItem

    private var tracked: [Course] { courses.filter(\.isTracked) }

    var body: some View {
        let items = results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                TextField("Chercher", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .focused($focused)
                    .onSubmit { run(items, timing: false) }
                    .onKeyPress(.downArrow) { move(1, in: items); return .handled }
                    .onKeyPress(.upArrow) { move(-1, in: items); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        run(items, timing: true)
                        return .handled
                    }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if items.isEmpty {
                            Text("Rien pour « \(query) ».")
                                .foregroundStyle(.secondary)
                                .padding(18)
                        }
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index == 0 || items[index - 1].section != item.section {
                                Text(item.section)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 18)
                                    .padding(.top, index == 0 ? 8 : 12)
                                    .padding(.bottom, 4)
                            }
                            PaletteRow(item: item, selected: index == selected)
                                .id(index)
                                .onTapGesture { selected = index; run(items, timing: false) }
                                .onHover { if $0 { selected = index } }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .onChange(of: selected) { _, value in proxy.scrollTo(value) }
            }
            .frame(height: 360)
            Divider()
            HStack(spacing: 14) {
                hint("↩", String(localized: "ouvrir"))
                hint("⌘↩", String(localized: "chronométrer"))
                hint("↑↓", "choisir")
                Spacer()
                hint(String(localized: "Échap"), String(localized: "fermer"))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
        .frame(width: 620)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Carnet.rule))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in selected = 0 }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Carnet.sheetRaised, in: RoundedRectangle(cornerRadius: 4))
            Text(label).font(.caption).foregroundStyle(Carnet.inkSecondary)
        }
    }

    private func move(_ delta: Int, in items: [Item]) {
        guard !items.isEmpty else { return }
        selected = (selected + delta + items.count) % items.count
    }

    private func run(_ items: [Item], timing: Bool) {
        guard items.indices.contains(selected) else { return }
        let item = items[selected]
        if timing, let time = item.time { time() } else { item.run() }
        dismiss()
    }

    // MARK: Résultats

    private var results: [Item] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let actions = actionItems.filter { needle.isEmpty || matches($0.title, needle) }
        guard !needle.isEmpty else {
            return actions + tracked.map(courseItem)
        }
        let hits = SearchEngine.search(needle, in: SearchIndexBuilder.documents(courses: tracked))
            .filter { [.course, .series, .exercise, .theory, .exam].contains($0.kind) }
            .prefix(40)
        let found: [Item] = hits.compactMap { hit in
            guard let target = resolve(hit) else { return nil }
            let course = tracked.first { $0.id == target.course }
            var item = Item(id: hit.document.id, title: hit.document.title,
                            subtitle: [hit.document.courseCode, hit.document.subtitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                            icon: hit.kind.icon, tint: MacTargets.tint(course), section: hit.kind.label,
                            run: { navigate(.target(course: target.course, item: target.item)) })
            if let id = target.item, let course {
                let type: TaskType = course.theoryItems.contains { $0.id == id } ? .theory : .exercise
                item.time = { time(course.id, type, id) }
            } else {
                item.time = { time(target.course, .exercise, nil) }
            }
            return item
        }
        return actions + found.sorted { $0.section < $1.section }
    }

    private var actionItems: [Item] {
        var items: [Item] = []
        switch timer.phase {
        case .idle:
            items.append(Item(id: "a.start", title: String(localized: "Démarrer le chrono"), icon: "play.fill", section: "Chrono", shortcut: "⌘T") { timer.start() })
        case .running:
            items.append(Item(id: "a.pause", title: String(localized: "Mettre en pause"), icon: "pause.fill", section: "Chrono", shortcut: "⌘T") { timer.pause() })
        case .paused:
            items.append(Item(id: "a.resume", title: String(localized: "Reprendre"), icon: "play.fill", section: "Chrono", shortcut: "⌘T") { timer.resume() })
        case .onBreak:
            items.append(Item(id: "a.skip", title: String(localized: "Écourter la pause"), icon: "forward.fill", section: "Chrono") { timer.skipBreak() })
        }
        if timer.phase != .idle, !timer.isLocked {
            items.append(Item(id: "a.finish", title: String(localized: "Terminer et enregistrer"), icon: "checkmark", section: "Chrono", shortcut: "⇧⌘T") { timer.finish() })
        }
        items.append(Item(id: "a.float", title: settings.floatingTimer ? String(localized: "Masquer le chrono flottant") : String(localized: "Afficher le chrono flottant"),
                          icon: "pip", section: "Chrono") {
            settings.floatingTimer.toggle()
            MiniTimerPanel.shared.update()
        })
        items.append(Item(id: "p.today", title: String(localized: "Aujourd'hui"), icon: "sun.max", section: "Aller à", shortcut: "⌘1") { navigate(.page(.today)) })
        items.append(Item(id: "p.focus", title: String(localized: "Chrono"), icon: "timer", section: "Aller à", shortcut: "⌘2") { navigate(.page(.focus)) })
        items.append(Item(id: "p.agenda", title: String(localized: "Agenda"), icon: "calendar", section: "Aller à", shortcut: "⌘3") { navigate(.page(.agenda)) })
        items.append(Item(id: "p.stats", title: String(localized: "Bilan"), icon: "chart.bar.xaxis", section: "Aller à", shortcut: "⌘4") { navigate(.page(.stats)) })
        items.append(Item(id: "a.study", title: String(localized: "Mode étude…"), subtitle: String(localized: "Plein écran"),
                          icon: "moon.stars", section: "Actions", shortcut: "⇧⌘E") {
            StudyModeController.shared.presentSetup(courseID: timer.courseID)
        })
        items.append(Item(id: "a.settings", title: String(localized: "Réglages…"), icon: "gearshape", section: "Aller à", shortcut: "⌘,") { openSettings() })
        return items
    }

    private func courseItem(_ course: Course) -> Item {
        Item(id: "c.\(course.id)", title: course.name, subtitle: course.displayCode, icon: "book.closed.fill",
             tint: Carnet.tint(course.colorHex), section: "Cours",
             run: { navigate(.page(.course(course.id))) },
             time: { time(course.id, .exercise, nil) })
    }

    private func time(_ course: UUID, _ type: TaskType, _ target: UUID?) {
        if timer.phase == .idle {
            timer.start(courseID: course, taskType: type, targetID: target)
        } else {
            timer.retarget(courseID: course, taskType: type, targetID: target)
        }
    }

    private func matches(_ text: String, _ needle: String) -> Bool {
        text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// `exercise.<uuid>` → le cours et l'élément.
    private func resolve(_ hit: SearchHit) -> (course: UUID, item: UUID?)? {
        let parts = hit.document.id.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch hit.kind {
        case .course: return (id, nil)
        case .series:
            return tracked.first { $0.series.contains { $0.id == id } }
                .map { ($0.id, $0.series.first { $0.id == id }?.sortedExercises.first?.id) }
        case .exercise:
            return tracked.first { $0.allExercises.contains { $0.id == id } }.map { ($0.id, id) }
        case .theory:
            return tracked.first { $0.theoryItems.contains { $0.id == id } }.map { ($0.id, id) }
        case .exam:
            return tracked.first { $0.exams.contains { $0.id == id } }.map { ($0.id, nil) }
        default: return nil
        }
    }
}
