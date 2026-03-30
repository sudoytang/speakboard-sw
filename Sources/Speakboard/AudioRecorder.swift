import AVFoundation
import Accelerate

final class AudioRecorder {

    private(set) var isRecording = false

    private let engine = AVAudioEngine()
    private var capturedBuffers: [AVAudioPCMBuffer] = []

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

    /// Stop capturing and return the audio encoded as a WAV Data blob, or nil if nothing was recorded.
    func stopRecording() -> Data? {
        guard isRecording else { return nil }
        isRecording = false

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        let data = Self.encodeWAV(buffers: capturedBuffers)
        capturedBuffers.removeAll()
        return data
    }

    // MARK: - Private

    private func doStart() throws {
        capturedBuffers.removeAll()

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            if let copy = buffer.copy() as? AVAudioPCMBuffer {
                self.capturedBuffers.append(copy)
            }
        }

        try engine.start()
        isRecording = true
    }

    // MARK: - WAV encoding (16-bit mono PCM)

    private static func encodeWAV(buffers: [AVAudioPCMBuffer]) -> Data? {
        guard let first = buffers.first else { return nil }
        let sampleRate  = UInt32(first.format.sampleRate)
        let channelCount = Int(first.format.channelCount)

        var samples = [Int16]()
        for buf in buffers {
            guard let channels = buf.floatChannelData else { continue }
            let n = Int(buf.frameLength)
            for frame in 0..<n {
                var mono: Float = 0
                for ch in 0..<channelCount { mono += channels[ch][frame] }
                mono /= Float(channelCount)
                samples.append(Int16(max(-1, min(1, mono)) * 32767))
            }
        }
        guard !samples.isEmpty else { return nil }

        let dataSize = UInt32(samples.count * 2)
        var h = Data()
        h += ascii("RIFF"); h += le32(36 + dataSize)
        h += ascii("WAVE")
        h += ascii("fmt "); h += le32(16)
        h += le16(1)                    // PCM
        h += le16(1)                    // mono
        h += le32(sampleRate)
        h += le32(sampleRate * 2)       // byteRate
        h += le16(2)                    // blockAlign
        h += le16(16)                   // bitsPerSample
        h += ascii("data"); h += le32(dataSize)
        return h + samples.withUnsafeBytes { Data($0) }
    }

    private static func ascii(_ s: String) -> Data { s.data(using: .ascii)! }
    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
}
