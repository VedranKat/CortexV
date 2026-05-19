import SwiftUI

struct ReleaseNotesView: View {
    private let notes = ReleaseNote.all

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Release Notes")
                        .font(.largeTitle.weight(.semibold))
                    Text("Small notes for each Cortex V release.")
                        .foregroundStyle(.secondary)
                }

                LazyVStack(spacing: 12) {
                    ForEach(notes) { note in
                        ReleaseNoteCard(note: note)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct ReleaseNoteCard: View {
    let note: ReleaseNote

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(note.version)
                    .font(.headline)

                Spacer()

                if let date = note.date {
                    Text(date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(note.summary)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}

private struct ReleaseNote: Identifiable {
    let version: String
    let date: String?
    let summary: String

    var id: String { version }

    static let all: [ReleaseNote] = [
        ReleaseNote(
            version: "v0.1.0",
            date: nil,
            summary: "Initial Cortex V build with agent setup, workspace binding, session tracking, tool-call history, and change review foundations."
        )
    ]
}
