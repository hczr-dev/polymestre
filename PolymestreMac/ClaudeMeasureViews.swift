import AppKit
import Charts
import SwiftUI

// Avec mesure, à l'écran du Mac : les réglages (onglet « Claude Code »), la carte
// du Bilan et la ligne de la barre des menus. Le calcul est dans `ClaudeMeasure`.

private typealias CM = ClaudeMeasure

// MARK: - Réglages

/// « Demain » au milieu d'une phrase : sans majuscule.
private func lowered(_ text: String) -> String { text.prefix(1).lowercased() + text.dropFirst() }

/// Les règles se modifient sur un brouillon et s'appliquent d'un bouton : un
/// pas de stepper ne crée pas une demande en attente à chaque clic.
struct ClaudeMeasureSettingsPane: View {
    @State private var service = ClaudeMeasureService.shared
    @State private var draft = CM.Rules.standard

    var body: some View {
        Form {
            Section {
                Toggle("Avec mesure", isOn: Binding(get: { service.wantsEnabled }, set: { service.setEnabled($0) }))
                status
                plugin
            } header: {
                Text("Claude Code")
            } footer: {
                Text("Compte ton temps de Claude Code. L'étude n'est jamais limitée ; les projets suivent tes règles (assouplir prend effet le lendemain).")
            }

            Section("Projets") {
                LimitStepper(title: String(localized: "En semaine"), value: $draft.budgetWeekday)
                LimitStepper(title: String(localized: "Le week-end"), value: $draft.budgetWeekend)
                Stepper("D'abord étudier, en semaine : \(minutes(draft.studyFirstWeekday))",
                        value: $draft.studyFirstWeekday, in: 0...480, step: 15)
                Stepper("D'abord étudier, le week-end : \(minutes(draft.studyFirstWeekend))",
                        value: $draft.studyFirstWeekend, in: 0...480, step: 15)
                Toggle("Une pause après une longue série", isOn: Binding(
                    get: { draft.streak != nil }, set: { draft.streak = $0 ? (draft.streak ?? 50) : nil }))
                if let streak = draft.streak {
                    Stepper("Série : \(streak) min", value: Binding(get: { streak }, set: { draft.streak = $0 }), in: 20...180, step: 5)
                    Stepper("Pause : \(draft.pause) min", value: $draft.pause, in: 5...60, step: 5)
                }
            }

            Section("Moments") {
                Toggle("Pas pendant les cours (horaire)", isOn: $draft.duringClasses)
                Toggle("Pas en mode étude", isOn: $draft.duringStudyMode)
                Toggle("Couvre-feu", isOn: Binding(
                    get: { draft.curfew != nil },
                    set: { draft.curfew = $0 ? (draft.curfew ?? CM.Curfew(start: "23:30", end: "07:00")) : nil }))
                if draft.curfew != nil {
                    DatePicker("De", selection: time(\.start), displayedComponents: .hourAndMinute)
                    DatePicker("À", selection: time(\.end), displayedComponents: .hourAndMinute)
                    Toggle("Aussi pour l'étude", isOn: $draft.curfewAll)
                }
            }

            Section {
                Stepper("\(draft.passes) par jour", value: $draft.passes, in: 0...5)
                Stepper("\(draft.passMinutes) min chacun", value: $draft.passMinutes, in: 5...60, step: 5)
                Stepper("Délai de réflexion : \(draft.passDelay) min", value: $draft.passDelay, in: 0...15)
            } header: {
                Text("Passes")
            } footer: {
                Text("Dans Claude Code : /mesure encore <raison>. La raison est gardée dans ton bilan ; pas de pass pendant un cours ni en mode étude.")
            }

            Section {
                FolderList(title: String(localized: "Étude (jamais limitée)"), folders: $draft.studyFolders)
                FolderList(title: String(localized: "Libres (pas dans le budget)"), folders: $draft.freeFolders)
            } header: {
                Text("Dossiers")
            } footer: {
                Text("Le reste est « projets » : Polymestre lui-même, tes autres dépôts…")
            }

            Section {
                HStack {
                    Text(changeSummary).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Rétablir") { draft = service.desired }.disabled(draft == service.desired)
                    Button("Appliquer") { service.setRules(draft) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(draft == service.desired)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            draft = service.desired
            service.refreshUsage(force: true)
        }
    }

    @ViewBuilder private var status: some View {
        let now = Date()
        if let policy = service.policy {
            if policy.enabled, CM.ms(now) < policy.enforceFrom {
                Label("Jour d'observation jusqu'à \(day(CM.date(policy.enforceFrom))) : Avec mesure compte et prévient, ne bloque rien.",
                      systemImage: "eye")
                    .foregroundStyle(.secondary)
            }
            if let pending = policy.pending, CM.ms(now) < pending.from {
                Label(pending.enabled
                      ? "Assouplissement en attente : appliqué \(day(CM.date(pending.from)))."
                      : "Avec mesure s'éteindra \(day(CM.date(pending.from))).",
                      systemImage: "clock")
                    .foregroundStyle(Carnet.review)
            }
            if let today = service.today {
                let budget = CM.budgetMinutes(CM.effectiveRules(policy, now: now), now: now)
                LabeledContent("Aujourd'hui") {
                    Text("projets \(CM.duration(today.projets))\(budget.map { " sur \(CM.duration(Double($0 * 60)))" } ?? "") · étude \(CM.duration(today.etude))")
                        .monospacedDigit()
                }
            }
            if !service.verdict.allow {
                Label(service.verdict.message, systemImage: "pause.circle").foregroundStyle(Carnet.review)
            }
        } else {
            Text("Pas encore en route. Allumé, le premier jour observe seulement.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var plugin: some View {
        HStack {
            if let seen = service.modSeenAt {
                Label("Mod branché\(service.modVersion.map { " (\($0))" } ?? ""), vu \(lowered(DateUtils.relativeLabel(seen)))", systemImage: "checkmark.circle")
                    .foregroundStyle(Carnet.correct)
            } else {
                Label("Mod pas encore branché sur Claude Code", systemImage: "puzzlepiece.extension")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(service.installing ? "Branchement…" : service.modSeenAt == nil ? "Brancher Claude Code" : "Rebrancher") {
                service.install()
            }
            .disabled(service.installing)
        }
        if let message = service.installMessage {
            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private var changeSummary: String {
        guard draft != service.desired else { return "" }
        let current = service.policy.map { CM.effectiveRules($0, now: Date()) } ?? draft
        guard service.policy?.enabled == true else { return String(localized: "S'applique tout de suite.") }
        return CM.stricter(current, draft) == draft
            ? String(localized: "Plus strict : s'applique tout de suite.")
            : String(localized: "Ce qui assouplit attendra demain, 4 h ; ce qui durcit s'applique tout de suite.")
    }

    private func minutes(_ value: Int) -> String {
        value == 0 ? String(localized: "non") : CM.duration(Double(value * 60))
    }

    private func day(_ date: Date) -> String {
        String(localized: "\(lowered(DateUtils.relativeLabel(date))) à \(CM.clock(date))")
    }

    /// Une heure « hh:mm » du couvre-feu, éditée comme une date.
    private func time(_ key: WritableKeyPath<CM.Curfew, String>) -> Binding<Date> {
        Binding(
            get: {
                let text = draft.curfew?[keyPath: key] ?? "00:00"
                let parts = text.split(separator: ":").map { Int($0) ?? 0 }
                return Calendar.current.date(bySettingHour: parts.first ?? 0, minute: parts.count > 1 ? parts[1] : 0, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                draft.curfew?[keyPath: key] = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
            })
    }
}

/// Une limite en minutes, ou « sans limite ».
private struct LimitStepper: View {
    let title: String
    @Binding var value: Int?

    var body: some View {
        HStack {
            Toggle(title, isOn: Binding(get: { value != nil }, set: { value = $0 ? (value ?? 90) : nil }))
            Spacer()
            if let minutes = value {
                Stepper(CM.duration(Double(minutes * 60)), value: Binding(get: { minutes }, set: { value = $0 }), in: 0...600, step: 15)
                    .monospacedDigit()
            } else {
                Text("sans limite").foregroundStyle(.secondary)
            }
        }
    }
}

private struct FolderList: View {
    let title: String
    @Binding var folders: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Button("Ajouter…", action: add)
            }
            ForEach(folders, id: \.self) { folder in
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(folder).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { folders.removeAll { $0 == folder } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Retirer \(folder)")
                }
            }
            if folders.isEmpty { Text("aucun").font(.caption).foregroundStyle(.tertiary) }
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
        if !folders.contains(path) { folders.append(path) }
    }
}

// MARK: - Bilan

/// Dans le Bilan, à côté du temps d'étude : le temps de Claude Code, jour par
/// jour, et les passes avec leurs raisons. L'inconfortable, écrit noir sur blanc.
struct ClaudeMeasureCard: View {
    @State private var service = ClaudeMeasureService.shared

    var body: some View {
        if service.isConfigured {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Claude Code")
                figures
                chart
                passesList
            }
            .macCard()
            .onAppear { service.refreshUsage(force: true) }
        }
    }

    private var figures: some View {
        let week = service.week
        let projets = week.reduce(0) { $0 + $1.projets }
        let etude = week.reduce(0) { $0 + $1.etude }
        let blocks = week.reduce(0) { $0 + $1.blocks }
        return HStack(spacing: 36) {
            figure(CM.duration(service.today?.projets ?? 0), String(localized: "projets aujourd'hui"))
            figure(CM.duration(projets), String(localized: "projets en 7 jours"))
            figure(CM.duration(etude), String(localized: "Claude pour étudier"))
            figure("\(blocks)", blocks > 1 ? String(localized: "demandes bloquées") : String(localized: "demande bloquée"))
            Spacer()
        }
    }

    private var chart: some View {
        let budget = service.policy.flatMap { $0.desired.budgetWeekday }
        // La légende est le texte des séries : le même, traduit, des deux côtés.
        let projects = String(localized: "projets"), study = String(localized: "étude")
        return Chart {
            ForEach(service.week) { day in
                BarMark(x: .value("Jour", dateOf(day.day), unit: .day), y: .value("Heures", day.projets / 3600))
                    .foregroundStyle(by: .value("Claude", projects))
                    .cornerRadius(3)
                BarMark(x: .value("Jour", dateOf(day.day), unit: .day), y: .value("Heures", day.etude / 3600))
                    .foregroundStyle(by: .value("Claude", study))
                    .cornerRadius(3)
            }
            if let budget {
                RuleMark(y: .value("Budget", Double(budget) / 60))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Carnet.review)
                    .annotation(position: .top, alignment: .trailing) {
                        Text("budget en semaine").font(.caption2).foregroundStyle(Carnet.inkSecondary)
                    }
            }
        }
        .chartForegroundStyleScale([projects: Carnet.wrong, study: Carnet.correct])
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.weekday(.abbreviated))
            }
        }
        .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) { value in
            AxisGridLine()
            AxisValueLabel { if let h = value.as(Double.self) { Text(h < 1 ? "\(Int(h * 60)) min" : "\(Int(h)) h") } }
        } }
        .frame(height: 160)
    }

