import CoreMedia
import Foundation
import os

/// The capture delegate only retains an immutable sample. Subscribers perform
/// their own copying and conversion off the capture queue; the AAC writer keeps
/// consuming the original buffer and timestamps.
struct MicrophoneAudioSample: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer

    init(sampleBuffer: CMSampleBuffer) {
        self.sampleBuffer = sampleBuffer
    }
}

/// An independent right to keep the shared microphone session running. Holding
/// this lease never enables a recording track or changes its selected device.
final class MicrophoneAudioLease: Sendable {
    let samples: AsyncThrowingStream<MicrophoneAudioSample, any Error>
    let deviceUniqueID: String?
    private let releaseOperation: OSAllocatedUnfairLock<(@Sendable () async -> Void)?>

    init(
        samples: AsyncThrowingStream<MicrophoneAudioSample, any Error>,
        deviceUniqueID: String?,
        release: @escaping @Sendable () async -> Void
    ) {
        self.samples = samples
        self.deviceUniqueID = deviceUniqueID
        releaseOperation = OSAllocatedUnfairLock(initialState: release)
    }

    func release() async {
        let operation = releaseOperation.withLock { stored in
            let operation = stored
            stored = nil
            return operation
        }
        await operation?()
    }

    deinit {
        let operation = releaseOperation.withLock { stored in
            let operation = stored
            stored = nil
            return operation
        }
        if let operation { Task { await operation() } }
    }
}

enum MicrophoneLiveAudioError: LocalizedError, Sendable {
    case deviceChanged
    case deviceDisconnected
    case captureFailed(String)
    case noAudio

    var errorDescription: String? {
        switch self {
        case .deviceChanged:
            appLocalized("麦克风已更换，请重新开启语音跟读。")
        case .deviceDisconnected:
            appLocalized("麦克风已断开，请连接设备后重试。")
        case let .captureFailed(reason):
            String(format: appLocalized("麦克风监听失败：%@"), reason)
        case .noAudio:
            appLocalized("没有收到麦克风音频，请检查设备后重试。")
        }
    }
}
