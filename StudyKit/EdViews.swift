import SwiftUI

// MARK: - Fil

/// Un fil d'Ed, en natif : la question, les réponses (validées en tête), les
/// commentaires en retrait — et l'on y répond d'ici (réponse ou commentaire,
/// au fil ou à un message), formules comprises.
struct EdThreadReader: View {
    let id: Int
    let title: String
    var desk: SiteHub
    var open: (String, String) -> Void
    var openWeb: (URL, String) -> Void

    @State private var post: EdDiscussion.Post?
    @State private var needsLogin = false
    @State private var failed = false
    @State private var draft = ""
    @State private var asAnswer = true
    @State private var replyTo: EdDiscussion.Post?
    @State private var sending = false
    @State private var sendError: String?
    @State private var reload = 0

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Kicker("Ed")
                    Text(title).font(Carnet.serif(28)).foregroundStyle(Carnet.ink)
                    if let post {
                        message(post, depth: 0)
                    } else if needsLogin {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Connecte-toi à Ed.").foregroundStyle(Carnet.inkSecondary)
                            Button("Se connecter") { desk.signIn = .ed }.buttonStyle(.ink)
                        }
                    } else if failed {
                        Text("Fil introuvable.").foregroundStyle(Carnet.inkSecondary)
                    } else {
                        ProgressView()
                    }
                }
                .padding(32)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            if post != nil {
                Rectangle().fill(Carnet.rule).frame(height: 1)
                composer
            }
        }
        .task(id: "\(id)|\(desk.signInRevision)|\(reload)") { await load() }
    }

    private func load() async {
        needsLogin = false
        await SchoolConnect.shared.ensure(.ed)
        do { post = try await desk.ed.thread(id); failed = post == nil }
        catch HiddenSiteSession.SiteError.notSignedIn { needsLogin = true }
        catch { failed = true }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let replyTo {
                    Label("À \(replyTo.author)", systemImage: "arrowshape.turn.up.left").font(.caption).foregroundStyle(Carnet.inkSecondary)
                    Button { self.replyTo = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Carnet.inkTertiary)
                } else {
                    Picker("Type", selection: $asAnswer) {
                        Text("Réponse").tag(true)
                        Text("Commentaire").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Spacer()
                if let sendError { Text(sendError).font(.caption).foregroundStyle(Carnet.wrong) }
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ta réponse ($x^2$ pour une formule)", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...8)
                    .padding(10)
                    .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Carnet.rule))
                Button { Task { await send() } } label: {
                    if sending { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.up.circle.fill").font(.title) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(draft.isEmpty ? Carnet.inkTertiary : Carnet.ink)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(14)
    }

    private func send() async {
        sending = true
        sendError = nil
        defer { sending = false }
        do {
            if let replyTo {
                try await desk.ed.reply(toComment: replyTo.id, markdown: draft, isAnswer: false)
            } else {
                try await desk.ed.reply(toThread: id, markdown: draft, isAnswer: asAnswer)
            }
            draft = ""
            replyTo = nil
            reload += 1
        } catch {
            sendError = error.localizedDescription
        }
    }

    private func message(_ post: EdDiscussion.Post, depth: Int) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(post.author).font(.callout.weight(.medium)).foregroundStyle(Carnet.ink)
                if post.isEndorsed { Label("Validée", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(Carnet.correct) }
                else if post.isAnswer { Text("Réponse").font(.caption).foregroundStyle(Carnet.inkSecondary) }
                Spacer()
                Text(EdThreadReader.day(post.date)).font(.caption).foregroundStyle(Carnet.inkTertiary)
                if depth > 0 {
                    Button("Répondre") { replyTo = post }.buttonStyle(.plain).font(.caption).foregroundStyle(Carnet.inkSecondary)
                }
            }
            SiteBlocksView(blocks: EdDiscussion.blocks(post.content), desk: desk, open: open, openWeb: openWeb)
            ForEach(EdDiscussion.pollIDs(in: post.content), id: \.self) { id in
                EdPollCard(id: id, desk: desk, open: open, openWeb: openWeb)
            }
            ForEach(Array(post.replies.enumerated()), id: \.offset) { _, reply in
                message(reply, depth: depth + 1)
            }
        }
        .padding(depth == 0 ? 0 : 14)
        .background(depth == 0 ? Color.clear : Carnet.sheetRaised.opacity(depth == 1 ? 0.7 : 0.4),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)))
    }

    /// « 2026-10-10T10:00:00.123+02:00 » → « 10 oct. ».
    static func day(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        return date.map { $0.formatted(.dateTime.day().month(.abbreviated).locale(DateUtils.appLocale)) } ?? ""
    }
}

