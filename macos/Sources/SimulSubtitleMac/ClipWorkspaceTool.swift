import Foundation

enum ClipWorkspaceTool: String, CaseIterable, Identifiable {
    case importVideo, edit, highlights, subtitles
    var id: String { rawValue }
}
