import Foundation

enum PlayMode: String, CaseIterable, Codable {
    case listLoop
    case singleLoop
    case shuffle

    var title: String {
        switch self {
        case .listLoop:
            return "列表循环"
        case .singleLoop:
            return "单曲循环"
        case .shuffle:
            return "随机循环"
        }
    }

    var iconName: String {
        switch self {
        case .listLoop:
            return "repeat"
        case .singleLoop:
            return "repeat.1"
        case .shuffle:
            return "shuffle"
        }
    }

    var next: PlayMode {
        switch self {
        case .listLoop:
            return .singleLoop
        case .singleLoop:
            return .shuffle
        case .shuffle:
            return .listLoop
        }
    }
}

enum CloudDownloadState: String, Codable, Equatable {
    case local
    case notDownloaded
    case downloading
}

struct Song: Identifiable, Codable, Equatable {
    var id: String { relativePath }
    let title: String
    let relativePath: String
    let fileExtension: String
    var duration: TimeInterval
    var cloudDownloadState: CloudDownloadState

    init(
        title: String,
        relativePath: String,
        fileExtension: String,
        duration: TimeInterval = 0,
        cloudDownloadState: CloudDownloadState = .local
    ) {
        self.title = title
        self.relativePath = relativePath
        self.fileExtension = fileExtension
        self.duration = duration
        self.cloudDownloadState = cloudDownloadState
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case relativePath
        case fileExtension
        case duration
        case cloudDownloadState
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        fileExtension = try container.decode(String.self, forKey: .fileExtension)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        cloudDownloadState = try container.decodeIfPresent(
            CloudDownloadState.self,
            forKey: .cloudDownloadState
        ) ?? .local
    }
}

extension TimeInterval {
    var playerTimeText: String {
        guard isFinite, self > 0 else {
            return "0:00"
        }

        let seconds = Int(self.rounded())
        let hours = seconds / 3600
        let minutes = seconds % 3600 / 60
        let remainder = seconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }

        return String(format: "%d:%02d", minutes, remainder)
    }
}
