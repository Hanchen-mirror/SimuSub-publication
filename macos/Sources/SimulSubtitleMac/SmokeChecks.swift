import Foundation
import AVFoundation
import CoreMedia

private final class SmokeURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    override func stopLoading() { }
}

final class SmokeOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    func setFailure(_ failure: String) { lock.lock(); stored = failure; lock.unlock() }
    var failure: String? { lock.lock(); defer { lock.unlock() }; return stored }
}

enum SmokeChecks {
    static func run() async throws {
        try checkCapturedPCM()
        precondition("字幕をテストしています".containsJapaneseScript)
        precondition(!"Hello world".containsJapaneseScript)
        let japanese = AppModel.removingOverlap("字幕をテストしています", previous: "今日は日本語の字幕を")
        precondition(japanese == "テストしています")
        let english = AppModel.removingOverlap("the subtitle test is running", previous: "This is the subtitle test")
        precondition(english == "is running")
        let repeated = AppModel.removingOverlap("はい", previous: "はい")
        precondition(repeated == "はい")
        let wav = WAVEncoder.wav(samples: [0, 0.5, -0.5], sampleRate: 16_000)
        precondition(String(data: wav.prefix(4), encoding: .ascii) == "RIFF")
        precondition(String(data: wav[8..<12], encoding: .ascii) == "WAVE")
        precondition(wav.count == 50 && wav[40..<44] == Data([6, 0, 0, 0]))

        precondition("自动（日语 / 英语）".asrLanguageCode == nil)
        precondition("英语".asrLanguageCode == "en")
        precondition("日语".asrLanguageCode == "ja")
        precondition("中文".asrLanguageCode == "zh")
        let session = makeSession()
        SmokeURLProtocol.handler = { request in
            precondition(request.httpMethod == "POST")
            precondition(request.url?.path == "/v1/audio/transcriptions")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            let body = requestBody(request)
            precondition(body.range(of: Data("name=\"model\"".utf8)) != nil)
            precondition(body.range(of: Data("name=\"language\"".utf8)) != nil)
            precondition(body.range(of: Data("whisper-1".utf8)) != nil)
            precondition(body.range(of: Data("filename=\"speech.wav\"".utf8)) != nil)
            return (response(for: request), Data("{\"text\":\" hello \"}".utf8))
        }
        let asr = ServiceProfile(name: "Smoke ASR", kind: .openAICompatible, purpose: .speechRecognition,
                                 baseURL: "https://unit.test/v1", model: "whisper-1")
        let transcript = try await OpenAICompatibleSpeechRecognizer(profile: asr, apiKey: "test-key", session: session)
            .recognize(samples: [0, 0.25])
        precondition(transcript == "hello")

        SmokeURLProtocol.handler = { request in
            precondition(request.url?.path == "/v1/chat/completions")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
            precondition(body["model"] as? String == "deepseek-chat")
            return (response(for: request), Data("{\"choices\":[{\"message\":{\"content\":\"你好\"}}]}".utf8))
        }
        let mt = ServiceProfile(name: "Smoke MT", kind: .openAICompatible, purpose: .translation,
                                baseURL: "https://unit.test/v1", model: "deepseek-chat")
        let translated = try await OpenAICompatibleTranslator(profile: mt, apiKey: "test-key", session: session)
            .translate("こんにちは", from: "Japanese", to: "Chinese")
        precondition(translated == "你好")
        SmokeURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data("Unauthorized".utf8))
        }
        do {
            _ = try await OpenAICompatibleTranslator(profile: mt, apiKey: "test-key", session: session).translate("Hello", from: "English", to: "中文")
            throw URLError(.unknown)
        } catch ServiceError.http(let status, _) { precondition(status == 401) }
        SmokeURLProtocol.handler = nil
        print("WAV, automatic language, cloud transcription, translation, HTTP 401 checks passed")
    }

    private static func checkCapturedPCM() throws {
        let mono: [Float] = [0, 0.25, -0.5, 0.75]
        let monoBytes = mono.withUnsafeBufferPointer { Data(buffer: $0) }
        let floatFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let monoBuffer = try capturedBuffer(bytes: monoBytes, format: floatFormat, frames: mono.count)
        guard AudioCaptureEngine.floatSamples(monoBuffer) == mono else { throw ServiceError.invalidResponse }
        let stereo: [Int16] = [16_000, 8_000, -16_000, -8_000]
        let stereoBytes = stereo.withUnsafeBufferPointer { Data(buffer: $0) }
        let intFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 2, interleaved: true)!
        let stereoBuffer = try capturedBuffer(bytes: stereoBytes, format: intFormat, frames: 2)
        guard let decoded = AudioCaptureEngine.floatSamples(stereoBuffer), decoded.count == 2,
              abs(decoded[0] - Float(12_000) / Float(Int16.max)) < 0.00001,
              abs(decoded[1] + Float(12_000) / Float(Int16.max)) < 0.00001 else { throw ServiceError.invalidResponse }
        print("ScreenCaptureKit PCM destination length, float mono and interleaved int16 stereo checks passed")
    }

    private static func capturedBuffer(bytes: Data, format: AVAudioFormat, frames: Int) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: bytes.count,
            flags: 0, blockBufferOut: &block) == noErr, let block else { throw ServiceError.invalidResponse }
        let status = bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) }
        guard status == noErr else { throw ServiceError.invalidResponse }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format.formatDescription, sampleCount: frames, presentationTimeStamp: .zero,
            packetDescriptions: nil, sampleBufferOut: &sample) == noErr, let sample else { throw ServiceError.invalidResponse }
        return sample
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SmokeURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func requestBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private static func response(for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
}
