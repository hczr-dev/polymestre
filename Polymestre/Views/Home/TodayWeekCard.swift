import SwiftUI

/// La semaine en un coup d'œil : les heures travaillées depuis lundi, jour par
/// jour, et l'avancement de la semaine — théorie vue, exercices des séries
/// faits — tous cours confondus.
///
/// Pas d'« objectif » EPFL ici : un total attendu comparé à un mercredi dit
/// toujours « en retard » et n'aide à rien. Ce qui compte est ce qui est fait.
struct WeekTimeCard: View {
    /// Secondes d'étude enregistrées, du lundi au dimanche.
    let days: [Int]
    let weekStart: Date
    /// La semaine du semestre, tous cours suivis : faits sur prévus.
    let theory: (done: Int, total: Int)
    let series: (done: Int, total: Int)
    /// Exercices de la semaine faits, et parmi eux corrigés.
    let corrections: (done: Int, total: Int)
    /// Éléments des semaines passées pas faits (corrections comprises), tous
    /// cours confondus.
    let late: Int
    /// L'objectif de la semaine (réglé, sinon la charge EPFL), en secondes.
    var goal: Int = 0
    var onOpen: () -> Void

    private var todayIndex: Int {
        min(max(DateUtils.daysBetween(weekStart, Date()), 0), 6)
    }

