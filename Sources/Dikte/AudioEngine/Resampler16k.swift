import AVFoundation

/// Herhangi bir PCM biçimini Whisper'ın beklediği 16 kHz mono Float32'ye çevirir.
/// Mikrofon ve sistem sesi yakalama aynı dönüştürücüyü kullanır.
final class Resampler16k {
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private let converter: AVAudioConverter

    init?(from format: AVAudioFormat) {
        guard format.sampleRate > 0,
              let converter = AVAudioConverter(from: format, to: Self.targetFormat)
        else { return nil }
        self.converter = converter
    }

    /// Akış halinde çağrılabilir: dönüştürücü parçalar arasındaki durumu kendi tutar.
    func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return nil }

        var consumed = false
        var convError: NSError?
        converter.convert(to: outBuffer, error: &convError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let convError {
            Log.write("Ses dönüştürme hatası: \(convError.localizedDescription)")
            return nil
        }
        guard let channel = outBuffer.floatChannelData?[0], outBuffer.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(outBuffer.frameLength)))
    }
}
