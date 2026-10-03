func wait(player: AVAudioPlayerNode) async {
    // ruleid: playernode-isplaying-poll
    while player.isPlaying {
        try? await Task.sleep(for: .milliseconds(50))
    }
}

func extract(fmt: AVAudioFormat, list: UnsafePointer<AudioBufferList>) {
    // ruleid: buffer-nocopy-escape
    let b = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: list)
}
