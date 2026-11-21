import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

struct LocalModelDefinition: Codable, Identifiable, Sendable {
    struct File: Codable, Sendable {
        let name: String
        let url: URL
        let byteCount: Int64
        let sha256: String
    }
    let id: String
    let name: String
    let purpose: ServicePurpose
    let engine: String
    let homepage: URL
    let files: [File]
    var bytes: Int64 { files.reduce(0) { $0 + $1.byteCount } }
    static let catalog: [Self] = {
        guard let url = Bundle.main.url(forResource: "LocalModelCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url), let result = try? JSONDecoder().decode([Self].self, from: data) else { return [] }
        return result
    }()
}

@MainActor
final class LocalModelLibrary: ObservableObject {
    @Published private(set) var directory: URL
    @Published private(set) var downloadingID: String?
    @Published private(set) var progress = 0.0
    @Published var message = ""
    private var locations: [String: String]
    private var downloadTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private let downloadsAllowed: Bool
    private let bundledRoot: URL?
    var onChange: (() -> Void)?

    init(defaults: UserDefaults, defaultRoot: URL, bundledRoot: URL? = nil, downloadsAllowed: Bool = !AppLaunchOptions.isDiagnostic) {
        self.bundledRoot = bundledRoot
        self.defaults = defaults; self.downloadsAllowed = downloadsAllowed
        directory = defaults.string(forKey: "models.directory.v142").map { URL(fileURLWithPath: $0) } ?? defaultRoot
        locations = defaults.dictionary(forKey: "models.locations.v142") as? [String: String] ?? [:]
    }
    func userFolder(for model: LocalModelDefinition) -> URL {
        locations[model.id].map { URL(fileURLWithPath: $0) } ?? directory.appendingPathComponent(model.id)
    }

    private func isUnlinked(_ model: LocalModelDefinition, folder: URL) -> Bool {
        let unlinked = defaults.dictionary(forKey: "models.unlinkedFolders") as? [String: String]
        return unlinked?[model.id] == folder.standardizedFileURL.path
    }

