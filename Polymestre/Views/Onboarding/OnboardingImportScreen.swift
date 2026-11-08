import SwiftUI
import CoreMotion

/// L'import, cours par cours, tel qu'il se fait :
///
///   - **Plan** : la page Moodle du cours, avec ses sections et ses activités
///     sous leur vrai nom ;
///   - **Ouverture** : chaque lien, fichier, dossier, devoir est ouvert — la
///     ligne se retourne et dit ce qu'elle cachait (« PDF », « Vidéo »…) ;
///   - **Analyse** : les éléments passent un à un sous la lecture — à quelle
///     semaine appartient chacun, série, vidéo ou échéance ;
///   - **Rangement** : chaque élément tombe dans sa semaine ; les semaines
///     défilent en carrousel, et se parcourent du doigt.
///
/// Un rail d'étapes dit où on en est, une phrase avec les vrais nombres dit ce
/// qui se fait. Le cours suivant arrive en tournant la page.
struct ImportScreen: View {
    @Bindable var setup: OnboardingAutoSetup
    var retry: () -> Void
    var goManual: () -> Void
    var proceed: () -> Void

    private var course: ImportFeed.Course? { setup.feed.current }
    private var failure: String? {
        if case .failed(let message) = setup.phase { return message }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OverallBar(setup: setup)
                .padding(.top, 10)
            if let failure {
                failureCard(failure).padding(.top, 32)
                Spacer()
            } else if let course {
                VStack(alignment: .leading, spacing: 18) {
                    CourseTitle(course: course)
                    StepRail(stage: course.stage, tint: Carnet.tint(course.colorHex))
                    Text(Self.explanation(course))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Carnet.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: Self.explanation(course))
                        .frame(minHeight: 40, alignment: .topLeading)
                }
                .padding(.top, 22)
                .id(course.id)
                .transition(.pageTurn)

                ImportStage(course: course, weeks: setup.weeks, currentWeek: setup.currentWeek)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 6)
                    .id("stage-\(course.id)")
                    .transition(.pageTurn)
            } else {
                Spacer()
                ProgressView().controlSize(.large).frame(maxWidth: .infinity)
                Spacer()
            }
            footer
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: Layout.readableWidth)
        .frame(maxWidth: .infinity)
        .animation(.spring(duration: 0.8, bounce: 0.1), value: course?.id)
        .task(id: setup.phase == .done) {
            guard setup.phase == .done else { return }
            Haptics.success()
            // Le temps de voir les derniers éléments tomber dans leur semaine.
            try? await Task.sleep(for: .seconds(3.4))
            proceed()
        }
    }

    /// Ce qui se fait à l'instant, avec les vrais nombres.
    static func explanation(_ course: ImportFeed.Course) -> String {
        switch course.stage {
        case .waiting, .outline:
            if course.sections.isEmpty { return String(localized: "Lecture du plan du cours sur Moodle…") }
            let count = course.activities.count
            return "Plan lu : \(course.sections.count) sections, \(Plural.count(count, "\(count) activité", "\(count) activités"))."
        case .activities:
            return String(localized: "Ouverture de chaque lien et fichier pour voir ce qu'il contient : \(course.openedCount) / \(max(course.openableCount, course.openedCount)).")
        case .sources:
            switch course.currentSource {
            case "Plan du cours"?: return String(localized: "Lecture du plan du cours, pour savoir quoi faire chaque semaine.")
            case "MOOC"?: return String(localized: "Lecture du MOOC Courseware cité par le cours : ses chapitres et leurs vidéos.")
            case "MediaSpace"?: return String(localized: "Lecture des listes de vidéos MediaSpace citées par le cours.")
            case "Explique"?: return String(localized: "Lecture des vidéos et des exercices d'Explique.")
            case "Botafogo"?: return String(localized: "Lecture du polycopié Botafogo du cours.")
            default: return String(localized: "Recherche des autres sources du cours : plan, MOOC, vidéos.")
            }
        case .analysis:
            return String(localized: "Analyse : à quelle semaine appartient chaque élément, et s'il s'agit d'une série, d'une vidéo ou d'une échéance.")
        case .writing, .done:
            let weeks = Set(course.placed.map(\.week)).count
            if course.placed.isEmpty { return String(localized: "Rien à ranger dans ce cours pour l'instant.") }
            return String(localized: "\(course.placed.count) éléments rangés dans \(Plural.count(weeks, "\(weeks) semaine", "\(weeks) semaines")).")
        }
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: setup.isPaused ? "pause.circle.fill" : "lock.iphone")
                .font(.subheadline)
            Text(setup.isPaused
                 ? "En pause : iOS a suspendu l'import. Il reprend dès que l'app est ouverte."
                 : "Tu peux verrouiller ton téléphone : l'import continue et s'affiche sur l'écran verrouillé.")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Carnet.inkTertiary)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(setup.phase == .done ? 0 : 1)
    }

    private func failureCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(Carnet.ink)
                .fixedSize(horizontal: false, vertical: true)
            Button("Réessayer la connexion", action: retry)
                .buttonStyle(.carnetPrimaryWide)
            Button("Continuer sans Moodle", action: goManual)
                .buttonStyle(.carnetSecondaryWide)
        }
        .padding(18)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