    private var total: Int { days.reduce(0, +) }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    CarnetKicker("Depuis lundi")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Carnet.inkTertiary)
                }
                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(DateUtils.hoursLabel(seconds: total))
                                .font(Carnet.serif(.largeTitle, weight: .regular))
                                .foregroundStyle(Carnet.ink)
                                .contentTransition(.numericText())
                            if goal > 0 {
                                Text("/ \(DateUtils.hoursLabel(seconds: goal))")
                                    .font(.subheadline)
                                    .foregroundStyle(total >= goal ? Carnet.correct : Carnet.inkSecondary)
                            }
                        }
                        Text(todayLine)
                            .font(.footnote)
                            .foregroundStyle(Carnet.inkSecondary)
                    }
                    .fixedSize()
                    dayStrip
                }
                Rectangle().fill(Carnet.rule).frame(height: 1)
                HStack(spacing: 18) {
                    axis("Théorie", theory)
                    axis("Séries", series)
                    axis("Corrigés", corrections)
                }
                if late > 0 {
                    Label("\(late) à rattraper dans tes cours",
                          systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(Carnet.wrong)
                }
            }
            .padding(16)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.99))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Ouvre le bilan")
    }

    private var todayLine: String {
        let today = days.indices.contains(todayIndex) ? days[todayIndex] : 0
        return today > 0 ? String(localized: "dont \(DateUtils.durationLabel(seconds: today)) aujourd'hui") : String(localized: "rien encore aujourd'hui")
    }

    private func axis(_ title: String, _ value: (done: Int, total: Int)) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(ui: title).font(.subheadline).foregroundStyle(Carnet.inkSecondary)
                Spacer(minLength: 4)
                Text(value.total == 0 ? "—" : "\(value.done)")
                    .font(Carnet.serif(.title3))
                    .foregroundStyle(value.total > 0 && value.done == value.total ? Carnet.correct : Carnet.ink)
                if value.total > 0 {
                    Text("/\(value.total)").font(.footnote).foregroundStyle(Carnet.inkSecondary)
                }
            }
            CarnetBar(value: CourseProgress.ratio(value.done, value.total), tint: Carnet.ink, height: 5)
                .opacity(value.total == 0 ? 0.3 : 1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) cette semaine : \(value.done) sur \(value.total)")
    }

    private var dayStrip: some View {
        let peak = max(days.max() ?? 0, 3600)
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(0..<7, id: \.self) { index in
                let seconds = days.indices.contains(index) ? days[index] : 0
                let isToday = index == todayIndex
                VStack(spacing: 4) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Carnet.sheetRaised)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(isToday ? Carnet.ink : Carnet.inkTertiary)
                            .frame(height: seconds == 0 ? 0 : max(3, 40 * CGFloat(seconds) / CGFloat(peak)))
                    }
                    .frame(height: 40)
                    .opacity(index > todayIndex ? 0.5 : 1)
                    Text(DateUtils.weekdayInitial(DateUtils.addDays(index, to: weekStart)))
                        .font(.caption2.weight(isToday ? .bold : .regular))
                        .foregroundStyle(isToday ? Carnet.ink : Carnet.inkTertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Un cours dans sa semaine : sa couleur, son nom, théorie, exercices et
/// corrections faits sur prévus, et le retard en mots.
struct WeekCourseRow: View {
    let summary: WeekCourseSummary
    /// Toucher « N en retard » ouvre « À rattraper » (le reste de la ligne, le cours).
    var openLate: (() -> Void)? = nil

    var body: some View {
        let course = summary.course
        let week = summary.week
        let tint = Carnet.tint(course.colorHex)
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(tint)
                .frame(width: 4)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(course.displayCode)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                    Text(course.name.isEmpty ? course.displayCode : course.name)
                        .font(.body)
                        .foregroundStyle(Carnet.ink)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    standing(late: summary.late, ahead: summary.ahead, week: week)
                }
                if week.hasItems {
                    HStack(spacing: 14) {
                        axis("Théorie", done: week.watchedCount, total: week.videoCount, tint: tint)
                        axis("Exercices", done: week.doneCount, total: week.exerciseCount, tint: tint)
                        if week.doneCount > 0 {
                            axis("Corrigés", done: week.correctedCount, total: week.doneCount, tint: tint)
                        }
                    }
                }
                if !summary.corrections.isEmpty {
                    Label(correctionsLine, systemImage: "checkmark.seal")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Carnet.inkSecondary)
                }
                if let exam = course.nextExam, DateUtils.daysBetween(Date(), exam.date) <= 14 {
                    Label("\(exam.kind.label) \(DateUtils.countdownLabel(to: exam.date).lowercased())",
                          systemImage: exam.kind.icon)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(DateUtils.daysBetween(Date(), exam.date) <= 3 ? Carnet.wrong : Carnet.inkSecondary)
                }
            }
        }
        .padding(.horizontal, Carnet.rowInset)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var correctionsLine: String {
        // Hors retard : celles des séries échues sont déjà dans « N en retard ».
        String(localized: "\(summary.corrections.toCorrect) à corriger cette semaine")
    }

    private func axis(_ title: String, done: Int, total: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(ui: title)
                    .font(.caption)
                    .foregroundStyle(Carnet.inkSecondary)
                Spacer(minLength: 2)
                Text(total == 0 ? "—" : "\(done)/\(total)")
                    .font(Carnet.mono(.caption, weight: .medium))
                    .foregroundStyle(total > 0 && done == total ? Carnet.correct : Carnet.ink)
            }
            CarnetBar(value: CourseProgress.ratio(done, total), tint: tint, height: 4)
                .opacity(total == 0 ? 0.3 : 1)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func standing(late: Int, ahead: Int, week: WeeklyProgress) -> some View {
        if late > 0 {
            if let openLate {
                Button(action: openLate) {
                    HStack(spacing: 2) {
                        Text("\(late) en retard")
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Carnet.wrong)
                    .padding(.vertical, 6)
                    .padding(.leading, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Ouvre ce qui est à rattraper")
            } else {
                Text("\(late) en retard")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Carnet.wrong)
            }
        } else if week.isComplete {
            Label("semaine faite", systemImage: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Carnet.correct)
        } else if ahead > 0 {
            Text("\(ahead) d'avance")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Carnet.correct)
        } else {
            Text("à jour")
                .font(.caption)
                .foregroundStyle(Carnet.inkSecondary)
        }
    }
}
