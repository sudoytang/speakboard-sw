import AppKit

// MARK: - WaveformView
//
// Displays 5 vertical bar‐graph bars driven by real-time audio RMS.
//
// Design spec:
//   • Area: 44 × 32 pt
//   • Weights (left → right): [0.5, 0.8, 1.0, 0.75, 0.55]  (natural mountain shape)
//   • Envelope: attack α = 0.4, release α = 0.15  (fast rise, slow fall)
//   • Jitter: ±4 % per bar, refreshed every 5 frames (~166 ms) for organic feel
//   • RMS is amplified × 6 so normal speech (~0.05–0.25) fills the full height
//   • updateRMS(_:) is called at ~30 fps from AudioRecorder.onRMSUpdate

final class WaveformView: NSView {

    // MARK: - Constants

    private let barCount  = 5
    private let weights:  [Float] = [0.5, 0.8, 1.0, 0.75, 0.55]
    private let barWidth: CGFloat = 3
    private let maxH:     CGFloat = 26   // max bar height (pt)
    private let minH:     CGFloat = 3    // min bar height when silent (pt)
    private let amplify:  Float   = 6    // RMS scale factor

    // MARK: - State

    private var smoothedRMS: Float = 0
    private var jitters: [Float]   = Array(repeating: 0, count: 5)
    private var frameCount = 0
    private var barLayers: [CALayer] = []

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Public

    /// Feed latest RMS value (~30 fps).  Must be called on the main thread.
    func updateRMS(_ rms: Float) {
        let alpha: Float = rms > smoothedRMS ? 0.4 : 0.15
        smoothedRMS = smoothedRMS * (1 - alpha) + rms * alpha

        frameCount += 1
        if frameCount % 5 == 0 {
            jitters = (0..<barCount).map { _ in Float.random(in: -0.04...0.04) }
        }

        redrawBars()
    }

    /// Reset waveform to silent state (e.g. when recording stops).
    func resetToSilent() {
        smoothedRMS = 0
        redrawBars()
    }

    // MARK: - Private

    private func setup() {
        wantsLayer = true

        let spacing = (44 - CGFloat(barCount) * barWidth) / CGFloat(barCount - 1)

        for i in 0..<barCount {
            let layer = CALayer()
            layer.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
            layer.cornerRadius    = barWidth / 2
            layer.frame = CGRect(
                x: CGFloat(i) * (barWidth + spacing),
                y: (32 - minH) / 2,
                width: barWidth,
                height: minH
            )
            self.layer?.addSublayer(layer)
            barLayers.append(layer)
        }
    }

    private func redrawBars() {
        let normalized = min(1.0, smoothedRMS * amplify)
        let spacing    = (44 - CGFloat(barCount) * barWidth) / CGFloat(barCount - 1)
        let viewH: CGFloat = 32

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for (i, layer) in barLayers.enumerated() {
            let h = max(minH, CGFloat(normalized * weights[i] * (1 + jitters[i])) * maxH)
            layer.frame = CGRect(
                x: CGFloat(i) * (barWidth + spacing),
                y: (viewH - h) / 2,
                width: barWidth,
                height: h
            )
        }

        CATransaction.commit()
    }
}
