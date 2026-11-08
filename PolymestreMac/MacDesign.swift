import SwiftUI
import SwiftData

/// Le vocabulaire visuel du Mac : l'anneau du chrono, les boutons ronds, les
/// lignes qui réagissent au survol, les feuilles. Un seul endroit, pour que la
/// barre des menus, la fenêtre, le chrono flottant et le mode étude parlent la
/// langue de l'iPhone (`Carnet`).
enum MacStyle {
    /// Les chiffres du chrono : serif, à chasse fixe.
    static func clock(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Carnet.clock(size, weight: weight)
    }

    /// Les titres de page : le serif de l'iPhone.
    static func title(_ size: CGFloat = 26) -> Font {
        Carnet.serif(size)
    }

    static let breakTint = Carnet.correct
    /// L'objectif du jour.
    static let goalTint = Carnet.review
}

// MARK: - Anneau

/// Un anneau qui se remplit : le bloc, la pause, l'objectif du jour.
///
/// Sans animation : il était animé sur 0,95 s à chaque seconde, donc en
/// mouvement permanent — le Mac redessinait l'anneau à 60 images par seconde
/// pendant toute la session, dans la barre d'outils, le chrono flottant et le
/// panneau. Il avance d'un cran par seconde, ce que l'œil ne distingue pas.
struct TimerRing: View {
    var progress: Double
    var tint: Color
    var lineWidth: CGFloat = 8
    /// Une pause se vide au lieu de se remplir.
    var draining = false
    /// Les douze graduations d'un cadran (le grand chrono, le mode étude).
    var graduated = false

    var body: some View {
        ZStack {
            Circle().stroke(Carnet.rule, lineWidth: lineWidth)
            if graduated {
                GeometryReader { proxy in
                    let radius = min(proxy.size.width, proxy.size.height) / 2
                    ForEach(0..<12, id: \.self) { index in
                        Capsule()
                            .fill(Carnet.inkTertiary.opacity(index % 3 == 0 ? 0.9 : 0.45))
                            .frame(width: 1.5, height: index % 3 == 0 ? 10 : 6)
                            .offset(y: -radius + lineWidth + 12)
                            .rotationEffect(.degrees(Double(index) * 30))
                            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    }
                }
            }
            Circle()
                .trim(from: 0, to: max(0.001, min(1, draining ? 1 - progress : progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
    }
}

/// Les blocs Pomodoro du cycle : pleins quand ils sont faits.
struct PomodoroDots: View {
    var completed: Int
    var every: Int
    var tint: Color

    var body: some View {
        let cycle = max(2, every)
        let inCycle = completed % cycle
        HStack(spacing: 5) {
            ForEach(0..<cycle, id: \.self) { index in
                Circle()
                    .fill(index < inCycle ? tint : Carnet.rule)
                    .frame(width: 6, height: 6)
            }
        }
        .help(Plural.count(completed, "\(completed) bloc terminé", "\(completed) blocs terminés"))
    }
}

// MARK: - Boutons

/// Un bouton rond : plein (encre ou couleur du cours) pour le geste principal,
/// feuille en retrait sinon.
struct RoundButtonStyle: ButtonStyle {
    var size: CGFloat = 44
    var prominent = false
    var tint: Color = Carnet.ink

    func makeBody(configuration: Configuration) -> some View {
        RoundButtonBody(configuration: configuration, size: size, prominent: prominent, tint: tint)
    }

    private struct RoundButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        let prominent: Bool
        let tint: Color
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(prominent ? Carnet.ground : Carnet.ink)
                .frame(width: size, height: size)
                .background {
                    Circle().fill(prominent ? tint : (hovering ? Carnet.rule : Carnet.sheetRaised))
                }
                .overlay {
                    if prominent && hovering { Circle().fill(Carnet.ground.opacity(0.12)) }
                }
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Circle())
                .onHover { hovering = $0 }
                .animation(.spring(duration: 0.18, bounce: 0.2), value: configuration.isPressed)
        }
    }
}

/// Une ligne de liste qui s'éclaire au survol (hors `List`).
struct HoverRow: ViewModifier {
    var radius: CGFloat = 8
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(hovering ? Carnet.sheetRaised : .clear, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverRow(radius: CGFloat = 8) -> some View { modifier(HoverRow(radius: radius)) }
    /// Une carte : une feuille de papier.
    func macCard(padding: CGFloat = 16) -> some View { paperSheet(padding: padding) }
}

/// Un titre de section : serif, à l'encre, une précision à droite.
struct SectionTitle: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(ui: title).font(Carnet.serif(.title3)).foregroundStyle(Carnet.ink)
            Spacer()
            if let trailing {
                Text(trailing).font(.callout).monospacedDigit().foregroundStyle(Carnet.inkSecondary)
            }
        }
    }
}

// MARK: - Cibles

/// Ce que désigne une cible du chrono : un exercice, un élément de théorie.
enum MacTargets {
    /// « Série 3 · Ex 2 », « Théorie 4.2 » — le nom court d'une cible.
    static func label(_ targetID: UUID?, in course: Course?) -> String? {
        guard let targetID, let course else { return nil }
        if let exercise = course.allExercises.first(where: { $0.id == targetID }) {
            return exercise.displayNumber
        }
        if let item = course.theoryItems.first(where: { $0.id == targetID }) {
            return item.title.isEmpty ? (item.number.isEmpty ? item.kind.label : String(localized: "Théorie \(item.number)")) : item.title
        }
        return nil
    }

    /// Ce qu'on travaille, en une ligne : la cible, sinon le travail.
    static func headline(course: Course?, taskType: TaskType, targetID: UUID?) -> String {
        label(targetID, in: course) ?? (course == nil ? String(localized: "Session libre") : taskType.label)
    }

    static func tint(_ course: Course?) -> Color {
        course.map { Carnet.tint($0.colorHex) } ?? Carnet.ink
    }
}
