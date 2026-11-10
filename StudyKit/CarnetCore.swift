import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// « Carnet » : le papier et l'encre, **les mêmes sur l'iPhone et le Mac**.
///
/// Ce fichier est compilé par les deux apps (dossier `StudyKit`) : les couleurs,
/// les titres en serif, les feuilles, les sur-titres et les deux boutons
/// (encre pleine, papier en retrait). Ce qui n'a de sens que sur un appareil
/// (le verre d'iOS 26, l'apparence de la barre de navigation, les mesures de la
/// fenêtre du Mac) vit dans une extension de `Carnet` propre à chaque app.
enum Carnet {

    // MARK: Papier et encre

    /// Le fond des écrans : papier crème, papier sombre la nuit.
    static let ground = Color.paper(light: "#F4F0E6", dark: "#15130F")
    /// Une feuille posée sur le fond : listes groupées, cartes.
    static let sheet = Color.paper(light: "#FFFDF8", dark: "#211E18")
    /// Une feuille en retrait : puces, pastilles, champs.
    static let sheetRaised = Color.paper(light: "#EFE9DC", dark: "#2B271F")
    /// L'encre : texte, glyphes, boutons pleins.
    static let ink = Color.paper(light: "#1D1B16", dark: "#EDE6D6")
    static let inkSecondary = Color.paper(light: "#6B655A", dark: "#A89F8D")
    /// Le troisième niveau de gris : ce qui est là sans être à lire (cotes,
    /// chevrons, « corrigé »). Il était trop pâle pour le texte qu'il porte :
    /// 3.10:1 sur le papier clair et 3.26:1 sur la feuille en retrait la nuit,
    /// sous les 4.5:1 du texte courant. Il est maintenant résolu contre la plus
    /// **claire** des surfaces où il se pose — 4.93:1 sur la feuille en retrait
    /// (le cas le plus clair), 5.87:1 sur la feuille, 5.24:1 sur le papier ;
    /// 4.96:1 la nuit. Il reste plus pâle que `inkSecondary` sans être illisible.
    static let inkTertiary = Color.paper(light: "#696356", dark: "#9E9480")
    /// Les traits : séparateurs, contours.
    static let rule = Color.paper(light: "#E6DFD0", dark: "#353027")
    /// Le surligneur : la sous-question en cours dans un énoncé.
    static let marker = Color.paper(light: "#FBF1C9", dark: "#4A4020")

    // MARK: Verdicts de correction

    /// Le vert « juste » : 4.27:1 sur la feuille en retrait du papier clair,
    /// sous le seuil du texte (4.76:1 maintenant), et 5.66:1 sur la feuille.
    static let correct = Color.paper(light: "#3A723A", dark: "#8FC58A")
    /// « À revoir » : l'ambre est le plus clair des trois verdicts sur le papier,
    /// et il n'était qu'à 4.18:1 — sous le seuil du texte (5.48:1 sur la feuille,
    /// 4.60:1 sur la feuille en retrait).
    static let review = Color.paper(light: "#8F5E06", dark: "#E0B04E")
    static let wrong = Color.paper(light: "#A33A2A", dark: "#E7836F")

    static func color(for correctness: Correctness) -> Color {
        switch correctness {
        case .correct: return correct
        case .partial: return review
        case .wrong: return wrong
        }
    }

    // MARK: Couleurs de cours

    /// La couleur d'un cours, **adoucie** pour le papier : même teinte,
    /// saturation et luminosité ramenées vers l'encre ; plus claire la nuit.
    static func tint(_ hex: String) -> Color {
        Color.adaptive(base: Color(hex: hex)) { h, s, b, dark in
            dark ? (h, min(s, 0.45), max(b, 0.82)) : (h, min(s * 0.62, 0.62), min(b * 0.74, 0.62))
        }
    }

    static func tint(_ course: Course?) -> Color {
        course.map { tint($0.colorHex) } ?? inkSecondary
    }

    /// Le fond léger d'une tuile d'icône de cette couleur.
    static func wash(_ hex: String) -> Color { tint(hex).opacity(0.16) }

    // MARK: Typographie

    /// Titres de section et nombres mis en avant : serif (New York).
    static func serif(_ style: Font.TextStyle, weight: Font.Weight = .medium) -> Font {
        .system(style, design: .serif).weight(weight)
    }

    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Les chiffres du chrono : serif, à chasse fixe.
    static func clock(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif).monospacedDigit()
    }

    /// Les coins d'une feuille du bureau (les mêmes sur les deux appareils).
    static let paperCorner: CGFloat = 14
}

extension Color {
    /// Une couleur explicite par apparence (clair / sombre), sur les deux appareils.
    static func paper(light: String, dark: String) -> Color {
        #if os(macOS)
        let light = NSColor(Color(hex: light)), dark = NSColor(Color(hex: dark))
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
        #else
        let light = UIColor(Color(hex: light)), dark = UIColor(Color(hex: dark))
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
        #endif
    }

    /// Une couleur recalculée selon l'apparence (teinte, saturation, luminosité).
    static func adaptive(base: Color, _ transform: @escaping (CGFloat, CGFloat, CGFloat, Bool) -> (CGFloat, CGFloat, CGFloat)) -> Color {
        #if os(macOS)
        let color = NSColor(base).usingColorSpace(.sRGB) ?? .gray
        return Color(nsColor: NSColor(name: nil) { appearance in
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            let (nh, ns, nb) = transform(h, s, b, appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            return NSColor(hue: nh, saturation: ns, brightness: nb, alpha: 1)
        })
        #else
        let color = UIColor(base)
        return Color(uiColor: UIColor { traits in
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            let (nh, ns, nb) = transform(h, s, b, traits.userInterfaceStyle == .dark)
            return UIColor(hue: nh, saturation: ns, brightness: nb, alpha: 1)
        })
        #endif
    }
}

// MARK: - Feuilles et traits

/// Une feuille posée sur le papier : fond, coins arrondis, un trait fin.
struct PaperSheet: ViewModifier {
    var padding: CGFloat = 16
    var highlighted: Color?

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.paperCorner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Carnet.paperCorner, style: .continuous)
                .strokeBorder(highlighted ?? Carnet.rule, lineWidth: highlighted == nil ? 1 : 1.5))
    }
}

