import AppKit
import SwiftUI
import SwiftData

/// Le chrono flottant : une petite pilule au-dessus de toutes les fenêtres,
/// sur tous les bureaux, pendant une session. On la déplace où on veut (la
/// place est retenue) ; au survol, pause et terminer. En mode étude, elle suit
/// dans GoodNotes ou Claude : le temps reste sous les yeux.
@MainActor
final class MiniTimerPanel {
    static let shared = MiniTimerPanel()

    private var panel: NSPanel?
    weak var timer: MacTimer?
    weak var settings: MacSettings?
    var container: ModelContainer?

    /// À appeler à chaque changement du chrono ou du réglage.
    func update() {
        guard let timer, let settings else { return }
        // Les barres flottantes montrent déjà le chrono par-dessus toutes les apps.
        let wanted = settings.floatingTimer && timer.phase != .idle && !StudyModeController.shared.chromeUp
        if wanted {
            show(timer: timer, settings: settings)
        } else {
            panel?.orderOut(nil)
        }
    }

    private func show(timer: MacTimer, settings: MacSettings) {
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 236, height: 52),
                                styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                                backing: .buffered, defer: false)
            // Au-dessus du mode étude aussi (niveau `.statusBar` pour le voile).
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isMovableByWindowBackground = true
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            var root = AnyView(MiniTimerView()
                .environment(timer)
                .environment(settings))
            if let container { root = AnyView(root.modelContainer(container)) }
            let host = NSHostingView(rootView: root)
            host.frame = panel.contentRect(forFrameRect: panel.frame)
            panel.contentView = host
            panel.setFrameAutosaveName("Polymestre.MiniTimer")
            if !panel.setFrameUsingName("Polymestre.MiniTimer"), let screen = NSScreen.main {
                let frame = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: frame.maxX - 236 - 24, y: frame.maxY - 52 - 24))
            }
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }
}

/// La pilule : l'anneau du cours, le temps, ce qu'on fait ; les gestes au survol.
struct MiniTimerView: View {
    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings
    @Query(sort: \Course.code) private var courses: [Course]
    @State private var hovering = false

    private var course: Course? { courses.first { $0.id == timer.courseID } }
    private var tint: Color { MacTargets.tint(course) }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                LiveTimerRing(tint: tint, lineWidth: 3.5)
                if timer.phase == .paused {
                    Image(systemName: "pause.fill").font(.caption2.weight(.bold)).foregroundStyle(tint)
                } else if timer.phase == .onBreak {
                    Image(systemName: "cup.and.saucer.fill").font(.caption2).foregroundStyle(MacStyle.breakTint)
                } else if timer.isStudying {
                    Image(systemName: "moon.stars.fill").font(.caption2).foregroundStyle(tint)
                }
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 0) {
                TimerClockText(font: MacStyle.clock(19))
                TimerTimeline(interval: 60) { date in
                    Text(subtitle(at: date))
                        .font(.caption2)
                        .foregroundStyle(Carnet.inkSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if hovering {
                HStack(spacing: 4) {
                    Button { primary() } label: {
                        Image(systemName: timer.phase == .running ? "pause.fill" : "play.fill")
                    }
                    .help(timer.phase == .running ? "Pause" : "Reprendre")
                    if timer.isStudying {
                        Button { StudyModeController.shared.present() } label: { Image(systemName: "moon.stars") }
                            .help("Mode étude")
                    } else {
                        Button { timer.finish() } label: { Image(systemName: "checkmark") }
                            .help("Terminer")
                    }
                }
                .buttonStyle(RoundButtonStyle(size: 26))
                .transition(.opacity)
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 12)
        .frame(width: 236, height: 52)
        .background(Carnet.sheet, in: Capsule())
        .overlay(Capsule().strokeBorder(Carnet.rule))
        .contentShape(Capsule())
        .onHover { value in withAnimation(.easeOut(duration: 0.15)) { hovering = value } }
        .onTapGesture(count: 2) { primary() }
        .contextMenu {
            Button(timer.phase == .running ? "Pause" : "Reprendre") { primary() }
            if timer.isStudying {
                Button("Mode étude") { StudyModeController.shared.present() }
            } else {
                Button("Terminer") { timer.finish() }
            }
            Divider()
            Button("Masquer") {
                settings.floatingTimer = false
                MiniTimerPanel.shared.update()
            }
        }
    }

    private func subtitle(at date: Date) -> String {
        let what = MacTargets.headline(course: course, taskType: timer.taskType, targetID: timer.targetID)
        if timer.isStudying {
            return String(localized: "Mode étude · reste \(StudyMode.remaining(timer.state, at: date).minuteLabel(roundingUp: true))")
        }
        if let status = timer.statusLabel(at: date) { return "\(status) · \(what)" }
        guard let course else { return what }
        return "\(course.displayCode) · \(what)"
    }

    private func primary() {
        if timer.phase == .onBreak { timer.skipBreak() } else { timer.toggle() }
    }
}
