import AVFoundation
import Foundation
import MediaPlayer
import SwiftUI
import UIKit

@MainActor
final class PlayerStore: ObservableObject {
    @Published private(set) var songs: [Song]
    @Published private(set) var activeSongID: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var folderName: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLoadingDurations = false
    @Published var playMode: PlayMode {
        didSet {
            storage.playMode = playMode
        }
    }
    @Published var alertMessage: String?

    let supportedExtensions = ["flac", "ape", "alac", "m4a", "mp3"]

    private var storage: LibraryStorage
    private var folderURL: URL?
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endedObserver: NSObjectProtocol?
    private var securityScopedURL: URL?
    private var refreshID = UUID()
    private var nowPlayingArtwork: MPMediaItemArtwork?

    init(storage: LibraryStorage = LibraryStorage()) {
        self.storage = storage
        self.songs = storage.loadSongs()
        self.playMode = storage.playMode
        self.folderName = storage.folderName

        if let url = storage.resolveFolderBookmark() {
            setFolderURL(url)
        }

        configureAudioSession()
        configureRemoteCommands()
    }

    deinit {
        MPRemoteCommandCenter.shared().playCommand.removeTarget(nil)
        MPRemoteCommandCenter.shared().pauseCommand.removeTarget(nil)
        MPRemoteCommandCenter.shared().togglePlayPauseCommand.removeTarget(nil)
        MPRemoteCommandCenter.shared().stopCommand.removeTarget(nil)
        MPRemoteCommandCenter.shared().previousTrackCommand.removeTarget(nil)
        MPRemoteCommandCenter.shared().nextTrackCommand.removeTarget(nil)
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.removeTarget(nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        if let endedObserver {
            NotificationCenter.default.removeObserver(endedObserver)
        }
        securityScopedURL?.stopAccessingSecurityScopedResource()
    }

    var activeSong: Song? {
        guard let activeSongID else {
            return nil
        }
        return songs.first { $0.id == activeSongID }
    }

    func chooseFolder(_ url: URL) {
        setFolderURL(url)
        do {
            try storage.saveFolderBookmark(for: url)
            refreshLibrary()
        } catch {
            alertMessage = "无法保存文件夹权限：\(error.localizedDescription)"
        }
    }

    func refreshLibrary() {
        guard let folderURL else {
            alertMessage = "请先选择 iCloud 音乐文件夹"
            return
        }

        let currentRefreshID = UUID()
        refreshID = currentRefreshID
        isRefreshing = true
        let supportedExtensions = Set(supportedExtensions)

        Task {
            let scannedSongs = await Task.detached(priority: .userInitiated) {
                Self.scanSongs(in: folderURL, supportedExtensions: supportedExtensions)
            }.value

            guard self.refreshID == currentRefreshID else {
                return
            }

            let sortedSongs = scannedSongs.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            self.songs = sortedSongs
            self.isRefreshing = false

            do {
                try self.storage.saveSongs(self.songs)
            } catch {
                self.alertMessage = "无法保存歌曲清单：\(error.localizedDescription)"
            }

            if sortedSongs.isEmpty {
                self.alertMessage = "未找到支持的歌曲文件。请确认文件夹内包含 FLAC、APE、ALAC、M4A 或 MP3。"
            }

            if let activeSongID, self.songs.contains(where: { $0.id == activeSongID }) == false {
                self.stop()
            }

            self.loadDurations(for: sortedSongs, refreshID: currentRefreshID)
        }
    }

    func toggleMainPlayback() {
        if player == nil {
            play(song: activeSong ?? songs.first)
            return
        }

        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func toggle(song: Song) {
        if activeSongID == song.id {
            isPlaying ? pause() : play()
        } else {
            play(song: song)
        }
    }

    func playPrevious() {
        play(song: neighborSong(step: -1))
    }

    func playNext() {
        play(song: neighborSong(step: 1))
    }

    func seek(activeSong song: Song, to seconds: TimeInterval) {
        guard activeSongID == song.id else {
            return
        }

        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = max(0, seconds)
        updateNowPlayingInfo()
    }

    func elapsedTime(for song: Song) -> TimeInterval {
        activeSongID == song.id ? currentTime : 0
    }

    private func play(song: Song?) {
        guard let song else {
            alertMessage = "歌曲清单为空，请选择文件夹或刷新"
            return
        }

        guard let url = resolvedURL(for: song) else {
            alertMessage = "找不到歌曲文件：\(song.title)"
            return
        }

        replacePlayer(with: url)
        activeSongID = song.id
        currentTime = 0
        updateNowPlayingInfo()
        play()
    }

    private func play() {
        player?.play()
        isPlaying = player != nil
        updateNowPlayingPlaybackState()
    }

    private func playFromRemoteCommand() {
        if player == nil {
            play(song: activeSong ?? songs.first)
        } else if isPlaying == false {
            play()
        }
    }

    private func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlayingPlaybackState()
    }

    private func stop() {
        player?.pause()
        player = nil
        activeSongID = nil
        currentTime = 0
        isPlaying = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func handleSongEnded() {
        switch playMode {
        case .singleLoop:
            player?.seek(to: .zero)
            player?.play()
        case .listLoop, .shuffle:
            playNext()
        }
    }

    private func replacePlayer(with url: URL) {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        if let endedObserver {
            NotificationCenter.default.removeObserver(endedObserver)
        }

        let item = AVPlayerItem(url: url)
        let nextPlayer = AVPlayer(playerItem: item)
        nextPlayer.actionAtItemEnd = .pause

        timeObserver = nextPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.35, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.currentTime = max(0, time.seconds)
                self?.updateNowPlayingElapsedTime()
            }
        }

        endedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSongEnded()
            }
        }

        player = nextPlayer
    }

    private func neighborSong(step: Int) -> Song? {
        guard songs.isEmpty == false else {
            return nil
        }

        if playMode == .shuffle, step > 0 {
            if songs.count == 1 {
                return songs[0]
            }
            let candidates = songs.filter { $0.id != activeSongID }
            return candidates.randomElement()
        }

        guard
            let activeSongID,
            let index = songs.firstIndex(where: { $0.id == activeSongID })
        else {
            return songs.first
        }

        let nextIndex = (index + step + songs.count) % songs.count
        return songs[nextIndex]
    }

    private func setFolderURL(_ url: URL) {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        if url.startAccessingSecurityScopedResource() {
            securityScopedURL = url
        } else {
            securityScopedURL = nil
        }
        folderURL = url
        folderName = url.lastPathComponent
        storage.folderName = url.lastPathComponent
    }

    private func loadDurations(for songs: [Song], refreshID: UUID) {
        guard songs.isEmpty == false else {
            return
        }

        isLoadingDurations = true

        Task {
            for song in songs {
                guard self.refreshID == refreshID else {
                    self.isLoadingDurations = false
                    return
                }

                guard let url = self.resolvedURL(for: song) else {
                    continue
                }

                let duration = await Task.detached(priority: .utility) {
                    await Self.duration(for: url)
                }.value

                guard self.refreshID == refreshID else {
                    self.isLoadingDurations = false
                    return
                }

                if let index = self.songs.firstIndex(where: { $0.id == song.id }) {
                    self.songs[index].duration = duration
                    if self.activeSongID == song.id {
                        self.updateNowPlayingInfo()
                    }
                }
            }

            self.isLoadingDurations = false
            do {
                try self.storage.saveSongs(self.songs)
            } catch {
                self.alertMessage = "无法保存歌曲时长：\(error.localizedDescription)"
            }
        }
    }

    private nonisolated static func scanSongs(in folderURL: URL, supportedExtensions: Set<String>) -> [Song] {
        let didStartAccessing = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        requestDownloadIfNeeded(for: folderURL)

        return scanAudioFiles(in: folderURL, supportedExtensions: supportedExtensions).map { url in
            Song(
                title: url.deletingPathExtension().lastPathComponent,
                relativePath: relativePath(for: url, folderURL: folderURL),
                fileExtension: url.pathExtension.lowercased(),
                duration: 0
            )
        }
    }

    private nonisolated static func scanAudioFiles(in folderURL: URL, supportedExtensions: Set<String>) -> [URL] {
        var coordinatedFiles: [URL] = []
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: folderURL, options: [], error: &coordinationError) { coordinatedURL in
            coordinatedFiles = scanAudioFilesWithoutCoordination(
                in: coordinatedURL,
                supportedExtensions: supportedExtensions
            )
        }

        if coordinatedFiles.isEmpty == false || coordinationError == nil {
            return coordinatedFiles
        }

        return scanAudioFilesWithoutCoordination(in: folderURL, supportedExtensions: supportedExtensions)
    }

    private nonisolated static func scanAudioFilesWithoutCoordination(
        in folderURL: URL,
        supportedExtensions: Set<String>
    ) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator.compactMap { item in
            guard let url = item as? URL else {
                return nil
            }

            let ext = url.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else {
                return nil
            }

            let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard resourceValues?.isDirectory != true else {
                return nil
            }

            requestDownloadIfNeeded(for: url)
            return url
        }
    }

    private nonisolated static func requestDownloadIfNeeded(for url: URL) {
        let resourceValues = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ])

        guard resourceValues?.isUbiquitousItem == true else {
            return
        }

        if resourceValues?.ubiquitousItemDownloadingStatus != .current {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
    }

    private nonisolated static func duration(for url: URL) async -> TimeInterval {
        await withTaskGroup(of: TimeInterval.self) { group in
            group.addTask {
                await loadDuration(for: url)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                return 0
            }

            let result = await group.next() ?? 0
            group.cancelAll()
            return result
        }
    }

    private nonisolated static func loadDuration(for url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else {
            return 0
        }
        let seconds = duration.seconds
        return seconds.isFinite ? max(0, seconds) : 0
    }

    private nonisolated static func relativePath(for url: URL, folderURL: URL) -> String {
        let folderPath = folderURL.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(folderPath) else {
            return url.lastPathComponent
        }

        return String(filePath.dropFirst(folderPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func resolvedURL(for song: Song) -> URL? {
        folderURL?.appendingPathComponent(song.relativePath)
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            alertMessage = "无法启用后台播放会话：\(error.localizedDescription)"
        }
    }

    private func configureRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.playFromRemoteCommand()
            }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.pause()
            }
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.toggleMainPlayback()
            }
            return .success
        }

        commandCenter.stopCommand.isEnabled = true
        commandCenter.stopCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.stop()
            }
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.playPrevious()
            }
            return .success
        }

        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.playNext()
            }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }

            Task { @MainActor in
                guard let self, let song = self.activeSong else {
                    return
                }
                self.seek(activeSong: song, to: event.positionTime)
            }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let activeSong else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: activeSong.title,
            MPMediaItemPropertyArtist: folderName ?? "XMusic",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]

        if activeSong.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = activeSong.duration
        }

        if let artwork = lockScreenArtwork() {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        updateNowPlayingPlaybackState()
    }

    private func updateNowPlayingPlaybackState() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else {
            return
        }

        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        if #available(iOS 13.0, *) {
            MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        }
    }

    private func updateNowPlayingElapsedTime() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else {
            return
        }

        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func lockScreenArtwork() -> MPMediaItemArtwork? {
        if let nowPlayingArtwork {
            return nowPlayingArtwork
        }

        guard let image = UIImage(named: "LockScreenArtwork") else {
            return nil
        }

        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        nowPlayingArtwork = artwork
        return artwork
    }
}
