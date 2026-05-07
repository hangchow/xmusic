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

struct Song: Identifiable, Codable, Equatable {
    var id: String { relativePath }
    let title: String
    let relativePath: String
    let fileExtension: String
    var duration: TimeInterval

    init(
        title: String,
        relativePath: String,
        fileExtension: String,
        duration: TimeInterval = 0
    ) {
        self.title = title
        self.relativePath = relativePath
        self.fileExtension = fileExtension
        self.duration = duration
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
