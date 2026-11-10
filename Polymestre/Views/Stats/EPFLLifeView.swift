import SwiftUI
import SwiftData

/// La vie de l'EPFL : quand l'école vit, en dehors des cours.
///
/// L'app connaissait mes cours et mes séries ; elle ignorait la fin des
/// enseignements, le début des examens, les vacances et les délais
/// d'inscription — c'est-à-dire tout ce qui ne se rattrape pas. Les dates
/// viennent du **calendrier académique public de l'EPFL**, embarqué hors ligne et
/// relisible d'un bouton.
struct EPFLLifeView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \AcademicMilestone.date) private var milestones: [AcademicMilestone]
    @Query private var terms: [AcademicTerm]

    @State private var isRefreshing = false
    @State private var message: String?
    @State private var showingAdd = false
    @State private var showingEverything = false

    private var runningTerm: AcademicTerm? { AcademicTerm.resolve(from: terms) }

    private var upcoming: [AcademicMilestone] {
        AcademicCalendarService.upcoming(milestones)
    }

    private var nextStructural: AcademicMilestone? {
        AcademicCalendarService.nextStructural(milestones)
    }

    private var deadlines: [AcademicMilestone] {
        upcoming.filter { $0.kind == .deadline }
    }

    private var restful: [AcademicMilestone] {
        upcoming.filter { $0.kind == .holiday || $0.kind == .break }
    }

    private var mine: [AcademicMilestone] {
        milestones.filter { !$0.isOfficial }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                positionCard
                if !deadlines.isEmpty { deadlinesCard }
                if !restful.isEmpty { restfulCard }
                timelineCard
                sourceCard
            }
            .padding()
            .adaptiveColumn()
        }
        .background(Carnet.ground.ignoresSafeArea())
        .carnetBackground()
        .navigationTitle("Vie de l'EPFL")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Ajouter une échéance personnelle")
            }
        }
        .sheet(isPresented: $showingAdd) {
            MilestoneFormView()
        }
    }

    // MARK: Où j'en suis

    private var positionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Layout.block) {
                if let term = runningTerm {
                    Text(term.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: Layout.control) {
                        Text("Semaine \(term.currentWeek)")
                            .font(.system(.title, design: .rounded).weight(.bold))
                            .monospacedDigit()
                        Text("/ \(term.totalWeeks)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    LabeledProgress(title: String(localized: "Avancement du semestre"),
                                    progress: term.timeProgress,
                                    color: Theme.accent)
                } else {
                    Text("Aucun semestre enregistré")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let next = nextStructural {
                    Divider()
                    HStack(alignment: .top, spacing: Layout.control) {
                        Image(systemName: next.kind.icon)
                            .foregroundStyle(Theme.accent.accessibleMark)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(next.title)
                                .font(.subheadline.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                            Text("\(DateUtils.fullDay.string(from: next.date)) · \(next.value.countdown())")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: Layout.inline)
                        Pill(text: next.kind.label, color: Theme.accent)
                    }
                }
            }
        }
    }

    // MARK: Délais

    private var deadlinesCard: some View {
        Card(title: String(localized: "Délais à ne pas manquer"), icon: "exclamationmark.circle.fill",
             trailing: "\(deadlines.count)") {
            VStack(spacing: 0) {
                ForEach(deadlines) { milestone in
                    row(milestone, showsCountdown: true)
                    if milestone.id != deadlines.last?.id {
                        Divider().padding(.vertical, Layout.snug)
                    }
                }
            }
        }
    }

    private var restfulCard: some View {
        Card(title: String(localized: "Vacances et jours fériés"), icon: "sun.max.fill",
             trailing: "\(restful.count)") {
            VStack(spacing: 0) {
                ForEach(restful) { milestone in
                    row(milestone, showsCountdown: true)
                    if milestone.id != restful.last?.id {
                        Divider().padding(.vertical, Layout.snug)
                    }
                }
            }
        }
    }

    // MARK: Déroulé

    private var timelineCard: some View {
        Card(title: String(localized: "Le semestre"), icon: "calendar") {
            VStack(alignment: .leading, spacing: Layout.block) {
                let shown = showingEverything ? upcoming : Array(upcoming.prefix(6))
                if shown.isEmpty {
                    Text("Aucune échéance à venir.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    ForEach(shown) { milestone in
                        row(milestone, showsCountdown: true)
                        if milestone.id != shown.last?.id {
                            Divider().padding(.vertical, Layout.snug)
                        }
                    }
                }

                if upcoming.count > 6 {
                    Button {
                        withAnimation(Motion.snappy) { showingEverything.toggle() }
                    } label: {
                        Label(showingEverything
                              ? "Réduire"
                              : "Voir les \(upcoming.count - 6) échéances suivantes",
                              systemImage: showingEverything ? "chevron.up" : "chevron.down")
                            .font(.caption)
                    }
                }

                if !mine.isEmpty {
                    Divider()
                    Text("Mes échéances")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        ForEach(mine) { milestone in
                            row(milestone, showsCountdown: true)
                            if milestone.id != mine.last?.id {
                                Divider().padding(.vertical, Layout.snug)
                            }
                        }
                    }
                }
            }
        }
    }

    private func row(_ milestone: AcademicMilestone, showsCountdown: Bool) -> some View {
        HStack(alignment: .top, spacing: Layout.control) {
            Image(systemName: milestone.kind.icon)
                .font(.footnote)
                .foregroundStyle(milestone.kind.isStructural
                                 ? Theme.accent.accessibleMark : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Layout.snug) {
                    Text(milestone.title)
                        .font(.subheadline.weight(milestone.isImportant ? .semibold : .regular))
                        .fixedSize(horizontal: false, vertical: true)
                    if milestone.isImportant {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.orange.accessibleInk)
                            .accessibilityLabel("Date clé")
                    }
                    if milestone.isApproximate {
                        Pill(text: String(localized: "approximatif"), color: .secondary)
                    }
                }
                Text(subtitle(milestone, showsCountdown: showsCountdown))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Layout.inline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(milestone.title), \(subtitle(milestone, showsCountdown: showsCountdown))")
    }

    private func subtitle(_ milestone: AcademicMilestone, showsCountdown: Bool) -> String {
        var parts: [String] = []
        if milestone.isApproximate {
            parts.append(String(localized: "vers le \(DateUtils.shortDay.string(from: milestone.date))"))
        } else {
            parts.append(DateUtils.fullDay.string(from: milestone.date))
        }
        if showsCountdown, !milestone.isPast { parts.append(milestone.value.countdown()) }
        if !milestone.termLabel.isEmpty { parts.append(milestone.termLabel) }
        return parts.joined(separator: " · ")
    }

    // MARK: Source

    private var sourceCard: some View {
        Card(title: "Source", icon: "link") {
            VStack(alignment: .leading, spacing: Layout.block) {
                Text("Dates relevées sur le calendrier académique public de l'EPFL, embarquées le \(EPFLCalendarSnapshot.capturedOn) pour fonctionner hors ligne.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(AcademicCalendarParser.sourceURL)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                Button {
                    Task { await refresh() }
                } label: {
                    if isRefreshing {
                        HStack(spacing: Layout.snug) {
                            ProgressView()
                            Text("Lecture de la page…")
                        }
                        .font(.subheadline)
                    } else {
                        Label("Actualiser depuis l'EPFL", systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isRefreshing)

                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func refresh() async {
        isRefreshing = true
        message = nil
        do {
            let result = try await AcademicCalendarService.refresh(context)
            try? context.save()
            message = result.message
            Haptics.success()
        } catch {
            message = String(localized: "Actualisation impossible — \(error.localizedDescription) L'instantané embarqué reste utilisé.")
            Haptics.error()
        }
        isRefreshing = false
    }
}

/// Ajout d'une échéance personnelle : un oral, une remise de projet, une date de
/// section que l'EPFL ne publie pas au niveau central.
struct MilestoneFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var title = ""
    @State private var date = DateUtils.addDays(7, to: Date())
    @State private var kind: MilestoneKind = .deadline
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Échéance") {
                    TextField("Intitulé (ex : remise du projet)", text: $title)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    Picker("Nature", selection: $kind) {
                        ForEach(MilestoneKind.allCases) { value in
                            Label(value.label, systemImage: value.icon).tag(value)
                        }
                    }
                }
                Section("Notes") {
                    TextField("Détail, salle, consigne…", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .carnetBackground()
            .navigationTitle("Nouvelle échéance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ajouter") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let resolved = title.trimmingCharacters(in: .whitespaces)
        let milestone = AcademicMilestone(
            externalID: "perso.\(UUID().uuidString)",
            title: resolved,
            date: date,
            kind: kind,
            isOfficial: false,
            notes: notes)
        context.insert(milestone)
        try? context.save()
        Haptics.success()
        dismiss()
    }
}
