import SwiftUI

/// Le cadran du chrono : un anneau, le temps au centre.
///
/// Le compteur était un simple texte posé dans une carte. Un anneau fait deux
/// choses qu'un texte ne fait pas : il **situe** la session dans le bloc en cours,
/// et il donne au chrono la présence visuelle qu'on attend de l'écran principal
/// d'une app de travail.
struct TimerDial: View {
    var time: String
    /// Progression de l'anneau. `nil` quand il n'y a rien à mesurer — le chrono
    /// libre n'a pas d'échéance, et un anneau qui tourne pour rien mentirait.
    var progress: Double?
    var tint: Color = Theme.accent
    var isRunning: Bool = false
    /// Libellé sous le temps (« Bloc 2 », « reste 12 min »).
    var caption: String?
    /// Ce sur quoi porte la session (« CS-250 · Exercices »).
    var context: String?
    /// Temps écoulé, en secondes. Sert à **poser** le point sur l'anneau : sa
    /// position est le temps lui-même, pas un angle tenu à part — le point ne peut
    /// donc pas diverger de l'affichage.
    var elapsed: TimeInterval = 0
    /// Mode ajustement : un point apparaît sur l'anneau et se fait glisser.
    var isAdjusting: Bool = false
    /// Variation à appliquer, en secondes (positive ou négative).
    var onAdjust: ((TimeInterval) -> Void)?
    /// Fixe le temps **absolu** — c'est ce qu'un champ éditable demande.
    var onSet: ((TimeInterval) -> Void)??

    /// Un tour complet de l'anneau vaut une heure : 6° par minute. Assez fin pour
    /// viser la minute, assez large pour ajouter une heure en un geste.
    private static let minutesPerTurn: Double = 60

    /// Au repos, le cadran se fait petit : « 00:00 » ne dit rien, et la place
    /// revient à ce qui lance une session (les choix, les raccourcis). Il
    /// reprend sa taille dès qu'un temps s'écoule.
    var compact: Bool = false

    @ScaledMetric(relativeTo: .largeTitle) private var fullDiameter: CGFloat = 270
    @ScaledMetric(relativeTo: .largeTitle) private var fullTimeSize: CGFloat = 64
    private var diameter: CGFloat { fullDiameter * (compact ? 0.68 : 1) }
    private var timeSize: CGFloat { fullTimeSize * (compact ? 0.72 : 1) }
    @ScaledMetric(relativeTo: .body) private var ringWidth: CGFloat = 5

    private var clamped: Double { min(1, max(0, progress ?? 0)) }

    /// Position du point sur l'anneau : le temps ramené à un tour d'heure.
    private var knobAngle: Double {
        let secondsInTurn = max(0, elapsed).truncatingRemainder(dividingBy: 3600)
        return secondsInTurn / 3600 * 360
    }

    /// Dernier angle touché, pour ne compter que la **variation**.
    @State private var lastDragAngle: Double?
    /// Saisie au clavier en cours.
    @State private var isTyping = false
    @State private var typed = ""
    @FocusState private var typingFocused: Bool
    /// Minute atteinte au dernier retour haptique.
    @State private var lastTick: Int = 0

