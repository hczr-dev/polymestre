import SwiftUI
import SwiftData

/// Avancement du groupe sur **une** matière : chaque membre, série et exercice,
/// et son écart avec moi.
///
/// C'est l'écran qui répond à la question que la carte « Matières » ne fait
/// qu'effleurer : « où en est Alice, exactement ? ». On y montre trois axes, parce
/// qu'ils ne progressent pas ensemble : on peut avoir fini les vidéos et rien
/// commencé des exercices.
struct GroupSubjectProgressView: View {
    let group: StudyGroup
    let subject: String

    @Environment(AppContainer.self) private var app
    @Query(sort: \Course.code) private var courses: [Course]

    /// L'axe mis en avant dans les barres. Les trois compteurs restent affichés
    /// sur chaque ligne — le sélecteur choisit ce qu'on **compare**, pas ce qu'on
    /// voit.
    @State private var axis: Axis = .overall

    enum Axis: String, CaseIterable, Identifiable {
        case overall, series, exercises, theory

        var id: String { rawValue }

        var label: String {
            switch self {
            case .overall: return "Global"
            case .series: return String(localized: "Séries")
            case .exercises: return String(localized: "Exercices")
            case .theory: return String(localized: "Théorie")
            }
        }
    }

    private var course: Course? {
        courses.first { $0.code.uppercased() == subject.uppercased() }
    }

    private var comparison: GroupProgressEngine.SubjectComparison {
        GroupProgressBuilder.comparison(subject: subject,
                                        group: group,
                                        course: course,
                                        meID: app.social.userID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                summaryCard
                axisPicker
                membersCard
            }
            .padding()
            .adaptiveColumn()
        }
        .background(Carnet.ground.ignoresSafeArea())
        .carnetBackground()
        .navigationTitle(subject)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Résumé

    private var summaryCard: some View {
        Card(title: course?.name ?? String(localized: "Matière hors programme"), icon: "chart.bar.fill") {
            summaryContent
        }
    }

    @ViewBuilder
    private var summaryContent: some View {
        let comparison = self.comparison
        VStack(alignment: .leading, spacing: Layout.block) {
            if let me = comparison.me {
                LabeledProgress(title: "Toi",
                                progress: axis.progress(of: me),
                                color: Theme.accent,
                                countLabel: axis.countLabel(of: me))
            } else {
                Text("Connecte-toi pour te comparer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: Layout.block) {
                StatCard(icon: "person.3.fill",
                         value: "\(comparison.rows.filter(\.isPresent).count)",
                         title: "membres", onCard: true)
                StatCard(icon: "checkmark.circle.fill",
                         value: "\(comparison.rows.filter { $0.isPresent && $0.doneTotal > 0 }.count)",
                         title: String(localized: "ont commencé"), onCard: true)
                StatCard(icon: "hourglass",
                         value: "\(comparison.notStarted)",
                         title: String(localized: "rien fait"), onCard: true)
            }

            if comparison.reference.isEmpty {
                Label("Seules les séries sont comparées pour ce cours.",
                      systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var axisPicker: some View {
        Picker("Comparer", selection: $axis) {
            ForEach(Axis.allCases) { value in
                Text(value.label).tag(value)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Choisir l'axe comparé")
    }

    // MARK: Où en est chacun

    private var membersCard: some View {
        Card(title: String(localized: "Où en est chacun"), icon: "list.number") {
            membersContent
        }
    }

    @ViewBuilder
    private var membersContent: some View {
        let comparison = self.comparison
        if comparison.rows.isEmpty {
            Text("Aucun membre dans ce groupe.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(comparison.rows) { row in
                    memberBlock(row)
                    if row.id != comparison.rows.last?.id {
                        Divider().padding(.vertical, Layout.block)
                    }
                }
            }
        }
    }

    private func memberBlock(_ row: SubjectMemberProgress) -> some View {
        let tint: Color = row.isMe ? Theme.accent : .teal
        return VStack(alignment: .leading, spacing: Layout.inline) {
            HStack(spacing: Layout.control) {
                Text(row.isMe ? "Toi" : row.displayName)
                    .font(.subheadline.weight(row.isMe ? .bold : .regular))
                    .lineLimit(1)
                if row.isMe {
                    Pill(text: "toi", color: Theme.accent)
                } else if !row.isPresent {
                    Pill(text: String(localized: "hors groupe"), color: .secondary)
                }
                Spacer(minLength: Layout.inline)
                if let gap = row.gapLabel {
                    Text(gap)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(gap == String(localized: "au même point") ? Color.secondary : Color.orange.accessibleInk)
                        .lineLimit(1)
                }
            }

            ProgressBar(progress: axis.progress(of: row), color: tint, height: 7)

            // Les trois compteurs, toujours : le sélecteur ne fait que choisir
            // lequel est mis en avant.
            HStack(spacing: Layout.block) {
                counter(String(localized: "Séries"), done: row.seriesDone, total: row.seriesTotal, active: axis == .series)
                counter(String(localized: "Exercices"), done: row.exercisesDone, total: row.exerciseTotal, active: axis == .exercises)
                counter(String(localized: "Théorie"), done: row.theoryDone, total: row.theoryTotal, active: axis == .theory)
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(row))
    }

    @ViewBuilder
    private func counter(_ title: String, done: Int, total: Int, active: Bool) -> some View {
        if total > 0 {
            VStack(alignment: .leading, spacing: 1) {
                Text(ui: title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(done)/\(total)")
                    .font(.caption.weight(active ? .bold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(active ? Theme.accentInk : .primary)
            }
        }
    }

    private func accessibilityLabel(_ row: SubjectMemberProgress) -> String {
        var parts = [row.isMe ? "Toi" : row.displayName]
        if row.seriesTotal > 0 { parts.append(String(localized: "\(row.seriesDone) séries sur \(row.seriesTotal)")) }
        if row.exerciseTotal > 0 { parts.append(String(localized: "\(row.exercisesDone) exercices sur \(row.exerciseTotal)")) }
        if row.theoryTotal > 0 { parts.append(String(localized: "\(row.theoryDone) théorie sur \(row.theoryTotal)")) }
        if let gap = row.gapLabel { parts.append(gap) }
        return parts.joined(separator: ", ")
    }

    // MARK: Explication

}

private extension GroupSubjectProgressView.Axis {
    func progress(of row: SubjectMemberProgress) -> Double {
        switch self {
        case .overall: return row.overallPercent
        case .series: return row.seriesPercent
        case .exercises: return row.exercisePercent
        case .theory: return row.theoryPercent
        }
    }

    func countLabel(of row: SubjectMemberProgress) -> String? {
        switch self {
        case .overall:
            return row.itemTotal > 0 ? String(localized: "\(row.doneTotal)/\(row.itemTotal) éléments") : nil
        case .series:
            return row.seriesTotal > 0 ? String(localized: "\(row.seriesDone)/\(row.seriesTotal) séries") : nil
        case .exercises:
            return row.exerciseTotal > 0 ? String(localized: "\(row.exercisesDone)/\(row.exerciseTotal) exercices") : nil
        case .theory:
            return row.theoryTotal > 0 ? String(localized: "\(row.theoryDone)/\(row.theoryTotal) théorie") : nil
        }
    }
}
