import SwiftUI
import WebKit
import AVKit

final class MovieDownloads: NSObject, ObservableObject, WKDownloadDelegate {
    static let shared = MovieDownloads()

    struct Entry: Identifiable {
        let id: UUID
        var title: String
        var file: URL?
        var state: String
        var resumeData: Data?
    }

    @Published private(set) var entries: [Entry] = []
    @Published var notice = ""
    private var active: [UUID: WKDownload] = [:]
    private var destinations: [UUID: URL] = [:]
    private weak var sourceView: WKWebView?
    private let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MovieDownloads", isDirectory: true)

    override init() {
        super.init()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dirs = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        entries = dirs.compactMap { dir in
            guard let id = UUID(uuidString: dir.lastPathComponent),
                  FileManager.default.fileExists(atPath: dir.appendingPathComponent(".complete").path),
                  let file = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?.first else { return nil }
            return Entry(id: id, title: file.deletingPathExtension().lastPathComponent, file: file, state: "Downloaded")
        }
    }

    func attach(_ download: WKDownload, webView: WKWebView) {
        let id = UUID()
        entries.insert(Entry(id: id, title: "Movie", state: "Downloading"), at: 0)
        active[id] = download
        download.delegate = self
        sourceView = webView
        notice = id.uuidString
    }

    private func id(for download: WKDownload) -> UUID? {
        active.first { $0.value === download }?.key
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        if let id = id(for: download), destinations[id] == nil, let view = sourceView {
            view.evaluateJavaScript("document.querySelector('.mk-watch-white__title, .mkmas-single .mk-single__title, h1.entry-title')?.textContent.trim() || ''") { value, _ in
                if let title = value as? String, !title.isEmpty,
                   let i = self.entries.firstIndex(where: { $0.id == id }) {
                    self.entries[i].title = title
                }
                self.chooseDestination(download, response, suggestedFilename, completionHandler)
            }
        } else {
            chooseDestination(download, response, suggestedFilename, completionHandler)
        }
    }

    private func chooseDestination(_ download: WKDownload, _ response: URLResponse,
                                   _ suggestedFilename: String, _ completionHandler: (URL?) -> Void) {
        guard let id = id(for: download), let index = entries.firstIndex(where: { $0.id == id }) else {
            completionHandler(nil); return
        }
        let ext = URL(fileURLWithPath: suggestedFilename).pathExtension.lowercased()
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              response.url?.scheme == "https",
              response.mimeType?.hasPrefix("video/") == true
                || (response.mimeType == "application/octet-stream" && ["mp4", "m4v", "mov"].contains(ext)) else {
            entries[index].state = "Not a downloadable video"
            active[id] = nil
            completionHandler(nil)
            return
        }
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let original = entries[index].title == "Movie" ? URL(fileURLWithPath: suggestedFilename).deletingPathExtension().lastPathComponent : entries[index].title
        let cleaned = String(original.components(separatedBy: invalid).joined(separator: " ").prefix(80))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "Movie" : cleaned
        let dir = folder.appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // A resumed WKDownload may request a fresh destination for its final file.
            let file = dir.appendingPathComponent(title).appendingPathExtension(["mp4", "m4v", "mov"].contains(ext) ? ext : "mp4")
            destinations[id] = file
            entries[index].title = title
            completionHandler(file)
        } catch {
            entries[index].state = "Could not create download file"
            active[id] = nil
            completionHandler(nil)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let id = id(for: download), let i = entries.firstIndex(where: { $0.id == id }),
              let file = destinations.removeValue(forKey: id) else { return }
        active[id] = nil
        do {
            try Data().write(to: file.deletingLastPathComponent().appendingPathComponent(".complete"), options: .atomic)
        } catch {
            entries[i].state = "Could not save download"
            return
        }
        entries[i].file = file
        entries[i].state = "Downloaded"
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let id = id(for: download), let i = entries.firstIndex(where: { $0.id == id }) else { return }
        active[id] = nil
        entries[i].resumeData = resumeData
        entries[i].state = resumeData == nil ? "Failed — reopen movie to retry" : "Interrupted"
    }

    func pause(_ id: UUID) {
        guard let download = active.removeValue(forKey: id), let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].state = "Pausing"
        download.cancel { [weak self] data in
            guard let self, let index = self.entries.firstIndex(where: { $0.id == id }) else { return }
            self.entries[index].resumeData = data
            self.entries[index].state = data == nil ? "Cannot resume — reopen movie to retry" : "Paused"
        }
    }

    func resume(_ id: UUID, webView: WKWebView) {
        guard let i = entries.firstIndex(where: { $0.id == id }), let data = entries[i].resumeData else { return }
        entries[i].resumeData = nil
        entries[i].state = "Resuming"
        webView.resumeDownload(fromResumeData: data) { download in
            guard let index = self.entries.firstIndex(where: { $0.id == id }) else {
                download.cancel { _ in }; return
            }
            self.active[id] = download
            download.delegate = self
            self.entries[index].state = "Downloading"
        }
    }

    func remove(_ id: UUID) {
        let directory = folder.appendingPathComponent(id.uuidString, isDirectory: true)
        if let download = active.removeValue(forKey: id) {
            download.cancel { _ in try? FileManager.default.removeItem(at: directory) }
        } else {
            try? FileManager.default.removeItem(at: directory)
        }
        destinations[id] = nil
        entries.removeAll { $0.id == id }
    }
}

struct DownloadsView: View {
    @ObservedObject var downloads: MovieDownloads
    let webView: WKWebView
    @Environment(\.dismiss) private var dismiss
    @State private var playback: MovieDownloads.Entry?

    var body: some View {
        NavigationStack {
            List(downloads.entries) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.title).font(.headline)
                    Text(entry.state).font(.caption)
                    if entry.state == "Downloading" || entry.state == "Resuming" { ProgressView() }
                    HStack {
                        if entry.file != nil {
                            Button("Play") { playback = entry }
                        } else if entry.resumeData != nil {
                            Button("Resume") { downloads.resume(entry.id, webView: webView) }
                        } else if entry.state == "Downloading" {
                            Button("Pause") { downloads.pause(entry.id) }
                        }
                        Button(entry.file == nil ? "Cancel" : "Delete", role: .destructive) { downloads.remove(entry.id) }
                    }.buttonStyle(.bordered)
                }
            }
            .navigationTitle("Downloads")
            .toolbar { Button("Done") { dismiss() } }
            .sheet(item: $playback) { entry in
                if let file = entry.file { OfflineMovie(file: file) }
            }
        }
    }
}

private struct OfflineMovie: View {
    @State private var player: AVPlayer
    init(file: URL) { _player = State(initialValue: AVPlayer(url: file)) }
    var body: some View {
        VideoPlayer(player: player).onAppear { player.play() }.onDisappear { player.pause() }
    }
}
