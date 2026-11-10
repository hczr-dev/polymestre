import SwiftUI
import SwiftData

// MARK: - Le quiz de la semaine

/// Les quiz du cours de la semaine (séance, programme, sections du
/// polycopié à lire), un par un : dix minutes dans le métro, le score à la
/// fin. Lu sur le site Botafogo du cours, comme le reste.
struct WeekQuizView: View {
    let course: Course
    let site: URL

    @State private var quizzes: [BotafogoPage.Quiz]?
    @State private var index = 0
    @State private var answers: [Int: Bool] = [:]
    @Environment(\.dismiss) private var dismiss

    private var tint: Color { Carnet.tint(course.colorHex) }
    private var book: BotafogoBook { SiteHub.shared.botafogo(site) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Quiz de la semaine").font(Carnet.serif(20, weight: .medium)).foregroundStyle(Carnet.ink)
                    Text(course.displayCode).font(.caption).foregroundStyle(tint)
                }
                Spacer()
                if let quizzes, !quizzes.isEmpty, !answers.isEmpty {
                    Text("\(answers.values.filter { $0 }.count)/\(answers.count) juste\(answers.values.filter { $0 }.count > 1 ? "s" : "")")
                        .font(.callout.monospacedDigit()).foregroundStyle(Carnet.inkSecondary)
                }
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Carnet.inkTertiary)
            }
            .padding(20)
            if let quizzes {
                if quizzes.isEmpty {
                    ContentUnavailableView("Pas de quiz cette semaine", systemImage: "checklist",
                                           description: Text("Les séances et les sections à lire n'en ont pas."))
                } else if index >= quizzes.count {
                    finished(quizzes)
                } else {
                    progress(quizzes.count)
                    ScrollView {
                        let quiz = quizzes[index]
                        BotafogoQuizCard(title: quiz.title.isEmpty ? "Quiz" : quiz.title, choices: quiz.choices, columns: quiz.columns, size: 16,
                                         onAnswer: { answers[index] = $0 }) {
                            BotafogoBlocksView(blocks: quiz.prompt, book: book, desk: SiteHub.shared, openWeb: { _, _ in }, size: 16)
                        }
                        .id(index)
                        .padding(20)
                    }
                    Button {
                        withAnimation(.snappy) { index += 1 }
                    } label: {
                        Text(index + 1 == quizzes.count ? "Voir le score" : (answers[index] == nil ? "Passer" : String(localized: "Suivant")))
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .foregroundStyle(Carnet.ground)
                            .background(tint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(20)
                }
            } else {
                ProgressView(String(localized: "Les quiz de la semaine…")).frame(maxHeight: .infinity)
            }
        }
        .background(Carnet.ground)
        .environment(\.botafogoTint, tint)
        .task { await load() }
    }

    private func progress(_ count: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { item in
                Capsule()
                    .fill(answers[item].map { $0 ? Carnet.correct : Carnet.wrong } ?? (item == index ? tint : Carnet.rule))
                    .frame(height: 4)
            }
        }
        .padding(.horizontal, 20)
    }

    private func finished(_ quizzes: [BotafogoPage.Quiz]) -> some View {
        let right = answers.values.filter { $0 }.count
        return VStack(spacing: 14) {
            Spacer()
            Text("\(right) sur \(quizzes.count)").font(Carnet.serif(48)).foregroundStyle(Carnet.ink)
            Text(right == quizzes.count ? "Tout juste. La semaine est acquise." : "Les quiz ratés reviennent au prochain tour.")
                .foregroundStyle(Carnet.inkSecondary)
            Button("Refaire ceux ratés") {
                let missed = answers.filter { !$0.value }.keys.sorted().map { quizzes[$0] }
                self.quizzes = missed
                answers = [:]
                index = 0
            }
            .buttonStyle(.paper)
            .disabled(right == quizzes.count)
            Spacer()
        }
        .padding(30)
    }

    /// La semaine en cours : les documents des séances et les sections à lire.
    private func load() async {
        guard quizzes == nil else { return }
        await book.load(site)
        guard let current = BotafogoSite.currentWeek(book.weeks), book.weeks.indices.contains(current) else { quizzes = []; return }
        let week = book.weeks[current]
        let parts = (week.children ?? []).filter { BotafogoSite.isSessionPart($0) }.compactMap(\.url)
        var urls = parts
        if let weekContent = (week.children ?? []).first(where: { $0.type == "weekContent" })?.url {
            urls += await book.readings(of: weekContent).map(\.path)
        }
        var found: [BotafogoPage.Quiz] = []
        for url in urls {
            if let page = await book.page(url) { found += BotafogoPage.quizzes(page) }
        }
        quizzes = found
    }
}

// MARK: - En route

/// Loin du bureau : ce qui se fait avec un téléphone. Les reprises dues (sur
/// papier, l'énoncé seul), le quiz de la semaine, la prochaine section à lire.
struct OnTheGoCard: View {
    let courses: [Course]
    var openExercise: (Exercise) -> Void
    @State private var quizCourse: Course?

    private var due: [Exercise] {
        SeriesReview.redoQueue(courses).filter { ($0.redoDueAt ?? .distantFuture) <= Date() }
    }

    private func botafogoSite(_ course: Course) -> URL? {
        course.contentSources.compactMap(URL.init(string:)).first { ContentSource.detect(host: $0.host) == .botafogo }
    }

    var body: some View {
        let quizCourses = courses.filter { botafogoSite($0) != nil }
        if !due.isEmpty || !quizCourses.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("En route").font(Carnet.serif(.title3)).foregroundStyle(Carnet.ink)
                ForEach(due.prefix(3)) { exercise in
                    Button { openExercise(exercise) } label: {
                        row(icon: "arrow.counterclockwise.circle.fill", color: Carnet.review,
                            title: String(localized: "Reprise : \(exercise.series?.course?.displayCode ?? "") \(exercise.displayNumber)"),
                            detail: String(localized: "sur papier, l'énoncé seul — ") + (exercise.redoWhy.isEmpty ? "15 min" : exercise.redoWhy))
                    }
                    .buttonStyle(.plain)
                }
                ForEach(quizCourses) { course in
                    Button { quizCourse = course } label: {
                        row(icon: "checklist", color: Carnet.tint(course.colorHex), title: String(localized: "Quiz de la semaine · \(course.displayCode)"),
                            detail: String(localized: "les quiz des séances et du polycopié, un par un"))
                    }
                    .buttonStyle(.plain)
                }
            }
            #if DEBUG
            // `-weekQuiz` : le quiz de la semaine ouvert (captures).
            .task {
                if CommandLine.arguments.contains("-weekQuiz"), quizCourse == nil {
                    try? await Task.sleep(for: .seconds(1))
                    quizCourse = quizCourses.first
                }
            }
            #endif
            .sheet(item: $quizCourse) { course in
                if let site = botafogoSite(course) { WeekQuizView(course: course, site: site) }
            }
        }
    }

    private func row(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(color).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold)).foregroundStyle(Carnet.ink)
                Text(detail).font(.caption).foregroundStyle(Carnet.inkSecondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Carnet.inkTertiary)
        }
        .padding(12)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }
}
