import Foundation

enum WAVEncoder {
    static func wav(samples: [Float], sampleRate: UInt32) -> Data {
        var data = Data()
        let bytes = samples.count * MemoryLayout<Int16>.size
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + bytes), to: &data)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data) // PCM
        append(UInt16(1), to: &data) // mono
        append(sampleRate, to: &data)
        append(sampleRate * 2, to: &data)
        append(UInt16(2), to: &data)
        append(UInt16(16), to: &data)
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(bytes), to: &data)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            append(Int16(clamped * Float(Int16.max)), to: &data)
        }
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