    @ViewBuilder private var passesList: some View {
        let recent = service.passes.prefix(8)
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Passes").font(Carnet.serif(.callout, weight: .semibold)).foregroundStyle(Carnet.ink)
                ForEach(Array(recent)) { pass in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(DateUtils.relativeLabel(CM.date(pass.at))) \(CM.clock(CM.date(pass.at)))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                        Text("« \(pass.reason) »").font(.callout)
                        Spacer()
                        if let rule = pass.rule { Text(rule.label).font(.caption).foregroundStyle(.tertiary) }
                    }
                }
            }
        }
    }

    private func figure(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(MacStyle.clock(24)).foregroundStyle(Carnet.ink)
            Text(caption).font(.callout).foregroundStyle(Carnet.inkSecondary)
        }
    }

    private func dateOf(_ key: String) -> Date {
        let parts = key.split(separator: "-").map { Int($0) ?? 0 }
        return Calendar.current.date(from: DateComponents(year: parts.first, month: parts.count > 1 ? parts[1] : 1,
                                                          day: parts.count > 2 ? parts[2] : 1)) ?? Date()
    }
}

// MARK: - Barre des menus

/// Une ligne, quand Avec mesure est en route : les projets du jour, et ce qui bloque.
struct ClaudeMeasureMenuLine: View {
    @State private var service = ClaudeMeasureService.shared

    var body: some View {
        if let policy = service.policy, CM.effectiveEnabled(policy, now: Date()) {
            let budget = CM.budgetMinutes(CM.effectiveRules(policy, now: Date()), now: Date())
            HStack(spacing: 6) {
                Image(systemName: service.verdict.allow ? "terminal" : "pause.circle")
                    .foregroundStyle(service.verdict.allow ? Carnet.inkSecondary : Carnet.review)
                Text("Claude Code · projets \(CM.duration(service.today?.projets ?? 0))\(budget.map { " / \(CM.duration(Double($0 * 60)))" } ?? "")")
                    .monospacedDigit()
                if !service.verdict.allow, let rule = service.verdict.rule {
                    Text("· \(rule.label)").foregroundStyle(Carnet.review)
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(Carnet.inkSecondary)
            .help(service.verdict.allow ? (service.verdict.warn ?? String(localized: "Avec mesure")) : service.verdict.message)
            .onAppear { service.refreshUsage() }
        }
    }
}
