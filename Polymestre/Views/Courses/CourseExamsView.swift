import SwiftUI
import SwiftData

/// Examens d'un cours : évaluations et annales.
///
/// Remplace l'ancien onglet « Agenda » du cours, qui mêlait évaluations,
/// annales, sessions planifiées, séances d'amphi et tâches — un fourre-tout où
/// rien ne se trouvait. Les séances et les sessions vivent désormais dans
/// l'Agenda (filtrable par cours), les tâches dans « Tâches » ; il reste ici ce
/// qui prépare un examen.
struct CourseExamsView: View {
    let course: Course

    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var app

    @State private var showingAddExam = false
    @State private var editingExam: Exam?
    @State private var editingPastExam: PastExam?
    @State private var creatingPastExam = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                examsCard
                pastExamsCard
                agendaLink
            }
            .padding(Layout.screenPadding)
            .adaptiveColumn()
        }
        .background(Carnet.ground.ignoresSafeArea())
        .carnetBackground()
        .navigationTitle("Examens · \(course.displayCode)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingAddExam = true
                    } label: {
                        Label("Ajouter une évaluation", systemImage: "graduationcap")
                    }
                    Button {
                        creatingPastExam = true
                    } label: {
                        Label("Ajouter une annale", systemImage: "archivebox")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Ajouter")
            }
        }
        .sheet(isPresented: $showingAddExam) {
            ExamFormSheet(course: course)
        }
        .sheet(item: $editingExam) { exam in
            ExamFormSheet(course: course, exam: exam)
        }
        .sheet(item: $editingPastExam) { past in
            PastExamFormSheet(course: course, exam: past)
        }
        .sheet(isPresented: $creatingPastExam) {
            PastExamFormSheet(course: course, exam: nil)
        }
    }

    /// Les séances et les sessions de ce cours sont dans l'Agenda : on y mène,
    /// filtré, plutôt que de les recopier ici.
    private var agendaLink: some View {
        Button {
            app.router.openAgenda(courseID: course.id)
        } label: {
            HStack(spacing: Layout.block) {
                Image(systemName: "calendar")
                    .foregroundStyle(Theme.accentInk)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: Layout.micro) {
                    Text("Séances et sessions de \(course.displayCode)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("Dans l'Agenda, filtré sur ce cours")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Layout.inline)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(Layout.gutter)
            .background(Theme.softBackground, in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    /// Les sujets passés : ce qu'on travaille pour réviser.
    private var pastExamsCard: some View {
        Card(title: "Annales", icon: "archivebox.fill",
             trailing: course.pastExams.isEmpty ? nil : progress.label) {
            VStack(alignment: .leading, spacing: Layout.block) {
                if course.pastExams.isEmpty {
                    Text("Aucun sujet passé.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if let first = progress.pendingYears.first {
                        Label("À travailler en priorité : \(first)",
                              systemImage: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(Color.orange.accessibleInk)
                    }

                    VStack(spacing: 0) {
                        ForEach(course.sortedPastExams) { past in
                            Button {
                                editingPastExam = past
                            } label: {
                                pastExamRow(past)
                            }
                            .buttonStyle(.plain)
                            if past.id != course.sortedPastExams.last?.id {
                                Divider()
                            }
                        }
                    }
                }

                Button {
                    creatingPastExam = true
                } label: {
                    Label("Ajouter une annale", systemImage: "plus.circle")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func pastExamRow(_ past: PastExam) -> some View {
        HStack(spacing: Layout.control) {
            Image(systemName: past.kind.icon)
                .foregroundStyle(past.kind.color.accessibleMark)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(past.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(past.statusLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Layout.inline)
            ConfidenceDot(level: past.confidence)
            if past.url != nil {
                Image(systemName: "arrow.up.right.square")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, Layout.snug)
        .contentShape(Rectangle())
    }

    private var progress: PastExamProgress.Summary {
        PastExamProgress.summary(course.pastExams.map { (year: $0.year, worked: $0.isWorked) })
    }

    private var examsCard: some View {
        Card(title: String(localized: "Évaluations"), icon: "graduationcap.fill",
             trailing: course.exams.isEmpty ? nil : "\(course.exams.count)") {
            VStack(alignment: .leading, spacing: 12) {
            if course.sortedExams.isEmpty {
                Text("Aucune évaluation.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(course.sortedExams) { exam in
                        Button {
                            editingExam = exam
                        } label: {
                        HStack(spacing: 12) {
                            Image(systemName: exam.kind.icon)
                                .foregroundStyle(exam.kind.color.accessibleMark)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(exam.title).font(.subheadline.weight(.medium))
                                // Une seule chaîne : deux textes séparés par un
                                // espacement donnaient « octobre  · SG1 ».
                                Text([DateUtils.fullDayLabel(exam.date), exam.location]
                                        .filter { !$0.isEmpty }
                                        .joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: Layout.tight) {
                                Text(DateUtils.countdownLabel(to: exam.date))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(exam.isPast ? Color.secondary : exam.kind.color.accessibleInk)
                                if let weight = exam.weightLabel {
                                    Text(weight).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Modifier l'évaluation")
                    }
                }
            }

            Button {
                showingAddExam = true
            } label: {
                Label("Ajouter une évaluation", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderless)
            }
        }
    }
}
