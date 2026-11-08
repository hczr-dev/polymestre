import SwiftUI
import SwiftData

/// La progression d'un cours : **où j'en suis**, le semestre semaine par
/// semaine, et le temps passé cette semaine.
///
/// Ce qui traîne a sa propre page, « À rattraper » (`LateWorkView`) : la liste
/// que cette page tenait comptait autrement que le badge « N en retard ».
struct ProgressTabView: View {
    let course: Course

    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var context
    @State private var expanded: Set<Int> = []
    @State private var openedVideo: TheoryItem?
    @State private var openedExercise: Exercise?

    private var weeks: [WeeklyProgress] { ProgressEngine.semesterWeeks(for: course) }
    private var current: Int { course.isTermRunning ? course.currentWeek : 0 }
    private var tint: Color { Carnet.tint(course.colorHex) }

    private var late: LateWork { LateWork.of(course) }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            standing
            weeksSection
            unplannedSection
            timeSection
        }
        .onAppear { if current > 0 { expanded.insert(current) } }
        .sheet(item: $openedVideo) { VideoDetailSheet(video: $0) }
        .sheet(item: $openedExercise) { ExerciseSheet(exercise: $0) }
    }

    // MARK: Où tu en es

    private var standing: some View {
        let progress = ProgressEngine.progress(for: course)
        let late = self.late.total
        let ahead = ProgressEngine.aheadCount(for: course)
        let sentence: String
        if late > 0 {
            sentence = late == 1 ? "1 élément à rattraper" : "\(late) éléments à rattraper"
        } else if ahead > 0 {
            sentence = "À jour, et \(ahead) d'avance"
        } else {
            sentence = "À jour"
        }
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                CarnetKicker(current > 0 ? "Semaine \(current) sur \(course.term?.totalWeeks ?? 14)" : "Semestre", color: tint)
                HStack(spacing: 8) {
                    Image(systemName: late > 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(late > 0 ? Carnet.review : Carnet.correct)
                    Text(sentence)
                        .font(Carnet.serif(.title2))
                        .foregroundStyle(Carnet.ink)
                }
                if late > 0 {
                    Text(self.late.summary.prefix(1).uppercased() + self.late.summary.dropFirst() + ".")
                        .font(.subheadline)
                        .foregroundStyle(Carnet.inkSecondary)
                }
            }
            HStack(spacing: 14) {
                axis("Théorie", progress.watchedCount, progress.videoCount)
                axis("Séries", progress.doneCount, progress.exerciseCount)
                axis("Corrigés", progress.correctedCount, progress.doneCount)
            }
            if progress.wrongOrRedoCount > 0 {
                Label("\(Plural.count(progress.wrongOrRedoCount, "\(progress.wrongOrRedoCount) exercice", "\(progress.wrongOrRedoCount) exercices")) à refaire",
                      systemImage: "arrow.counterclockwise")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Carnet.wrong)
            }
        }
        .padding(16)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
    }

    private func axis(_ title: String, _ done: Int, _ total: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(ui: title).font(.caption).foregroundStyle(Carnet.inkSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(total == 0 ? "—" : "\(done)")
                    .font(Carnet.serif(.title3))
                    .foregroundStyle(total > 0 && done == total ? Carnet.correct : Carnet.ink)
                if total > 0 { Text("/\(total)").font(.caption).foregroundStyle(Carnet.inkSecondary) }
            }
            CarnetBar(value: CourseProgress.ratio(done, total), tint: tint, height: 4)
                .opacity(total == 0 ? 0.3 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) : \(done) sur \(total)")
    }

    private func line(done: Bool, week: Int, title: String, detail: String,
                      toggle: @escaping () -> Void, open: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            CheckCircleButton(isOn: done, tint: tint, label: "Marquer \(title) fait", action: {
                toggle()
                Haptics.soft()
            })
            Button(action: open) {
                VStack(alignment: .leading, spacing: 2) {
                    MathText(title, font: .body)
                        .foregroundStyle(done ? Carnet.inkSecondary : Carnet.ink)
                        .lineLimit(1)
                    Text(week > 0 ? "S\(week) · \(detail)" : detail)
                        .font(.footnote)
                        .foregroundStyle(Carnet.inkSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 6)
        .padding(.trailing, Carnet.rowInset)
        .padding(.vertical, 6)
    }

    // MARK: Semaine par semaine

    @ViewBuilder
    private var weeksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle("Semaine par semaine")
            if weeks.allSatisfy({ !$0.hasItems }) {
                CarnetEmpty(icon: "calendar", title: "Rien de planifié",
                            message: "Importe la théorie et les séries du cours.",
                            actionTitle: "Importer du contenu") {
                    app.router.openContentImport(courseID: course.id)
                }
            } else {
                CarnetSheet {
                    let shown = weeks.filter { $0.hasItems || $0.week == current }
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, week in
                        weekRow(week)
                        if index < shown.count - 1 { CarnetRule(inset: 64) }
                    }
                }
            }
        }
    }

    private func weekRow(_ week: WeeklyProgress) -> some View {
        let isCurrent = week.week == current
        let isLate = current > 0 && week.week < current && week.remainingCount > 0
        let isOpen = expanded.contains(week.week)
        let total = week.videoCount + week.exerciseCount
        let done = week.watchedCount + week.doneCount
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                guard week.hasItems else { return }
                withAnimation(Motion.snappy) {
                    if isOpen { expanded.remove(week.week) } else { expanded.insert(week.week) }
                }
                Haptics.soft()
            } label: {
                HStack(spacing: 12) {
                    VStack(spacing: 0) {
                        Text("S\(week.week)")
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(isCurrent ? Carnet.ground : Carnet.ink)
                            .frame(width: 40, height: 40)
                            .background(isCurrent ? tint : Carnet.sheetRaised, in: Circle())
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(weekSummary(week))
                                .font(.subheadline)
                                .foregroundStyle(Carnet.ink)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if week.isComplete {
                                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Carnet.correct)
                            } else if isLate {
                                Text(Plural.count(week.remainingCount, "\(week.remainingCount) restant", "\(week.remainingCount) restants"))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Carnet.review)
                            } else if isCurrent {
                                Text("en cours").font(.caption.weight(.semibold)).foregroundStyle(tint.accessibleInk)
                            }
                        }
                        CarnetBar(value: CourseProgress.ratio(done, total), tint: week.isComplete ? Carnet.correct : tint, height: 4)
                            .opacity(total == 0 ? 0.3 : 1)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Carnet.inkTertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .opacity(week.hasItems ? 1 : 0)
                }
                .padding(.horizontal, Carnet.rowInset)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibility(week, isCurrent: isCurrent))

            if isOpen {
                weekDetail(week)
                    .padding(.leading, 52)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
    }

    /// « Théorie 1/1 · Série 4 : 3/5 ».
    private func weekSummary(_ week: WeeklyProgress) -> String {
        guard week.hasItems else { return "Rien de prévu" }
        var parts: [String] = []
        if week.videoCount > 0 { parts.append("Théorie \(week.watchedCount)/\(week.videoCount)") }
        if week.exerciseCount > 0 {
            let name = week.seriesNumbers.isEmpty ? "Séries" : "Série " + week.seriesNumbers.map(String.init).joined(separator: ", ")
            parts.append("\(name) : \(week.doneCount)/\(week.exerciseCount)")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func weekDetail(_ week: WeeklyProgress) -> some View {
        let theory = course.sortedTheoryItems.filter { $0.plannedWeek == week.week }
        let exercises = course.sortedSeries.filter { $0.plannedWeek == week.week }.flatMap(\.sortedExercises)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(theory) { item in
                line(done: item.isWatched, week: 0, title: item.title.isEmpty ? item.number : item.title,
                     detail: CarnetTheoryLine.detail(for: item), toggle: {
                        item.watchedAt = item.isWatched ? nil : Date()
                        try? context.save()
                     }, open: { openedVideo = item })
            }
            ForEach(exercises) { exercise in
                line(done: exercise.isDone, week: 0,
                     title: exercise.displayNumber + (exercise.isBonus ? " (bonus)" : ""),
                     detail: exercise.isCorrected ? (exercise.correctness?.shortLabel ?? "corrigé") : ExerciseStage(exercise).label,
                     toggle: {
                        exercise.setDone(!exercise.isDone)
                        try? context.save()
                     }, open: { openedExercise = exercise })
            }
        }
    }

    private func accessibility(_ week: WeeklyProgress, isCurrent: Bool) -> String {
        guard week.hasItems else { return "Semaine \(week.week), rien de prévu" }
        return "Semaine \(week.week)\(isCurrent ? ", en cours" : ""). \(weekSummary(week))"
    }

    // MARK: Sans semaine

    @ViewBuilder
    private var unplannedSection: some View {
        let items = ProgressEngine.unplannedTheory(for: course)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                CarnetSectionTitle("Sans semaine") { Text("\(items.count)") }
                CarnetSheet {
                    ForEach(Array(items.prefix(8).enumerated()), id: \.element.id) { index, item in
                        line(done: item.isWatched, week: 0, title: item.title.isEmpty ? item.number : item.title,
                             detail: "Ouvre-le pour lui donner une semaine", toggle: {
                                item.watchedAt = item.isWatched ? nil : Date()
                                try? context.save()
                             }, open: { openedVideo = item })
                        if index < min(items.count, 8) - 1 { CarnetRule(inset: 52) }
                    }
                }
            }
        }
    }

    // MARK: Temps

    private var timeSection: some View {
        let weekStart = DateUtils.startOfWeek(Date())
        let weekly = WorkloadEngine.weeklyDelta(for: course, hoursPerCredit: app.settings.hoursPerCredit,
                                                from: weekStart, to: DateUtils.addWeeks(1, to: weekStart))
        let byType = Dictionary(grouping: course.sessions.filter { $0.startedAt >= weekStart }) { $0.taskType.canonical }
            .mapValues { $0.reduce(0) { $0 + $1.durationSeconds } }
        return VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle("Ton temps cette semaine")
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(weekly.actualLabel).font(Carnet.serif(.title2)).foregroundStyle(Carnet.ink)
                    Text("sur \(weekly.expectedLabel) attendues").font(.subheadline).foregroundStyle(Carnet.inkSecondary)
                    Spacer()
                }
                CarnetBar(value: weekly.completion, tint: weekly.isBehind ? Carnet.review : tint, height: 5)
                if !byType.isEmpty {
                    HStack(spacing: 16) {
                        ForEach(TaskType.reportCategories.filter { byType[$0] != nil }, id: \.self) { type in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(type.shortLabel).font(.caption).foregroundStyle(Carnet.inkSecondary)
                                Text(DateUtils.durationLabel(seconds: byType[type] ?? 0))
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(Carnet.ink)
                            }
                        }
                    }
                }
                Text("Attendu : \(Int(app.settings.hoursPerCredit)) h par crédit ECTS, amphi compris.")
                    .font(.footnote)
                    .foregroundStyle(Carnet.inkSecondary)
            }
            .padding(16)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
        }
    }
}
