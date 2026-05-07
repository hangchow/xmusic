import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var store = PlayerStore()
    @State private var isFolderPickerPresented = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                toolbar

                if store.songs.isEmpty {
                    emptyState
                } else {
                    songList
                }
            }
            .background(Color(.systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
            .fileImporter(
                isPresented: $isFolderPickerPresented,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        store.chooseFolder(url)
                    }
                case .failure(let error):
                    store.alertMessage = "无法打开文件夹：\(error.localizedDescription)"
                }
            }
            .alert(
                "XMusic",
                isPresented: Binding(
                    get: { store.alertMessage != nil },
                    set: { if $0 == false { store.alertMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(store.alertMessage ?? "")
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            IconButton(
                systemName: store.playMode.iconName,
                accessibilityLabel: store.playMode.title
            ) {
                store.playMode = store.playMode.next
            }

            IconButton(
                systemName: store.isPlaying ? "pause.fill" : "play.fill",
                accessibilityLabel: store.isPlaying ? "暂停" : "播放"
            ) {
                store.toggleMainPlayback()
            }

            IconButton(systemName: "backward.fill", accessibilityLabel: "上一首") {
                store.playPrevious()
            }

            IconButton(systemName: "forward.fill", accessibilityLabel: "下一首") {
                store.playNext()
            }

            IconButton(systemName: "arrow.clockwise", accessibilityLabel: "刷新清单") {
                store.refreshLibrary()
            }
            .disabled(store.isRefreshing)

            IconButton(systemName: "folder", accessibilityLabel: "选择 iCloud 文件夹") {
                isFolderPickerPresented = true
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(emptyStateTitle)
                .font(.headline)

            Text(emptyStateMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                isFolderPickerPresented = true
            } label: {
                Label("选择 iCloud 文件夹", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)

            if let folderName = store.folderName {
                Text("上次文件夹：\(folderName)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
        }
        .multilineTextAlignment(.center)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateTitle: String {
        if store.isRefreshing {
            return "正在扫描歌曲..."
        }
        if store.folderName != nil {
            return "未找到歌曲"
        }
        return "未选择歌曲文件夹"
    }

    private var emptyStateMessage: String {
        if store.isRefreshing {
            return "清单会先显示，歌曲时长随后补全。"
        }
        return "支持 FLAC、APE、ALAC、M4A、MP3。"
    }

    private var songList: some View {
        List(store.songs) { song in
            SongRow(song: song, store: store)
                .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
                .listRowBackground(Color(.secondarySystemGroupedBackground))
        }
        .listStyle(.plain)
        .safeAreaInset(edge: .bottom) {
            footer
        }
    }

    private var footer: some View {
        HStack {
            Label(store.folderName ?? "未选择文件夹", systemImage: "folder")
                .lineLimit(1)
            Spacer()
            Text(store.isLoadingDurations ? "读取时长..." : "\(store.songs.count) 首")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.regularMaterial)
    }
}

private struct SongRow: View {
    let song: Song
    @ObservedObject var store: PlayerStore

    private var isActive: Bool {
        store.activeSongID == song.id
    }

    private var elapsed: TimeInterval {
        store.elapsedTime(for: song)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                store.toggle(song: song)
            } label: {
                Image(systemName: isActive && store.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isActive && store.isPlaying ? "暂停 \(song.title)" : "播放 \(song.title)")

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(song.title)
                        .font(.body.weight(isActive ? .semibold : .regular))
                        .lineLimit(2)
                        .foregroundStyle(.primary)

                    cloudDownloadIndicator

                    Text(song.fileExtension.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 4))
                }

                Slider(
                    value: Binding(
                        get: { min(elapsed, max(song.duration, 0)) },
                        set: { store.seek(activeSong: song, to: $0) }
                    ),
                    in: 0...max(song.duration, 1),
                    step: 1
                )
                .disabled(isActive == false || song.cloudDownloadState != .local)
                .tint(isActive ? .accentColor : .secondary)

                HStack {
                    Text(elapsed.playerTimeText)
                    Spacer()
                    Text(song.duration.playerTimeText)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var cloudDownloadIndicator: some View {
        switch song.cloudDownloadState {
        case .local:
            EmptyView()
        case .notDownloaded:
            Image(systemName: "icloud.and.arrow.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityLabel("未下载")
        case .downloading:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("正在下载")
        }
    }
}

private struct IconButton: View {
    let systemName: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

#Preview {
    ContentView()
}
