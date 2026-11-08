import SwiftUI

/// Ce que l'app va faire, en neuf secondes et en boucle, avant même la
/// connexion : une page Moodle s'écrit, chaque fichier se retourne pour dire ce
/// qu'il est, puis s'envole dans la semaine où il doit être fait.
///
/// C'est exactement ce que l'import fera ensuite avec les vrais cours.
struct MoodleExplainer: View {
    @State private var start = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let period = 9.5
    private static let tint = Carnet.tint("#0891B2")

    private struct Item {
        var icon: String
        var name: String
        var badge: String
        var chipIcon: String
        var chipTitle: String
        var chipDetail: String
        var isDeadline = false
    }

    private static let items = [
        Item(icon: "doc", name: String(localized: "Série 3.pdf"), badge: "PDF",
             chipIcon: "doc.text.fill", chipTitle: String(localized: "Série 3"), chipDetail: String(localized: "Série · 6 exercices")),
        Item(icon: "link", name: String(localized: "Vidéos du cours"), badge: String(localized: "Vidéo"),
             chipIcon: "play.rectangle.fill", chipTitle: String(localized: "Limites et continuité"), chipDetail: String(localized: "Vidéo · 3 vidéos")),
        Item(icon: "folder", name: String(localized: "Corrigés"), badge: "Dossier · 3 PDF",
             chipIcon: "checkmark.seal.fill", chipTitle: String(localized: "Corrigé de la série 2"), chipDetail: String(localized: "Corrigé")),
        Item(icon: "tray.and.arrow.up", name: String(localized: "Mini-projet 1"), badge: "Devoir",
             chipIcon: "flag.fill", chipTitle: String(localized: "Rendu du mini-projet"), chipDetail: String(localized: "Échéance · 14 oct."), isDeadline: true),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { context in
            let elapsed = context.date.timeIntervalSince(start)
            let t = reduceMotion ? 6.5 : elapsed.truncatingRemainder(dividingBy: Self.period)
            VStack(spacing: 18) {
                GeometryReader { proxy in
                    diorama(t: t, size: proxy.size)
                }
                .rotation3DEffect(.degrees(reduceMotion ? 0 : 7 * sin(elapsed * 0.5)), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                .rotation3DEffect(.degrees(9), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
                steps(t: t)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Animation : l'app lit une page Moodle, ouvre chaque fichier et le range dans sa semaine.")
    }

    // MARK: La scène

    private func diorama(t: Double, size: CGSize) -> some View {
        let width = size.width
        let pageTop: CGFloat = 0
        let pageHeight: CGFloat = 200
        let cardTop: CGFloat = size.height - 162
        let rowWidth = width - 28
        let pageIn = ease(progress(t, 0, 0.5))
        let cardIn = ease(progress(t, 3.3, 0.5))
        let out = 1 - progress(t, 8.7, 0.6)
        let landed = progress(t, 5.6, 0.3)

        return ZStack(alignment: .topLeading) {
            page(scan: t > 1.5 && t < 3.6 ? progress(t, 1.5, 2.1) : nil)
                .frame(width: width, height: pageHeight)
                .offset(y: pageTop + (1 - pageIn) * 24)
                .opacity(pageIn * out)

            weekCard(glow: landed)
                .frame(width: width, height: 162)
                .offset(y: cardTop + (1 - cardIn) * 40)
                .opacity(cardIn * out)

            ForEach(Self.items.indices, id: \.self) { index in
                let item = Self.items[index]
                let appear = ease(progress(t, 0.6 + Double(index) * 0.22, 0.3))
                let flip = progress(t, 1.8 + Double(index) * 0.38, 0.45)
                let travel = ease(progress(t, 4.0 + Double(index) * 0.32, 0.7))
                let fromY = pageTop + 100 + CGFloat(index) * 24
                let toY = cardTop + 44 + CGFloat(index) * 27
                let arc = sin(travel * .pi)
                row(item, flip: flip, travel: travel)
                    .frame(width: rowWidth, height: 22)
                    .scaleEffect(1 + 0.12 * arc)
                    .shadow(color: .black.opacity(0.18 * arc), radius: 10 * arc, y: 8 * arc)
                    .offset(x: 14 + 26 * arc * (index % 2 == 0 ? 1 : -1),
                            y: fromY + (toY - fromY) * travel + (1 - appear) * 8)
                    .opacity(appear * out)
                    .zIndex(travel > 0 && travel < 1 ? 10 : 1)
            }
        }
    }

    private func page(scan: Double?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(Carnet.rule).frame(width: 7, height: 7) }
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill").font(.system(size: 7))
                    Text(Institution.current.moodleHostName).font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(Carnet.inkTertiary)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Carnet.sheetRaised, in: Capsule())
                .frame(maxWidth: .infinity)
                Color.clear.frame(width: 30, height: 1)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            VStack(alignment: .leading, spacing: 1) {
                Text("Analyse I").font(Carnet.serif(.headline, weight: .semibold)).foregroundStyle(Carnet.ink)
                Text("MATH-101").font(.caption2).foregroundStyle(Carnet.inkTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            Text("Semaine 3 · Limites et continuité")
                .font(.caption.weight(.bold))
                .foregroundStyle(Carnet.inkSecondary)
                .padding(.horizontal, 14)
                .padding(.top, 10)
            Spacer()
        }
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Carnet.rule, lineWidth: 0.5))
        .overlay {
            if let scan {
                GeometryReader { proxy in
                    LinearGradient(colors: [.clear, Self.tint.opacity(0.18), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 70)
                        .offset(y: (proxy.size.height + 70) * scan - 70)
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .shadow(color: .black.opacity(0.10), radius: 18, y: 10)
    }

    private func weekCard(glow: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Semaine 3").font(Carnet.serif(.headline, weight: .semibold)).foregroundStyle(Carnet.ink)
                Spacer()
                Label("rangé", systemImage: "checkmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Self.tint, in: Capsule())
                    .scaleEffect(0.6 + 0.4 * glow)
                    .opacity(glow)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            Spacer()
        }
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(Self.tint.opacity(0.2 + 0.4 * glow), lineWidth: 0.5 + glow))
        .shadow(color: Self.tint.opacity(0.25 * glow), radius: 20 * glow, y: 8)
    }

    /// Une ligne : Moodle (gris), retournée (ce qu'elle cachait), puis rangée.
    private func row(_ item: Item, flip: Double, travel: Double) -> some View {
        let angle = flip * 180
        let chip = travel > 0.5
        let color = item.isDeadline ? Carnet.wrong : Self.tint
        return ZStack {
            if chip {
                HStack(spacing: 8) {
                    Image(systemName: item.chipIcon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(color)
                        .frame(width: 20, height: 20)
                        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text(item.chipTitle).font(.caption.weight(.semibold)).foregroundStyle(Carnet.ink).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(item.chipDetail).font(.caption2).foregroundStyle(Carnet.inkSecondary).lineLimit(1)
                }
                .padding(.horizontal, 4)
                .transition(.opacity)
            } else {
                ZStack {
                    HStack(spacing: 8) {
                        Image(systemName: item.icon).font(.caption2).foregroundStyle(Carnet.inkTertiary).frame(width: 20)
                        Text(item.name).font(.caption).foregroundStyle(Carnet.inkSecondary)
                        Spacer()
                    }
                    .opacity(angle < 90 ? 1 : 0)
                    HStack(spacing: 8) {
                        Image(systemName: item.icon).font(.caption2.weight(.semibold)).foregroundStyle(Self.tint).frame(width: 20)
                        Text(item.name).font(.caption.weight(.medium)).foregroundStyle(Carnet.ink)
                        Spacer()
                        Text(item.badge)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Self.tint.accessibleInk)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Self.tint.opacity(0.16), in: Capsule())
                    }
                    .background(Self.tint.opacity(0.06 * flip), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .rotation3DEffect(.degrees(180), axis: (x: 1, y: 0, z: 0))
                    .opacity(angle < 90 ? 0 : 1)
                }
                .rotation3DEffect(.degrees(angle), axis: (x: 1, y: 0, z: 0), perspective: 0.4)
            }
        }
        .background {
            if travel > 0 {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Carnet.sheet)
                    .padding(-4)
                    .opacity(min(1, travel * 3))
            }
        }
    }

    // MARK: Les trois temps

    private func steps(t: Double) -> some View {
        let active = t < 1.8 ? 0 : (t < 4.0 ? 1 : 2)
        let labels = [String(localized: "Lire le cours"), String(localized: "Ouvrir les fichiers"), "Ranger"]
        return HStack(spacing: 6) {
            ForEach(labels.indices, id: \.self) { index in
                HStack(spacing: 5) {
                    Text("\(index + 1)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .frame(width: 16, height: 16)
                        .background(index == active ? Color.white.opacity(0.25) : Carnet.rule, in: Circle())
                    Text(labels[index])
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .foregroundStyle(index == active ? Color.white : Carnet.inkSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(index == active ? Self.tint : Carnet.sheet, in: Capsule())
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.25), value: active)
    }

    // MARK: Temps

    private func progress(_ t: Double, _ start: Double, _ duration: Double) -> Double {
        min(1, max(0, (t - start) / duration))
    }

    private func ease(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
}
