import AppKit

// MARK: - State

enum CapsuleState: Equatable {
    case recording
    case processing
    case result(String)
    case error
}

// MARK: - CapsuleContentView
//
// Hosts four sub-views, one per state.  Transitions with a 120 ms cross-fade.
// The containing window is responsible for sizing itself to match each state.

final class CapsuleContentView: NSView {

    // MARK: - Sub-views

    let waveform  = WaveformView(frame: NSRect(x: 0, y: 0, width: 44, height: 32))
    private let spinner   = NSProgressIndicator()
    private let textLabel = NSTextField(labelWithString: "")
    private let errorIcon = NSImageView()

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Public

    func setState(_ state: CapsuleState, animated: Bool = true) {
        if case .result(let t) = state { textLabel.stringValue = t }
        if case .processing = state { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

        waveform.resetToSilent()

        let all: [NSView]  = [waveform, spinner, textLabel, errorIcon]
        let next: NSView   = view(for: state)

        if animated {
            // Fade out currently visible views.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                for v in all where !v.isHidden { v.animator().alphaValue = 0 }
            }
            // After fade-out completes, switch to the new view and fade it in.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) { [weak self] in
                guard self != nil else { return }
                for v in all { v.isHidden = true; v.alphaValue = 1 }
                next.alphaValue = 0
                next.isHidden   = false
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.12
                    next.animator().alphaValue = 1
                }
            }
        } else {
            for v in all { v.isHidden = true }
            next.isHidden = false
        }
    }

    func updateRMS(_ rms: Float) {
        waveform.updateRMS(rms)
    }

    // MARK: - Private helpers

    private func view(for state: CapsuleState) -> NSView {
        switch state {
        case .recording:  return waveform
        case .processing: return spinner
        case .result:     return textLabel
        case .error:      return errorIcon
        }
    }

    private func setup() {
        // Waveform
        waveform.translatesAutoresizingMaskIntoConstraints = false
        addSubview(waveform)

        // Spinner (hidden by default)
        spinner.style            = .spinning
        spinner.controlSize      = .regular
        spinner.isIndeterminate  = true
        spinner.isHidden         = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)

        // Text label (hidden by default)
        textLabel.font          = .systemFont(ofSize: 14, weight: .medium)
        textLabel.textColor     = .white
        textLabel.alignment     = .center
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.isHidden      = true
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textLabel)

        // Error icon (hidden by default)
        let img = NSImage(systemSymbolName: "exclamationmark.circle.fill",
                          accessibilityDescription: "Error")
        errorIcon.image               = img
        errorIcon.symbolConfiguration = .init(pointSize: 22, weight: .medium)
        errorIcon.contentTintColor    = .white
        errorIcon.isHidden            = true
        errorIcon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(errorIcon)

        // Layout — each sub-view is centered; only one is visible at a time.
        NSLayoutConstraint.activate([
            // Waveform
            waveform.centerXAnchor.constraint(equalTo: centerXAnchor),
            waveform.centerYAnchor.constraint(equalTo: centerYAnchor),
            waveform.widthAnchor.constraint(equalToConstant: 44),
            waveform.heightAnchor.constraint(equalToConstant: 32),

            // Spinner
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Text
            textLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            textLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            textLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),

            // Error icon
            errorIcon.centerXAnchor.constraint(equalTo: centerXAnchor),
            errorIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            errorIcon.widthAnchor.constraint(equalToConstant: 26),
            errorIcon.heightAnchor.constraint(equalToConstant: 26),
        ])
    }
}