    var body: some View {
        ZStack {
            // Piste : toujours visible, pour que l'anneau ne « saute » pas quand la
            // progression repart de zéro.
            Circle()
                .stroke(Carnet.rule, lineWidth: ringWidth)
            // Les graduations d'un cadran : douze traits fins, sur le papier.
            ForEach(0..<12, id: \.self) { index in
                Capsule()
                    .fill(Carnet.inkTertiary.opacity(index % 3 == 0 ? 0.9 : 0.45))
                    .frame(width: 1.5, height: index % 3 == 0 ? 10 : 6)
                    .offset(y: -diameter / 2 + ringWidth + 12)
                    .rotationEffect(.degrees(Double(index) * 30))
            }

            if progress != nil {
                Circle()
                    .trim(from: 0, to: clamped)
                    .stroke(tint,
                            style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    // La progression doit glisser, pas sauter d'un coup à chaque
                    // battement : c'est ce qui rend l'anneau lisible pendant
                    // qu'on travaille. Sauf sous le doigt : une courbe qui
                    // traîne derrière le geste se bat contre lui.
                    .animation(isAdjusting ? nil : Motion.progress, value: clamped)
            }

            if isAdjusting {
                // Le point à faire glisser, posé sur l'anneau.
                Circle()
                    .fill(Carnet.ink)
                    .frame(width: 22, height: 22)
                    .overlay(Circle().stroke(Carnet.ground, lineWidth: 3))
                    .offset(y: -diameter / 2)
                    .rotationEffect(.degrees(knobAngle))
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
            }

            VStack(spacing: 6) {
                if isTyping {
                    // Un champ, au même endroit et à la même taille que le temps :
                    // on corrige ce qu'on lit, sans changer d'écran.
                    TextField("", text: $typed)
                        .font(.system(size: timeSize * 0.8, weight: .regular, design: .serif))
                        .monospacedDigit()
                        .multilineTextAlignment(.center)
                        .keyboardType(.numbersAndPunctuation)
                        .textFieldStyle(.plain)
                        .focused($typingFocused)
                        .frame(maxWidth: diameter - ringWidth * 2 - 24)
                        .foregroundStyle(Carnet.ink)
                        .onSubmit(commitTyping)
                        .onChange(of: typingFocused) { _, focused in
                            if !focused { commitTyping() }
                        }
                        .accessibilityLabel("Temps compté, format minutes:secondes")
                } else {
                    Text(time)
                        .font(.system(size: timeSize, weight: .regular, design: .serif))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .contentTransition(.numericText())
                        .foregroundStyle(isRunning ? Carnet.ink : Carnet.inkSecondary)
                        // En ajustement, taper le temps ouvre la saisie : c'est le
                        // geste qu'on essaie d'abord, avant de faire glisser.
                        .onTapGesture {
                            guard isAdjusting, onSet != nil else { return }
                            typed = TimerText.text(from: elapsed)
                            isTyping = true
                            typingFocused = true
                        }
                        .accessibilityHint(isAdjusting ? "Touche pour saisir le temps" : "")
                }

                if let context {
                    Text(context)
                        .font(.caption)
                        .foregroundStyle(Carnet.inkSecondary)
                        .lineLimit(1)
                }

                if let caption {
                    Text(caption)
                        .font(.footnote)
                        .foregroundStyle(Carnet.inkSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, ringWidth + 8)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(isAdjusting && onAdjust != nil ? dragGesture : nil)
        .animation(.easeOut(duration: 0.2), value: isAdjusting)
        // Un anneau est décoratif : ce qui compte est le temps, déjà lisible.
        .accessibilityElement(children: isAdjusting ? .contain : .combine)
        .accessibilityLabel([time, context, caption].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(isAdjusting ? "Fais glisser autour de l'anneau pour ajuster le temps" : "")
    }

    /// Valide la saisie. Un texte illisible laisse le temps tel quel : mieux vaut
    /// ne rien changer que de mettre zéro sur une faute de frappe.
    private func commitTyping() {
        defer { isTyping = false }
        guard let seconds = TimerText.seconds(from: typed) else { return }
        onSet??(seconds)
        Haptics.tap()
    }

    // MARK: Ajustement au doigt

    /// Glisser **autour** de l'anneau modifie le temps.
    ///
    /// La variation, et non la position : viser une position absolue obligerait à
    /// savoir où l'on se trouve sur le tour, et un temps de plus d'une heure
    /// reviendrait au même point. Ici, un tour complet vaut une heure, dans un sens
    /// comme dans l'autre, quel que soit le total.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let center = CGPoint(x: diameter / 2, y: diameter / 2)
                let vector = CGVector(dx: value.location.x - center.x,
                                      dy: value.location.y - center.y)
                // `atan2` donne l'angle depuis l'axe des x ; on le ramène à un
                // repère où midi vaut 0, comme l'anneau.
                var degrees = atan2(vector.dy, vector.dx) * 180 / .pi + 90
                if degrees < 0 { degrees += 360 }

                defer { lastDragAngle = degrees }
                guard let previous = lastDragAngle else { return }

                // Écart le plus court : passer de 359° à 1° vaut +2°, pas −358°.
                var delta = degrees - previous
                if delta > 180 { delta -= 360 }
                if delta < -180 { delta += 360 }

                let minutes = delta / 360 * Self.minutesPerTurn
                let seconds = minutes * 60
                guard abs(seconds) >= 1 else { return }

                onAdjust?(seconds)

                // Un retour toutes les minutes : on sent la valeur défiler sans
                // quitter l'anneau des yeux.
                let tick = Int((max(0, elapsed + seconds) / 60).rounded(.down))
                if tick != lastTick {
                    lastTick = tick
                    Haptics.soft()
                }
            }
            .onEnded { _ in
                lastDragAngle = nil
            }
    }
}

/// Le bouton principal du chrono : un disque, une icône, un mot.
///
/// Il y a une action qu'on fait dix fois par session (démarrer, mettre en pause,
/// reprendre après une pause) et une qu'on fait une fois (terminer). La première
/// est ce disque ; la seconde, un bouton discret à côté.
struct TimerPrimaryButton: View {
    var title: String
    var icon: String
    var tint: Color = Theme.accent
    var action: () -> Void

    @ScaledMetric(relativeTo: .title) private var diameter: CGFloat = 84

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(spacing: Layout.inline) {
                ZStack {
                    Circle().fill(Carnet.ink)
                    Image(systemName: icon)
                        .font(.system(size: diameter * 0.32, weight: .bold))
                        .foregroundStyle(Carnet.ground)
                        .contentTransition(.symbolEffect(.replace))
                        // Le triangle a sa masse à gauche : centré au pixel, il
                        // paraît décalé. On le pousse vers son centre optique.
                        .offset(x: icon.hasPrefix("play") ? diameter * 0.03 : 0)
                }
                .frame(width: diameter, height: diameter)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Carnet.ink)
                    .contentTransition(.opacity)
            }
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(title)
    }
}

/// Les boutons qui entourent le disque : plus petits, neutres, un seul mot.
///
/// La disposition est celle du chronomètre d'iOS — l'action rare à gauche,
/// l'action fréquente au centre, la conclusion à droite — pour que le pouce les
/// trouve sans lire.
struct TimerSideButton: View {
    var title: String
    var icon: String
    var role: ButtonRole? = nil
    var isEnabled: Bool = true
    var action: () -> Void

    @ScaledMetric(relativeTo: .title) private var diameter: CGFloat = 56

    var body: some View {
        Button(role: role) {
            action()
        } label: {
            VStack(spacing: Layout.inline) {
                Image(systemName: icon)
                    .font(.system(size: diameter * 0.36, weight: .semibold))
                    .foregroundStyle(role == .destructive ? Carnet.wrong : Carnet.ink)
                    .frame(width: diameter, height: diameter)
                    .background(Carnet.sheetRaised, in: Circle())
                    .contentTransition(.symbolEffect(.replace))
                Text(ui: title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Carnet.inkSecondary)
            }
            .frame(minWidth: 72)
        }
        .buttonStyle(PressableStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel(title)
    }
}
