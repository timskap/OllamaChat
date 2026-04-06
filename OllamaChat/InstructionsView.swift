import SwiftUI

struct InstructionsView: View {
    @ObservedObject var store: ProjectStore
    let projectID: UUID

    @State private var draft = ""

    private var project: Project? {
        store.projects.first { $0.id == projectID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "doc.text")
                    .font(.title2)
                Text("Project Instructions")
                    .font(.title2.bold())
                Spacer()
            }

            Text("Sent as system prompt with every message in this project.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let project {
                TextEditor(text: $draft)
                    .font(.body)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(8)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(0.1))
                    )

                HStack {
                    Spacer()
                    if draft != project.instructions {
                        Button("Revert") { draft = project.instructions }
                        Button("Save") {
                            store.updateInstructions(projectID: projectID, instructions: draft)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Text("Saved")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(24)
        .onAppear { if let p = project { draft = p.instructions } }
        .onChange(of: projectID) { _, _ in if let p = project { draft = p.instructions } }
    }
}
