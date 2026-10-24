import Foundation

/// User-facing categories only: tool stderr can contain paths, URLs or credentials.
enum ClipFailure {
    static func tool(_ detail: String, operation: String) -> ClipError {
        let text = detail.lowercased()
        let code: String, reason: String, action: String
        if text.contains("permission denied") || text.contains("operation not permitted") {
            code = "CLIP-PERMISSION"; reason = "没有读取素材或写入文件夹的权限"; action = "请检查文件权限，或选择可写入的导出文件夹。"
        } else if text.contains("no space left") || text.contains("disk quota") {
            code = "CLIP-DISK-FULL"; reason = "磁盘空间不足"; action = "请释放空间后重试，或更换导出文件夹。"
        } else if text.contains("no such file") {
            code = "CLIP-NOT-FOUND"; reason = "文件或文件夹已不存在"; action = "请重新定位素材或选择导出文件夹。"
        } else if text.contains("invalid data") || text.contains("moov atom") || text.contains("error while decoding") {
            code = "CLIP-MEDIA"; reason = "素材不完整、损坏或无法解码"; action = "请确认原文件可以播放，必要时重新录制或导入。"
        } else if text.contains("encoder") || text.contains("videotoolbox") || text.contains("pixel format") {
            code = "CLIP-ENCODER"; reason = "编码器无法处理当前素材"; action = "请尝试转为常见 H.264 MP4 后重新导入。"
        } else {
            code = "CLIP-TOOL"; reason = "媒体处理程序未能完成操作"; action = "请确认素材可播放、目标文件夹可写；重试仍失败时请提供此错误编号和操作步骤。"
        }
        return .message("\(operation)失败：\(reason)。原视频与已保存内容保留。\(action)［\(code)］")
    }

    static func message(_ error: Error, operation: String) -> String {
        if let error = error as? ClipError { return error.localizedDescription }
        if error is CancellationError { return "操作已取消，已保存内容保留。" }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return tool("no such file", operation: operation).localizedDescription
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return tool("permission denied", operation: operation).localizedDescription
            case NSFileWriteOutOfSpaceError:
                return tool("no space left", operation: operation).localizedDescription
            default: break
            }
        }
        if ns.domain == NSPOSIXErrorDomain {
            switch ns.code {
            case 1, 13: return tool("permission denied", operation: operation).localizedDescription
            case 2: return tool("no such file", operation: operation).localizedDescription
            case 28: return tool("no space left", operation: operation).localizedDescription
            default: break
            }
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain != ns.domain || underlying.code != ns.code {
            return message(underlying, operation: operation)
        }
        if error is LiveMonitorError || error is LocalLlamaError || error is ServiceError {
            // Existing service errors already carry a recovery instruction.
            return operation + "未完成：" + error.localizedDescription
        }
        return "\(operation)未完成，原视频与已保存内容保留。请检查文件权限或更换导出文件夹后重试。［CLIP-SYSTEM-\(ns.code)］"
    }
}
