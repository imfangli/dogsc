import Foundation

public enum SubtitleAudioSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case microphone
    case system
    case finalMix

    public var id: String { rawValue }
}

/// End-exclusive seconds on the original screen recording clock. A word can
/// own several ranges when it was recognized across a cut in the edited audio.
public struct SubtitleTimeRange: Codable, Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { end - start }
    public var isValid: Bool { start.isFinite && end.isFinite && start >= 0 && end > start }
}

/// The smallest timed unit supplied by Apple Speech. Corrections never mutate
/// these units: they regroup their stable IDs and replace only displayed text.
public struct SubtitleWord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var text: String
    public var sourceRanges: [SubtitleTimeRange]

    public init(id: UUID = UUID(), text: String, sourceRanges: [SubtitleTimeRange]) {
        self.id = id
        self.text = text
        self.sourceRanges = sourceRanges
    }
}

public struct SubtitleCue: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var wordIDs: [UUID]
    public var text: String
    /// Only human timing edits set this override. It is still source anchored,
    /// so subsequent trims, moves and playback-rate changes remain automatic.
    public var manualSourceRanges: [SubtitleTimeRange]?
    public var isManuallyEdited: Bool

    public var suggestedDuration: TimeInterval {
        min(max(Double(SubtitleTextFormatter.format(text).filter { !$0.isWhitespace }.count) / 7, 1), 8)
    }

    public init(
        id: UUID = UUID(), wordIDs: [UUID], text: String,
        manualSourceRanges: [SubtitleTimeRange]? = nil, isManuallyEdited: Bool = false
    ) {
        self.id = id
        self.wordIDs = wordIDs
        self.text = text
        self.manualSourceRanges = manualSourceRanges
        self.isManuallyEdited = isManuallyEdited
    }

    private enum CodingKeys: String, CodingKey {
        case id, wordIDs, text, manualSourceRanges, isManuallyEdited
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            wordIDs: try values.decode([UUID].self, forKey: .wordIDs),
            text: try values.decode(String.self, forKey: .text),
            manualSourceRanges: try values.decodeIfPresent([SubtitleTimeRange].self, forKey: .manualSourceRanges),
            isManuallyEdited: try values.decodeIfPresent(Bool.self, forKey: .isManuallyEdited) ?? false
        )
    }
}

public struct SubtitleStyle: Codable, Equatable, Sendable {
    public var textColor: HexColor
    public var backgroundColor: HexColor
    public var backgroundOpacity: Double
    /// Point size at a 1080-pixel canvas short edge; preview and export scale it.
    public var fontSize: Double
    /// Distance from the final canvas bottom, as a fraction of canvas height.
    public var bottomInset: Double

    public init(
        textColor: HexColor = .white, backgroundColor: HexColor = .black,
        backgroundOpacity: Double = 0.62, fontSize: Double = 44,
        bottomInset: Double = 0.065
    ) {
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.backgroundOpacity = backgroundOpacity
        self.fontSize = fontSize
        self.bottomInset = bottomInset
    }
}

public struct SubtitleDocument: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var audioSource: SubtitleAudioSource
    public var script: String
    public var theme: String
    public var style: SubtitleStyle
    public var words: [SubtitleWord]
    public var cues: [SubtitleCue]
    /// Identifies the source, audio selection and edit snapshot used to generate
    /// these words. UI can warn about newly restored, unrecognized source audio.
    public var generationSignature: String?

    public init(
        enabled: Bool = false, audioSource: SubtitleAudioSource = .microphone,
        script: String = "", theme: String = "", style: SubtitleStyle = SubtitleStyle(),
        words: [SubtitleWord] = [], cues: [SubtitleCue] = [],
        generationSignature: String? = nil
    ) {
        self.enabled = enabled
        self.audioSource = audioSource
        self.script = script
        self.theme = theme
        self.style = style
        self.words = words
        self.cues = cues
        self.generationSignature = generationSignature
    }

    public mutating func setRecognizedWords(_ words: [SubtitleWord]) {
        self.words = words
        cues = SubtitleSegmentation.cues(for: words)
        enabled = !cues.isEmpty
    }
}

/// One projected display interval per authored cue, with a stable identity.
/// Rearranged cues choose their longest continuous surviving interval.
public struct ResolvedSubtitleCue: Equatable, Identifiable, Sendable {
    public var id: String
    public var cueID: UUID
    public var text: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var requiresReview: Bool
    public var wasRearranged: Bool

    public init(
        id: String, cueID: UUID, text: String, startTime: TimeInterval,
        endTime: TimeInterval, requiresReview: Bool = false, wasRearranged: Bool = false
    ) {
        self.id = id
        self.cueID = cueID
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.requiresReview = requiresReview
        self.wasRearranged = wasRearranged
    }

    public var duration: TimeInterval { endTime - startTime }
    public var isTooShort: Bool {
        duration < max(0.6, Double(text.filter { !$0.isWhitespace }.count) / 12)
    }
}
