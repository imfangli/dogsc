import Foundation
import QuartzCore

enum EditorPlaybackNavigationOrigin: Equatable { case timeline, subtitle }

struct EditorPlaybackTimelineSnapshot: Equatable {
    let outputTime: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    var allowsViewportReveal = true
    var navigationRevision: UInt64 = 0
    var navigationOrigin: EditorPlaybackNavigationOrigin?
}

@MainActor
protocol EditorPlaybackTimelineObserver: AnyObject {
    func editorPlaybackTimelineDidUpdate(_ snapshot: EditorPlaybackTimelineSnapshot)
}

@MainActor
final class EditorPlaybackTimelineObserverHub {
    private final class WeakBox {
        weak var value: (any EditorPlaybackTimelineObserver)?

        init(_ value: any EditorPlaybackTimelineObserver) {
            self.value = value
        }
    }

    private var observers: [WeakBox] = []

    func add(
        _ observer: any EditorPlaybackTimelineObserver,
        current snapshot: EditorPlaybackTimelineSnapshot
    ) {
        remove(observer)
        observers.append(WeakBox(observer))
        observer.editorPlaybackTimelineDidUpdate(snapshot)
    }

    func remove(_ observer: any EditorPlaybackTimelineObserver) {
        observers.removeAll { $0.value == nil || $0.value === observer }
    }

    func publish(_ snapshot: EditorPlaybackTimelineSnapshot) {
        // Observers each wrap their layer changes in a CATransaction. Called
        // from the display link there is no enclosing transaction, so every
        // observer's commit was a top-level commit that ran AppKit's whole
        // display cycle over the window (measured: ~44% of the main thread
        // during playback). One enclosing transaction makes theirs nested:
        // the window commits once per tick.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        var containsExpiredObserver = false
        for box in observers {
            if let observer = box.value {
                observer.editorPlaybackTimelineDidUpdate(snapshot)
            } else {
                containsExpiredObserver = true
            }
        }
        if containsExpiredObserver {
            observers.removeAll { $0.value == nil }
        }
    }
}
