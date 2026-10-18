import Foundation
import UIKit
import CoreImage
import DeltaCore

struct GameFrame: Sendable {
    let rgba: Data
    let number: UInt64
    let buttons: UInt32
}

/// Queue-confined reusable render target. Emitted frames retain a Data value;
/// later writes trigger copy-on-write only while an earlier frame is still live.
struct BoundFramePixelStorage {
    private var data = Data(count: SharingFrame.byteCount)

    mutating func withMutableBytes<Result>(_ body: (UnsafeMutableRawBufferPointer) throws -> Result) rethrows -> Result {
        try data.withUnsafeMutableBytes(body)
    }

    func withBytes<Result>(_ body: (UnsafeRawBufferPointer) throws -> Result) rethrows -> Result {
        try data.withUnsafeBytes(body)
    }

    func frame(number: UInt64) -> GameFrame {
        GameFrame(rgba: data, number: number, buttons: 0)
    }
}

/// Capture happens on Delta's existing owner callback; conversion/sharing never queues per frame.
final class BoundDeltaFrameTap: @unchecked Sendable {
    private let gate = BoundFrameCaptureGate()
    private let queue = DispatchQueue(label: "Bound Delta frame conversion", qos: .utility)
    private let context = CIContext(options: [.workingColorSpace: NSNull()])
    private var pixels = BoundFramePixelStorage() // Conversion queue only.
    private var sequence: UInt64 = 0 // Conversion queue only.
    private let deliver: @MainActor (GameFrame) -> Void
    init(deliver: @escaping @MainActor (GameFrame) -> Void) { self.deliver = deliver }
    func setEnabled(_ enabled: Bool) { gate.configure(enabled: enabled) }
    func receive(_ core: EmulatorCore) {
        guard let epoch = gate.begin(now: ProcessInfo.processInfo.systemUptime) else { return }
        guard let image = core.videoManager.detachedBitmapImage() else { _ = gate.finish(epoch: epoch); return }
        queue.async { [self] in
            let success = pixels.withMutableBytes { buffer -> Bool in
                guard image.extent.width > 0, image.extent.height > 0,
                      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB), let bytes = buffer.baseAddress else { return false }
                let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                    .transformed(by: CGAffineTransform(scaleX: 240 / image.extent.width, y: 160 / image.extent.height))
                context.render(normalized, toBitmap: bytes, rowBytes: 240 * 4,
                    bounds: CGRect(x: 0, y: 0, width: 240, height: 160), format: .RGBA8, colorSpace: colorSpace)
                return true
            }
            guard success else { _ = gate.finish(epoch: epoch); return }
            sequence &+= 1
            // Retain the rendered Data value directly. This avoids allocating an
            // intermediate byte array and then copying it into a second Data.
            let frame = pixels.frame(number: sequence)
            // Pending stays set through main delivery, bounding the entire bridge.
            DispatchQueue.main.async { [self] in
                guard gate.finish(epoch: epoch) else { return }
                deliver(frame)
            }
        }
    }
}
