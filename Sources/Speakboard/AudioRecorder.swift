import AVFoundation

// Streams real-time PCM i16 LE audio at 16 kHz mono to the provided onChunk callback.
// Each call to onChunk delivers a Data blob containing raw 16-bit signed little-endian samples.
final class AudioRecorder {

    private(set) var isRecording = false

    /// Called on the AVAudioEngine internal thread with raw i16 LE PCM at 16 kHz mono.
    var onChunk: ((Data) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    // MARK: - Public

    /// Request microphone permission if needed, then start capturing audio.
    func startRecording(completion: @escaping (Error?) -> Void) {
        guard !isRecording else { completion(nil); return }

        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard granted else {
                    completion(NSError(domain: "AudioRecorder", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "Microphone access denied."]))
                    return
                }
                do {
                    try self?.doStart()
                    completion(nil)
                } catch {
                    completion(error)
                }
            }
        }
    }

    /// Stop capturing. Any in-flight onChunk call may still complete after this returns.
    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
    }

    // MARK: - Private

    private func doStart() throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let conv = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw NSError(domain: "AudioRecorder", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create audio converter."])
        }
        converter = conv

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] inBuf, _ in
            guard let self, let conv = self.converter else { return }

            let outCapacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio + 1)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: self.outputFormat,
                                                frameCapacity: outCapacity) else { return }

            var inputConsumed = false
            var convError: NSError?
            let status = conv.convert(to: outBuf, error: &convError) { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                outStatus.pointee = .haveData
                inputConsumed = true
                return inBuf
            }

            guard status != .error, outBuf.frameLength > 0 else { return }

            let data = Self.toI16LE(outBuf)
            if !data.isEmpty { self.onChunk?(data) }
        }

        try engine.start()
        isRecording = true
    }

    // MARK: - Float32 mono → i16 LE

    private static func toI16LE(_ buffer: AVAudioPCMBuffer) -> Data {
        guard let channels = buffer.floatChannelData else { return Data() }
        let n = Int(buffer.frameLength)
        var data = Data(count: n * 2)
        data.withUnsafeMutableBytes { ptr in
            let p = ptr.baseAddress!.assumingMemoryBound(to: Int16.self)
            for i in 0..<n {
                let clamped = max(-1.0, min(1.0, channels[0][i]))
                p[i] = Int16(clamped * 32_767)
            }
        }
        return data
    }
}
