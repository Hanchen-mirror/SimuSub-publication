import CryptoKit
import Foundation
import SherpaOnnx

struct ASRModelFile: Hashable {
    let relativePath: String
    let url: URL
    let byteCount: Int64
    let sha256: String
}

final class LocalModelStore: @unchecked Sendable {
    let root: URL
    let bundledRoot: URL?
    static var applicationModels: URL? { Bundle.main.sharedSupportURL?.appendingPathComponent("Models") }

    static func isInsideApplication(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let app = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        return path == app || path.hasPrefix(app + "/")
    }

    private let files: [ASRModelFile]
    private let translationModel: ASRModelFile

    init(root: URL? = nil, bundledRoot: URL? = nil) {
        self.bundledRoot = bundledRoot ?? (root == nil ? Self.applicationModels : nil)
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SimulSubtitle/models")
        let base = "https://huggingface.co/csukuangfj/reazonspeech-k2-v2/resolve/c273a8666b943526a37e6facb1f9c2cf6739d710"
        self.files = [
            ASRModelFile(relativePath: "asr-ja/encoder.int8.onnx", url: URL(string: "\(base)/encoder-epoch-99-avg-1.int8.onnx")!, byteCount: 154_670_139, sha256: "2c7bd08a8a99f9ddd0d9e458456577b1f6279214e51426f114f9eced44c54e1d"),
            ASRModelFile(relativePath: "asr-ja/decoder.onnx", url: URL(string: "\(base)/decoder-epoch-99-avg-1.onnx")!, byteCount: 11_767_836, sha256: "58b18211ae06265466bfa17172dab574df94f76c8bcb61a3640c28ba860e4124"),
            ASRModelFile(relativePath: "asr-ja/joiner.int8.onnx", url: URL(string: "\(base)/joiner-epoch-99-avg-1.int8.onnx")!, byteCount: 2_696_970, sha256: "49cc7ea1d3d35a40a27442db5e89996da64bf0e683a903dce76e99e57a12e4de"),
            ASRModelFile(relativePath: "asr-ja/tokens.txt", url: URL(string: "\(base)/tokens.txt")!, byteCount: 45_754, sha256: "2c3ac659818a48a0c04010e0593bbc4d7c8a24a054340b01131499c05fd52def")
        ]
        translationModel = ASRModelFile(
            relativePath: "mt/index-translate-2b.gguf",
            url: URL(string: "https://huggingface.co/IndexTeam/Index-Translate-2B-GGUF/resolve/449c9e6457b3632d328c6cbb78ae8e8e0c8059a5/Index-Translate-2B.Q4_K_M.gguf")!,
            byteCount: 1_312_164_352,
            sha256: "044b313d29342bd3b2c77cbb64023ca0d209bd9b3247763f9d162767ef2d746a"
        )
    }

    var managedSpeechFiles: ManagedModelFiles {
        ManagedModelFiles(folder: root.appendingPathComponent("asr-ja"),
                          filenames: files.map { URL(fileURLWithPath: $0.relativePath).lastPathComponent })
    }

    var asrDownloadBytes: Int64 { files.reduce(0) { $0 + $1.byteCount } }
    var translationDownloadBytes: Int64 { translationModel.byteCount }

    private func readableRoot(for requested: [ASRModelFile]) -> URL {
        if let bundledRoot, !requested.allSatisfy({ matches($0, in: root) }),
           requested.allSatisfy({ matches($0, in: bundledRoot) }) { return bundledRoot }
        return root
    }

    var speechFolder: URL { readableRoot(for: files).appendingPathComponent("asr-ja") }
    var isASRInstalled: Bool {
        let location = readableRoot(for: files)
        return files.allSatisfy { matches($0, in: location) }
    }
    var isTranslationInstalled: Bool { matches(translationModel, in: readableRoot(for: [translationModel])) }
    var translationModelPath: String { readableRoot(for: [translationModel]).appending(path: translationModel.relativePath).path }

    func missingDownloadBytes(for purpose: ServicePurpose) throws -> Int64 {
        let requested = purpose == .speechRecognition ? files : [translationModel]
        let location = readableRoot(for: requested)
        return try requested.reduce(0) { count, file in
            let path = location.appending(path: file.relativePath).path
            guard FileManager.default.fileExists(atPath: path) else { return count + file.byteCount }
            guard FileManager.default.isReadableFile(atPath: path), matches(file, in: location) else {
                throw ModelStoreError.checksumFailed(file.relativePath)
            }
            return count
        }
    }

