import SwiftUI

/// « À rattraper » sur l'iPhone : la page partagée (`LateWorkView`), et ses
/// feuilles — l'exercice, la théorie, le corrigé dans le navigateur de l'app.
struct LateWorkScreen: View {
    let course: Course

    @State private var openedExercise: Exercise?
    @State private var openedVideo: TheoryItem?
    @State private var browsing: BrowsedLink?

    var body: some View {
        LateWorkView(course: course,
                     openExercise: { openedExercise = $0 },
                     openTheory: { openedVideo = $0 },
                     openURL: { browsing = BrowsedLink(title: "Corrigé", url: $0, icon: "checkmark.seal") })
            .navigationTitle("À rattraper")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $openedExercise) { ExerciseSheet(exercise: $0) }
            .sheet(item: $openedVideo) { VideoDetailSheet(video: $0) }
            .sheet(item: $browsing) { InAppBrowser(link: $0) }
    }
}
