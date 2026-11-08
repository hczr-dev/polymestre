import AppKit
import SwiftData
import SwiftUI

/// L'onglet Web vide : les sites permis du cours, à ouvrir.
struct StudyWebHome: View {
    let course: Course?
    var open: (StudyMode.Tool) -> Void
    @Environment(MacSettings.self) private var settings

    var body: some View {
        let tools = StudyTools.tools(for: course, settings: settings).filter { !$0.isApp }
            + [StudyMode.Tool(id: "geogebra", title: "GeoGebra", subtitle: String(localized: "Géométrie"), icon: "compass.drawing",
                              kind: .web(URL(string: "https://www.geogebra.org/calculator")!))]
        VStack(alignment: .leading, spacing: 14) {
            Text("Sites permis").font(Carnet.serif(.title2)).foregroundStyle(StudyPalette.ink)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                ForEach(tools.filter(isAllowed)) { tool in
                    Button { open(tool) } label: {
                        HStack(spacing: 12) {
                            StudyToolIcon(tool: tool, size: 36)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tool.title).foregroundStyle(StudyPalette.ink)
                                Text(tool.subtitle).font(.caption).foregroundStyle(StudyPalette.inkSecondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .background(StudyPalette.raised.opacity(0.9), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(StudyPalette.rule))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Pour en ajouter : Réglages › Mode étude.")
                .font(.caption).foregroundStyle(StudyPalette.inkTertiary)
            Spacer()
        }
        .padding(32)
    }

    private func isAllowed(_ tool: StudyMode.Tool) -> Bool {
        guard case .web(let url) = tool.kind else { return false }
        return StudyMode.isAllowed(url: url, sites: settings.studySites)
    }
}
