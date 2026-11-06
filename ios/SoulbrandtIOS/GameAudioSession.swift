import AVFoundation

enum GameAudioSession {
    /// Reserve the device's normal game-output route at 48 kHz. The PS3 cellAudio
    /// mixer/resampler still needs to be connected to this output path.
    static func configure() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setPreferredSampleRate(48_000)
            try session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
        } catch {
            NSLog("[Soulbrandt audio] session setup failed: %@", error.localizedDescription)
        }
    }
}
