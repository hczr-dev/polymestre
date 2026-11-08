import SwiftUI
import SwiftData

/// « À rattraper » : ce que le « N en retard » d'un cours recouvre, rangé par
/// ce qu'il y a à **faire**, dans l'ordre où le reprendre.
///
/// L'ancienne destination était la page « Progression » : un autre total que
/// le badge (les corrections n'y comptaient pas, un retard fait de corrections
/// s'y lisait « À jour »), douze lignes puis « + N autres » qui ne menait nulle
/// part, théorie et exercices de toutes les séries mélangés, puis le semestre
/// semaine par semaine et le temps de la semaine — une page de bilan, pas la
/// réponse à « qu'est-ce qui traîne ? ».
///
/// Ici, un seul calcul (`LateWork`) donne le nombre et la liste :
///   1. à refaire — une correction fausse, à reprendre tant qu'elle est fraîche ;
///   2. à corriger — fait, corrigé publié : comparer et donner la couleur ;
///   3. exercices à faire — série par série, chacune avec « tout marquer fait » ;
///   4. théorie à voir — semaine par semaine.
/// Rien n'est tronqué. Aucune correction ne se coche en masse : une couleur se
/// constate en comparant au corrigé, elle ne s'invente pas.
///
/// Partagée par l'iPhone et le Mac : ouvrir un exercice ou une théorie est
/// laissé à l'hôte (une feuille sur l'iPhone, l'inspecteur sur le Mac).
struct LateWorkView: View {
    let course: Course
    var openExercise: (Exercise) -> Void
    var openTheory: (TheoryItem) -> Void
    var openURL: ((URL) -> Void)? = nil

    @Environment(\.modelContext) private var context
    @State private var undo: Undo?

    /// Ce qu'un geste a coché, pour le défaire exactement.
    struct Undo: Equatable {
        var exercises: [UUID] = []
        var theory: [UUID] = []
        var label: String
    }

    private var tint: Color { Carnet.tint(course.colorHex) }