    func path(_ relative: String) -> String {
        let location = relative.hasPrefix("asr-ja/") ? readableRoot(for: files) : root
        return location.appending(path: relative).path
    }

    typealias Progress = @Sendable (Double, String) -> Void

    func downloadASR(control: ModelDownloadControl? = nil, progress: @escaping Progress = { _, _ in }) async throws {
        try await download(files, control: control, progress: progress)
    }

    func downloadTranslation(control: ModelDownloadControl? = nil, progress: @escaping Progress = { _, _ in }) async throws {
        try await download([translationModel], control: control, progress: progress)
    }

    /// Read-only verification: existing models and their markers are never rewritten.
    func verifyInstalled(for purpose: ServicePurpose) async throws -> Bool {
        let requested = purpose == .speechRecognition ? files : [translationModel]
        return try await Task.detached { [self] in
            let location = readableRoot(for: requested)
            var complete = true
            for file in requested {
                let url = location.appending(path: file.relativePath)
                guard FileManager.default.fileExists(atPath: url.path) else { complete = false; continue }
                guard matches(file, in: location), FileManager.default.isReadableFile(atPath: url.path),
                      let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      Int64(size) == file.byteCount, try Self.sha256(of: url) == file.sha256 else {
                    throw ModelStoreError.checksumFailed(file.relativePath)
                }
            }
            return complete
        }.value
    }