// MARK: - En haut : l'ensemble

/// Un segment par cours, qui se remplit ; le cours en cours et le temps restant.
private struct OverallBar: View {
    let setup: OnboardingAutoSetup

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 10, paused: !setup.isWorking)) { context in
            let now = context.date
            let kept = setup.feed.courses
            let index = kept.firstIndex { $0.id == setup.feed.currentID } ?? 0
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(kept) { course in
                        let fraction = setup.phase == .done ? 1 : (setup.progress.courses.first { $0.id == course.id }?.fraction(at: now) ?? 0)
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Carnet.rule)
                                Capsule().fill(Carnet.tint(course.colorHex))
                                    .frame(width: max(0, proxy.size.width * fraction))
                            }
                        }
                        .frame(height: 5)
                    }
                }
                HStack {
                    Text(setup.phase == .done ? "\(kept.count) cours importés" : "Cours \(index + 1) sur \(kept.count)")
                    Spacer()
                    if setup.phase != .done {
                        Text(ImportProgress.remainingLabel(setup.progress.remainingSeconds(at: now)))
                            .contentTransition(.numericText())
                    }
                }
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(Carnet.inkTertiary)
            }
        }
    }
}

private struct CourseTitle: View {
    let course: ImportFeed.Course

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(course.code)
                .font(.caption.weight(.bold))
                .foregroundStyle(Carnet.tint(course.colorHex).accessibleInk)
            Text(course.name)
                .font(Carnet.serif(.title, weight: .semibold))
                .foregroundStyle(Carnet.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Le rail des étapes

private struct StepRail: View {
    let stage: ImportProgress.Stage
    let tint: Color

    private struct Step {
        var label: String
        var icon: String
        var stages: [ImportProgress.Stage]
    }

    private static let steps = [
        Step(label: "Plan", icon: "list.bullet.rectangle.portrait", stages: [.waiting, .outline]),
        Step(label: String(localized: "Ouverture"), icon: "doc.viewfinder", stages: [.activities]),
        Step(label: "Analyse", icon: "text.magnifyingglass", stages: [.sources, .analysis]),
        Step(label: String(localized: "Rangement"), icon: "calendar", stages: [.writing, .done]),
    ]

    private var active: Int {
        Self.steps.firstIndex { $0.stages.contains(stage) } ?? 0
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Self.steps.indices, id: \.self) { index in
                VStack(spacing: 6) {
                    node(index)
                    Text(Self.steps[index].label)
                        .font(.caption2.weight(index == active ? .bold : .medium))
                        .foregroundStyle(index <= active ? Carnet.ink : Carnet.inkTertiary)
                }
                .frame(width: 70)
                if index < Self.steps.count - 1 {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Carnet.rule)
                        Capsule().fill(tint).scaleEffect(x: index < active ? 1 : 0, anchor: .leading)
                    }
                    .frame(height: 3)
                    .padding(.top, 16)
                }
            }
        }
        .animation(.spring(duration: 0.6, bounce: 0.2), value: active)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Étape \(active + 1) sur 4 : \(Self.steps[active].label)")
    }

    private func node(_ index: Int) -> some View {
        let done = index < active || stage == .done
        let current = index == active && stage != .done
        return ZStack {
            Circle().fill(done || current ? tint : Carnet.sheetRaised)
            if current {
                Circle().stroke(tint.opacity(0.35), lineWidth: 6)
                    .phaseAnimator([1.0, 1.35]) { view, scale in
                        view.scaleEffect(scale).opacity(2 - scale * 1.2)
                    } animation: { _ in .easeInOut(duration: 1.1) }
            }
            Image(systemName: done ? "checkmark" : Self.steps[index].icon)
                .font(.footnote.weight(.bold))
                .foregroundStyle(done || current ? Color.white : Carnet.inkTertiary)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 34, height: 34)
    }
}

