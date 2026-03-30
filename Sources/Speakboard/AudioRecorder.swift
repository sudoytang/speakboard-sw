import AVFoundation
import Accelerate

// MARK: - Errors

enum AudioRecorderError: LocalizedError {
    case permissionDenied
    case engineStartFailed(Error)
    case noAudioCaptured

    var errorDescription: String? {
        switch self {
        case .permissionDenied:     return "Microphone access was denied."
        case .engineStartFailed(let e): return "Audio engine failed: \(e)"
        case .noAudioCaptured:      return "No audio was captured."
        }
    }
}

// MARK: - AudioRecorder

final class AudioRecorder {

    // Called on the main thread at ~30 fps while recording.
    var onRMSUpdate: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private var capturedBuffers: [AVAudioPCMBuffer] = []
    private var rmsTimer: Timer?
    // Written on audio thread, read on main thread.
    // A minor data-race on a Float is acceptable for display-only RMS values.
    private var latestRMS: Float = 0
    private var recording = false

    // MARK: - Public

    /// Request microphone permission if needed, then start recording.
    func startRecording(completion: @escaping (Error?) -> Void) {
        guard !recording else { completion(nil); return }

        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard granted else {
                    completion(AudioRecorderError.permissionDenied)
                    return
                }
                do {
                    try self?.doStart()
                    completion(nil)
                } catch {
                    completion(AudioRecorderError.engineStartFailed(error))
                }
            }
        }
    }

    /// Stop recording and return the captured audio encoded as WAV.
    func stopRecording() -> Data? {
        guard recording else { return nil }
        recording = false

        rmsTimer?.invalidate()
        rmsTimer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        let data = Self.encodeWAV(buffers: capturedBuffers)
        capturedBuffers.removeAll()
        latestRMS = 0
        return data
    }

    // MARK: - Private

    private func doStart() throws {
        capturedBuffers.removeAll()
        latestRMS = 0

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            // Copy buffer before the audio thread reuses it.
            if let copy = buffer.copy() as? AVAudioPCMBuffer {
                self.capturedBuffers.append(copy)
            }
            // Compute RMS for the waveform display.
            if let data = buffer.floatChannelData?[0] {
                var rms: Float = 0
                vDSP_rmsqv(data, 1, &rms, vDSP_Length(buffer.frameLength))
                self.latestRMS = rms
            }
        }

        try engine.start()
        recording = true

        rmsTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.onRMSUpdate?(self.latestRMS)
        }
    }

    // MARK: - WAV encoding

    /// Mix all captured buffers to mono and encode as 16-bit PCM WAV at the
    /// native sample rate.  The backend (server.py) resamples to 16 kHz automatically.
    private static func encodeWAV(buffers: [AVAudioPCMBuffer]) -> Data? {
        guard let first = buffers.first else { return nil }
        let sampleRate = UInt32(first.format.sampleRate)
        let channelCount = Int(first.format.channelCount)

        var samples = [Int16]()
        samples.reserveCapacity(buffers.reduce(0) { $0 + Int($1.frameLength) })

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
        return buildWAVHeader(sampleRate: sampleRate, sampleCount: samples.count)
            + samples.withUnsafeBytes { Data($0) }
    }

    private static func buildWAVHeader(sampleRate: UInt32, sampleCount: Int) -> Data {
        let dataSize  = UInt32(sampleCount * 2)
        var h = Data()
        h += ascii("RIFF");  h += le32(36 + dataSize)
        h += ascii("WAVE")
        h += ascii("fmt ");  h += le32(16)
        h += le16(1)          // PCM
        h += le16(1)          // mono
        h += le32(sampleRate)
        h += le32(sampleRate * 2)  // byteRate
        h += le16(2)               // blockAlign
        h += le16(16)              // bitsPerSample
        h += ascii("data");  h += le32(dataSize)
        return h
    }

    private static func ascii(_ s: String) -> Data { s.data(using: .ascii)! }
    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
}
