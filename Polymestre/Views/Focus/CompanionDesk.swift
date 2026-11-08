import SwiftData
import SwiftUI
import UIKit
import VisionKit

/// L'iPhone **à côté** du Mac, pendant une session menée sur le Mac : pas un
/// second bureau, un compagnon.
///
/// - l'heure qui reste et l'exercice, d'un coup d'œil (posé contre l'écran) ;
/// - **ta copie**, numérisée et envoyée au bureau du Mac (jointe à la
///   conversation de Claude) ; **« Je bloque »**, la photo part à Claude qui
///   donne l'indice minimal ; une **question** tapée ou dictée ;
/// - les questions de l'exercice à cocher, sans quitter le papier ;
/// - la musique, un seul lecteur pour les deux appareils ;
/// - le verrou et la pause.
struct CompanionDesk: View {
    @Environment(AppContainer.self) private var app
    @Query(sort: \Course.code) private var courses: [Course]
    var showFullDesk: () -> Void

    @State private var scanning: DeskDrop.Intent?
    @State private var asking = false
    @State private var question = ""
    @State private var sent: String?
    @State private var failed: String?
    @State private var music = StudyMusic.shared

    private var focus: FocusController { app.focus }
    private var course: Course? { courses.first { $0.id == focus.state?.courseID } }
    private var exercise: Exercise? { course?.allExercises.first { $0.id == focus.state?.targetID } }
    private var tint: Color { course.map { Carnet.tint($0.colorHex) } ?? Carnet.ink }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                clock
                drops
                if let exercise { exerciseCard(exercise) }
                if music.nowPlaying.hasTrack || music.devices.count > 1 {
                    MusicNowPlayingCard(compact: true)
                }
                footer
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 30)
        }
        .sheet(item: $scanning) { intent in
            DocumentScanner { images in
                scanning = nil
                send(intent, images: images)
            } cancel: {
                scanning = nil
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $asking) { askSheet }
        .overlay(alignment: .top) {
            if let note = sent ?? failed {
                Label(note, systemImage: failed == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: sent ?? failed)
    }

    // MARK: En haut

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "laptopcomputer").foregroundStyle(tint)
            Text("La session est sur ton Mac").font(.subheadline.weight(.semibold)).foregroundStyle(Carnet.ink)
            Spacer()
            if focus.isLocked {
                Label("Verrouillé", systemImage: "lock.fill").font(.caption).foregroundStyle(Carnet.inkSecondary)
            }
            Button("Bureau complet", action: showFullDesk)
                .font(.caption)
                .foregroundStyle(Carnet.inkSecondary)
        }
    }

    private var clock: some View {
        TimelineView(.periodic(from: StudyMode.tickAnchor(focus.state), by: 1)) { context in
            let onBreak = focus.state?.breakEndsAt.map { $0 > context.date } ?? false
            VStack(spacing: 4) {
                Text(onBreak ? "Pause — lève-toi, bois un verre d'eau" : (course?.displayCode ?? String(localized: "Mode étude")))
                    .font(.caption.weight(.semibold)).textCase(onBreak ? nil : .uppercase).tracking(1)
                    .foregroundStyle(tint)
                Text(TimerText.clock(StudyMode.clock(focus.state, at: context.date)))
                    .font(.system(size: 76, weight: .regular, design: .serif))
                    .monospacedDigit()
                    .foregroundStyle(Carnet.ink)
                    .contentTransition(.numericText())
                Text(exercise?.displayNumber ?? (focus.state?.contextLabel ?? ""))
                    .font(Carnet.serif(.title3))
                    .foregroundStyle(Carnet.inkSecondary)
                HStack(spacing: 12) {
                    Button {
                        if focus.isRunning { focus.pause() } else { focus.resume() }
                    } label: {
                        Image(systemName: focus.isRunning ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 54, height: 54)
                            .background(Carnet.ink, in: Circle())
                            .foregroundStyle(Carnet.ground)
                    }
                    .accessibilityLabel(focus.isRunning ? "Pause" : "Reprendre")
                    if !StudyMode.isOpenEnded(focus.state) {
                        Button { focus.extendStudy(minutes: 5) } label: { Label("5 min", systemImage: "plus") }
                            .buttonStyle(.carnetSecondary)
                    }
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(Carnet.sheet.opacity(0.5), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    // MARK: Vers le Mac

    private var drops: some View {
        VStack(spacing: 10) {
            Button { scanning = .copy } label: {
                HStack(spacing: 14) {
                    Image(systemName: "doc.viewfinder").font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Envoyer ma copie au Mac").font(.headline)
                        Text("Numérisée, jointe à la conversation de Claude").font(.caption).opacity(0.8)
                    }
                    Spacer()
                }
                .padding(16)
                .foregroundStyle(Carnet.ground)
                .background(tint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            HStack(spacing: 10) {
                dropButton("Je bloque", icon: "hand.raised", detail: "photo → un indice") { scanning = .stuck }
                dropButton("Question", icon: "mic", detail: "tape ou dicte") { asking = true }
            }
        }
    }

    private func dropButton(_ title: String, icon: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon).font(.title3).foregroundStyle(tint)
                Text(ui: title).font(.headline).foregroundStyle(Carnet.ink)
                Text(ui: detail).font(.caption).foregroundStyle(Carnet.inkSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Carnet.sheetRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var askSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Elle part à Claude, sur ton Mac, avec l'exercice en cours.")
                    .font(.callout).foregroundStyle(Carnet.inkSecondary)
                TextField("Où tu bloques ? (le micro du clavier pour dicter)", text: $question, axis: .vertical)
                    .lineLimit(3...8)
                    .padding(12)
                    .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Spacer()
            }
            .padding(20)
            .navigationTitle("Question")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { asking = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Envoyer") {
                        asking = false
                        deliver(DeskDrop(from: CloudRelay.deviceID, intent: .ask, question: question, exerciseID: exercise?.id, sentAt: Date()),
                                note: String(localized: "Question envoyée au Mac"))
                        question = ""
                    }
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func send(_ intent: DeskDrop.Intent, images: [UIImage]) {
        guard let pdf = Self.pdf(from: images) else {
            failed = String(localized: "La numérisation est trop lourde : moins de pages")
            clearSoon()
            return
        }
        deliver(DeskDrop(from: CloudRelay.deviceID, intent: intent, document: pdf, isPDF: true, exerciseID: exercise?.id, sentAt: Date()),
                note: intent == .stuck ? String(localized: "Envoyé : Claude regarde où ça bloque") : String(localized: "Ta copie est sur le Mac"))
    }

    private func deliver(_ drop: DeskDrop, note: String) {
        if TimerLink.shared.sendDrop(drop) {
            sent = note
            failed = nil
        } else {
            failed = TimerLink.shared.isConnected ? String(localized: "Trop lourd pour partir") : String(localized: "Le Mac n'est pas joignable (réseau ?)")
        }
        clearSoon()
    }

    private func clearSoon() {
        Task {
            try? await Task.sleep(for: .seconds(3))
            sent = nil
            failed = nil
        }
    }

    /// Les pages en un PDF léger : 1400 px au plus, JPEG compressé, jusqu'à
    /// tenir sous la limite du relais.
    static func pdf(from images: [UIImage]) -> Data? {
        for quality in [0.55, 0.4, 0.28] {
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
            let data = renderer.pdfData { context in
                for image in images {
                    let scaled = image.downscaled(maxSide: 1400)
                    guard let jpeg = scaled.jpegData(compressionQuality: quality), let page = UIImage(data: jpeg) else { continue }
                    let size = page.size
                    let bounds = CGRect(x: 0, y: 0, width: 595, height: 595 * size.height / max(size.width, 1))
                    context.beginPage(withBounds: bounds, pageInfo: [:])
                    page.draw(in: bounds)
                }
            }
            if data.count <= DeskDrop.maxDocumentBytes { return data }
        }
        return nil
    }

    // MARK: L'exercice

    private func exerciseCard(_ exercise: Exercise) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if exercise.hasSubQuestions {
                SubQuestionChecklist(exercise: exercise, tint: tint, onDark: true)
            }
            ExerciseQuickMark(exercise: exercise)
            if exercise.isQueuedForRedo {
                RedoPanel(exercise: exercise, ladder: RedoLadder.Config(), tint: tint)
            }
        }
        .padding(16)
        .background(Carnet.sheet.opacity(0.5), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var footer: some View {
        Text("Les photos et questions passent chiffrées par le relais de Polymestre, avec une clé tirée de ton compte iCloud ; rien n'est gardé en route.")
            .font(.caption2)
            .foregroundStyle(Carnet.inkTertiary)
            .multilineTextAlignment(.center)
    }
}

extension DeskDrop.Intent: Identifiable {
    var id: String { rawValue }
}

private extension UIImage {
    func downscaled(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return self }
        let scale = maxSide / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }
}

/// La numérisation de documents de l'iPhone (cadrage, redressement, contraste).
struct DocumentScanner: UIViewControllerRepresentable {
    var done: ([UIImage]) -> Void
    var cancel: () -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done, cancel: cancel) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let done: ([UIImage]) -> Void
        let cancel: () -> Void
        init(done: @escaping ([UIImage]) -> Void, cancel: @escaping () -> Void) {
            self.done = done
            self.cancel = cancel
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            done((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { cancel() }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { cancel() }
    }
}