// MARK: - La scène

/// Ce qui se voit de l'étape en cours, en profondeur, et qui suit
/// l'inclinaison du téléphone.
private struct ImportStage: View {
    let course: ImportFeed.Course
    let weeks: Int
    let currentWeek: Int

    private enum Act { case page, analysis, placing }

    private var act: Act {
        switch course.stage {
        case .waiting, .outline, .activities: return .page
        case .sources, .analysis: return .analysis
        case .writing, .done: return .placing
        }
    }

    var body: some View {
        ZStack {
            if act != .placing {
                MoodlePage(course: course, receded: act == .analysis)
                    .transition(.asymmetric(insertion: .opacity,
                                            removal: .scale(scale: 0.6).combined(with: .opacity).combined(with: .offset(y: -80))))
            }
            if act == .analysis {
                AnalysisLens(course: course, readingSources: course.stage == .sources)
                    .id(course.stage == .sources)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            if act == .placing {
                PlacingCarousel(course: course, weeks: weeks, currentWeek: currentWeek)
                    .transition(.asymmetric(insertion: .scale(scale: 1.15).combined(with: .opacity),
                                            removal: .opacity))
            }
        }
        .animation(.spring(duration: 0.8, bounce: 0.15), value: act)
        .parallax()
    }
}

// MARK: Plan et ouverture : la page Moodle

private struct MoodlePage: View {
    let course: ImportFeed.Course
    var receded = false

    @State private var revealedRows = 0

    private enum Row: Identifiable {
        case header(ImportFeed.Section)
        case activity(ImportFeed.Activity, order: Int)

        var id: String {
            switch self {
            case .header(let section): return "s\(section.id)"
            case .activity(let activity, _): return activity.id
            }
        }

        var height: CGFloat {
            if case .header = self { return 34 }
            return 40
        }
    }

    private var rows: [Row] {
        var list: [Row] = []
        var order = 0
        for section in course.sections {
            list.append(.header(section))
            for activity in section.activities {
                list.append(.activity(activity, order: order))
                if activity.isOpened { order += 1 }
            }
        }
        return list
    }

