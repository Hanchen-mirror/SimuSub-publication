import Foundation
import LlamaSwift

/// Converts the verified Gemma audio projector once for the bundled Metal backend.
/// The official BF16 source remains untouched; the derived FP16 file stays beside it.
enum GemmaAudioProjector {
    static func prepare(source: URL, sourceSHA256: String, derivedSHA256: String,
                        compatibleDerivedSHA256: String? = nil) throws -> URL {
        guard source.lastPathComponent.hasPrefix("gemma-4-"), source.lastPathComponent.hasSuffix("-it-mmproj.gguf") else {
            throw ServiceError.modelFilesMissing
        }
        let destination = source.deletingLastPathComponent().appendingPathComponent(
            source.lastPathComponent.replacingOccurrences(of: ".gguf", with: "-f16.gguf"))
        // Python GGUFWriter and native gguf serialize general.file_type at
        // different positions. Both audited files have identical tensor bytes.
        let accepted = Set([derivedSHA256, compatibleDerivedSHA256].compactMap { $0 })
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try accepted.contains(LocalModelStore.sha256(of: destination)) else {
                throw ModelStoreError.checksumFailed(destination.lastPathComponent)
            }
            return destination
        }
        guard try LocalModelStore.sha256(of: source) == sourceSHA256 else {
            throw ModelStoreError.checksumFailed(source.lastPathComponent)
        }
        let parameters = gguf_init_params(no_alloc: true, ctx: nil)
        guard let metadata = source.path.withCString({ gguf_init_from_file($0, parameters) }) else {
            throw LocalLlamaError.modelLoad
        }
        defer { gguf_free(metadata) }
        // Read into private memory, never modify a shared file mapping.
        var bytes = try Data(contentsOf: source)
        let dataOffset = gguf_get_data_offset(metadata)
        try bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { throw LocalLlamaError.modelLoad }
            var scratch = [Float](repeating: 0, count: 16_384)
            for index in 0..<gguf_get_n_tensors(metadata) {
                let type = gguf_get_tensor_type(metadata, index)
                guard type == GGML_TYPE_BF16 else { continue }
                let offset = dataOffset + gguf_get_tensor_offset(metadata, index)
                let size = gguf_get_tensor_size(metadata, index)
                guard offset <= raw.count, size <= raw.count - offset, size % 2 == 0 else {
                    throw LocalLlamaError.modelLoad
                }
                let values = base.advanced(by: offset)
                for start in stride(from: 0, to: size / 2, by: scratch.count) {
                    let count = min(scratch.count, size / 2 - start)
                    ggml_bf16_to_fp32_row(values.advanced(by: start * 2).assumingMemoryBound(to: ggml_bf16_t.self), &scratch, Int64(count))
                    ggml_fp32_to_fp16_row(scratch, values.advanced(by: start * 2).assumingMemoryBound(to: ggml_fp16_t.self), Int64(count))
                }
                gguf_set_tensor_type(metadata, gguf_get_tensor_name(metadata, index), GGML_TYPE_F16)
            }
            gguf_set_val_u32(metadata, "general.file_type", 1)
            guard gguf_get_meta_size(metadata) == dataOffset else { throw LocalLlamaError.modelLoad }
            gguf_get_meta_data(metadata, base)
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".gemma-projector-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try bytes.write(to: temporary, options: .atomic)
        let actualSHA256 = try LocalModelStore.sha256(of: temporary)
        guard accepted.contains(actualSHA256) else {
            throw ModelStoreError.checksumFailed(destination.lastPathComponent)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        try (actualSHA256 + "\n").write(toFile: destination.path + ".sha256", atomically: true, encoding: .utf8)
        return destination
    }
}
