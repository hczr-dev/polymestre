import PDFKit
import SwiftUI

/// Une annale, travaillée question par question : à gauche la question
/// (découpée dans le sujet), à droite son corrigé — caché tant qu'on ne l'a
/// pas demandé, et seulement la partie de cette question. À la fin, « J'ai
/// fini » note la date et la sûreté, comme partout.
struct PastExamWorkView: View {
    @Bindable var exam: PastExam
    var desk: SiteHub
    var ask: (String) -> Void

    @State private var subject: URL?
    @State private var solution: URL?
    @State private var questions: [String] = []
    /// `nil` : le sujet entier.
    @State private var question: Int?
    @State private var revealed: Set<String> = []
    @State private var loaded = false
    @State private var subjectCrop: URL?
    @State private var solutionCrop: URL?

    private var tint: Color { Carnet.tint(exam.course?.colorHex ?? "") }
    private var label: String? { question.flatMap { questions.indices.contains($0) ? questions[$0] : nil } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Carnet.rule).frame(height: 1)
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if subject == nil {
                ContentUnavailableView("Sujet introuvable", systemImage: "doc.questionmark",
                                       description: Text("Connecte-toi à Moodle, ou vérifie le lien de l'annale."))
            } else {
                HStack(spacing: 0) {
                    pdf(subjectCrop ?? subject)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Rectangle().fill(Carnet.rule).frame(width: 1)
                    solutionSide
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Carnet.ground)
        .task(id: exam.id) { await load() }
        .task(id: "\(question ?? -1)|\(loaded)") { crop() }
    }

    // MARK: En haut

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(exam.title).font(Carnet.serif(.title2)).foregroundStyle(Carnet.ink).lineLimit(1)
                Spacer()
                Menu {
                    ForEach(ConfidenceLevel.allCases) { level in
                        Button { exam.workedAt = exam.workedAt ?? Date(); exam.confidence = level } label: {
                            Label(level.label, systemImage: level.icon)
                        }
                    }
                } label: {
                    Label(exam.isWorked ? (exam.confidence?.label ?? String(localized: "Fait")) : String(localized: "J'ai fini l'annale"),
                          systemImage: exam.isWorked ? (exam.confidence?.icon ?? "checkmark.circle.fill") : "checkmark.circle")
                }
                .fixedSize()
                Button { ask("Je travaille l'annale « \(exam.title) »\(label.map { ", \($0)" } ?? ""). Aide-moi sans me donner la solution.") } label: {
                    Label("Claude", systemImage: "sparkle")
                }
                .buttonStyle(.paper)
            }
            if !questions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        chip(String(localized: "Sujet entier"), selected: question == nil) { question = nil }
                        ForEach(Array(questions.enumerated()), id: \.offset) { index, name in
                            chip(short(name), selected: question == index, done: revealed.contains(name)) { question = index }
                        }
                    }
                }
            }
        }
        .padding(14)
    }

    private func short(_ name: String) -> String {
        name.split(separator: " ").last.map { "Q\($0)" } ?? name
    }

    private func chip(_ title: String, selected: Bool, done: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).font(.callout.weight(selected ? .semibold : .regular))
                if done { Image(systemName: "eye").font(.caption2) }
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .foregroundStyle(selected ? Carnet.ground : Carnet.ink)
            .background(selected ? tint : Carnet.sheetRaised.opacity(0.7), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Le corrigé

    @ViewBuilder
    private var solutionSide: some View {
        let key = label ?? "all"
        if exam.solutionURLString.isEmpty {
            ContentUnavailableView("Pas de corrigé", systemImage: "checkmark.seal",
                                   description: Text("Ajoute son lien depuis la page du cours."))
        } else if !revealed.contains(key) {
            VStack(spacing: 14) {
                Image(systemName: "eye.slash").font(.largeTitle).foregroundStyle(Carnet.inkTertiary)
                Text(label.map { String(localized: "Le corrigé de \($0)") } ?? String(localized: "Le corrigé"))
                    .font(Carnet.serif(.title2)).foregroundStyle(Carnet.ink)
                Text("Cherche d'abord, en temps limité comme à l'examen.")
                    .foregroundStyle(Carnet.inkSecondary)
                Button { revealed.insert(key) } label: { Label("Voir le corrigé", systemImage: "checkmark.seal") }
                    .buttonStyle(.ink)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if solution == nil {
            ContentUnavailableView("Corrigé introuvable", systemImage: "doc.questionmark")
        } else {
            pdf(solutionCrop ?? solution, search: solutionCrop == nil ? label.map { [$0] } ?? [] : [])
        }
    }

    @ViewBuilder
    private func pdf(_ file: URL?, search: [String] = []) -> some View {
        if let file { PDFPane(url: file, search: search) }
    }

    // MARK: Lire

    private func load() async {
        loaded = false
        subject = exam.urlString.isEmpty ? nil : await desk.pdfFile(exam.urlString)
        solution = exam.solutionURLString.isEmpty ? nil : await desk.pdfFile(exam.solutionURLString)
        if let subject, let document = PDFDocument(url: subject) {
            questions = PDFExerciseCrop.questions(in: document)
        }
        loaded = true
    }

    /// La question choisie, découpée dans le sujet et dans le corrigé.
    private func crop() {
        guard loaded, let index = question, questions.indices.contains(index) else {
            subjectCrop = nil
            solutionCrop = nil
            return
        }
        let terms = [questions[index]]
        let next = questions.indices.contains(index + 1) ? [questions[index + 1]] : []
        subjectCrop = subject.flatMap { PDFExerciseCrop.file(source: $0, terms: terms, nextTerms: next) }
        solutionCrop = solution.flatMap { PDFExerciseCrop.file(source: $0, terms: terms, nextTerms: next) }
    }
}
