import AVFoundation

/// Запись с микрофона в WAV 16 кГц моно — родной формат Whisper.
///
/// Две тонкости, на которых легко уронить процесс:
///
/// 1. У `AVAudioFile` формат на диске и формат обмена — разные вещи.
///    Настройки задают Int16, но `processingFormat` всегда float32, и
///    `write(from:)` требует буфер именно в нём. Несовпадение роняет
///    CoreAudio ассертом, а не возвращает ошибку.
/// 2. Колбэк тапа исполняется на реальном аудиопотоке. Писать оттуда в файл
///    нельзя: это блокирующий ввод-вывод с аллокациями. Буфер копируется и
///    уезжает на свою очередь, где уже конвертируется и пишется.
final class Recorder {
    enum Failure: LocalizedError {
        case noConverter
        case tooShort
        case silence

        var errorDescription: String? {
            switch self {
            case .noConverter: "Не удалось настроить преобразование звука"
            case .tooShort: "Слишком коротко"
            case .silence: "Тишина"
            }
        }
    }

    private static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "local.whisper.dictate.recorder")
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var processing: AVAudioFormat?
    private var output: URL?
    private var peak: Float = 0

    /// Ниже этого порога считаем, что не говорили. На тишине Whisper
    /// галлюцинирует ("Продолжение следует...") — такой текст вставлять нельзя.
    private static let silenceThreshold: Float = 0.01

    var isRecording: Bool { engine.isRunning }

    func start() throws -> URL {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictate-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: Self.settings)
        // Именно processingFormat, а не то, что записано в настройках.
        let processing = file.processingFormat
        guard let converter = AVAudioConverter(from: inputFormat, to: processing) else {
            throw Failure.noConverter
        }

        queue.sync {
            self.file = file
            self.processing = processing
            self.converter = converter
            self.peak = 0
        }
        output = url

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let copy = Self.copy(buffer) else { return }
            self.queue.async { self.append(copy) }
        }
        engine.prepare()
        try engine.start()
        return url
    }

    func stop() throws -> URL {
        guard engine.isRunning else { throw Failure.tooShort }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        // Дождаться, пока очередь допишет уже принятые буферы, и только
        // потом закрывать файл.
        var frames: AVAudioFramePosition = 0
        var loudest: Float = 0
        queue.sync {
            frames = self.file?.length ?? 0
            loudest = self.peak
            self.file = nil
            self.converter = nil
            self.processing = nil
        }
        guard let url = output, frames > 4_000 else {  // меньше 0.25 с — промах по клавише
            throw Failure.tooShort
        }
        Log.write("записано \(frames) кадров, пик \(String(format: "%.4f", loudest))")
        guard loudest >= Self.silenceThreshold else {
            Log.write("тишина (пик \(String(format: "%.4f", loudest))) — не отправляю")
            try? FileManager.default.removeItem(at: url)
            throw Failure.silence
        }
        return url
    }

    /// Движок переиспользует буфер после возврата из колбэка, поэтому копия.
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let source = buffer.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let target = out.floatChannelData
        else { return nil }
        out.frameLength = buffer.frameLength
        let bytes = Int(buffer.frameLength) * MemoryLayout<Float>.size
        for channel in 0..<Int(buffer.format.channelCount) {
            memcpy(target[channel], source[channel], bytes)
        }
        return out
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let converter, let file, let processing else { return }

        let ratio = processing.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: processing, frameCapacity: capacity) else { return }

        var delivered = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if delivered { status.pointee = .noDataNow; return nil }
            delivered = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0 else { return }
        if let samples = out.floatChannelData?[0] {
            for i in 0..<Int(out.frameLength) {
                peak = max(peak, abs(samples[i]))
            }
        }
        do {
            try file.write(from: out)
        } catch {
            Log.write("ОШИБКА записи звука: \(error.localizedDescription)")
        }
    }
}