    private func download(_ requested: [ASRModelFile], control: ModelDownloadControl?, progress: @escaping Progress) async throws {
        let location = readableRoot(for: requested)
        if requested.allSatisfy({ matches($0, in: location) }) { return }
        let total = requested.reduce(Int64(0)) { $0 + $1.byteCount }
        var completed: Int64 = 0
        for file in requested {
            try Task.checkCancellation()
            if matches(file, in: root) { completed += file.byteCount; continue }
            let destination = root.appending(path: file.relativePath)
            guard !Self.isInsideApplication(destination) else { throw CocoaError(.fileWriteNoPermission) }
            // Never overwrite an existing model, including one with an invalid marker.
            if FileManager.default.fileExists(atPath: destination.path) {
                throw ModelStoreError.checksumFailed(file.relativePath)
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let before = completed
            let downloader = ModelDownloader()
            control?.attach(downloader)
            let temporary = try await downloader.download(file.url) { fraction in
                progress((Double(before) + fraction * Double(file.byteCount)) / Double(total), "正在下载 \(file.relativePath)")
            }
            defer { try? FileManager.default.removeItem(at: temporary) }
            progress(Double(completed + file.byteCount) / Double(total), "正在校验 \(file.relativePath)…")
            try await Task.detached {
                let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
                guard Int64(size) == file.byteCount, try Self.sha256(of: temporary) == file.sha256 else {
                    throw ModelStoreError.checksumFailed(file.relativePath)
                }
            }.value
            try Task.checkCancellation()
            // Another process may have installed it while this request was in flight.
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                if matches(file, in: root) { completed += file.byteCount; continue }
                throw ModelStoreError.checksumFailed(file.relativePath)
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
            try file.sha256.write(to: URL(fileURLWithPath: destination.path + ".sha256"), atomically: true, encoding: .utf8)
            completed += file.byteCount
            progress(Double(completed) / Double(total), "已安装 \(file.relativePath)")
        }
    }

    func importModels(from folder: URL) async throws {
        let all = files + [translationModel]
        let root = root
        try await Task.detached {
            var count = 0
            for file in all {
                let source = folder.appending(path: file.relativePath)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                guard try Self.sha256(of: source) == file.sha256 else { throw ModelStoreError.checksumFailed(file.relativePath) }
                let destination = root.appending(path: file.relativePath)
                guard !Self.isInsideApplication(destination), !Self.isInsideApplication(URL(fileURLWithPath: destination.path + ".sha256"))
                else { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if source.standardizedFileURL != destination.standardizedFileURL {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.copyItem(at: source, to: destination)
                }
                try file.sha256.write(to: URL(fileURLWithPath: destination.path + ".sha256"), atomically: true, encoding: .utf8)
                count += 1
            }
            if count == 0 { throw ModelStoreError.downloadFailed("该目录没有 asr-ja/ 或 mt/ 模型文件") }
        }.value
    }

    private func matches(_ file: ASRModelFile, in location: URL) -> Bool {
        let url = location.appending(path: file.relativePath)
        let marker = URL(fileURLWithPath: url.path + ".sha256")
        guard FileManager.default.isReadableFile(atPath: url.path),
              let saved = try? String(contentsOf: marker, encoding: .utf8),
              saved.trimmingCharacters(in: .whitespacesAndNewlines) == file.sha256,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return false }
        return Int64(size) == file.byteCount
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

final class ReazonSpeechRecognizer: JapaneseWindowRecognizing, @unchecked Sendable {
    private let recognizer: SherpaOnnxOfflineRecognizer
    private let decodeLock = NSLock()
    let hotwordPlan: ASRHotwordPlan
    private var hotwordFile: URL?

    init(store: LocalModelStore, threads: Int = 4, decoding: String = "greedy_search", hotwords: [String] = [], hotwordScore: Float = 1.0) throws {
        let encoder = store.path("asr-ja/encoder.int8.onnx")
        let decoder = store.path("asr-ja/decoder.onnx")
        let joiner = store.path("asr-ja/joiner.int8.onnx")
        let tokens = store.path("asr-ja/tokens.txt")
        guard [encoder, decoder, joiner, tokens].allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else {
            throw ServiceError.modelFilesMissing
        }
        hotwordPlan = ASRHotwordPlan(words: hotwords, tokenTable: try String(contentsOfFile: tokens, encoding: .utf8))
        guard ["greedy_search", "modified_beam_search"].contains(decoding), hotwordScore.isFinite, (0...3).contains(hotwordScore) else {
            throw ClipError.message("识别解码配置无效。")
        }
        if !hotwordPlan.accepted.isEmpty {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("simusub-hotwords-\(UUID().uuidString).txt")
            try hotwordPlan.accepted.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            hotwordFile = url
        }
        let transducer = sherpaOnnxOfflineTransducerModelConfig(encoder: encoder, decoder: decoder, joiner: joiner)
        let model = sherpaOnnxOfflineModelConfig(tokens: tokens, transducer: transducer, numThreads: threads, provider: "cpu", modelType: "transducer")
        let feature = sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80)
        var config = sherpaOnnxOfflineRecognizerConfig(featConfig: feature, modelConfig: model, decodingMethod: hotwordPlan.accepted.isEmpty ? decoding : "modified_beam_search", hotwordsFile: hotwordFile?.path ?? "", hotwordsScore: hotwordScore)
        recognizer = withUnsafePointer(to: &config) { SherpaOnnxOfflineRecognizer(config: $0) }
    }

    deinit { if let hotwordFile { try? FileManager.default.removeItem(at: hotwordFile) } }

    func recognize(samples: [Float]) async throws -> String {
        try await recognizeDetailed(samples: samples).text
    }

    func recognizeDetailed(samples: [Float]) async throws -> RecognizedSpeech {
        guard !samples.isEmpty else { return RecognizedSpeech(text: "") }
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) { [self] in
          try decodeLock.withLock {
            try Task.checkCancellation()
            var padded = [Float](repeating: 0, count: 4_800)
            padded.append(contentsOf: samples)
            padded.append(contentsOf: repeatElement(0, count: 4_800))
            let result = recognizer.decode(samples: padded, sampleRate: 16_000)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var tokens: [RecognizedSpeech.Token] = []
            if let pointers = result.result.pointee.tokens_arr, result.timestamps.count == result.count {
                for i in 0..<result.count {
                    guard let pointer = pointers[i] else { tokens = []; break }
                    let token = String(cString: pointer).replacingOccurrences(of: "▁", with: " ")
                    tokens.append(.init(text: token, time: max(0, Double(result.timestamps[i]) - 0.3)))
                }
            }
            // Do not invent offsets when token reconstruction differs from text.
            if tokens.map(\.text).joined() != text { tokens = [] }
            try Task.checkCancellation()
            return RecognizedSpeech(text: text, tokens: tokens)
          }
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}

enum ModelStoreError: Error, LocalizedError {
    case downloadFailed(String)
    case checksumFailed(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let path): "模型下载失败：\(path)"
        case .checksumFailed(let path): "模型校验失败：\(path)。已有文件未修改，请检查模型路径。"
        }
    }
}
