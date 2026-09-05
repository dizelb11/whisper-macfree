import AppKit
import AVFoundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let hotkey = HotKey()
    private let recorder = Recorder()
    private var busy = false
    private var polishThis = false
    private var permissionTimer: Timer?
    private var state: State = .idle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = buildMenu()
        show(.idle)

        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted { Task { @MainActor in self.show(.error("нет доступа к микрофону")) } }
        }

        hotkey.onPress = { [weak self] shift in
            self?.startRecording(polish: Settings.shared.polish(shiftHeld: shift))
        }
        hotkey.onShiftAdded = { [weak self] in
            guard let self, recorder.isRecording else { return }
            polishThis = Settings.shared.polish(shiftHeld: true)
            show(polishThis ? .recordingPolish : .recording)
        }
        hotkey.onRelease = { [weak self] shift in
            self?.finishRecording(polish: Settings.shared.polish(shiftHeld: shift))
        }
        awaitAccessibility()
    }

    /// Универсальный доступ выдаётся вручную и в произвольный момент. Раньше
    /// приложение проверяло его один раз и сдавалось навсегда — теперь ждёт
    /// и включается само, без перезапуска.
    private func awaitAccessibility() {
        if AXIsProcessTrusted() {
            enableHotkey()
            return
        }
        show(.needsAccess)
        Log.write("жду Универсальный доступ")
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            MainActor.assumeIsolated { self.enableHotkey() }
        }
    }

    private func enableHotkey() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        if hotkey.start() {
            Log.write("готов: слушаю Fn")
            show(.idle)
        } else {
            show(.error("не удалось перехватить Fn — нужен Мониторинг ввода"))
        }
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func openHistory() {
        HistoryWindowController.shared.show()
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: - Цикл диктовки

    private func startRecording(polish: Bool) {
        guard !busy, !recorder.isRecording else { return }
        polishThis = polish
        do {
            _ = try recorder.start()
            show(polish ? .recordingPolish : .recording)
        } catch {
            show(.error(error.localizedDescription))
        }
    }

    private func finishRecording(polish: Bool) {
        guard recorder.isRecording else { return }
        polishThis = polish
        let wav: URL
        do {
            wav = try recorder.stop()
        } catch {
            show(.idle)
            return
        }

        busy = true
        show(.thinking)
        let polish = polishThis
        Log.write("диктовка\(polish ? " с причёсыванием" : "")")
        Task.detached {
            let result = Result { try DaemonClient.transcribe(wav: wav, polish: polish) }
            try? FileManager.default.removeItem(at: wav)
            await MainActor.run { self.deliver(result) }
        }
    }

    private func deliver(_ result: Result<String, Error>) {
        busy = false
        switch result {
        case .success(let text) where !text.isEmpty:
            do {
                try Paster.paste(text)
                show(.idle)
            } catch {
                show(.error(error.localizedDescription))
            }
        case .success:
            show(.idle)
        case .failure(let error):
            show(.error(error.localizedDescription))
        }
    }

    // MARK: - Menubar

    private enum State {
        case idle, recording, recordingPolish, thinking, needsAccess, error(String)
    }

    private func show(_ state: State) {
        self.state = state
        guard let button = statusItem.button else { return }
        switch state {
        case .idle:
            button.title = "🎙"
            let mode = Settings.shared.polishByDefault ? "с причёсыванием" : "обычная"
            button.toolTip = "Fn — \(mode). Shift даёт противоположный режим."

        case .recording:
            button.title = "🔴"
            button.toolTip = "Запись..."
        case .recordingPolish:
            button.title = "🟣"
            button.toolTip = "Запись, текст будет причёсан..."
        case .thinking:
            button.title = "⋯"
            button.toolTip = "Расшифровка..."
        case .needsAccess:
            button.title = "🔐"
            button.toolTip = "Нужен Универсальный доступ — открой меню"
        case .error(let message):
            button.title = "⚠️"
            button.toolTip = message
            Log.write("ОШИБКА: \(message)")
        }
    }

    private var statusItemLabel: NSMenuItem?

    /// Демон мог подняться или упасть — перечитываем при открытии меню.
    func menuWillOpen(_ menu: NSMenu) {
        statusItemLabel?.title = DaemonClient.isReady() ? "Демон готов" : "Демон не запущен"
        show(state)  // подсказка на иконке должна отражать текущий режим
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        status.title = DaemonClient.isReady() ? "Демон готов" : "Демон не запущен"
        statusItemLabel = status
        menu.addItem(status)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "История диктовок…",
                                action: #selector(openHistory), keyEquivalent: "h"))
        menu.addItem(NSMenuItem(title: "Настройки…",
                                action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Разрешения macOS…",
                                action: #selector(openAccessibilitySettings), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}

// Самопроверка: пишет заданное число секунд и прогоняет через демон, минуя
// хоткей и менюбар. Нужна, чтобы проверять звуковой тракт без нажатия клавиш.
if let idx = CommandLine.arguments.firstIndex(of: "--selftest") {
    let seconds = Double(CommandLine.arguments[safe: idx + 1] ?? "") ?? 3
    let recorder = Recorder()
    do {
        let url = try recorder.start()
        print("пишу \(seconds)с в \(url.lastPathComponent)...")
        Thread.sleep(forTimeInterval: seconds)
        let wav = try recorder.stop()
        let size = (try? FileManager.default.attributesOfItem(atPath: wav.path)[.size] as? Int) ?? 0
        print("записано: \(size ?? 0) байт")
        let started = Date()
        let text = try DaemonClient.transcribe(wav: wav, polish: CommandLine.arguments.contains("--polish"))
        print("расшифровка за \(Int(Date().timeIntervalSince(started) * 1000))мс: \(text.isEmpty ? "(тишина)" : text)")
        try? FileManager.default.removeItem(at: wav)
        exit(0)
    } catch {
        print("ПРОВАЛ: \(error.localizedDescription)")
        exit(1)
    }
}

// Код верхнего уровня в main.swift не изолирован, но исполняется на главном
// потоке — сообщаем это компилятору явно.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)  // без иконки в Dock
    app.run()
}


extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
