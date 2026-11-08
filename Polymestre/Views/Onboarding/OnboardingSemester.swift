import SwiftUI

// MARK: - Le carrousel des semaines

/// Les semaines du semestre en carrousel 3D : celle du centre de face, ses
/// voisines tournées et en retrait. Se fait glisser du doigt, un cran par
/// semaine.
struct WeekCarousel<Card: View>: View {
    let weeks: Int
    @Binding var focus: Double
    var cardSize: CGSize
    @ViewBuilder var card: (Int) -> Card

    @State private var dragStart: Double?

    private var spacing: CGFloat { cardSize.width * 0.56 }

    var body: some View {
        ZStack {
            ForEach(visibleWeeks, id: \.self) { week in
                placed(week)
            }
        }
        .frame(maxWidth: .infinity, minHeight: cardSize.height)
        .contentShape(Rectangle())
        .gesture(drag)
        .onChange(of: Int(focus.rounded())) { _, _ in
            if dragStart != nil { Haptics.soft() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAdjustableAction { direction in
            let step: Double = direction == .increment ? 1 : -1
            withAnimation { focus = min(Double(weeks), max(1, focus.rounded() + step)) }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragStart == nil { dragStart = focus }
                let raw = (dragStart ?? focus) - Double(value.translation.width / spacing)
                focus = rubberBand(raw)
            }
            .onEnded { value in
                let predicted = (dragStart ?? focus) - Double(value.predictedEndTranslation.width / spacing)
                dragStart = nil
                withAnimation(.spring(duration: 0.55, bounce: 0.2)) {
                    focus = min(Double(weeks), max(1, predicted.rounded()))
                }
            }
    }

    private var visibleWeeks: [Int] {
        (1...max(weeks, 1)).filter { abs(Double($0) - focus) < 3.6 }
    }

    /// Une carte à sa place : décalée, tournée et en retrait selon sa distance au centre.
    private func placed(_ week: Int) -> some View {
        let distance: Double = Double(week) - focus
        let away: Double = abs(distance)
        let angle: Double = max(-58, min(58, -distance * 34))
        let scale: CGFloat = 1 - CGFloat(min(away, 3)) * 0.1
        let fade: Double = away > 2.8 ? max(0, 3.6 - away) : 1
        return card(week)
            .frame(width: cardSize.width, height: cardSize.height)
            .scaleEffect(scale)
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
            .offset(x: CGFloat(distance) * spacing)
            .opacity(fade)
            .zIndex(-away)
            .onTapGesture {
                Haptics.tap()
                withAnimation(.spring(duration: 0.5, bounce: 0.18)) { focus = Double(week) }
            }
    }

    /// Au-delà de la première ou de la dernière semaine, ça résiste.
    private func rubberBand(_ value: Double) -> Double {
        let upper = Double(weeks)
        if value < 1 { return 1 - (1 - value) * 0.3 }
        if value > upper { return upper + (value - upper) * 0.3 }
        return value
    }
}

// MARK: - Une semaine d'un cours (pendant l'import)

struct CourseWeekCard: View {
    let course: ImportFeed.Course
    let week: Int
    let landed: Set<String>
    let isCurrent: Bool

    private var items: [ImportFeed.Placed] { course.placed(inWeek: week).filter { landed.contains($0.id) } }

    var body: some View {
        let tint = Carnet.tint(course.colorHex)
        VStack(alignment: .leading, spacing: 12) {
            WeekHeader(week: week, isCurrent: isCurrent, tint: tint)
            if items.isEmpty {
                Spacer()
                Text("Rien de rangé ici")
                    .font(.footnote)
                    .foregroundStyle(Carnet.inkTertiary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(items.prefix(5)) { item in
                        PlacedRow(item: item, tint: tint)
                            .transition(.asymmetric(
                                insertion: .offset(y: -70).combined(with: .scale(scale: 0.6)).combined(with: .opacity),
                                removal: .opacity))
                    }
                    if items.count > 5 {
                        Text("+ \(items.count - 5) autres")
                            .font(.caption)
                            .foregroundStyle(Carnet.inkTertiary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(isCurrent ? tint.opacity(0.6) : Carnet.rule, lineWidth: isCurrent ? 1.5 : 0.5))
        .shadow(color: .black.opacity(0.10), radius: 18, y: 10)
    }
}

private struct WeekHeader: View {
    let week: Int
    let isCurrent: Bool
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Semaine \(week)")
                .font(Carnet.serif(.title3, weight: .semibold))
                .foregroundStyle(Carnet.ink)
            Spacer(minLength: 4)
            if isCurrent {
                Text("cette semaine")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(tint, in: Capsule())
            }
        }
    }
}

private struct PlacedRow: View {
    let item: ImportFeed.Placed
    let tint: Color

    var body: some View {
        let color = item.kind == .deadline ? Carnet.wrong : tint
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Carnet.ink)
                    .lineLimit(1)
                Text([item.kindLabel, item.detail].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Carnet.inkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 4. Ton semestre

/// Tout le semestre, semaine par semaine, tous cours confondus : les cartes
/// arrivent du fond, le carrousel se pose sur la semaine en cours, et se
/// parcourt du doigt.
struct SemesterScreen: View {
    @Bindable var setup: OnboardingAutoSetup
    var proceed: () -> Void

    @State private var focus: Double = 1
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ton semestre est rangé")
                    .font(Carnet.serif(.largeTitle, weight: .semibold))
                    .foregroundStyle(Carnet.ink)
                Text(summary)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Carnet.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 28)
            .rise(appeared, delay: 0.05)

            Spacer(minLength: 16)
            WeekCarousel(weeks: setup.weeks, focus: $focus, cardSize: CGSize(width: 286, height: 400)) { week in
                SemesterWeekCard(groups: setup.feed.week(week), week: week, isCurrent: week == setup.currentWeek)
            }
            .scaleEffect(appeared ? 1 : 0.6)
            .rotation3DEffect(.degrees(appeared ? 0 : 50), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
            .opacity(appeared ? 1 : 0)
            .animation(.spring(duration: 1.0, bounce: 0.2).delay(0.15), value: appeared)
            .parallax(6)

            Text("Fais glisser pour parcourir les semaines.")
                .font(.footnote)
                .foregroundStyle(Carnet.inkTertiary)
                .padding(.top, 14)
                .rise(appeared, delay: 1.2)
            Spacer(minLength: 16)
            Button(action: proceed) {
                Label("Continuer", systemImage: "arrow.right")
            }
            .buttonStyle(.carnetPrimaryWide)
            .padding(.bottom, 8)
            .rise(appeared, delay: 1.0)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: Layout.readableWidth)
        .frame(maxWidth: .infinity)
        .onAppear {
            appeared = true
            // Le carrousel balaie le semestre depuis la première semaine, puis
            // s'arrête sur celle en cours.
            withAnimation(.spring(duration: 1.6, bounce: 0.12).delay(0.5)) {
                focus = Double(setup.currentWeek)
            }
        }
        .sensoryFeedback(.success, trigger: appeared)
    }

    private var summary: String {
        let t = setup.feed.totals
        var parts = [String(localized: "\(setup.feed.courses.count) cours")]
        if t.series > 0 { parts.append(String(localized: "\(t.series) séries")) }
        if t.videos + t.theory > 0 { parts.append("\(t.videos + t.theory) chapitres") }
        if t.deadlines > 0 { parts.append(Plural.count(t.deadlines, "\(t.deadlines) échéance", "\(t.deadlines) échéances")) }
        return parts.joined(separator: " · ") + String(localized: ", sur \(setup.weeks) semaines.")
    }
}

private struct SemesterWeekCard: View {
    let groups: [(course: ImportFeed.Course, items: [ImportFeed.Placed])]
    let week: Int
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WeekHeader(week: week, isCurrent: isCurrent, tint: Carnet.ink)
            if groups.isEmpty {
                Spacer()
                Text("Rien de prévu")
                    .font(.footnote)
                    .foregroundStyle(Carnet.inkTertiary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(groups.prefix(5), id: \.course.id) { group in
                        CourseLine(course: group.course, items: group.items)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
            .strokeBorder(isCurrent ? Carnet.ink.opacity(0.5) : Carnet.rule, lineWidth: isCurrent ? 1.5 : 0.5))
        .shadow(color: .black.opacity(0.12), radius: 22, y: 12)
    }
}

/// Un cours dans la semaine : son code, puis ce qu'il y a à faire.
private struct CourseLine: View {
    let course: ImportFeed.Course
    let items: [ImportFeed.Placed]

    var body: some View {
        let tint = Carnet.tint(course.colorHex)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 8, height: 8)
                Text(course.code).font(.caption.weight(.bold)).foregroundStyle(tint.accessibleInk)
            }
            ForEach(items.prefix(3)) { item in
                HStack(spacing: 7) {
                    Image(systemName: item.icon)
                        .font(.caption2)
                        .foregroundStyle(item.kind == .deadline ? Carnet.wrong : Carnet.inkTertiary)
                        .frame(width: 14)
                    Text(item.title)
                        .font(.footnote)
                        .foregroundStyle(Carnet.ink)
                        .lineLimit(1)
                    if let detail = item.detail {
                        Text(detail).font(.caption).foregroundStyle(Carnet.inkTertiary).lineLimit(1)
                    }
                }
            }
            if items.count > 3 {
                Text("+ \(items.count - 3)").font(.caption).foregroundStyle(Carnet.inkTertiary).padding(.leading, 21)
            }
        }
    }
}
