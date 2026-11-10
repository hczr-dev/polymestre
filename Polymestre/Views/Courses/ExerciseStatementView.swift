import SwiftUI

/// L'énoncé d'un exercice, tel qu'il est imprimé : la bande du PDF de la série
/// qui lui correspond (formules et figures comprises), sinon le texte lu à
/// l'import, sinon un lien vers l'énoncé d'origine.
///
/// Sert au chrono (« exercice par exercice ») et à la fiche d'un exercice.
struct ExerciseStatementView: View {
    let exercise: Exercise
    /// Ouvre l'énoncé d'origine quand rien ne peut être montré ici.
    var onOpenLink: ((BrowsedLink) -> Void)? = nil

    private enum Phase: Equatable {
        case loading
        case images([UIImage])
        case unavailable
    }

    /// Y a-t-il quoi que ce soit à montrer ici pour cet exercice — un texte lu
    /// à l'import, un PDF d'où tirer la bande, ou au moins un lien vers
    /// l'énoncé d'origine ? Sinon, proposer « Afficher l'énoncé » ne mène qu'à
    /// « pas d'énoncé lisible ».
    static func hasSomething(for exercise: Exercise) -> Bool {
        if !exercise.statement.isEmpty { return true }
        if let series = exercise.series, SeriesPDFStore.shared.hasDocument(for: series) { return true }
        return !ExerciseLinks.links(for: exercise).isEmpty
    }

    @State private var phase: Phase = .loading
    /// L'énoncé ouvert en plein écran, d'un toucher.
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch phase {
            case .loading:
                if !exercise.statement.isEmpty {
                    statementText
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Lecture de l'énoncé…")
                            .font(.footnote)
                            .foregroundStyle(Carnet.inkSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 60)
                }
            case .images(let images):
                VStack(spacing: 0) {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                        Image(uiImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                    }
                }
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Carnet.rule, lineWidth: 1))
                .overlay(alignment: .bottomTrailing) { expandBadge }
                .contentShape(Rectangle())
                .onTapGesture { open() }
                .accessibilityElement()
                .accessibilityLabel(exercise.statement.isEmpty
                                    ? "Énoncé de l'\(exercise.displayNumber.lowercased()), tel qu'imprimé"
                                    : exercise.statement)
                .accessibilityHint("Touche deux fois pour l'agrandir")
                .accessibilityAddTraits(.isButton)
            case .unavailable:
                if !exercise.statement.isEmpty {
                    statementText
                } else {
                    Text("Pas d'énoncé lisible ici pour cet exercice.")
                        .font(.footnote)
                        .foregroundStyle(Carnet.inkSecondary)
                }
                if let link = ExerciseLinks.links(for: exercise).first, let onOpenLink {
                    Button { onOpenLink(link) } label: {
                        Label(link.title, systemImage: link.icon)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Carnet.ink)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task(id: exercise.id) { await load() }
        .fullScreenCover(isPresented: $expanded) {
            StatementReader(exercise: exercise)
        }
    }

    /// Le signe « agrandir », dans le coin : sans lui, rien ne disait qu'un
    /// énoncé imprimé en petit pouvait s'ouvrir en grand.
    private var expandBadge: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Carnet.inkSecondary)
            .frame(width: 28, height: 28)
            .background(.regularMaterial, in: Circle())
            .padding(6)
            .accessibilityHidden(true)
    }

    private func open() {
        Haptics.soft()
        expanded = true
    }

    /// Le texte lu à l'import. Pas de `textSelection` ici : un toucher ouvre le
    /// lecteur, où le texte, plus grand, se sélectionne.
    private var statementText: some View {
        MathText(exercise.statement, font: .system(.body, design: .serif))
            .foregroundStyle(Carnet.ink)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { open() }
            .accessibilityHint("Touche deux fois pour l'agrandir")
            .accessibilityAddTraits(.isButton)
    }

    private func load() async {
        phase = .loading
        guard let series = exercise.series, SeriesPDFStore.shared.hasDocument(for: series) else {
            phase = .unavailable
            return
        }
        do {
            let images = try await SeriesPDFStore.shared.statementImages(for: exercise, width: 420)
            phase = images.isEmpty ? .unavailable : .images(images)
        } catch {
            phase = .unavailable
        }
    }
}


// MARK: - Lecteur plein écran

/// L'énoncé en grand : la bande du PDF rendue à la largeur de l'écran,
/// zoomable au pincement (comme dans Photos), ou le texte en grand caractère.
///
/// Dans le chrono et la fiche, l'énoncé tient dans une carte : une figure ou un
/// indice de formule y devenait illisible, et rien ne permettait de l'agrandir.
struct StatementReader: View {
    let exercise: Exercise

    @Environment(\.dismiss) private var dismiss
    @State private var images: [UIImage] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Group {
                if !images.isEmpty {
                    ZoomableImages(images: images)
                        .background(Color.white.ignoresSafeArea())
                } else if loaded || !exercise.statement.isEmpty {
                    ScrollView {
                        MathText(exercise.statement.isEmpty ? String(localized: "Pas d'énoncé lisible ici pour cet exercice.") : exercise.statement,
                                 font: .system(.title3, design: .serif))
                            .foregroundStyle(Carnet.ink)
                            .lineSpacing(6)
                            .textSelection(.enabled)
                            .frame(maxWidth: Layout.readableWidth, alignment: .leading)
                            .padding(20)
                    }
                    .background(Carnet.ground.ignoresSafeArea())
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(exercise.displayNumber)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        defer { loaded = true }
        guard let series = exercise.series, SeriesPDFStore.shared.hasDocument(for: series) else { return }
        // Plus large que dans la carte : la netteté doit tenir au zoom ×3.
        let width = min(1100, max(UIScreen.main.bounds.width, UIScreen.main.bounds.height))
        images = (try? await SeriesPDFStore.shared.statementImages(for: exercise, width: width)) ?? []
    }
}

/// Des images empilées dans un `UIScrollView` zoomable : pincer, double-toucher
/// pour zoomer ou revenir, défiler. SwiftUI n'a pas encore d'équivalent fiable
/// (`MagnifyGesture` ne recentre ni ne borne le défilement).
private struct ZoomableImages: UIViewRepresentable {
    let images: [UIImage]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.bouncesZoom = true
        scroll.backgroundColor = .white
        scroll.delegate = context.coordinator

        let stack = UIStackView(arrangedSubviews: images.map { image in
            let view = UIImageView(image: image)
            view.contentMode = .scaleAspectFit
            view.translatesAutoresizingMaskIntoConstraints = false
            view.heightAnchor.constraint(equalTo: view.widthAnchor,
                                         multiplier: image.size.height / max(image.size.width, 1)).isActive = true
            return view
        })
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
        context.coordinator.content = stack

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {}

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var content: UIView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

        @objc func toggleZoom(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            if scroll.zoomScale > 1.01 {
                scroll.setZoomScale(1, animated: true)
            } else if let content {
                let point = gesture.location(in: content)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(origin: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), size: size),
                            animated: true)
            }
        }
    }
}
