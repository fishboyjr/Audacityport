import AudioCore
import Foundation

/// File menu: projects, import, export, autosave.
extension EditorModel {
    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var autosaveURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Autosave.\(ProjectArchive.fileExtension)")
    }

    func savedProjects() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Self.documentsURL, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension == ProjectArchive.fileExtension }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
    }

    func newProject() {
        stop()
        project = Project()
        resetHistory()
        projectURL = nil
        isDirty = false
        playhead = 0
        viewStart = 0
        framesPerPoint = 441
        clearAutosave()
    }

    func open(_ url: URL) {
        stop()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if url.pathExtension == ProjectArchive.fileExtension {
            do {
                project = try ProjectArchive.load(from: url)
                resetHistory()
                projectURL = url
                isDirty = false
                playhead = 0
                zoomToFit()
            } catch {
                errorMessage = "Could not open project: \(error.localizedDescription)"
            }
        } else {
            importAudio(urls: [url])
        }
    }

    func save(as name: String? = nil) {
        if let name, !name.isEmpty { project.name = name }
        let url = (name == nil ? projectURL : nil)
            ?? Self.documentsURL.appendingPathComponent(project.name).appendingPathExtension(ProjectArchive.fileExtension)
        do {
            try ProjectArchive.save(project, to: url)
            projectURL = url
            isDirty = false
            statusMessage = "Saved “\(project.name)”"
            clearAutosave()
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    func deleteProject(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        if url == projectURL { projectURL = nil }
    }

    func importAudio(urls: [URL]) {
        stop()
        isBusy = true
        statusMessage = "Importing…"
        let at = project.selection.isEmpty ? 0 : project.selection.cursor
        Task.detached(priority: .userInitiated) {
            var decoded: [(PlanarAudio, Double, String)] = []
            var failures: [String] = []
            for url in urls {
                do {
                    let (audio, rate) = try AudioFiles.read(url)
                    decoded.append((audio, rate, url.deletingPathExtension().lastPathComponent))
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            let results = decoded
            let errors = failures
            await MainActor.run {
                self.isBusy = false
                self.statusMessage = nil
                if !results.isEmpty {
                    let firstImport = self.project.tracks.isEmpty
                    self.perform("Import Audio") { p in
                        // The first file into an empty project sets the project rate.
                        if p.tracks.isEmpty, let rate = results.first?.1 { p.sampleRate = rate }
                        var ids: Set<UUID> = []
                        for (audio, rate, name) in results {
                            ids.insert(p.importAudio(audio, sampleRate: rate, name: name, at: at))
                        }
                        p.selection = Selection(range: at..<at, trackIDs: ids)
                        if firstImport { p.name = results[0].2 }
                    }
                    self.zoomToFit()
                }
                if !errors.isEmpty { self.errorMessage = "Import failed:\n" + errors.joined(separator: "\n") }
            }
        }
    }

    /// Render the mix (whole project or selection) and write it in the chosen format.
    func export(options: AudioFiles.ExportOptions, selectionOnly: Bool) async -> URL? {
        let p = project
        let range: Range<Int> = selectionOnly && !p.selection.isEmpty ? p.selection.range : 0..<p.endFrame
        guard !range.isEmpty else { errorMessage = "Nothing to export."; return nil }
        let ids: Set<UUID>? = selectionOnly && !p.selection.trackIDs.isEmpty ? p.selection.trackIDs : nil
        isBusy = true
        statusMessage = "Exporting…"
        defer { isBusy = false; statusMessage = nil }
        let task = Task.detached(priority: .userInitiated) { () throws -> URL in
            let mix = Mixer(project: p, trackIDs: ids).render(range, channels: options.channels)
            return try AudioFiles.write(mix, sampleRate: p.sampleRate, name: p.name, options: options)
        }
        do {
            return try await task.value
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: Autosave

    func autosave() {
        guard isDirty, !project.tracks.isEmpty else { return }
        let dir = Self.autosaveURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? ProjectArchive.save(project, to: Self.autosaveURL)
    }

    func restoreAutosaveIfNeeded() {
        guard project.tracks.isEmpty,
              FileManager.default.fileExists(atPath: Self.autosaveURL.path),
              let p = try? ProjectArchive.load(from: Self.autosaveURL) else { return }
        project = p
        resetHistory()
        isDirty = true
        statusMessage = "Recovered unsaved project “\(p.name)”"
        zoomToFit()
    }

    func clearAutosave() {
        try? FileManager.default.removeItem(at: Self.autosaveURL)
    }
}
