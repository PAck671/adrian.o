import SwiftUI

/// Shared sticky notes: pinned first, then newest. Both of you can edit any note.
struct NotesBoard: View {
    @Environment(AppState.self) private var state
    @State private var editing: SharedNote?

    var body: some View {
        let notes = state.notes.sorted { a, b in a.pinned != b.pinned ? a.pinned : a.updatedAt > b.updatedAt }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Shared notes").font(.headline)
                Spacer()
                Button { editing = SharedNote(text: "", authorId: state.settings.deviceId) } label: {
                    Label("New note", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderedProminent)
            }
            if notes.isEmpty {
                Text("Bucket lists, gift ideas, things you want to say next call… everything here is shared.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], spacing: 14) {
                ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                    Button { editing = note } label: {
                        NoteCard(note: note, author: state.isPartner(note.authorId) ? state.settings.partnerName : "You")
                    }
                    .buttonStyle(.plain)
                    .rotationEffect(.degrees(index % 2 == 0 ? -1.5 : 1.5))
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.7), value: state.notes)
        }
        .sheet(item: $editing) { NoteEditor(note: $0) }
    }
}

struct NoteCard: View {
    let note: SharedNote
    let author: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if note.pinned {
                Image(systemName: "pin.fill").font(.caption).foregroundStyle(.red)
            }
            Text(note.text.isEmpty ? " " : note.text)
                .font(.callout)
                .lineLimit(8)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Text("\(author) · \(note.updatedAt.formatted(.relative(presentation: .named)))")
                .font(.caption2)
                .opacity(0.65)
        }
        .foregroundStyle(.black)
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .background(note.color.color, in: RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the note")
    }
}

struct NoteEditor: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State var note: SharedNote

    var body: some View {
        let exists = state.notes.contains { $0.id == note.id }
        NavigationStack {
            VStack(spacing: 16) {
                TextEditor(text: $note.text)
                    .scrollContentBackground(.hidden)
                    .font(.body)
                    .foregroundStyle(.black)
                    .padding(12)
                    .background(note.color.color, in: RoundedRectangle(cornerRadius: 10))
                    .frame(minHeight: 240)
                HStack(spacing: 14) {
                    ForEach(NoteColor.allCases) { color in
                        Button { note.color = color } label: {
                            Circle()
                                .fill(color.color)
                                .frame(width: 34, height: 34)
                                .overlay(Circle().stroke(.white, lineWidth: note.color == color ? 3 : 0))
                        }
                        .accessibilityLabel("\(color.rawValue) note")
                        .accessibilityAddTraits(note.color == color ? .isSelected : [])
                    }
                    Spacer()
                    Toggle(isOn: $note.pinned) { Image(systemName: "pin.fill") }
                        .toggleStyle(.button)
                        .accessibilityLabel("Pin note")
                }
                HStack {
                    Button {
                        state.textPartner("📝 \(note.text)")
                    } label: { Label("Send via iMessage", systemImage: "message.fill") }
                        .disabled(note.text.isEmpty)
                    Spacer()
                    if exists {
                        Button(role: .destructive) {
                            state.deleteNote(note)
                            dismiss()
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                }
                Spacer()
            }
            .padding()
            .navigationTitle(exists ? "Edit note" : "New note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        state.saveNote(note)
                        dismiss()
                    }
                    .disabled(note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.large])
    }
}
