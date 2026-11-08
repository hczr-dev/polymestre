import SwiftUI

/// Les boutons de Claude et ses modèles, sans ouvrir `polymestre.json` : la
/// liste à gauche (dans la série, puis le système), le bouton choisi à droite.
/// Seuls `commands` et `models` sont réécrits ; le reste du fichier est gardé
/// (`ClaudeProject.updating`).
struct ClaudeButtonsEditor: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    @State private var commands: [ClaudeProject.File.Command] = []
    @State private var models = ClaudeProject.File.Models()
    @State private var selection: String?
    @State private var error: String?
    @State private var loaded = false

    private typealias Command = ClaudeProject.File.Command

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                list.frame(minWidth: 220, idealWidth: 240, maxWidth: 300)
                detail.frame(minWidth: 380, maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 560)
        .onAppear(perform: load)
    }

    // MARK: Liste

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("Dans la série") {
                    ForEach(commands.filter { $0.scope == .series }) { row($0) }
                }
                Section("Système") {
                    ForEach(commands.filter { $0.scope == .system }) { row($0) }
                }
            }
            .listStyle(.sidebar)
            HStack(spacing: 4) {
                Menu {
                    Button("Dans la série") { add(.series) }
                    Button("Système") { add(.system) }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton).fixedSize()
                Button { remove() } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless).disabled(selection == nil)
                Spacer()
                Button { move(-1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).disabled(!canMove(-1))
                Button { move(1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless).disabled(!canMove(1))
            }
            .padding(8)
        }
    }

    private func row(_ command: Command) -> some View {
        Label(command.label.isEmpty ? command.id : command.label, systemImage: command.icon)
            .tag(command.id)
    }

    // MARK: Détail

    @ViewBuilder
    private var detail: some View {
        if let index = commands.firstIndex(where: { $0.id == selection }) {
            Form {
                Section {
                    TextField("Libellé", text: $commands[index].label)
                    LabeledContent("Icône") {
                        HStack {
                            Image(systemName: commands[index].icon).frame(width: 20)
                            TextField("", text: $commands[index].icon, prompt: Text("sparkle"))
                                .labelsHidden()
                        }
                    }
                    Picker("Conversation", selection: $commands[index].scope) {
                        Text("La série").tag(Command.Scope.series)
                        Text("Le système").tag(Command.Scope.system)
                    }
                    Picker("Modèle", selection: modelBinding(index)) {
                        Text("Celui de la conversation").tag("")
                        Text("Indices (\(models.tutor ?? "défaut"))").tag("tutor")
                        Text("Système (\(models.system ?? "défaut"))").tag("system")
                        ForEach(Self.modelNames, id: \.self) { Text($0).tag($0) }
                    }
                }
                Section {
                    TextEditor(text: $commands[index].prompt)
                        .font(.body.monospaced())
                        .frame(minHeight: 110)
                } header: {
                    Text("Message")
                } footer: {
                    Text("{code} {cours} {serie} {titre} {exercice} : remplacés par la session en cours.")
                }
                Section {
                    Toggle("Proposer une photo d'abord", isOn: flag(index, \.capture))
                    Toggle("Joindre un fichier", isOn: flag(index, \.attach))
                    Toggle("Proposer des verdicts à noter", isOn: flag(index, \.verdicts))
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("Aucun bouton choisi", systemImage: "rectangle.and.hand.point.up.left",
                                   description: Text(commands.isEmpty ? "Ajoute-en un avec +." : "Choisis-en un à gauche."))
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Picker("Indices", selection: optional(\.tutor)) {
                Text("Par défaut").tag("")
                ForEach(Self.modelNames, id: \.self) { Text($0).tag($0) }
            }
            .fixedSize()
            Picker("Système", selection: optional(\.system)) {
                Text("Par défaut").tag("")
                ForEach(Self.modelNames, id: \.self) { Text($0).tag($0) }
            }
            .fixedSize()
            if let error { Text(error).font(.caption).foregroundStyle(Carnet.wrong) }
            Spacer()
            Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Enregistrer", action: save).keyboardShortcut(.defaultAction).disabled(!loaded)
        }
        .padding(12)
    }

    // MARK: Données

    private static let modelNames = ["haiku", "sonnet", "opus"]

    private func load() {
        let data = try? Data(contentsOf: url)
        if let data, !data.isEmpty {
            guard let file = ClaudeProject.File.decode(data) else {
                error = String(localized: "polymestre.json est illisible : corrige-le avant d'éditer ici.")
                return
            }
            commands = file.commands
            models = file.models
        }
        selection = commands.first?.id
        loaded = true
    }

    private func save() {
        let cleaned = commands.map { command -> Command in
            var copy = command
            copy.label = copy.label.trimmingCharacters(in: .whitespaces)
            if copy.icon.trimmingCharacters(in: .whitespaces).isEmpty { copy.icon = "sparkle" }
            return copy
        }
        guard let data = ClaudeProject.updating(try? Data(contentsOf: url), commands: cleaned, models: models) else {
            error = String(localized: "polymestre.json n'a pas pu être réécrit.")
            return
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func add(_ scope: Command.Scope) {
        let label = scope == .series ? String(localized: "Nouveau bouton") : String(localized: "Nouvelle commande")
        let command = Command(id: ClaudeProject.commandID(for: label, taken: commands.map(\.id)),
                              label: label, prompt: "", scope: scope)
        commands.append(command)
        selection = command.id
    }

    private func remove() {
        guard let index = commands.firstIndex(where: { $0.id == selection }) else { return }
        commands.remove(at: index)
        selection = commands.indices.contains(index) ? commands[index].id : commands.last?.id
    }

    /// Monter ou descendre parmi les boutons de la même conversation.
    private func neighbour(_ delta: Int) -> (Int, Int)? {
        guard let index = commands.firstIndex(where: { $0.id == selection }) else { return nil }
        let scope = commands[index].scope
        let same = commands.indices.filter { commands[$0].scope == scope }
        guard let position = same.firstIndex(of: index), same.indices.contains(position + delta) else { return nil }
        return (index, same[position + delta])
    }

    private func canMove(_ delta: Int) -> Bool { neighbour(delta) != nil }

    private func move(_ delta: Int) {
        guard let (from, to) = neighbour(delta) else { return }
        commands.swapAt(from, to)
    }

    private func modelBinding(_ index: Int) -> Binding<String> {
        Binding(get: { commands[index].model ?? "" },
                set: { commands[index].model = $0.isEmpty ? nil : $0 })
    }

    private func flag(_ index: Int, _ path: WritableKeyPath<Command, Bool?>) -> Binding<Bool> {
        Binding(get: { commands[index][keyPath: path] == true },
                set: { commands[index][keyPath: path] = $0 ? true : nil })
    }

    private func optional(_ path: WritableKeyPath<ClaudeProject.File.Models, String?>) -> Binding<String> {
        Binding(get: { models[keyPath: path] ?? "" },
                set: { models[keyPath: path] = $0.isEmpty ? nil : $0 })
    }
}
