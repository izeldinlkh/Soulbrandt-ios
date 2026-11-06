import AVFoundation

enum GameAudioSession {
    private static var engine: AVAudioEngine?
    private static var sourceNode: AVAudioSourceNode?

    /// Pulls mixed PS3 stereo float audio from the lock-free C ring into
    /// AVAudioEngine. The render callback performs no allocation or locking.
    static func configure() {
        guard engine == nil else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setPreferredSampleRate(48_000)
            try session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)

            soulbrandt_audio_reset()

            let audioEngine = AVAudioEngine()
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 2,
                interleaved: true
            ) else {
                throw AudioBridgeFailure.invalidFormat
            }

            let source = AVAudioSourceNode(format: format) {
                isSilence, _, frameCount, audioBufferList in
                let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
                guard let buffer = buffers.first, let data = buffer.mData else {
                    isSilence.pointee = ObjCBool(true)
                    return noErr
                }

                let copied = soulbrandt_audio_pull(
                    data.assumingMemoryBound(to: Float.self),
                    frameCount
                )
                isSilence.pointee = ObjCBool(copied == 0)
                return noErr
            }

            audioEngine.attach(source)
            audioEngine.connect(source, to: audioEngine.mainMixerNode, format: format)
            try audioEngine.start()

            sourceNode = source
            engine = audioEngine
            NSLog("[Soulbrandt audio] AVAudioEngine started at 48 kHz stereo")
        } catch {
            NSLog("[Soulbrandt audio] setup failed: %@", error.localizedDescription)
        }
    }

    static func stop() {
        engine?.stop()
        engine = nil
        sourceNode = nil
        soulbrandt_audio_reset()
    }
}

private enum AudioBridgeFailure: LocalizedError {
    case invalidFormat

    var errorDescription: String? {
        "Could not create the 48 kHz stereo audio format."
    }
}
