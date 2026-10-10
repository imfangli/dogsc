import AVFoundation
import CoreMedia

enum MemoSpeechPCMBuffer {
    /// Copy into caller-owned storage before changing format or passing the
    /// audio to Speech. The recorder's original sample remains untouched.
    static func copy(_ sample: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard sample.isValid, CMSampleBufferDataIsReady(sample),
              let description = CMSampleBufferGetFormatDescription(sample),
              CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee.mFormatID == kAudioFormatLinearPCM
        else { throw MemoSpeechError.invalidAudio }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, frames <= Int(Int32.max),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { throw MemoSpeechError.invalidAudio }
        pcm.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList) == noErr
        else { throw MemoSpeechError.invalidAudio }
        return pcm
    }
}
