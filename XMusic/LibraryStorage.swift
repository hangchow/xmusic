import Foundation

struct LibraryStorage {
    private let defaults: UserDefaults
    private let songsURL: URL

    private enum Key {
        static let playMode = "playMode"
        static let folderBookmark = "folderBookmark"
        static let folderName = "folderName"
    }

    init(defaults: UserDefaults = .standard, songsURL: URL? = nil) {
        self.defaults = defaults
        if let songsURL {
            self.songsURL = songsURL
        } else {
            let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.songsURL = supportDirectory.appendingPathComponent("songs.json")
        }
    }

    var playMode: PlayMode {
        get {
            guard
                let rawValue = defaults.string(forKey: Key.playMode),
                let mode = PlayMode(rawValue: rawValue)
            else {
                return .listLoop
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.playMode)
        }
    }

    var folderName: String? {
        get { defaults.string(forKey: Key.folderName) }
        set { defaults.set(newValue, forKey: Key.folderName) }
    }

    func loadSongs() -> [Song] {
        guard
            let data = try? Data(contentsOf: songsURL),
            let songs = try? JSONDecoder().decode([Song].self, from: data)
        else {
            return []
        }
        return songs
    }

    func saveSongs(_ songs: [Song]) throws {
        try FileManager.default.createDirectory(
            at: songsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(songs)
        try data.write(to: songsURL, options: [.atomic])
    }

    func saveFolderBookmark(for url: URL) throws {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: Key.folderBookmark)
        defaults.set(url.lastPathComponent, forKey: Key.folderName)
    }

    func resolveFolderBookmark() -> URL? {
        guard let data = defaults.data(forKey: Key.folderBookmark) else {
            return nil
        }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                try saveFolderBookmark(for: url)
            }
            return url
        } catch {
            return nil
        }
    }
}
