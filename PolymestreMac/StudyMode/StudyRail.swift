import AppKit
import SwiftData
import SwiftUI

// MARK: - Colonne d'outils

struct StudyRail: View {
    @State private var running = RunningApps.shared
    @State private var ed = EdWatcher.shared
    var desk: StudyDesk
    var browser: StudyBrowserModel
    let course: Course?
    @Environment(MacSettings.self) private var settings

    var body: some View {
        VStack(spacing: 6) {
            ForEach(StudyDesk.Pane.allCases) { pane in
                RailButton(title: pane.title, icon: pane.icon, selected: desk.pane == pane,
                           badge: pane == .web && !browser.tabs.isEmpty ? "\(browser.tabs.count)"
                                : (pane == .course && edUnread > 0 ? "\(edUnread)" : nil)) {
                    desk.pane = pane
                }
                .help("\(pane.title) (⌘\(String(pane.shortcut.character)))")
            }
            Rectangle().fill(StudyPalette.rule).frame(width: 34, height: 1).padding(.vertical, 4)
            // Par-dessus ou à côté de l'outil du centre, sans le remplacer.
            RailButton(title: "Claude", icon: "sparkle", selected: desk.claudeVisible,
                       badge: desk.claudeUnread ? "•" : (desk.chats.values.contains { $0.isAnswering } ? "…" : nil)) { desk.toggleClaude() }
                .help(desk.claudePlacement == .floating ? "Claude, par-dessus (⌘J)" : "Claude, à droite (⌘J)")
                .contextMenu {
                    Button { desk.floatClaude() } label: { Label("Flottant", systemImage: "macwindow") }
                    Button { desk.dockClaude() } label: { Label("Ancré à droite", systemImage: "sidebar.right") }
                }
            RailButton(title: String(localized: "À côté"), icon: "sidebar.right", selected: desk.sideOpen) { desk.sideOpen.toggle() }
                .help("Le volet d'à côté : un cahier, l'énoncé, un PDF… (⌘\\)")
            Spacer()
            Rectangle().fill(StudyPalette.rule).frame(width: 34, height: 1)
            ForEach(apps, id: \.self) { bundleID in
                Button {
                    StudyModeController.shared.openApp(bundleID: bundleID)
                } label: {
                    VStack(spacing: 3) {
                        if let icon = StudyModeController.icon(for: bundleID) {
                            Image(nsImage: icon).resizable().frame(width: 30, height: 30)
                                .overlay(alignment: .bottom) {
                                    // Ouverte : un point, comme dans le Dock.
                                    if running.running.contains(bundleID) {
                                        Circle().fill(StudyPalette.ink).frame(width: 4, height: 4).offset(y: 6)
                                    }
                                }
                        }
                        Text(StudyModeController.name(for: bundleID)).font(.caption2).foregroundStyle(StudyPalette.inkTertiary)
                            .lineLimit(1)
                    }
                    .frame(width: 64)
                }
                .buttonStyle(.plain)
                .help(StudyModeController.name(for: bundleID))
            }
        }
        .onAppear { running.start() }
        .padding(.vertical, 14)
        .frame(width: 76)
        .deskChrome(edge: .trailing)
    }

    /// Les nouveaux messages Ed du cours étudié (le point de « Cours »).
    private var edUnread: Int { course.map { ed.unread[$0.id] ?? 0 } ?? 0 }

    /// Les apps permises et installées (sauf le Finder et la Calculette : le
    /// bureau a les siennes).
    private var apps: [String] {
        settings.studyApps.filter {
            $0 != "com.apple.finder" && $0 != "com.apple.calculator" && StudyModeController.isInstalled($0)
        }
    }
}

struct RailButton: View {
    let title: String
    let icon: String
    let selected: Bool
    /// Ouvert à côté (côte à côte) : marqué, sans être l'onglet principal.
    var beside = false
    var badge: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            RailButtonLabel(title: title, icon: icon, selected: selected, beside: beside, badge: badge)
        }
        .buttonStyle(.plain)
    }
}

struct RailButtonLabel: View {
    let title: String
    let icon: String
    let selected: Bool
    var beside = false
    var badge: String?
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3.weight(selected ? .semibold : .regular))
                .frame(width: 44, height: 34)
                .background(selected ? StudyPalette.ink : (hovering ? StudyPalette.raisedMore : .clear),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    if beside {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(StudyPalette.ink.opacity(0.7), lineWidth: 1.5)
                    }
                }
                .foregroundStyle(selected ? StudyPalette.ground : StudyPalette.ink)
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Text(badge).font(.caption2.weight(.bold)).padding(3)
                            .background(Carnet.wrong, in: Circle()).foregroundStyle(.white).offset(x: 4, y: -4)
                    }
                }
            Text(title).font(.caption2.weight(selected || beside ? .semibold : .regular))
                .foregroundStyle(selected || beside ? StudyPalette.ink : StudyPalette.inkSecondary)
        }
        .frame(width: 64)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
