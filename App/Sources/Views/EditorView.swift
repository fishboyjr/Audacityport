import AudioCore
import SwiftUI
import UniformTypeIdentifiers

/// Main window: transport toolbar, timeline with tracks, edit toolbar and menus.
struct EditorView: View {
    @Bindable var model: EditorModel

    @State private var showImporter = false
    @State private var showExport = false
    @State private var showProjects = false
    @State private var showSpectrum = false
    @State private var activeEffect: EffectSheetItem?
    @State private var labelText = ""
    @State private var showLabelPrompt = false
    @State private var saveName = ""
    @State private var showSavePrompt = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TransportBar(model: model)
                Divider()
                if model.project.tracks.isEmpty && model.recordingPreview == nil {
                    emptyState
                } else {
                    TracksTimeline(model: model)
                }
                Divider()
                EditBar(model: model)
            }
            .navigationTitle(model.project.name + (model.isDirty ? " •" : ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { menus }
            .overlay(alignment: .top) { statusOverlay }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: AudioFiles.importTypes,
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { model.importAudio(urls: urls) }
            }
            .sheet(isPresented: $showExport) { ExportSheet(model: model) }
            .sheet(isPresented: $showProjects) { ProjectBrowser(model: model) }
            .sheet(isPresented: $showSpectrum) { SpectrumView(model: model) }
            .sheet(item: $activeEffect) { item in EffectSheet(model: model, effect: item.effect) }
            .alert("Add Label", isPresented: $showLabelPrompt) {
                TextField("Label", text: $labelText)
                Button("Add") { model.addLabel(labelText); labelText = "" }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Save Project As", isPresented: $showSavePrompt) {
                TextField("Name", text: $saveName)
                Button("Save") { model.save(as: saveName) }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Error", isPresented: Binding(get: { model.errorMessage != nil },
                                                 set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Tracks", systemImage: "waveform")
        } description: {
            Text("Record with the microphone, import audio files, or generate a tone.")
        } actions: {
            HStack {
                Button("Record", systemImage: "record.circle") { model.record() }
                Button("Import", systemImage: "square.and.arrow.down") { showImporter = true }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if model.isBusy || model.statusMessage != nil {
            HStack(spacing: 8) {
                if model.isBusy { ProgressView() }
                Text(model.statusMessage ?? "Working…").font(.footnote)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
            .padding(.top, 60)
            .task(id: model.statusMessage) {
                guard !model.isBusy, model.statusMessage != nil else { return }
                try? await Task.sleep(for: .seconds(2))
                if !model.isBusy { model.statusMessage = nil }
            }
        }
    }

    @ToolbarContentBuilder
    private var menus: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button("New Project", systemImage: "doc") { model.newProject() }
                Button("Open…", systemImage: "folder") { showProjects = true }
                Button("Save", systemImage: "square.and.arrow.down.on.square") {
                    if model.projectURL == nil { saveName = model.project.name; showSavePrompt = true } else { model.save() }
                }
                Button("Save As…") { saveName = model.project.name; showSavePrompt = true }
                Divider()
                Button("Import Audio…", systemImage: "square.and.arrow.down") { showImporter = true }
                Button("Export Audio…", systemImage: "square.and.arrow.up") { showExport = true }
                    .disabled(model.project.tracks.isEmpty)
            } label: {
                Label("File", systemImage: "doc.text")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button("Add Mono Track") { model.addTrack(stereo: false) }
                Button("Add Stereo Track") { model.addTrack(stereo: true) }
                Button("Remove Selected Tracks", role: .destructive) { model.removeSelectedTracks() }
                Divider()
                Button("Mix and Render") { model.mixAndRender() }
                Button("Add Label at Selection") { showLabelPrompt = true }
            } label: {
                Label("Tracks", systemImage: "square.stack.3d.up")
            }

            Menu {
                Section("Generate") {
                    ForEach(EffectCatalog.generators.map { EffectSheetItem(effect: $0) }) { item in
                        Button(item.effect.name + "…") { activeEffect = item }
                    }
                }
                Section("Effect") {
                    ForEach(EffectCatalog.effects.map { EffectSheetItem(effect: $0) }) { item in
                        let e = item.effect
                        Button(e.name + (e.parameters.isEmpty ? "" : "…")) {
                            if e.parameters.isEmpty {
                                model.apply(e, values: e.defaults)
                            } else {
                                activeEffect = item
                            }
                        }
                        .disabled(model.project.selection.isEmpty || model.project.selection.trackIDs.isEmpty)
                    }
                }
                Section("Analyze") {
                    Button("Plot Spectrum…") { showSpectrum = true }
                        .disabled(model.project.selection.isEmpty)
                    Button("Get Noise Profile") { model.captureNoiseProfile() }
                        .disabled(model.project.selection.isEmpty)
                }
            } label: {
                Label("Effects", systemImage: "wand.and.stars")
            }
        }
    }
}

struct EffectSheetItem: Identifiable {
    let effect: any AudioEffect
    var id: String { effect.id }
}