/// Le trait entre deux lignes d'une feuille.
struct PaperRule: View {
    var inset: CGFloat = 0

    var body: some View {
        Rectangle().fill(Carnet.rule).frame(height: 1).padding(.leading, inset)
    }
}

/// Un sur-titre : petites capitales espacées.
struct Kicker: View {
    let text: String
    var color: Color = Carnet.inkSecondary

    init(_ text: String, color: Color = Carnet.inkSecondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(verbatim: Bundle.main.localizedString(forKey: text, value: text, table: nil).uppercased())
            .font(.caption.weight(.semibold))
            .tracking(1.1)
            .foregroundStyle(color)
    }
}

/// Le fond de chaque page : le papier.
struct PaperPage: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Carnet.ground)
    }
}

extension View {
    func paperSheet(padding: CGFloat = 16, highlighted: Color? = nil) -> some View {
        modifier(PaperSheet(padding: padding, highlighted: highlighted))
    }
    func paperPage() -> some View { modifier(PaperPage()) }
}

// MARK: - Boutons

/// Le bouton plein : encre sur papier (papier sur encre la nuit), ou la couleur
/// du cours quand on la donne.
struct InkButtonStyle: ButtonStyle {
    var tint: Color?
    var large = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(large ? .body.weight(.semibold) : .callout.weight(.semibold))
            .foregroundStyle(tint == nil ? Carnet.ground : .white)
            .padding(.horizontal, large ? 20 : 14)
            .frame(minHeight: large ? 40 : Self.minHeight)
            .background(tint ?? Carnet.ink, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .contentShape(Capsule())
    }

    /// Une cible au doigt plus haute que sous la souris.
    #if os(macOS)
    static let minHeight: CGFloat = 30
    #else
    static let minHeight: CGFloat = 40
    #endif
}

/// Le bouton secondaire : une feuille en retrait.
struct PaperButtonStyle: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        PaperButtonBody(configuration: configuration, large: large, isEnabled: isEnabled)
    }

    private struct PaperButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let large: Bool
        let isEnabled: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(large ? .body.weight(.medium) : .callout.weight(.medium))
                .foregroundStyle(Carnet.ink)
                .padding(.horizontal, large ? 18 : 12)
                .frame(minHeight: large ? 40 : InkButtonStyle.minHeight - 2)
                .background(hovering ? Carnet.rule : Carnet.sheetRaised, in: Capsule())
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == InkButtonStyle {
    static var ink: InkButtonStyle { InkButtonStyle() }
}

extension ButtonStyle where Self == PaperButtonStyle {
    static var paper: PaperButtonStyle { PaperButtonStyle() }
    static var paperLarge: PaperButtonStyle { PaperButtonStyle(large: true) }
}

// MARK: - Cases à cocher

/// La case à cocher du système sur le Mac ; sur l'iPhone, une case dessinée
/// (le style `.checkbox` n'y existe pas).
struct CarnetCheckbox: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(configuration.isOn ? Carnet.ink : Carnet.inkTertiary)
                configuration.label.foregroundStyle(Carnet.ink)
            }
        }
        .buttonStyle(.plain)
    }
}

extension View {
    @ViewBuilder
    func studyCheckbox() -> some View {
        #if os(macOS)
        toggleStyle(.checkbox)
        #else
        toggleStyle(CarnetCheckbox())
        #endif
    }
}

extension View {
    /// Un titre de navigation en ligne (l'iPhone ; rien sur le Mac).
    @ViewBuilder
    func navigationBarTitleDisplayModeInline() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

extension Text {
    /// Un libellé de l'interface reçu en `String` (titre d'un composant) :
    /// traduit s'il est au catalogue, affiché tel quel sinon — sans Markdown ni
    /// format, pour qu'un nom de cours passe sans surprise.
    init(ui text: String) {
        self.init(verbatim: Bundle.main.localizedString(forKey: text, value: text, table: nil))
    }
}

// MARK: - Teintes des natures de travail

extension TaskType {
    /// Une teinte par nature de travail, **la même partout** : bilan de l'iPhone,
    /// du Mac et de Windows (`palette.ts`), anneaux et pictogrammes des fiches de
    /// cours. Des teintes sourdes, dans la palette du papier, qui ne rivalisent
    /// pas avec les verdicts de correction (vert, ambre, rouge) — les couleurs
    /// vives du système (`.purple`, `.blue`, `.orange`…) juraient avec le reste
    /// et ne disaient pas la même chose d'un écran à l'autre.
    var tint: Color {
        switch canonical {
        case .theory: return Carnet.tint("#4F6FB8")
        case .exercise: return Carnet.tint("#C08A2E")
        case .correction: return Carnet.tint("#5E9A6A")
        case .flashcards: return Carnet.tint("#A0567E")
        // Sa propre teinte, pas le gris d'« Autre » : les heures d'amphi se
        // distinguent dans le bilan.
        case .lecture: return Carnet.tint("#3E8E96")
        default: return Carnet.tint("#7A7468")
        }
    }
}

extension TheoryKind {
    /// Tous les supports sont de la **théorie** : une seule teinte. Le glyphe
    /// suffit à distinguer une vidéo d'une lecture.
    var tint: Color { TaskType.theory.tint }
}