// MARK: - Nouvelle question

/// Poser une question (ou poster) sur Ed : titre, catégorie, texte avec
/// formules, aperçu, privé / anonyme.
struct EdComposeSheet: View {
    let courseID: Int
    var desk: SiteHub
    var posted: (Int?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var text = ""
    @State private var category = ""
    @State private var categories: [String] = []
    @State private var isQuestion = true
    @State private var isPrivate = false
    @State private var isAnonymous = false
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Nouvelle question").font(Carnet.serif(.title3)).foregroundStyle(Carnet.ink)
                Spacer()
                Picker("Type", selection: $isQuestion) {
                    Text("Question").tag(true)
                    Text("Message").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            TextField("Titre", text: $title).textFieldStyle(.roundedBorder)
            if !categories.isEmpty {
                Picker("Catégorie", selection: $category) {
                    ForEach(categories, id: \.self) { Text($0).tag($0) }
                }
            }
            HStack(alignment: .top, spacing: 12) {
                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: 180)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Carnet.rule))
                ScrollView {
                    RichTextView(text: text.isEmpty ? String(localized: "*Aperçu*") : text, size: 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 180)
                .padding(8)
                .background(Carnet.sheetRaised.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Toggle("Privée", isOn: $isPrivate)
                Toggle("Anonyme", isOn: $isAnonymous)
                Spacer()
                if let error { Text(error).font(.caption).foregroundStyle(Carnet.wrong) }
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(sending ? "Envoi…" : "Publier") { Task { await send() } }
                    .buttonStyle(.ink)
                    .disabled(title.isEmpty || text.isEmpty || sending)
            }
        }
        .padding(20)
        .frame(width: 760)
        .task {
            categories = (try? await desk.ed.categories(course: courseID)) ?? []
            category = categories.first ?? "General"
        }
    }

    private func send() async {
        sending = true
        defer { sending = false }
        do {
            let id = try await desk.ed.postThread(course: courseID, title: title, category: category, markdown: text,
                                                  isQuestion: isQuestion, isPrivate: isPrivate, isAnonymous: isAnonymous)
            posted(id)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Leçons et quiz

/// Une leçon d'Ed : ses diapositives (texte, quiz). On répond aux questions
/// ici ; Ed dit si c'est juste, avec son explication.
struct EdLessonReader: View {
    let lesson: EdDiscussion.Lesson
    var desk: SiteHub
    var open: (String, String) -> Void
    var openWeb: (URL, String) -> Void

    @State private var slides: [EdDiscussion.Slide] = []
    @State private var current = 0
    @State private var questions: [Int: [EdDiscussion.Question]] = [:]

    var body: some View {
        VStack(spacing: 0) {
            if slides.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(slides.enumerated()), id: \.offset) { index, slide in
                            Button { current = index } label: {
                                Label(slide.title.isEmpty ? "\(index + 1)" : slide.title,
                                      systemImage: slide.type == "quiz" ? "checklist" : (slide.isCompleted ? "checkmark.circle" : "doc.text"))
                                    .font(.caption)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(current == index ? Carnet.ink.opacity(0.15) : Carnet.sheetRaised, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                }
                Rectangle().fill(Carnet.rule).frame(height: 1)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(lesson.title).font(Carnet.serif(28)).foregroundStyle(Carnet.ink)
                    if slides.indices.contains(current) {
                        let slide = slides[current]
                        if !slide.content.isEmpty {
                            SiteBlocksView(blocks: EdDiscussion.blocks(slide.content), desk: desk, open: open, openWeb: openWeb)
                            ForEach(EdDiscussion.pollIDs(in: slide.content), id: \.self) { id in
                                EdPollCard(id: id, desk: desk, open: open, openWeb: openWeb)
                            }
                        }
                        ForEach(questions[slide.id] ?? []) { question in
                            EdQuestionCard(question: question, desk: desk, open: open, openWeb: openWeb)
                        }
                        HStack {
                            if current > 0 { Button("Précédente") { current -= 1 }.buttonStyle(.paper) }
                            Spacer()
                            if current + 1 < slides.count {
                                Button("Suivante") { Task { await desk.ed.complete(slide: slide.id) }; current += 1 }.buttonStyle(.ink)
                            }
                        }
                    } else {
                        ProgressView()
                    }
                }
                .padding(32)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .task(id: lesson.id) { slides = (try? await desk.ed.slides(lesson: lesson.id)) ?? [] }
        .task(id: "\(current)|\(slides.count)") {
            guard slides.indices.contains(current), slides[current].type == "quiz", questions[slides[current].id] == nil else { return }
            questions[slides[current].id] = (try? await desk.ed.questions(slide: slides[current].id)) ?? []
        }
    }
}

private struct EdQuestionCard: View {
    let question: EdDiscussion.Question
    var desk: SiteHub
    var open: (String, String) -> Void
    var openWeb: (URL, String) -> Void

    @State private var choices: Set<Int> = []
    @State private var text = ""
    @State private var result: (correct: Bool?, explanation: String?)?
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SiteBlocksView(blocks: EdDiscussion.blocks(question.content), desk: desk, open: open, openWeb: openWeb)
            switch question.kind {
            case .choice(let multiple):
                ForEach(Array(question.answers.enumerated()), id: \.offset) { index, answer in
                    Button {
                        if multiple { if choices.contains(index) { choices.remove(index) } else { choices.insert(index) } }
                        else { choices = [index] }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: choices.contains(index) ? (multiple ? "checkmark.square.fill" : "largecircle.fill.circle")
                                                                    : (multiple ? "square" : "circle"))
                                .foregroundStyle(Carnet.ink)
                            SiteBlocksView(blocks: EdDiscussion.blocks(answer), desk: desk, open: open, openWeb: openWeb)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            case .text, .number:
                TextField("Ta réponse", text: $text).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
            case .other(let type):
                Text("Question « \(type) » : pas encore lisible ici.").font(.caption).foregroundStyle(Carnet.inkSecondary)
            }
            HStack {
                Button(sending ? "Envoi…" : "Valider") { Task { await submit() } }
                    .buttonStyle(.ink)
                    .disabled(sending || (choices.isEmpty && text.isEmpty))
                if let result {
                    if let correct = result.correct {
                        Label(correct ? "Juste" : "Faux", systemImage: correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(correct ? Carnet.correct : Carnet.wrong)
                    } else {
                        Label("Envoyé", systemImage: "paperplane").foregroundStyle(Carnet.inkSecondary)
                    }
                }
            }
            if let explanation = result?.explanation, !explanation.isEmpty {
                SiteBlocksView(blocks: EdDiscussion.blocks(explanation), desk: desk, open: open, openWeb: openWeb)
                    .padding(12)
                    .background(Carnet.sheetRaised.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .paperSheet(padding: 16)
    }

    private func submit() async {
        sending = true
        defer { sending = false }
        let response = EdDiscussion.response(choices: choices, text: text, for: question.kind)
        result = (try? await desk.ed.answer(question: question.id, response: response)) ?? (nil, String(localized: "L'envoi a échoué."))
    }
}

/// Un sondage d'Ed, comme sur le site : la question, les options à cocher,
/// « Voter », puis la part de la classe sur chaque option et ce qu'on a coché.
struct EdPollCard: View {
    let id: Int
    var desk: SiteHub
    var open: (String, String) -> Void
    var openWeb: (URL, String) -> Void

    @State private var poll: EdDiscussion.Poll?
    @State private var choices: Set<Int> = []
    @State private var sending = false
    @State private var failed = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let poll {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "chart.bar.fill").foregroundStyle(Carnet.inkSecondary)
                    SiteBlocksView(blocks: EdDiscussion.blocks(poll.question), desk: desk, open: open, openWeb: openWeb)
                }
                if poll.multipleChoice, poll.chosen == nil, !poll.isClosed {
                    Text("Plusieurs réponses possibles").font(.caption).foregroundStyle(Carnet.inkTertiary)
                }
                ForEach(Array(poll.options.enumerated()), id: \.offset) { index, option in
                    optionRow(poll, index: index, option: option)
                }
                HStack(spacing: 12) {
                    if poll.chosen == nil, !poll.isClosed {
                        Button(sending ? "Envoi…" : "Voter") { Task { await vote(poll) } }
                            .buttonStyle(.ink)
                            .disabled(sending || choices.isEmpty)
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(Carnet.wrong) }
                    Spacer()
                    Text(poll.isClosed ? "Fermé · \(votes(poll.voters))" : votes(poll.voters))
                        .font(.caption).foregroundStyle(Carnet.inkTertiary)
                }
            } else if failed {
                Text("Sondage illisible.").font(.caption).foregroundStyle(Carnet.inkSecondary)
            } else {
                ProgressView()
            }
        }
        .paperSheet(padding: 16)
        .task(id: id) { await load() }
    }

    private func votes(_ count: Int) -> String { Plural.count(count, "\(count) vote", "\(count) votes") }

    @ViewBuilder
    private func optionRow(_ poll: EdDiscussion.Poll, index: Int, option: String) -> some View {
        let answered = poll.chosen != nil || poll.isClosed
        let picked = poll.chosen?.contains(index) ?? choices.contains(index)
        Button {
            guard !answered else { return }
            if poll.multipleChoice {
                if choices.contains(index) { choices.remove(index) } else { choices.insert(index) }
            } else {
                choices = [index]
            }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: picked ? (poll.multipleChoice ? "checkmark.square.fill" : "largecircle.fill.circle")
                                         : (poll.multipleChoice ? "square" : "circle"))
                    .foregroundStyle(picked ? Carnet.ink : Carnet.inkTertiary)
                SiteBlocksView(blocks: EdDiscussion.blocks(option), desk: desk, open: open, openWeb: openWeb)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(alignment: .leading) {
                        if poll.showsResults {
                            GeometryReader { proxy in
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Carnet.ink.opacity(picked ? 0.16 : 0.08))
                                    .frame(width: proxy.size.width * poll.share(index))
                            }
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(picked ? Carnet.ink.opacity(0.5) : Carnet.rule, lineWidth: picked ? 1.5 : 1)
                    }
                if poll.showsResults {
                    Text("\(Int((poll.share(index) * 100).rounded())) %")
                        .font(.caption.monospacedDigit()).foregroundStyle(Carnet.inkSecondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        poll = try? await desk.ed.poll(id)
        failed = poll == nil
    }

    private func vote(_ poll: EdDiscussion.Poll) async {
        sending = true
        defer { sending = false }
        do {
            try await desk.ed.vote(poll: poll.id, options: Array(choices))
            error = nil
            await load()
        } catch {
            self.error = String(localized: "Le vote n'est pas passé.")
        }
    }
}