    var body: some View {
        let late = LateWork.of(course)
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header(late)
                if late.isEmpty {
                    upToDate(late)
                } else {
                    if !late.redo.isEmpty { redoSection(late.redo) }
                    if !late.toCorrect.isEmpty { correctSection(late.toCorrect) }
                    if !late.series.isEmpty { exercisesSection(late.series) }
                    if !late.theory.isEmpty { theorySection(late.theory) }
                    footnote(late)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, undo == nil ? 32 : 88)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Carnet.ground.ignoresSafeArea())
        .overlay(alignment: .bottom) { undoBar }
        .animation(Motion.snappy, value: late.total)
        .animation(Motion.snappy, value: undo)
    }

    // MARK: En-tête

    private func header(_ late: LateWork) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: [course.displayCode, late.currentWeek > 0 ? "semaine \(late.currentWeek)" : nil]
                .compactMap { $0 }.joined(separator: " · ").uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1.1)
                .foregroundStyle(tint)
            Text(late.isEmpty ? "Rien à rattraper" : "\(late.total) à rattraper")
                .font(Carnet.serif(30))
                .foregroundStyle(Carnet.ink)
            if !late.isEmpty {
                Text(late.summary.capitalizedFirstLetter + ".")
                    .font(.subheadline)
                    .foregroundStyle(Carnet.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func upToDate(_ late: LateWork) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(Carnet.correct)
            Text(late.currentWeek > 1
                 ? "Tout ce qui était prévu avant la semaine \(late.currentWeek) est vu, fait et corrigé, et rien n'est à refaire."
                 : "Le semestre commence : rien ne peut encore être en retard, sauf un exercice à refaire.")
                .font(.subheadline)
                .foregroundStyle(Carnet.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.paperCorner, style: .continuous))
    }

    // MARK: 1. À refaire

    private func redoSection(_ exercises: [Exercise]) -> some View {
        section("À refaire", count: exercises.count,
                why: "Corrigés faux. Reprends-les sans regarder la solution, tant que l'erreur est fraîche.") {
            rows(exercises) { exercise in
                exerciseRow(exercise, detail: detail(exercise, extra: exercise.correctedAt.map { "corrigé \(relative($0))" }),
                            mark: .icon("arrow.counterclockwise", Carnet.wrong))
            }
        }
    }

    // MARK: 2. À corriger

    private func correctSection(_ exercises: [Exercise]) -> some View {
        section("À corriger", count: exercises.count,
                why: "Faits, et le corrigé est publié. Compare ta copie au corrigé et donne la couleur : juste, moyen ou faux.") {
            rows(exercises) { exercise in
                exerciseRow(exercise, detail: detail(exercise, extra: exercise.doneAt.map { "fait \(relative($0))" }),
                            mark: .icon("checkmark.seal", Carnet.review),
                            trailing: AnyView(solutionButton(for: exercise)))
            }
        }
    }

    @ViewBuilder
    private func solutionButton(for exercise: Exercise) -> some View {
        if let openURL, let series = exercise.series, let url = URL(string: series.solutionURLString), !series.solutionURLString.isEmpty {
            Button("Corrigé") { openURL(url) }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.borderless)
                .foregroundStyle(tint)
                .help("Ouvrir le corrigé de la \(series.displayName)")
        }
    }

    // MARK: 3. Exercices à faire

    private func exercisesSection(_ groups: [LateWork.SeriesGroup]) -> some View {
        let count = groups.reduce(0) { $0 + $1.exercises.count }
        return section(count == 1 ? "Exercice à faire" : "Exercices à faire", count: count,
                       why: "Prévus les semaines passées, pas encore faits. Déjà faits sur papier ? Coche-les : ils passeront « à corriger ».") {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                if index > 0 { rule(inset: 0) }
                seriesHeader(group)
                rows(group.exercises) { exercise in
                    exerciseRow(exercise, detail: exerciseDetail(exercise), mark: .check)
                }
            }
        }
    }

    private func seriesHeader(_ group: LateWork.SeriesGroup) -> some View {
        let name = group.series.title.isEmpty || group.series.title == group.series.displayName
            ? group.series.displayName : "\(group.series.displayName) · \(group.series.title)"
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(Carnet.ink).lineLimit(1)
                Text("Semaine \(group.series.plannedWeek) · \(group.exercises.count) sur \(group.requiredCount) à faire")
                    .font(.caption).foregroundStyle(Carnet.inkSecondary)
            }
            Spacer(minLength: 8)
            if group.exercises.count > 1 {
                Button("Tout marquer fait") { markDone(group.exercises, label: group.series.displayName) }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
                    .foregroundStyle(tint)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // MARK: 4. Théorie à voir

    private func theorySection(_ groups: [LateWork.TheoryGroup]) -> some View {
        let count = groups.reduce(0) { $0 + $1.items.count }
        return section("Théorie à voir", count: count,
                       why: "Vidéos, transparents, sections du polycopié des semaines passées.") {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                if index > 0 { rule(inset: 0) }
                HStack(alignment: .firstTextBaseline) {
                    Text("Semaine \(group.week)").font(.subheadline.weight(.semibold)).foregroundStyle(Carnet.ink)
                    Spacer(minLength: 8)
                    if group.items.count > 1 {
                        Button("Tout marquer vu") { markWatched(group.items, label: "semaine \(group.week)") }
                            .font(.footnote.weight(.semibold))
                            .buttonStyle(.borderless)
                            .foregroundStyle(tint)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 4)
                rows(group.items) { item in theoryRow(item) }
            }
        }
    }

    // MARK: Pied

    private func footnote(_ late: LateWork) -> some View {
        Text("Compté dans le retard : ce qui était prévu avant la semaine \(late.currentWeek) et n'est pas fait ou pas vu, les exercices faits dont le corrigé est publié mais pas encore corrigés, et les exercices à refaire. La semaine en cours n'y entre pas, les bonus non plus.")
            .font(.footnote)
            .foregroundStyle(Carnet.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
    }

    @ViewBuilder
    private var undoBar: some View {
        if let undo {
            HStack(spacing: 12) {
                Text("Coché : \(undo.label)").font(.subheadline).foregroundStyle(Carnet.ink).lineLimit(1)
                Spacer(minLength: 8)
                Button("Annuler") { revert(undo) }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderless)
                    .foregroundStyle(tint)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Carnet.sheetRaised, in: Capsule())
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .frame(maxWidth: 520)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Lignes

    private enum Mark { case check, icon(String, Color) }

    private func section<Content: View>(_ title: String, count: Int, why: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Carnet.serif(.title3)).foregroundStyle(Carnet.ink).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Text("\(count)").font(.subheadline.monospacedDigit()).foregroundStyle(Carnet.inkSecondary)
            }
            .padding(.horizontal, 6)
            Text(why)
                .font(.footnote)
                .foregroundStyle(Carnet.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.paperCorner, style: .continuous))
        }
    }

    private func rows<Item: Identifiable, Row: View>(_ items: [Item], @ViewBuilder row: @escaping (Item) -> Row) -> some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            if index > 0 { rule(inset: 52) }
            row(item)
        }
    }

    private func rule(inset: CGFloat) -> some View {
        Rectangle().fill(Carnet.rule).frame(height: 1).padding(.leading, inset)
    }

    private func exerciseRow(_ exercise: Exercise, detail: String, mark: Mark,
                             trailing: AnyView? = nil) -> some View {
        HStack(spacing: 8) {
            switch mark {
            case .check:
                checkButton(isOn: exercise.isDone, label: "Marquer \(exercise.displayNumber) fait") {
                    markDone([exercise], label: exercise.displayNumber)
                }
            case .icon(let name, let color):
                Image(systemName: name)
                    .font(.body)
                    .foregroundStyle(color)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            }
            Button { openExercise(exercise) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    MathText(exercise.displayNumber + (exercise.title.isEmpty ? "" : " · \(exercise.title)"), font: .body)
                        .foregroundStyle(Carnet.ink)
                        .lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail).font(.footnote).foregroundStyle(Carnet.inkSecondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let trailing { trailing }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Carnet.inkTertiary)
                .accessibilityHidden(true)
        }
        .padding(.leading, 4)
        .padding(.trailing, 14)
        .padding(.vertical, 4)
    }

    private func theoryRow(_ item: TheoryItem) -> some View {
        HStack(spacing: 8) {
            checkButton(isOn: item.isWatched, label: "Marquer \(item.title) vu") {
                markWatched([item], label: item.title.isEmpty ? item.number : item.title)
            }
            Button { openTheory(item) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    MathText(item.title.isEmpty ? item.number : item.title, font: .body)
                        .foregroundStyle(Carnet.ink)
                        .lineLimit(1)
                    Text(theoryDetail(item)).font(.footnote).foregroundStyle(Carnet.inkSecondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Carnet.inkTertiary)
                .accessibilityHidden(true)
        }
        .padding(.leading, 4)
        .padding(.trailing, 14)
        .padding(.vertical, 4)
    }

    private func checkButton(isOn: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.soft()
            action()
        } label: {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isOn ? tint : Carnet.inkTertiary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Textes

    /// « Série 3 · semaine 3 · corrigé il y a 4 jours ».
    private func detail(_ exercise: Exercise, extra: String?) -> String {
        [exercise.series?.displayName, exercise.series.map { "semaine \($0.plannedWeek)" }, extra]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// « 2 questions sur 4 » quand l'exercice est commencé.
    private func exerciseDetail(_ exercise: Exercise) -> String {
        if exercise.hasSubQuestions, exercise.subQuestionDoneCount > 0 {
            return "commencé · \(exercise.subQuestionDoneCount) questions sur \(exercise.leafSubQuestions.count)"
        }
        if exercise.hasSubQuestions {
            return Plural.count(exercise.leafSubQuestions.count, "\(exercise.leafSubQuestions.count) question",
                                "\(exercise.leafSubQuestions.count) questions")
        }
        return exercise.statement.isEmpty ? "" : exercise.statement
    }

    private func theoryDetail(_ item: TheoryItem) -> String {
        var parts: [String] = []
        if item.kind == .video { parts.append(item.videoCount > 1 ? "\(item.videoCount) vidéos" : "vidéo") }
        if !item.sectionTitle.isEmpty, item.sectionTitle != item.title { parts.append(item.sectionTitle) }
        return parts.isEmpty ? item.number : parts.joined(separator: " · ")
    }

    private func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named).locale(Locale(identifier: "fr_CH")))
    }

    // MARK: Gestes

    private func markDone(_ exercises: [Exercise], label: String) {
        let changed = exercises.filter { !$0.isDone }
        guard !changed.isEmpty else { return }
        changed.forEach { $0.setDone(true) }
        try? context.save()
        undo = Undo(exercises: changed.map(\.id), label: label)
    }

    private func markWatched(_ items: [TheoryItem], label: String) {
        let changed = items.filter { !$0.isWatched }
        guard !changed.isEmpty else { return }
        let now = Date()
        changed.forEach { $0.watchedAt = now }
        try? context.save()
        undo = Undo(theory: changed.map(\.id), label: label)
    }

    private func revert(_ undo: Undo) {
        let exercises = Set(undo.exercises), theory = Set(undo.theory)
        for exercise in course.allExercises where exercises.contains(exercise.id) { exercise.setDone(false) }
        for item in course.theoryItems where theory.contains(item.id) { item.watchedAt = nil }
        try? context.save()
        self.undo = nil
    }
}

private extension String {
    var capitalizedFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}
