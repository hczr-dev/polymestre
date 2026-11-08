import SwiftUI

/// Le centre de contrôle du bureau d'étude : ce que le Centre de contrôle de
/// macOS offrait et qu'un blocage ferme — le volume de la musique, garder le
/// Mac éveillé, l'apparence, ranger le bureau, et ce qui est bloqué.
struct DeskControlCenterButton: View {
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "switch.2")
                .font(.callout)
                .foregroundStyle(StudyPalette.inkSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Centre de contrôle")
        .popover(isPresented: $shown, arrowEdge: .bottom) { DeskControlCenter() }
    }
}

private struct DeskControlCenter: View {
    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings
    @State private var music = StudyMusic.shared

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 14) {
            musicSection
            pomodoroSection
            Picker("Garder éveillé", selection: $settings.studyKeepAwake) {
                Text("Non").tag(KeepAwakePolicy.Mode.off)
                Text("Le Mac").tag(KeepAwakePolicy.Mode.system)
                Text("Le Mac et l'écran").tag(KeepAwakePolicy.Mode.display)
            }
            .onChange(of: settings.studyKeepAwake) { _, _ in StudyModeController.shared.update() }
            Toggle("Toujours sombre", isOn: $settings.studyAlwaysDark)
                .onChange(of: settings.studyAlwaysDark) { _, _ in StudyModeController.shared.update() }
            if let level = DeskStatus.shared.battery {
                Label("\(Int((level * 100).rounded())) % · \(DeskStatus.shared.charging ? "sur secteur" : "sur batterie")"
                      + (level < 0.2 && !DeskStatus.shared.charging ? String(localized: " · pense à brancher le Mac") : ""),
                      systemImage: DeskStatus.shared.charging ? "battery.100.bolt" : "battery.50")
                    .font(.caption)
                    .foregroundStyle(level < 0.2 && !DeskStatus.shared.charging ? Carnet.review : StudyPalette.inkSecondary)
            }
            Divider()
            HStack(spacing: 10) {
                Button("Réorganiser les outils") { NotificationCenter.default.post(name: .studyTidyDesk, object: nil) }
                if !StudyMode.isOpenEnded(timer.state) {
                    Button("Encore 25 min") { timer.extendStudy(minutes: 25) }
                }
            }
            Divider()
            blockedSection
            recentNotices
            if timer.isLocked {
                // La seule sortie sous verrou, ici aussi : à tenir, jamais un réflexe.
                HoldButton(title: "Sortie d'urgence", systemImage: "exclamationmark.triangle", hold: StudyMode.emergencyHold) {
                    timer.finish(emergency: true)
                }
                .help("Maintiens \(Int(StudyMode.emergencyHold)) secondes : la session s'enregistre, notée « sortie d'urgence ».")
            }
        }
        .padding(16)
        .frame(width: 320)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Pomodoro

    /// Allumer ou couper le Pomodoro en cours de séance, et régler ses durées : le premier
    /// bloc part de maintenant, ce qui a déjà été travaillé reste compté.
    @ViewBuilder
    private var pomodoroSection: some View {
        @Bindable var settings = settings
        // Dans une session de groupe, l'horloge est commune : on n'y touche pas seul·e.
        if timer.state?.groupSession == nil {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Pomodoro", isOn: Binding(get: { timer.state?.pomodoro ?? false }, set: { timer.setPomodoro($0) }))
                if timer.state?.pomodoro == true {
                    Stepper("Travail : \(settings.focusMinutes) min", value: $settings.focusMinutes, in: 5...90, step: 5)
                    Stepper("Pause : \(settings.shortBreakMinutes) min", value: $settings.shortBreakMinutes, in: 1...30)
                }
            }
            .onChange(of: settings.focusMinutes) { _, _ in timer.cycleDidChange() }
            .onChange(of: settings.shortBreakMinutes) { _, _ in timer.cycleDidChange() }
        }
    }

    // MARK: Musique

    @ViewBuilder
    private var musicSection: some View {
        let playing = music.nowPlaying
        VStack(alignment: .leading, spacing: 10) {
            if playing.hasTrack {
                HStack(spacing: 10) {
                    MusicNowArtwork(side: 40, radius: 6)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(playing.title ?? "").font(.callout.weight(.semibold)).foregroundStyle(StudyPalette.ink).lineLimit(1)
                        Text(playing.artist ?? "").font(.caption).foregroundStyle(StudyPalette.inkSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button { music.previous() } label: { Image(systemName: "backward.fill") }.buttonStyle(.plain)
                    Button { music.togglePlayPause() } label: { Image(systemName: playing.isPlaying ? "pause.fill" : "play.fill") }.buttonStyle(.plain)
                    Button { music.next() } label: { Image(systemName: "forward.fill") }.buttonStyle(.plain)
                }
                .foregroundStyle(StudyPalette.ink)
            } else if music.automationDenied {
                Label("Music n'est pas autorisé", systemImage: "music.note").font(.caption).foregroundStyle(Carnet.review)
            } else {
                Label("Rien ne joue", systemImage: "music.note").font(.caption).foregroundStyle(StudyPalette.inkSecondary)
            }
            if let volume = music.volume {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill").foregroundStyle(StudyPalette.inkSecondary)
                    Slider(value: Binding(get: { volume }, set: { music.setVolume($0) }), in: 0...1)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(StudyPalette.inkSecondary)
                }
            }
        }
    }

    // MARK: Notifications récentes

    @ViewBuilder
    private var recentNotices: some View {
        let recent = DeskNotifications.shared.history.prefix(5)
        if !recent.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Récemment").font(.caption.weight(.semibold)).foregroundStyle(StudyPalette.inkTertiary)
                ForEach(Array(recent)) { item in
                    Label {
                        HStack {
                            Text(item.text).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(item.at, format: .dateTime.hour().minute()).foregroundStyle(StudyPalette.inkTertiary).monospacedDigit()
                        }
                    } icon: { Image(systemName: item.icon) }
                    .font(.caption)
                    .foregroundStyle(StudyPalette.inkSecondary)
                }
            }
        }
    }

    // MARK: Ce qui est bloqué

    /// Ce que le blocage tient vraiment — et ce qu'il ne tient pas.
    private var blockedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(blockedSummary, systemImage: timer.studyLocks ? "lock.fill" : "lock.open")
                .font(.caption)
                .foregroundStyle(StudyPalette.inkSecondary)
            if timer.studyLocks {
                if !SystemHotKeys.isAvailable {
                    // Les fonctions du système manquent (une mise à jour de macOS) : on le dit.
                    Label("Raccourcis du système : non bloqués", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Carnet.review)
                } else if SystemLock.processSwitchingOff {
                    Label("Spotlight, ⌘Tab et Mission Control : éteints", systemImage: "checkmark")
                        .font(.caption).foregroundStyle(StudyPalette.inkSecondary)
                }
                if settings.studyBlockGestures {
                    Label("Gestes du trackpad : bloqués", systemImage: "checkmark")
                        .font(.caption).foregroundStyle(StudyPalette.inkSecondary)
                }
                if SystemChrome.currentPermission != .granted, settings.studyHideSystemChrome {
                    Label("Dock et barre des menus : visibles (permission manquante)", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Carnet.review)
                }
                if settings.studyPlaceApps, !AppPlacement.isTrusted {
                    Label("Apps pas posées dans le bureau (Accessibilité)", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(StudyPalette.inkSecondary)
                }
            }
        }
    }

    private var blockedSummary: String {
        guard timer.studyLocks else { return String(localized: "Rien n'est bloqué.") }
        let apps = settings.studyApps.filter { StudyModeController.isInstalled($0) }.count
        return String(localized: "Tout est bloqué sauf \(apps) apps et \(settings.studySites.count) sites.")
    }
}
