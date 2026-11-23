import SwiftUI

struct MainView: View {
    let model: AppModel

    @State private var isNamingAlbum = false
    @State private var newAlbumName = ""

    private static let newAlbumChoice = "\u{0}new album"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Watched folder")
                    HStack {
                        Text(model.folderPath ?? "None chosen")
                            .foregroundStyle(model.folderPath == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(model.folderPath ?? "")
                        Spacer()
                        Button("Choose Folder…") { model.chooseFolder() }
                    }
                }
                GridRow {
                    Text("Photos album")
                    Picker("Photos album", selection: albumSelection) {
                        ForEach(model.albumChoices, id: \.self) { Text($0).tag($0) }
                        Divider()
                        Text("New album…").tag(Self.newAlbumChoice)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            HStack {
                Toggle("Watch for new photos", isOn: watching)
                    .toggleStyle(.switch)
                    .disabled(!model.canWatch)
                Spacer()
                Text(model.statusText)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                if model.blocker == .photosAccessNeeded {
                    Button("Open Photos Privacy Settings…") { model.openPhotosPrivacySettings() }
                }
            }

            Table(model.recent) {
                TableColumn("File") { Text($0.fileName) }
                TableColumn("Folder") { Text($0.subfolder) }
                TableColumn("Time") { Text($0.time.formatted(date: .abbreviated, time: .shortened)) }
                TableColumn("Result") { row in
                    if let error = row.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .help(error)
                    } else {
                        Label("Imported", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .overlay {
                if model.recent.isEmpty {
                    Text("Nothing imported yet").foregroundStyle(.secondary)
                }
            }

            HStack {
                Toggle("Open at login", isOn: openAtLogin)
                if let note = model.loginItemNote {
                    Text(note).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding()
        .frame(minWidth: 620, minHeight: 420)
        .alert("New Album", isPresented: $isNamingAlbum) {
            TextField("Album name", text: $newAlbumName)
            Button("Create") { model.selectAlbum(newAlbumName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The album is created in Photos when watching starts.")
        }
    }

    private var albumSelection: Binding<String> {
        Binding {
            model.albumTitle
        } set: { choice in
            if choice == Self.newAlbumChoice {
                newAlbumName = ""
                isNamingAlbum = true
            } else {
                model.selectAlbum(choice)
            }
        }
    }

    private var watching: Binding<Bool> {
        Binding { model.isWatching } set: { model.setWatching($0) }
    }

    private var openAtLogin: Binding<Bool> {
        Binding { model.openAtLogin } set: { model.setOpenAtLogin($0) }
    }
}
