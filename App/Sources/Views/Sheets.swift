import AudioCore
import Charts
import SwiftUI

/// Auto-generated effect dialog built from the effect's parameter list.
struct EffectSheet: View {
    @Bindable var model: EditorModel
    let effect: any AudioEffect
    @State private var values: EffectValues
    @Environment(\.dismiss) private var dismiss

    init(model: EditorModel, effect: any AudioEffect) {
        _model = Bindable(model)
        self.effect = effect
        var v = effect.defaults
        // Generators default to the selection length when there is one.
        if effect is any AudioGenerator, !model.project.selection.isEmpty {
            v["duration"] = model.project.seconds(model.project.selection.range.count)
        }
        _values = State(initialValue: v)
    }

    var body: some View {
        NavigationStack {
            Form {
                ForEach(effect.parameters) { p in row(p) }
                if effect is NoiseReduction {
                    Section {
                        Button("Get Noise Profile from Selection") { model.captureNoiseProfile() }
                        Text(model.noiseProfile == nil ? "No profile captured yet." : "Profile captured.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } footer: {
                        Text("Step 1: select a few seconds of noise only and capture a profile. Step 2: select the audio to clean and apply.")
                    }
                }
                Section {
                    Button("Reset to Defaults") { values = effect.defaults }
                }
            }
            .navigationTitle(effect.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.stop(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { model.stop(); model.apply(effect, values: values); dismiss() }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button(model.isPlaying ? "Stop Preview" : "Preview", systemImage: model.isPlaying ? "stop.fill" : "play.fill") {
                        model.isPlaying ? model.stop() : model.preview(effect, values: values)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func row(_ p: EffectParameter) -> some View {
        switch p.kind {
        case .slider(let range, let step, let unit):
            VStack(alignment: .leading) {
                HStack {
                    Text(p.label)
                    Spacer()
                    TextField("", value: binding(p.id), format: .number.precision(.fractionLength(step < 1 ? 2 : 0)))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numbersAndPunctuation)
                        .frame(width: 80)
                    Text(unit).foregroundStyle(.secondary).frame(minWidth: 20, alignment: .leading)
                }
                Slider(value: clamped(p.id, range), in: range, step: step)
            }
        case .choice(let options):
            Picker(p.label, selection: Binding(get: { values.int(p.id) }, set: { values[p.id] = Double($0) })) {
                ForEach(options.indices, id: \.self) { Text(options[$0]).tag($0) }
            }
        case .toggle:
            Toggle(p.label, isOn: Binding(get: { values.flag(p.id) }, set: { values[p.id] = $0 ? 1 : 0 }))
        case .text:
            TextField(p.label, text: Binding(get: { values.text(p.id) }, set: { values.strings[p.id] = $0 }))
                .textInputAutocapitalization(.characters)
        }
    }

    private func binding(_ id: String) -> Binding<Double> {
        Binding(get: { values[id] }, set: { values[id] = $0 })
    }

    private func clamped(_ id: String, _ r: ClosedRange<Double>) -> Binding<Double> {
        Binding(get: { min(max(values[id], r.lowerBound), r.upperBound) }, set: { values[id] = $0 })
    }
}

/// Export dialog: format, channels, range; then share or save via the share sheet.
struct ExportSheet: View {
    @Bindable var model: EditorModel
    @State private var options = AudioFiles.ExportOptions()
    @State private var selectionOnly = false
    @State private var exported: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Picker("Format", selection: $options.format) {
                    ForEach(AudioFiles.ExportFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                if options.format == .wav {
                    Picker("Encoding", selection: $options.wavSampleFormat) {
                        ForEach(WAVCodec.SampleFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
                if options.format == .m4a {
                    Picker("Bit rate", selection: $options.aacBitRate) {
                        ForEach([96_000, 128_000, 192_000, 256_000, 320_000], id: \.self) { Text("\($0 / 1000) kbps").tag($0) }
                    }
                }
                Picker("Channels", selection: $options.channels) {
                    Text("Mono").tag(1)
                    Text("Stereo").tag(2)
                }
                Toggle("Export selection only", isOn: $selectionOnly)
                    .disabled(model.project.selection.isEmpty)
                Section {
                    Text("Sample rate: \(Int(model.project.sampleRate)) Hz").foregroundStyle(.secondary)
                    if let url = exported {
                        ShareLink(item: url) { Label("Share / Save “\(url.lastPathComponent)”", systemImage: "square.and.arrow.up") }
                    }
                }
            }
            .navigationTitle("Export Audio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") {
                        Task { exported = await model.export(options: options, selectionOnly: selectionOnly) }
                    }
                    .disabled(model.isBusy)
                }
            }
            .onChange(of: options.format) { exported = nil }
        }
    }
}

/// Frequency analysis of the selection (Plot Spectrum).
struct SpectrumView: View {
    @Bindable var model: EditorModel
    @State private var points: [SpectrumPoint] = []
    @State private var fftSize = 4096
    @Environment(\.dismiss) private var dismiss

    struct SpectrumPoint: Identifiable {
        let freq: Double
        let db: Double
        var id: Double { freq }
    }

    var body: some View {
        NavigationStack {
            VStack {
                Chart(points) { p in
                    LineMark(x: .value("Frequency (Hz)", p.freq), y: .value("Level (dB)", p.db))
                        .interpolationMethod(.linear)
                }
                .chartXScale(domain: 20...max(21, model.project.sampleRate / 2), type: .log)
                .chartYScale(domain: -120...0)
                .padding()
                Picker("Size", selection: $fftSize) {
                    ForEach([512, 1024, 2048, 4096, 8192, 16384], id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                if let peak = points.max(by: { $0.db < $1.db }) {
                    Text(String(format: "Peak: %.0f Hz at %.1f dB", peak.freq, peak.db))
                        .font(.footnote.monospacedDigit()).padding(.bottom)
                }
            }
            .navigationTitle("Frequency Analysis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: fftSize) { await compute() }
        }
    }

    private func compute() async {
        let p = model.project
        let size = fftSize
        let result = await Task.detached(priority: .userInitiated) { () -> [SpectrumPoint] in
            guard !p.selection.isEmpty else { return [] }
            let ids = p.selection.trackIDs.isEmpty ? nil : p.selection.trackIDs
            let mono = Mixer(project: p, trackIDs: ids).render(p.selection.range, channels: 1)[0]
            let db = DSP.spectrum(mono, fftSize: size)
            let binHz = p.sampleRate / Double(size)
            return db.indices.dropFirst().map { SpectrumPoint(freq: Double($0) * binHz, db: Double(max(-120, db[$0]))) }
        }.value
        points = result
    }
}

/// Saved projects in the app's Documents folder (also visible in the Files app).
struct ProjectBrowser: View {
    @Bindable var model: EditorModel
    @State private var urls: [URL] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if urls.isEmpty {
                    Text("No saved projects yet. Use File › Save.").foregroundStyle(.secondary)
                }
                ForEach(urls, id: \.self) { url in
                    Button {
                        model.open(url)
                        dismiss()
                    } label: {
                        Label(url.deletingPathExtension().lastPathComponent, systemImage: "waveform")
                    }
                }
                .onDelete { idx in
                    for i in idx { model.deleteProject(urls[i]) }
                    urls = model.savedProjects()
                }
            }
            .navigationTitle("Projects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { EditButton() }
            }
            .onAppear { urls = model.savedProjects() }
        }
    }
}