    private var tint: Color { Carnet.tint(course.colorHex) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            browserBar
            VStack(alignment: .leading, spacing: 2) {
                Text(course.name)
                    .font(Carnet.serif(.headline, weight: .semibold))
                    .foregroundStyle(Carnet.ink)
                    .lineLimit(1)
                Text(course.code)
                    .font(.caption2)
                    .foregroundStyle(Carnet.inkTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Rectangle().fill(Carnet.rule).frame(height: 0.5)
            GeometryReader { proxy in
                list(height: proxy.size.height)
            }
            .clipped()
        }
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Carnet.rule, lineWidth: 0.5))
        .overlay {
            if course.stage == .activities || course.sections.isEmpty {
                ReadingSweep(tint: tint).clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
        .shadow(color: .black.opacity(0.12), radius: 24, y: 14)
        .rotation3DEffect(.degrees(receded ? 42 : 10), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.5)
        .scaleEffect(receded ? 0.74 : 1)
        .offset(y: receded ? 110 : 0)
        .opacity(receded ? 0.22 : 1)
        .blur(radius: receded ? 2 : 0)
        .padding(.vertical, 8)
        .animation(.spring(duration: 0.9, bounce: 0.12), value: receded)
        .task(id: rows.count) {
            // Les lignes du plan s'écrivent l'une après l'autre (les trente
            // premières ; au-delà, elles sont hors de la page de toute façon).
            while revealedRows < rows.count {
                if revealedRows > 30 { revealedRows = rows.count; break }
                try? await Task.sleep(for: .seconds(0.05))
                withAnimation(.spring(duration: 0.4, bounce: 0.2)) { revealedRows += 1 }
            }
        }
    }

    private var browserBar: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { _ in
                Circle().fill(Carnet.rule).frame(width: 8, height: 8)
            }
            HStack(spacing: 5) {
                Image(systemName: "lock.fill").font(.system(size: 8))
                Text(Institution.current.moodleHostName).font(.caption2.weight(.medium))
            }
            .foregroundStyle(Carnet.inkTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Carnet.sheetRaised, in: Capsule())
            .frame(maxWidth: .infinity)
            Color.clear.frame(width: 36, height: 1)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    @ViewBuilder
    private func list(height: CGFloat) -> some View {
        if course.sections.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(0..<7, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Carnet.sheetRaised)
                        .frame(width: index % 3 == 0 ? 120 : 220, height: index % 3 == 0 ? 10 : 14)
                }
            }
            .padding(16)
        } else {
            let all = rows
            let shift = scroll(all, height: height)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(all.enumerated()), id: \.element.id) { index, row in
                    rowView(row)
                        .frame(height: row.height)
                        .opacity(index < revealedRows ? 1 : 0)
                        .offset(x: index < revealedRows ? 0 : 18)
                }
            }
            .padding(.horizontal, 12)
            .offset(y: -shift)
            .animation(.smooth(duration: 0.7), value: shift)
        }
    }

    /// De combien la page défile : la dernière activité ouverte reste à mi-hauteur.
    private func scroll(_ rows: [Row], height: CGFloat) -> CGFloat {
        var tops: [CGFloat] = []
        var y: CGFloat = 0
        for row in rows {
            tops.append(y)
            y += row.height
        }
        let frontier = rows.lastIndex { row in
            if case .activity(let activity, _) = row { return activity.isOpened }
            return false
        }
        let target = frontier.map { tops[$0] } ?? 0
        return max(0, min(target - height * 0.55, y - height + 12))
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        switch row {
        case .header(let section):
            Text(section.title)
                .font(.caption.weight(.bold))
                .foregroundStyle(Carnet.inkSecondary)
                .lineLimit(1)
                .padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .activity(let activity, let order):
            ActivityRow(activity: activity, tint: tint, angle: activity.isOpened ? 180 : 0)
                .animation(.spring(duration: 0.6, bounce: 0.25).delay(Double(order % 18) * 0.06),
                           value: activity.isOpened)
        }
    }
}

/// Une activité de la page Moodle. Ouverte, elle se retourne : au dos, ce
/// qu'elle cachait.
private struct ActivityRow: View, Animatable {
    let activity: ImportFeed.Activity
    let tint: Color
    var angle: Double

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    var body: some View {
        ZStack {
            front.opacity(angle < 90 ? 1 : 0)
            back
                .rotation3DEffect(.degrees(180), axis: (x: 1, y: 0, z: 0))
                .opacity(angle < 90 ? 0 : 1)
        }
        .rotation3DEffect(.degrees(angle), axis: (x: 1, y: 0, z: 0), perspective: 0.45)
    }

