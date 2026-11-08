import SwiftUI
import SwiftData

/// Avancement des séries, **série par série et membre par membre**.
///
/// La matrice « membre × S1…S14 » ne répondait pas à la question posée en salle
/// d'exercices : « t'en es où dans la série 3 ? ». Ici, chaque série est une carte,
/// chaque membre une ligne, et les numéros faits sont écrits — pas seulement un
/// pourcentage.
struct GroupSeriesProgressView: View {
    let group: StudyGroup

    @Environment(AppContainer.self) private var app
    @Query(sort: \Course.code) private var courses: [Course]

    @State private var subject: String = ""
    @State private var showAll = false

    private var subjects: [String] { group.subjectCodes }

    private var course: Course? {
        courses.first { $0.code.uppercased() == subject.uppercased() }
    }

    private var boards: [SeriesBoard] {
        GroupProgressBuilder.seriesBoards(subject: subject, group: group, course: course, meID: app.social.userID)
    }

    /// Les séries à afficher : celles déjà commencées par quelqu'un, plus la
    /// prochaine — le reste du semestre sur demande.
    private func visible(_ all: [SeriesBoard]) -> [SeriesBoard] {
        guard !showAll else { return all }
        let week = course?.currentWeek ?? 1
        let relevant = all.filter { $0.startedCount > 0 || $0.plannedWeek <= week + 1 }
        return relevant.isEmpty ? Array(all.prefix(3)) : relevant
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                if subjects.isEmpty {
                    EmptyCard(icon: "books.vertical",
                              title: String(localized: "Aucune matière"),
                              message: String(localized: "Ajoute les matières du groupe."))
                } else {
                    subjectPicker
                    let all = boards
                    if course == nil {
                        Card {
                            Label("Tu ne suis pas \(subject) : Polymestre ne connaît pas ses séries et ne peut pas les comparer.",
                                  systemImage: "info.circle")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else if all.isEmpty {
                        EmptyCard(icon: "list.bullet.rectangle",
                                  title: String(localized: "Aucune série dans \(subject)"),
                                  message: String(localized: "Les séries de tes cours apparaissent ici."))
                    } else {
                        headline(all)
                        ForEach(visible(all)) { board in
                            seriesCard(board)
                        }
                        if !showAll, visible(all).count < all.count {
                            Button {
                                withAnimation(Motion.snappy) { showAll = true }
                            } label: {
                                Label("Voir les \(all.count - visible(all).count) séries à venir", systemImage: "chevron.down")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        NavigationLink(value: GroupSubjectRoute(groupID: group.id, subject: subject)) {
                            Label("Théorie et détail par membre", systemImage: "person.text.rectangle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding()
            .adaptiveColumn()
        }
        .background(Carnet.ground.ignoresSafeArea())
        .carnetBackground()
        .navigationTitle("Avancement des séries")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if subject.isEmpty {
                // Ma première matière commune, sinon la première du groupe.
                let mine = Set(courses.filter(\.isTracked).map { $0.code.uppercased() })
                subject = subjects.first { mine.contains($0) } ?? subjects.first ?? ""
            }
        }
    }

    // MARK: Matière

    @ViewBuilder
    private var subjectPicker: some View {
        if subjects.count <= 3 {
            Picker("Matière", selection: $subject) {
                ForEach(subjects, id: \.self) { code in
                    Text(code).tag(code)
                }
            }
            .pickerStyle(.segmented)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Layout.inline) {
                    ForEach(subjects, id: \.self) { code in
                        Button {
                            subject = code
                            Haptics.soft()
                        } label: {
                            Text(code)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, Layout.block)
                                .padding(.vertical, Layout.inline)
                                .background(subject == code ? Theme.accent : Theme.softBackground,
                                            in: Capsule())
                                .foregroundStyle(subject == code ? Theme.accent.badgeInk : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: En-tête

    private func headline(_ boards: [SeriesBoard]) -> some View {
        let completedByMe = boards.filter { $0.me?.isComplete ?? false }.count
        let gap = GroupSeriesEngine.gapToLeader(boards)
        return Card(title: course?.name ?? subject, icon: "checkmark.seal.fill") {
            VStack(alignment: .leading, spacing: Layout.block) {
                HStack(spacing: Layout.block) {
                    StatCard(icon: "list.bullet.rectangle",
                             value: "\(boards.count)",
                             title: String(localized: "séries connues"), onCard: true)
                    StatCard(icon: "checkmark.circle.fill",
                             value: "\(completedByMe)",
                             title: String(localized: "terminées par toi"), onCard: true)
                    StatCard(icon: "person.3.fill",
                             value: "\(group.members.count)",
                             title: "membres", onCard: true)
                }
                if let gap {
                    Label("\(gap.name) a \(Plural.count(gap.gap, "\(gap.gap) exercice", "\(gap.gap) exercices")) d'avance sur toi",
                          systemImage: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(Color.orange.accessibleInk)
                } else if boards.contains(where: { $0.me != nil }) {
                    Label("Personne n'est devant toi sur cette matière", systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(Color.green.accessibleInk)
                }
            }
        }
    }

    // MARK: Une série

    private func seriesCard(_ board: SeriesBoard) -> some View {
        let isCurrent = board.plannedWeek == (course?.currentWeek ?? -1)
        return Card(title: board.title,
                    icon: isCurrent ? "star.circle.fill" : "list.number",
                    trailing: "S\(board.plannedWeek) · \(Plural.count(board.total, "\(board.total) exo", "\(board.total) exos"))") {
            VStack(alignment: .leading, spacing: Layout.block) {
                HStack(spacing: Layout.snug) {
                    if isCurrent { Pill(text: String(localized: "cette semaine"), color: Theme.accent) }
                    if !board.bonusNumbers.isEmpty {
                        Pill(text: "\(board.bonusNumbers.count) bonus", color: .orange, icon: "star.fill")
                    }
                    Text(board.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if board.total == 0 {
                    Text("Aucun exercice dans cette série.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(board.rows) { row in
                            memberRow(row, board: board)
                            if row.id != board.rows.last?.id {
                                Divider().padding(.vertical, Layout.snug)
                            }
                        }
                    }
                }
            }
        }
    }

    private func memberRow(_ row: SeriesMemberProgress, board: SeriesBoard) -> some View {
        let tint: Color = row.isMe ? Theme.accent : (row.isComplete ? .green : .teal)
        return VStack(alignment: .leading, spacing: Layout.snug) {
            HStack(spacing: Layout.control) {
                Text(row.isMe ? "Toi" : row.displayName)
                    .font(.subheadline.weight(row.isMe ? .bold : .regular))
                    .lineLimit(1)
                if row.isComplete {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(Color.green.accessibleMark)
                        .accessibilityLabel("terminée")
                }
                Spacer(minLength: Layout.inline)
                Text(row.isComplete && row.doneCount < board.total
                     ? "terminée"
                     : "\(row.doneCount)/\(board.total)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(row.doneCount == 0 && !row.isComplete ? .secondary : .primary)
            }
            ProgressBar(progress: row.percent, color: tint, height: 6)
            // Les numéros, pas seulement la barre : « 3.1 · 3.2 faits, il reste 3.3 ».
            if row.doneCount > 0 && !row.isComplete {
                HStack(spacing: Layout.tight) {
                    ForEach(board.exerciseNumbers, id: \.self) { number in
                        let done = row.doneNumbers.contains(number)
                        Text(number)
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .padding(.horizontal, Layout.snug)
                            .padding(.vertical, Layout.micro)
                            .background(done ? tint.badgeFill : Color.secondary.badgeFill, in: Capsule())
                            .foregroundStyle(done ? tint.badgeInk : Color.secondary)
                            .accessibilityLabel("\(number) \(done ? "fait" : "à faire")")
                    }
                }
            }
        }
        .padding(.vertical, Layout.micro)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.isMe ? "Toi" : row.displayName) : \(row.doneCount) sur \(board.total)\(row.isComplete ? ", terminée" : "")")
    }
}
