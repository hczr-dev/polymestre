import SwiftUI

/// Moodle dans le bureau : la page du cours comme on aimerait la lire. À
/// gauche les semaines (celle en cours ouverte), filtrables ; à droite la
/// semaine choisie (son texte, ses activités en cartes) ou l'activité ouverte,
/// toujours en natif.
struct MoodleCourseList: View {
    let page: MoodleCoursePage
    let tint: Color
    var selectedSection: Int?
    var selectedActivity: Int?
    var openSection: (MoodleCoursePage.Section) -> Void
    var openActivity: (MoodleCoursePage.Activity) -> Void

    enum Filter: String, CaseIterable, Identifiable {
        case all, series, documents, videos, tasks
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return String(localized: "Tout")
            case .series: return String(localized: "Séries")
            case .documents: return "Documents"
            case .videos: return String(localized: "Vidéos")
            case .tasks: return "Devoirs"
            }
        }

        func keeps(_ activity: MoodleCoursePage.Activity) -> Bool {
            switch self {
            case .all: return activity.module != "label"
            case .series: return activity.isSeries
            case .documents: return ["resource", "folder", "page"].contains(activity.module) && !activity.isSeries
            case .videos: return activity.isVideo
            case .tasks: return ["assign", "quiz"].contains(activity.module)
            }
        }
    }

    @State private var filter: Filter = .all
    @State private var expanded: Set<Int> = []

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Filter.allCases) { item in
                        Button { filter = item } label: {
                            Text(item.label)
                                .font(.caption.weight(filter == item ? .semibold : .regular))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(filter == item ? tint.opacity(0.18) : Carnet.sheetRaised, in: Capsule())
                                .foregroundStyle(filter == item ? Carnet.ink : Carnet.inkSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            ScrollViewReader { proxy in
                List {
                    ForEach(page.sections) { section in
                        let activities = section.activities.filter(filter.keeps)
                        if filter == .all || !activities.isEmpty {
                            Section {
                                if filter != .all || expanded.contains(section.number) || section.isCurrent {
                                    ForEach(activities) { activity in
                                        row(activity)
                                    }
                                }
                            } header: {
                                header(section, count: activities.count)
                                    .id(section.number)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .onAppear {
                    if let current = page.currentSection() {
                        expanded.insert(current.number)
                        proxy.scrollTo(current.number, anchor: .top)
                    }
                }
            }
        }
    }

    private func header(_ section: MoodleCoursePage.Section, count: Int) -> some View {
        Button {
            if expanded.contains(section.number) { expanded.remove(section.number) } else { expanded.insert(section.number) }
            openSection(section)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: expanded.contains(section.number) || section.isCurrent || filter != .all ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(Carnet.inkTertiary)
                    .frame(width: 10)
                Text(section.title).font(Carnet.serif(.headline)).foregroundStyle(Carnet.ink).lineLimit(1)
                if section.number == page.currentSection()?.number { Kicker("cette semaine", color: tint) }
                Spacer(minLength: 0)
                let done = section.activities.filter(\.completed).count
                if done > 0 { Text("\(done)/\(section.activities.filter { $0.module != "label" }.count)").font(.caption2.monospacedDigit()).foregroundStyle(Carnet.inkTertiary) }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .background(selectedSection == section.number ? tint.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func row(_ activity: MoodleCoursePage.Activity) -> some View {
        Button { openActivity(activity) } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: MoodleCourseList.icon(activity))
                    .foregroundStyle(tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(activity.name).foregroundStyle(Carnet.ink).lineLimit(2)
                    if let detail = MoodleCourseList.detail(activity) {
                        Text(detail).font(.caption2).foregroundStyle(Carnet.inkTertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if activity.completed {
                    Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(Carnet.correct)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(selectedActivity == activity.id ? tint.opacity(0.12) : Color.clear)
    }

    static func icon(_ activity: MoodleCoursePage.Activity) -> String {
        if activity.isSeries { return activity.name.lowercased().contains("corrig") || activity.name.lowercased().contains("sol") ? "checkmark.seal" : "list.number" }
        if activity.isVideo { return "play.rectangle" }
        if activity.module == "lti", activity.name.lowercased().contains("ed") { return "bubble.left.and.text.bubble.right" }
        return moduleIcon(activity.module)
    }

    static func moduleIcon(_ module: String) -> String {
        switch module {
        case "resource": return "doc.richtext"
        case "folder": return "folder"
        case "url": return "link"
        case "page": return "doc.text"
        case "assign": return "tray.and.arrow.up"
        case "forum": return "bubble.left.and.bubble.right"
        case "quiz": return "checklist"
        default: return "square.grid.2x2"
        }
    }

    static func detail(_ activity: MoodleCoursePage.Activity) -> String? {
        if let date = activity.dates.last { return date }
        let lower = activity.name.lowercased()
        let solution = lower.contains("corrig") || lower.contains("solution") || lower.hasSuffix(" sol") || lower.contains(" sol ")
        let label = activity.isVideo ? String(localized: "Vidéo") : (activity.isSeries ? (solution ? String(localized: "Corrigé") : String(localized: "Série")) : activity.kindLabel)
        return label.isEmpty ? nil : label
    }
}

/// Une semaine de Moodle, en page : son texte, puis ses activités en cartes.
struct MoodleSectionPage: View {
    let section: MoodleCoursePage.Section
    let tint: Color
    var desk: SiteHub
    var openActivity: (MoodleCoursePage.Activity) -> Void
    var openLink: (String, String) -> Void
    var openWeb: (URL, String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if section.isCurrent { Kicker("cette semaine", color: tint) }
                Text(section.title).font(Carnet.serif(30)).foregroundStyle(Carnet.ink)
                if !section.summary.isEmpty {
                    SiteBlocksView(blocks: SiteHTML.blocks(section.summary, base: URL(string: Institution.current.moodleBase + "/")),
                                   desk: desk, open: openLink, openWeb: openWeb)
                }
                ForEach(section.activities) { activity in
                    if activity.module == "label" {
                        if !activity.html.isEmpty {
                            SiteBlocksView(blocks: SiteHTML.blocks(activity.html, base: URL(string: Institution.current.moodleBase + "/")),
                                           desk: desk, open: openLink, openWeb: openWeb)
                                .padding(14)
                                .background(Carnet.sheetRaised.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    } else {
                        Button { openActivity(activity) } label: { card(activity) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func card(_ activity: MoodleCoursePage.Activity) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: MoodleCourseList.icon(activity))
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(activity.name).font(.body.weight(.medium)).foregroundStyle(Carnet.ink).multilineTextAlignment(.leading)
                if let detail = MoodleCourseList.detail(activity) {
                    Text(detail).font(.caption).foregroundStyle(Carnet.inkSecondary)
                }
            }
            Spacer(minLength: 0)
            if activity.completed {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Carnet.correct)
            } else {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Carnet.inkTertiary)
            }
        }
        .padding(12)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Carnet.rule))
        .contentShape(Rectangle())
    }
}

extension MoodleCoursePage {
    /// Le plan seul (`core_courseformat_get_state`), quand la page du cours ne
    /// se lit pas : mêmes semaines, sans texte.
    init(snapshot: MoodleCourseSnapshot) {
        self.init(title: snapshot.title, sections: snapshot.sections.map { section in
            Section(number: section.number, title: MoodleCourseAnalyzer.sectionTitle(section),
                    activities: section.activities.filter(\.isVisible).compactMap { activity in
                        guard let id = Int(activity.id) else { return nil }
                        return Activity(id: id, module: activity.module, name: activity.name, url: activity.link)
                    })
        })
    }
}