    private var front: some View {
        HStack(spacing: 10) {
            Image(systemName: activity.icon)
                .font(.footnote)
                .foregroundStyle(Carnet.inkTertiary)
                .frame(width: 22)
            Text(activity.name)
                .font(.footnote)
                .foregroundStyle(activity.isOpenable ? Carnet.inkSecondary : Carnet.inkTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
    }

    private var back: some View {
        HStack(spacing: 10) {
            Image(systemName: activity.icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
            Text(activity.name)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Carnet.ink)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(activity.revealed ?? "")
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint.accessibleInk)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(tint.opacity(0.16), in: Capsule())
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.vertical, 3)
    }
}

/// Un trait de lumière qui descend la page : elle est en train d'être lue.
private struct ReadingSweep: View {
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            GeometryReader { proxy in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
                LinearGradient(colors: [.clear, tint.opacity(0.16), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 90)
                    .offset(y: (proxy.size.height + 90) * phase - 90)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: Analyse

/// Les éléments ouverts passent un à un sous la lecture ; les questions que
/// l'analyse tranche s'allument à tour de rôle.
private struct AnalysisLens: View {
    let course: ImportFeed.Course
    let readingSources: Bool

    private var items: [ImportFeed.Activity] {
        let opened = course.activities.filter(\.isOpened)
        return opened.isEmpty ? course.activities : opened
    }

    private var questions: [String] {
        guard readingSources else { return [String(localized: "Quelle semaine ?"), String(localized: "Quel type ?"), String(localized: "Quelle date ?")] }
        return course.sourcesRead.isEmpty ? [String(localized: "Plan du cours"), "MOOC", String(localized: "Vidéos")] : Array(course.sourcesRead.suffix(3))
    }

    /// La question allumée : à tour de rôle pendant l'analyse ; la source en
    /// cours de lecture, sinon.
    private func lit(_ tick: Int) -> Int {
        guard readingSources, let current = course.currentSource, let index = questions.firstIndex(of: current) else {
            return tick % questions.count
        }
        return index
    }

    var body: some View {
        let tint = Carnet.tint(course.colorHex)
        TimelineView(.periodic(from: .now, by: 1.1)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate / 1.1)
            VStack(spacing: 22) {
                ZStack {
                    ForEach((0..<min(3, max(items.count, 1))).reversed(), id: \.self) { depth in
                        if !items.isEmpty {
                            let item = items[(tick + depth) % items.count]
                            LensCard(activity: item, tint: tint, scanning: depth == 0)
                                .scaleEffect(1 - CGFloat(depth) * 0.07)
                                .offset(y: CGFloat(depth) * -16)
                                .opacity(1 - Double(depth) * 0.3)
                                .zIndex(Double(-depth))
                                .id("\(item.id)-\(depth)")
                                .transition(.asymmetric(insertion: .opacity,
                                                        removal: .offset(y: 120).combined(with: .opacity).combined(with: .scale(scale: 0.8))))
                        }
                    }
                }
                .animation(.spring(duration: 0.55, bounce: 0.2), value: tick)
                .rotation3DEffect(.degrees(8), axis: (x: 1, y: 0, z: 0), perspective: 0.5)

                FlowRow(questions: questions, lit: lit(tick), tint: tint)
            }
            .padding(.top, 10)
        }
    }
}

private struct LensCard: View {
    let activity: ImportFeed.Activity
    let tint: Color
    let scanning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: activity.icon)
                    .font(.headline)
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Spacer()
                if let revealed = activity.revealed {
                    Text(revealed)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint.accessibleInk)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(tint.opacity(0.16), in: Capsule())
                }
            }
            Text(activity.name)
                .font(Carnet.serif(.title3, weight: .semibold))
                .foregroundStyle(Carnet.ink)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<3, id: \.self) { line in
                    RoundedRectangle(cornerRadius: 3).fill(Carnet.sheetRaised)
                        .frame(width: [220, 180, 120][line], height: 7)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: 320)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            if scanning {
                ScanBeam(tint: tint).clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(scanning ? tint.opacity(0.5) : Carnet.rule, lineWidth: scanning ? 1.5 : 0.5))
        .shadow(color: .black.opacity(0.12), radius: 18, y: 10)
    }
}

