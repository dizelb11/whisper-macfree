import AppKit
import Carbon.HIToolbox

/// Вставка текста туда, где курсор.
///
/// Через буфер обмена и синтетический Cmd+V, а не посимвольным вводом:
/// посимвольный ломается в части приложений и заметно медленнее на длинном
/// тексте. Буфер сохраняется и возвращается обратно.
enum Paster {
    enum Failure: LocalizedError {
        case secureInput

        var errorDescription: String? {
            switch self {
            case .secureInput:
                "Активно поле пароля — macOS блокирует вставку. Так и задумано."
            }
        }
    }

    static func paste(_ text: String) throws {
        guard !IsSecureEventInputEnabled() else { throw Failure.secureInput }

        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        sendCommandV()

        // Вернуть буфер после того, как приёмник успел прочитать вставку.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
    }

    private static func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }
}
