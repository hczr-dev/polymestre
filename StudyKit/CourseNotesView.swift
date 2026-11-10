import SwiftUI
import SwiftData

/// Les notes d'un cours, en Markdown (formules comprises) : lues mises en
/// page, modifiées en texte. Les mêmes sur l'iPhone et le Mac, par iCloud.
///
/// `Course.notes` existait depuis le début sans qu'aucun écran ne l'écrive : ce
/// qu'on retient d'un cours (le barème du midterm, la convention du prof, « le
/// corrigé de la série 4 a une erreur ») n'avait nulle part où aller.
struct CourseNotesView: View {
    @Bindable var course: Course
    var textSize: CGFloat = 16

    @Environment(\.modelContext) private var context
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(editing ? "Markdown : **gras**, *italique*, - listes, $formules$" : "")
                    .font(.caption)
                    .foregroundStyle(Carnet.inkTertiary)
                Spacer()
                Button(editing ? String(localized: "Terminé") : (course.notes.isEmpty ? "Écrire" : "Modifier")) {
                    if editing { try? context.save() }
                    editing.toggle()
                    focused = editing
                }
                .font(.callout.weight(.semibold))
            }
            if editing {
                TextEditor(text: $course.notes)
                    .font(.system(size: textSize))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .frame(minHeight: 260)
                    .padding(8)
                    .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.paperCorner, style: .continuous))
            } else if course.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Ce qui ne rentre nulle part ailleurs : le barème, ce que le prof a dit en amphi, l'erreur du corrigé.")
                    .font(.callout)
                    .foregroundStyle(Carnet.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.paperCorner, style: .continuous))
                    .onTapGesture { editing = true; focused = true }
            } else {
                RichTextView(text: course.notes, size: textSize)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.paperCorner, style: .continuous))
            }
        }
        .onDisappear { if editing { try? context.save() } }
    }
}