/// Le faisceau de lecture : une ligne lumineuse qui balaie la carte.
private struct ScanBeam: View {
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            GeometryReader { proxy in
                let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
                let y = proxy.size.height * (0.5 - 0.5 * cos(t * 2 * .pi))
                ZStack(alignment: .top) {
                    LinearGradient(colors: [tint.opacity(0), tint.opacity(0.22)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 44)
                        .offset(y: y - 44)
                    Rectangle().fill(tint).frame(height: 2)
                        .shadow(color: tint, radius: 6)
                        .offset(y: y)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct FlowRow: View {
    let questions: [String]
    let lit: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            ForEach(questions.indices, id: \.self) { index in
                Text(questions[index])
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(index == lit ? Color.white : Carnet.inkSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(index == lit ? tint : Carnet.sheet, in: Capsule())
                    .scaleEffect(index == lit ? 1.06 : 1)
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.3), value: lit)
    }
}

// MARK: Rangement

/// Les éléments compris tombent dans leur semaine, l'un après l'autre ; le
/// carrousel des semaines suit, puis revient sur la semaine en cours.
private struct PlacingCarousel: View {
    let course: ImportFeed.Course
    let weeks: Int
    let currentWeek: Int

    @State private var focus: Double = 1
    @State private var landed: Set<String> = []

    var body: some View {
        WeekCarousel(weeks: weeks, focus: $focus, cardSize: CGSize(width: 236, height: 300)) { week in
            CourseWeekCard(course: course, week: week, landed: landed, isCurrent: week == currentWeek)
        }
        .task(id: course.placed.count) {
            for item in course.placed where !landed.contains(item.id) {
                withAnimation(.spring(duration: 0.5, bounce: 0.35)) { _ = landed.insert(item.id) }
                withAnimation(.spring(duration: 0.55, bounce: 0.12)) { focus = Double(item.week) }
                if item.kind == .series || item.kind == .deadline { Haptics.soft() }
                try? await Task.sleep(for: .seconds(0.11))
            }
            try? await Task.sleep(for: .seconds(0.4))
            withAnimation(.spring(duration: 0.9, bounce: 0.15)) { focus = Double(currentWeek) }
        }
    }
}

// MARK: - Inclinaison

/// L'attitude du téléphone, partagée par les vues qui suivent l'inclinaison.
@MainActor
@Observable
final class DeviceTilt {
    static let shared = DeviceTilt()

    private(set) var pitch = 0.0
    private(set) var roll = 0.0
    @ObservationIgnored private let manager = CMMotionManager()
    @ObservationIgnored private var users = 0
    @ObservationIgnored private var basePitch: Double?

    func start() {
        users += 1
        guard users == 1, manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1 / 30
        manager.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let attitude = data?.attitude else { return }
            // La position de départ est la position neutre : on tient son
            // téléphone comme on veut.
            if self.basePitch == nil { self.basePitch = attitude.pitch }
            self.pitch = attitude.pitch - (self.basePitch ?? 0)
            self.roll = attitude.roll
        }
    }

    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        manager.stopDeviceMotionUpdates()
        basePitch = nil
    }
}

private struct Parallax: ViewModifier {
    var strength: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tilt = DeviceTilt.shared

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            let x = max(-1, min(1, tilt.pitch)) * strength
            let y = max(-1, min(1, tilt.roll)) * strength
            content
                .rotation3DEffect(.degrees(-x), axis: (x: 1, y: 0, z: 0), perspective: 0.4)
                .rotation3DEffect(.degrees(y), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
                .animation(.interactiveSpring(duration: 0.3), value: x)
                .animation(.interactiveSpring(duration: 0.3), value: y)
                .onAppear { tilt.start() }
                .onDisappear { tilt.stop() }
        }
    }
}

extension View {
    /// Suit l'inclinaison du téléphone, de quelques degrés.
    func parallax(_ strength: Double = 9) -> some View {
        modifier(Parallax(strength: strength))
    }
}

// MARK: - Page tournée

private struct PageTurnModifier: ViewModifier {
    let angle: Double
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), anchor: anchor, perspective: 0.5)
            .opacity(abs(angle) > 60 ? 0 : 1)
    }
}

extension AnyTransition {
    /// Le cours suivant arrive comme une page qu'on tourne.
    static var pageTurn: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: PageTurnModifier(angle: 80, anchor: .trailing),
                                 identity: PageTurnModifier(angle: 0, anchor: .trailing)),
            removal: .modifier(active: PageTurnModifier(angle: -80, anchor: .leading),
                               identity: PageTurnModifier(angle: 0, anchor: .leading)))
    }
}
