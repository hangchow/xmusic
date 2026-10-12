import XCTest
@testable import XMusic

final class ModelStorageTests: XCTestCase {
    private var defaults: UserDefaults!
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let suiteName = "ModelStorageTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelStorageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        defaults = nil
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    func testPlayModeCyclesThroughAllModes() {
        XCTAssertEqual(PlayMode.listLoop.next, .singleLoop)
        XCTAssertEqual(PlayMode.singleLoop.next, .shuffle)
        XCTAssertEqual(PlayMode.shuffle.next, .listLoop)
    }

    func testPlayerTimeTextFormatsShortAndLongDurations() {
        XCTAssertEqual(TimeInterval(0).playerTimeText, "0:00")
        XCTAssertEqual(TimeInterval(65).playerTimeText, "1:05")
        XCTAssertEqual(TimeInterval(3_725).playerTimeText, "1:02:05")
    }

    func testSongIDUsesRelativePathForStableRefreshIdentity() {
        let song = Song(
            title: "Track",
            relativePath: "Albums/Track.flac",
            fileExtension: "flac",
            duration: 12
        )

        XCTAssertEqual(song.id, "Albums/Track.flac")
    }

    func testSongDecodesLegacyPayloadWithoutCloudDownloadState() throws {
        let data = Data("""
        {
          "title": "Legacy",
          "relativePath": "Legacy.mp3",
          "fileExtension": "mp3",
          "duration": 42
        }
        """.utf8)

        let song = try JSONDecoder().decode(Song.self, from: data)

        XCTAssertEqual(song.cloudDownloadState, .local)
    }

    func testScanAudioFileMapsICloudPlaceholderToVisibleSong() throws {
        let folderURL = temporaryDirectory.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let placeholderURL = folderURL.appendingPathComponent(".Cloud Track.mp3.icloud")
        try Data().write(to: placeholderURL)

        let file = try XCTUnwrap(PlayerStore.scannedAudioFile(
            for: placeholderURL,
            folderURL: folderURL,
            supportedExtensions: ["mp3"]
        ))

        XCTAssertEqual(file.title, "Cloud Track")
        XCTAssertEqual(file.relativePath, "Cloud Track.mp3")
        XCTAssertEqual(file.fileExtension, "mp3")
        XCTAssertEqual(file.cloudDownloadState, .notDownloaded)
    }

    func testScanAudioFileSkipsHiddenNonICloudFiles() throws {
        let folderURL = temporaryDirectory.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let hiddenURL = folderURL.appendingPathComponent(".Hidden.mp3")
        try Data().write(to: hiddenURL)

        let file = PlayerStore.scannedAudioFile(
            for: hiddenURL,
            folderURL: folderURL,
            supportedExtensions: ["mp3"]
        )

        XCTAssertNil(file)
    }

    func testStoragePersistsPlayModeAndSongs() throws {
        let songsURL = temporaryDirectory.appendingPathComponent("songs.json")
        var storage = LibraryStorage(defaults: defaults, songsURL: songsURL)
        let songs = [
            Song(title: "One", relativePath: "One.mp3", fileExtension: "mp3", duration: 61),
            Song(
                title: "Two",
                relativePath: "Nested/Two.m4a",
                fileExtension: "m4a",
                duration: 122,
                cloudDownloadState: .notDownloaded
            )
        ]

        storage.playMode = .shuffle
        try storage.saveSongs(songs)

        let reloadedStorage = LibraryStorage(defaults: defaults, songsURL: songsURL)
        XCTAssertEqual(reloadedStorage.playMode, .shuffle)
        XCTAssertEqual(reloadedStorage.loadSongs(), songs)
    }

    func testStoragePersistsAndClampsAppVolume() {
        let songsURL = temporaryDirectory.appendingPathComponent("songs.json")
        var storage = LibraryStorage(defaults: defaults, songsURL: songsURL)

        XCTAssertEqual(storage.appVolume, 1)

        storage.appVolume = 0.035
        XCTAssertEqual(storage.appVolume, 0.035, accuracy: 0.000_001)

        storage.appVolume = -1
        XCTAssertEqual(storage.appVolume, 0)

        storage.appVolume = 2
        XCTAssertEqual(storage.appVolume, 1)

        storage.appVolume = .nan
        XCTAssertEqual(storage.appVolume, 1)
    }

