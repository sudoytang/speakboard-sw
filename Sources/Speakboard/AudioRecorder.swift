import AVFoundation
import CoreAudio

// Streams real-time PCM i16 LE audio at 16 kHz mono to the provided onChunk callback.
// Each call to onChunk delivers a Data blob containing raw 16-bit signed little-endian samples.
final class AudioRecorder {

    private struct InputFormatKey: Equatable {
        let sampleRate: Double
        let channelCount: AVAudioChannelCount
        let commonFormatRawValue: Int
        let isInterleaved: Bool

        init(_ format: AVAudioFormat) {
            sampleRate = format.sampleRate
            channelCount = format.channelCount
            commonFormatRawValue = Int(format.commonFormat.rawValue)
            isInterleaved = format.isInterleaved
        }
    }

    private struct HardwareListener {
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private(set) var isRecording = false

    /// Called on the AVAudioEngine internal thread with raw i16 LE PCM at 16 kHz mono.
    var onChunk: ((Data) -> Void)?

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var converterInputFormat: InputFormatKey?
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    private var audioChainDirty = true
    private var engineConfigObserver: NSObjectProtocol?
    private var hardwareListeners: [HardwareListener] = []

    init() {
        registerHardwareListeners()
    }

    deinit {
        unregisterHardwareListeners()
        removeEngineObserver()
    }

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
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        converter = nil
        converterInputFormat = nil

        if audioChainDirty {
            teardownEngine()
        }
    }

    // MARK: - Private

    private func doStart() throws {
        rebuildEngineIfNeeded()

        guard let engine else {
            throw NSError(domain: "AudioRecorder", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create audio engine."])
        }

        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)

        // Let AVAudioEngine pick the bus format so a device switch does not leave us
        // installing a tap with a stale format from the previous input route.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] inBuf, _ in
            guard let self, let conv = self.converter(for: inBuf.format) else { return }

            let ratio = self.outputFormat.sampleRate / inBuf.format.sampleRate
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

    private func converter(for inputFormat: AVAudioFormat) -> AVAudioConverter? {
        let key = InputFormatKey(inputFormat)
        if converterInputFormat == key, let converter {
            return converter
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            print("[recorder] cannot create audio converter for input format: \(inputFormat)")
            return nil
        }

        self.converter = converter
        converterInputFormat = key
        return converter
    }

    private func rebuildEngineIfNeeded() {
        guard engine == nil || audioChainDirty else { return }
        teardownEngine()

        let engine = AVAudioEngine()
        self.engine = engine
        audioChainDirty = false

        engineConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.markAudioChainDirty()
        }
    }

    private func teardownEngine() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        removeEngineObserver()
        engine = nil
        converter = nil
        converterInputFormat = nil
    }

    private func markAudioChainDirty() {
        audioChainDirty = true
        converter = nil
        converterInputFormat = nil

        if !isRecording {
            teardownEngine()
        }
    }

    private func registerHardwareListeners() {
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDevices,
        ]

        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.markAudioChainDirty()
            }

            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                block
            )

            if status == noErr {
                hardwareListeners.append(HardwareListener(address: address, block: block))
            } else {
                print("[recorder] failed to add hardware listener: \(status)")
            }
        }
    }

    private func unregisterHardwareListeners() {
        for listener in hardwareListeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                listener.block
            )
        }
        hardwareListeners.removeAll()
    }

    private func removeEngineObserver() {
        if let observer = engineConfigObserver {
            NotificationCenter.default.removeObserver(observer)
            engineConfigObserver = nil
        }
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
