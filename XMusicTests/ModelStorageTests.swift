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

    func testStoragePersistsPlayModeAndSongs() throws {
        let songsURL = temporaryDirectory.appendingPathComponent("songs.json")
        var storage = LibraryStorage(defaults: defaults, songsURL: songsURL)
        let songs = [
            Song(title: "One", relativePath: "One.mp3", fileExtension: "mp3", duration: 61),
            Song(title: "Two", relativePath: "Nested/Two.m4a", fileExtension: "m4a", duration: 122)
        ]

        storage.playMode = .shuffle
        try storage.saveSongs(songs)

        let reloadedStorage = LibraryStorage(defaults: defaults, songsURL: songsURL)
        XCTAssertEqual(reloadedStorage.playMode, .shuffle)
        XCTAssertEqual(reloadedStorage.loadSongs(), songs)
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
}
