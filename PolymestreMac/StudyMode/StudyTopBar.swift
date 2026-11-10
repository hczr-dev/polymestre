import AppKit
import SwiftData
import SwiftUI

// MARK: - Barre du haut

struct StudyTopBar: View {
    let course: Course?
    var tint: Color
    var moment: DeskMoment
    var openMusic: () -> Void
    var openResource: (SavedResource) -> Void
    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings
    @State private var music = StudyMusic.shared

    /// Une seule horloge : à gauche la session (avec **son** bouton pause,
    /// dans la même pastille) puis sur quoi on travaille, à droite la musique
    /// et les sorties. Rien au milieu : en plein écran, l'encoche des MacBook
    /// y cache ce qu'on pose.
    var body: some View {
        // Avec l'encoche, les trois blocs (gauche, vide, droite) font exactement la
        // largeur de l'écran : aucun espacement entre eux.
        HStack(spacing: Self.notch == nil ? 16 : 0) {
            if let notch = Self.notch {
                // L'encoche : rien dessous. La session et la cible à sa gauche, tout le
                // reste à sa droite, chacun dans la place qu'elle laisse.
                HStack(spacing: 16) {
                    sessionClock
                    subject
                        .frame(maxWidth: 360, alignment: .leading)
                        .layoutPriority(-1)
                    Spacer(minLength: 0)
                }
                .frame(width: notch.left, alignment: .leading)
                Spacer(minLength: notch.gap)
                rightGroup
                    .frame(width: notch.right, alignment: .trailing)
            } else {
                sessionClock
                subject
                    .frame(maxWidth: 360, alignment: .leading)
                    .layoutPriority(-1)
                Spacer(minLength: 12)
                rightGroup
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .deskChrome(edge: .bottom)
        // Suivie toute la session : la musique lancée dans Music apparaît
        // ici sans passer d'abord par l'onglet Musique.
        .musicAttached()
        .animation(.smooth(duration: 0.25), value: music.nowPlaying.hasTrack)
    }

    /// Le cours et la forme du bureau sur une ligne, la cible dessous.
    private var subject: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let course { CourseTag(code: course.displayCode, tint: tint) }
                momentMenu
                if let group = timer.state?.groupSession {
                    Label(group.groupName, systemImage: "person.2.fill")
                        .font(.caption)
                        .foregroundStyle(StudyPalette.inkSecondary)
                        .help("Chrono commun avec le groupe")
                }
            }
            Text(MacTargets.headline(course: course, taskType: timer.taskType, targetID: timer.targetID))
                .font(Carnet.serif(.title2))
                .foregroundStyle(StudyPalette.ink)
                .lineLimit(1)
        }
    }

    /// La session : l'anneau, ce qui reste (ou depuis quand), et la pause.
    private var sessionClock: some View {
        let paused = timer.phase == .paused
        return HStack(spacing: 12) {
            StudyTimeline { date in
                TimerRing(progress: StudyMode.progress(timer.state, at: date), tint: tint, lineWidth: 3)
                    .frame(width: 24, height: 24)
            }
            VStack(alignment: .leading, spacing: 0) {
                StudyTimeline { date in
                    Text(StudyMode.clock(timer.state, at: date).clockLabel)
                        .font(StudyType.barClock)
                        .foregroundStyle(paused ? StudyPalette.inkSecondary : StudyPalette.ink)
                }
                HStack(spacing: 4) {
                    Text(clockCaption)
                    // Le chrono de travail n'apparaît que quand il dit autre
                    // chose que la session : un bloc Pomodoro, une pause.
                    if timer.state?.pomodoro == true {
                        Text("·")
                        Image(systemName: timer.phase == .onBreak ? "cup.and.saucer" : "timer")
                        TimerClockText(font: .caption2.monospacedDigit())
                    }
                }
                .font(.caption2)
                .foregroundStyle(paused ? Carnet.review : StudyPalette.inkTertiary)
            }
            Button {
                if timer.phase == .onBreak { timer.skipBreak() } else { timer.toggle() }
            } label: {
                Image(systemName: timer.phase == .running ? "pause.fill" : (timer.phase == .onBreak ? "forward.fill" : "play.fill"))
                    .font(.callout.weight(.bold))
                    .foregroundStyle(StudyPalette.ground)
                    .frame(width: 30, height: 30)
                    .background(paused ? tint : StudyPalette.ink, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(timer.phase == .running ? "Mettre la session en pause" : (timer.phase == .onBreak ? String(localized: "Écourter la pause") : String(localized: "Reprendre la session")))
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(StudyPalette.raisedMore, in: Capsule())
        .overlay(Capsule().strokeBorder(paused ? tint.opacity(0.6) : StudyPalette.rule))
        .fixedSize()
    }

    private var clockCaption: String {
        if timer.phase == .paused { return String(localized: "En pause") }
        if StudyMode.isOpenEnded(timer.state) {
            return "depuis \(DateUtils.time.string(from: timer.state?.studySince ?? Date()))"
        }
        return String(localized: "jusqu'à \(DateUtils.time.string(from: timer.state?.studyUntil ?? Date()))")
    }

    /// Les outils (qui se replient quand la place manque) puis la sortie (qui ne se
    /// replie jamais).
    private var rightGroup: some View {
        HStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                tools(.full)
                tools(.medium)
                tools(.small)
                tools(.minimal)
            }
            .layoutPriority(1)
            exitControls
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
        }
    }

    /// L'encoche de l'écran principal (MacBook) : la place à gauche, à droite, et
    /// l'espace qu'elle prend au milieu. `nil` sans encoche.
    private static var notch: (left: CGFloat, right: CGFloat, gap: CGFloat)? {
        guard let screen = NSScreen.screens.first, screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
        let margin: CGFloat = 18
        return (max(0, left.width - margin), max(0, right.width - margin), max(0, right.minX - left.maxX))
    }

    private enum ToolsLevel { case full, medium, small, minimal }

    /// Ce qui se replie : les ressources, la musique, l'état, le centre de contrôle.
    @ViewBuilder
    private func tools(_ level: ToolsLevel) -> some View {
        HStack(spacing: 12) {
            resourcesMenu
            switch level {
            case .full, .medium:
                MusicMiniPlayer(open: openMusic)
            case .small:
                Button(action: openMusic) {
                    Image(systemName: music.nowPlaying.isPlaying ? "music.note" : "music.note")
                        .foregroundStyle(music.nowPlaying.isPlaying ? StudyPalette.ink : StudyPalette.inkSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Musique")
            case .minimal:
                EmptyView()
            }
            if level == .full {
                Rectangle().fill(StudyPalette.rule).frame(width: 1, height: 26)
                // Ce que la barre des menus de macOS montrait, et qu'un blocage cache.
                DeskStatusItems()
            }
            DeskControlCenterButton()
        }
        .fixedSize()
    }

    /// La sortie de la session : toujours visible.
    private var exitControls: some View {
        HStack(spacing: 12) {
            Rectangle().fill(StudyPalette.rule).frame(width: 1, height: 26)
            if timer.isLocked {
                // Sous verrou : une seule sortie, qu'on ne prend pas par réflexe.
                Image(systemName: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(StudyPalette.inkTertiary)
                    .help("Session verrouillée")
                HoldButton(title: String(localized: "Sortie d'urgence"), systemImage: "exclamationmark.triangle", hold: StudyMode.emergencyHold) {
                    timer.finish(emergency: true)
                }
                .help("Maintiens \(Int(StudyMode.emergencyHold)) secondes : la session s'enregistre, notée « sortie d'urgence ».")
            } else {
                HoldButton(title: String(localized: "Terminer"), systemImage: "checkmark", hold: settings.studyHoldToLeave ? 1.5 : 0) {
                    timer.finish()
                }
            }
            Menu {
                if !StudyMode.isOpenEnded(timer.state) {
                    Button { timer.extendStudy(minutes: 25) } label: { Label("Encore 25 min", systemImage: "plus") }
                    Divider()
                }
                if timer.state?.groupSession == nil {
                    Button { timer.setPomodoro(timer.state?.pomodoro != true) } label: {
                        Label(timer.state?.pomodoro == true ? "Couper le Pomodoro" : "Allumer le Pomodoro", systemImage: "timer")
                    }
                }
                Button("Réorganiser les outils selon mon travail") { NotificationCenter.default.post(name: .studyTidyDesk, object: nil) }
                Button("Mes cours") {
                    NSApp.setActivationPolicy(.regular)
                    NotificationCenter.default.post(name: .macOpenMainWindow, object: nil)
                }
                if !timer.isLocked {
                    Divider()
                    Button("Sortir, garder la session") { timer.leaveStudy() }
                    Button("Abandonner", role: .destructive) { timer.discard() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(StudyPalette.inkSecondary)
        }
    }

    /// Les ressources gardées du cours, à un clic : elles s'ouvrent à côté.
    @ViewBuilder
    private var resourcesMenu: some View {
        if let course {
            Menu {
                if course.savedResources.isEmpty {
                    Text("Rien de gardé pour l'instant")
                    Text("Le signet en haut d'un document, ou Cours › Gardés")
                } else {
                    ForEach(course.sortedResources) { resource in
                        Button { openResource(resource) } label: {
                            Label(resource.title, systemImage: resource.isPinned ? "pin" : resource.kind.icon)
                        }
                    }
                }
            } label: {
                Image(systemName: course.savedResources.isEmpty ? "bookmark" : "bookmark.fill")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(StudyPalette.inkSecondary)
            .help("Tes ressources gardées (elles s'ouvrent à côté)")
        }
    }

    /// La forme du bureau, à changer à la main : suivre le cours, faire la
    /// série, réviser. Le chrono continue ; le temps déjà compté reste.
    private var momentMenu: some View {
        Menu {
            Button { timer.retarget(courseID: timer.courseID, taskType: .lecture) } label: {
                Label(DeskMoment.lecture.title, systemImage: DeskMoment.lecture.icon)
            }
            Button { timer.retarget(courseID: timer.courseID, taskType: .exercise) } label: {
                Label(DeskMoment.series.title, systemImage: DeskMoment.series.icon)
            }
            Button { timer.retarget(courseID: timer.courseID, taskType: .theory) } label: {
                Label(course?.nextSitting != nil ? DeskMoment.revision.title : TaskType.theory.label, systemImage: DeskMoment.revision.icon)
            }
        } label: {
            HStack(spacing: 4) {
                Text("·").foregroundStyle(StudyPalette.inkTertiary)
                Image(systemName: moment.icon)
                Text(moment.title)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(StudyPalette.inkSecondary)
            .contentShape(Rectangle())
        }
        .pillMenu()
        .disabled(course == nil)
        .help("La forme du bureau")
    }
}