    func testStoragePersistsFolderBookmarkAndDisplayName() throws {
        let songsURL = temporaryDirectory.appendingPathComponent("songs.json")
        let folderURL = temporaryDirectory.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let storage = LibraryStorage(defaults: defaults, songsURL: songsURL)
        try storage.saveFolderBookmark(for: folderURL)

        XCTAssertEqual(storage.folderName, "Music")
        XCTAssertEqual(storage.resolveFolderBookmark()?.lastPathComponent, "Music")
    }

    @MainActor
    func testRefreshKeepsCachedDurationsAndOrdersSameTitlesByPath() async throws {
        let folderURL = try makeMusicFolder(files: ["B/Same.flac", "A/Same.flac", "Solo.flac"])
        let storage = LibraryStorage(
            defaults: defaults,
            songsURL: temporaryDirectory.appendingPathComponent("songs.json")
        )
        try storage.saveFolderBookmark(for: folderURL)
        try storage.saveSongs([
            Song(title: "Same", relativePath: "A/Same.flac", fileExtension: "flac", duration: 111),
            Song(title: "Solo", relativePath: "Solo.flac", fileExtension: "flac", duration: 222)
        ])

        let store = PlayerStore(storage: storage)
        try await waitUntil { store.isRefreshing == false && store.isLoadingDurations == false }

        XCTAssertEqual(store.songs.map(\.id), ["A/Same.flac", "B/Same.flac", "Solo.flac"])
        XCTAssertEqual(store.songs.map(\.duration), [111, 0, 222])
        XCTAssertEqual(storage.loadSongs().map(\.duration), [111, 0, 222])
    }

    @MainActor
    func testRefreshOfUnreadableFolderKeepsCachedSongs() async throws {
        let folderURL = try makeMusicFolder(files: ["One.flac"])
        let storage = LibraryStorage(
            defaults: defaults,
            songsURL: temporaryDirectory.appendingPathComponent("songs.json")
        )
        try storage.saveFolderBookmark(for: folderURL)

        let store = PlayerStore(storage: storage)
        try await waitUntil { store.isRefreshing == false && store.isLoadingDurations == false }
        XCTAssertEqual(store.songs.map(\.id), ["One.flac"])

        try FileManager.default.removeItem(at: folderURL)
        store.alertMessage = nil
        store.refreshLibrary()
        try await waitUntil { store.isRefreshing == false }

        XCTAssertEqual(store.songs.map(\.id), ["One.flac"])
        XCTAssertEqual(storage.loadSongs().map(\.id), ["One.flac"])
        XCTAssertEqual(store.alertMessage?.hasPrefix("无法读取文件夹"), true)
    }

    @MainActor
    func testUnplayableAndMissingSongsAreSkippedThenPlaybackStops() async throws {
        let folderURL = try makeMusicFolder(files: ["One.flac", "Two.flac"])
        let storage = LibraryStorage(
            defaults: defaults,
            songsURL: temporaryDirectory.appendingPathComponent("songs.json")
        )
        try storage.saveFolderBookmark(for: folderURL)

        let store = PlayerStore(storage: storage)
        try await waitUntil { store.isRefreshing == false && store.isLoadingDurations == false }
        XCTAssertEqual(store.songs.map(\.id), ["One.flac", "Two.flac"])

        try FileManager.default.removeItem(at: folderURL.appendingPathComponent("Two.flac"))
        store.toggle(song: store.songs[0])
        try await waitUntil { store.activeSongID == "Two.flac" && store.isPlaying == false }

        XCTAssertEqual(store.alertMessage, "找不到歌曲文件：Two")

        // Every song has failed once, so nothing may restart playback afterwards.
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(store.activeSongID, "Two.flac")
        XCTAssertFalse(store.isPlaying)
    }

    private func makeMusicFolder(files: [String]) throws -> URL {
        let folderURL = temporaryDirectory.appendingPathComponent("Music", isDirectory: true)
        for file in files {
            let fileURL = folderURL.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("not audio".utf8).write(to: fileURL)
        }
        return folderURL
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while condition() == false {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