    private func ready(_ model: LocalModelDefinition, in folder: URL, requireMarkers: Bool) -> Bool {
        model.files.allSatisfy { file in
            let url = folder.appendingPathComponent(file.name)
            guard FileManager.default.isReadableFile(atPath: url.path),
                  (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == file.byteCount
            else { return false }
            return !requireMarkers || (try? String(contentsOfFile: url.path + ".sha256", encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)) == file.sha256
        }
    }

    func folder(for model: LocalModelDefinition) -> URL {
        let user = userFolder(for: model)
        guard let bundled = bundledRoot?.appendingPathComponent(model.id) else { return user }
        if !isUnlinked(model, folder: user), ready(model, in: user, requireMarkers: !importedVerified.contains(model.id)) {
            return user
        }
        let managed = directory.appendingPathComponent(model.id)
        if managed.standardizedFileURL.path != user.standardizedFileURL.path, !isUnlinked(model, folder: managed),
           ready(model, in: managed, requireMarkers: true) { return managed }
        return ready(model, in: bundled, requireMarkers: true) ? bundled : user
    }

    func isImported(_ model: LocalModelDefinition) -> Bool {
        importedVerified.contains(model.id)
    }

    func unlink(_ model: LocalModelDefinition) {
        guard isImported(model) else { return }
        let previous = userFolder(for: model)
        locations.removeValue(forKey: model.id)
        defaults.set(locations, forKey: "models.locations.v142")
        importedVerified.remove(model.id)
        if previous.standardizedFileURL.path == userFolder(for: model).standardizedFileURL.path {
            // An explicitly imported folder may also be the normal download destination.
            var unlinked = defaults.dictionary(forKey: "models.unlinkedFolders") as? [String: String] ?? [:]
            unlinked[model.id] = previous.standardizedFileURL.path
            defaults.set(unlinked, forKey: "models.unlinkedFolders")
        }
        onChange?()
    }

    func isInstalled(_ model: LocalModelDefinition) -> Bool {
        let folder = folder(for: model)
        return !isUnlinked(model, folder: folder) && ready(model, in: folder, requireMarkers: true)
    }
    func setDirectory(_ url: URL) {
        // Changing the destination never moves, copies or removes installed files.
        guard !LocalModelStore.isInsideApplication(url) else { message = CocoaError(.fileWriteNoPermission).localizedDescription; return }
        directory = url.standardizedFileURL
        defaults.set(directory.path, forKey: "models.directory.v142"); onChange?()
    }
    func chooseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.directoryURL = directory; panel.prompt = L10n.text("选择")
        if panel.runModal() == .OK, let url = panel.url { setDirectory(url) }
    }
    func openDirectory(_ url: URL? = nil) {
        let target = url ?? directory
        do {
            if !FileManager.default.fileExists(atPath: target.path) {
                guard !LocalModelStore.isInsideApplication(target) else { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            }
            NSWorkspace.shared.open(target)
        } catch { message = error.localizedDescription }
    }
    func download(_ model: LocalModelDefinition) {
        guard downloadsAllowed, downloadingID == nil, !isUsable(model) else { return }
        downloadingID = model.id; progress = 0; message = ""
        downloadTask = Task {
            defer { downloadingID = nil; downloadTask = nil; onChange?() }
            do { try await install(model) }
            catch { message = error is CancellationError ? "下载已取消" : error.localizedDescription }
        }
    }
    func cancel() { downloadTask?.cancel() }

    func missingDownloadBytes(for model: LocalModelDefinition) throws -> Int64 {
        if isUsable(model) { return 0 }
        let destination = folder(for: model)
        if importedVerified.contains(model.id) { throw ServiceError.modelNotInstalled(model.name) }
        return try model.files.reduce(0) { count, file in
            let url = destination.appendingPathComponent(file.name)
            guard FileManager.default.fileExists(atPath: url.path) else { return count + file.byteCount }
            guard FileManager.default.isReadableFile(atPath: url.path),
                  (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == file.byteCount,
                  (try? String(contentsOfFile: url.path + ".sha256", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) == file.sha256 else {
                throw ModelStoreError.checksumFailed(file.name)
            }
            return count
        }
    }

    func install(_ model: LocalModelDefinition, onProgress: (@MainActor @Sendable (Double) -> Void)? = nil) async throws {
        if isUsable(model) { onProgress?(1); return }
        guard downloadsAllowed else { throw ClipError.message("诊断模式禁止下载模型。") }
        guard !importedVerified.contains(model.id) else { throw ServiceError.modelNotInstalled(model.name) }
        let destination = userFolder(for: model)
        guard !LocalModelStore.isInsideApplication(destination) else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var completed: Int64 = 0
        for file in model.files {
            try Task.checkCancellation()
            let target = destination.appendingPathComponent(file.name)
            guard !LocalModelStore.isInsideApplication(target),
                  !LocalModelStore.isInsideApplication(URL(fileURLWithPath: target.path + ".sha256"))
            else { throw CocoaError(.fileWriteNoPermission) }
            if FileManager.default.fileExists(atPath: target.path) {
                try await verify(file, at: target)
                // Existing model files and markers stay read only.
                guard (try? String(contentsOfFile: target.path + ".sha256", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) == file.sha256 else {
                    throw ClipError.message("已有模型缺少有效校验标记，请使用“导入已下载模型”验证。")
                }
            } else {
                let before = completed, total = model.bytes
                let temp = try await ModelDownloader().download(file.url) { [weak self] fraction in
                    Task { @MainActor in
                        let value = (Double(before) + fraction * Double(file.byteCount)) / Double(total)
                        self?.progress = value
                        onProgress?(value)
                    }
                }
                defer { try? FileManager.default.removeItem(at: temp) }
                try await verify(file, at: temp); try Task.checkCancellation()
                guard !FileManager.default.fileExists(atPath: target.path) else { throw ClipError.message("模型路径已被占用，已有文件未修改。") }
                try FileManager.default.moveItem(at: temp, to: target)
                try file.sha256.write(toFile: target.path + ".sha256", atomically: true, encoding: .utf8)
            }
            completed += file.byteCount; progress = Double(completed) / Double(model.bytes)
            onProgress?(progress)
        }
        remember(model, folder: destination)
    }
    func useExisting(_ model: LocalModelDefinition, folder: URL) async throws {
        for file in model.files { try await verify(file, at: folder.appendingPathComponent(file.name)) }
        // Only application-owned downloaded folders use markers. Imported folders
        // are verified once here and retain their files without added sidecars.
        remember(model, folder: folder)
        importedVerified.insert(model.id)
        defaults.set(Array(importedVerified), forKey: "models.importedVerified.v142")
        onChange?()
    }
    private var importedVerified: Set<String> {
        get { Set(defaults.stringArray(forKey: "models.importedVerified.v142") ?? []) }
        set { defaults.set(Array(newValue), forKey: "models.importedVerified.v142") }
    }
    func isUsable(_ model: LocalModelDefinition) -> Bool {
        let folder = folder(for: model)
        guard !isUnlinked(model, folder: folder) else { return false }
        let isExternal = importedVerified.contains(model.id) && folder.standardizedFileURL.path == userFolder(for: model).standardizedFileURL.path
        return ready(model, in: folder, requireMarkers: !isExternal)
    }
    func importFolder(_ model: LocalModelDefinition) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { do { try await useExisting(model, folder: folder) } catch { message = error.localizedDescription } }
    }
    private func remember(_ model: LocalModelDefinition, folder: URL) {
        if var unlinked = defaults.dictionary(forKey: "models.unlinkedFolders") as? [String: String] {
            unlinked.removeValue(forKey: model.id)
            defaults.set(unlinked, forKey: "models.unlinkedFolders")
        }
        locations[model.id] = folder.standardizedFileURL.path
        defaults.set(locations, forKey: "models.locations.v142"); onChange?()
    }
    func verifyReady(_ model: LocalModelDefinition) async throws {
        let folder = folder(for: model)
        for file in model.files { try await verify(file, at: folder.appendingPathComponent(file.name)) }
    }
    private func verify(_ file: LocalModelDefinition.File, at url: URL) async throws {
        try await Task.detached {
            guard FileManager.default.isReadableFile(atPath: url.path),
                  (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == file.byteCount,
                  try LocalModelStore.sha256(of: url) == file.sha256 else { throw ModelStoreError.checksumFailed(url.lastPathComponent) }
        }.value
    }
    nonisolated static func validateGGUF(_ url: URL) throws {
        guard url.pathExtension.lowercased() == "gguf", FileManager.default.isReadableFile(atPath: url.path) else {
            throw ClipError.message("请选择可读取的 GGUF 翻译模型。")
        }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        guard try handle.read(upToCount: 4) == Data("GGUF".utf8) else { throw ClipError.message("文件不是有效的 GGUF 模型。") }
    }
}

enum AppLaunchOptions {
    static func isDiagnostic(_ arguments: [String]) -> Bool {
        arguments.contains { value in
            value.hasPrefix("--") && (value.hasSuffix("-check") || value.hasSuffix("-test") || value.hasSuffix("-benchmark")
                || value.hasPrefix("--theme-") || ["--clip-demo", "--original-mode-preview", "--preview-subtitle-layout", "--permission-report", "--download-test-models", "--install-local-models"].contains(value))
        }
    }
    static var isDiagnostic: Bool { isDiagnostic(CommandLine.arguments) }
}
