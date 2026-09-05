import AppKit
import SwiftUI

/// Окно настроек. Раздел пока один, но заведено секциями — так следующие
/// добавляются, не ломая вёрстку.
struct SettingsView: View {
    @ObservedObject var settings: Settings

    var body: some View {
        Form {
            Section {
                Picker("", selection: $settings.polishByDefault) {
                    Text("Обычная диктовка").tag(false)
                    Text("С причёсыванием локальной моделью").tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                LabeledContent("Задержка") {
                    Text(settings.polishByDefault ? "около 2,5 секунды" : "около 0,6 секунды")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Что делает Fn")
            } footer: {
                Text("Shift, зажатый вместе с Fn, всегда даёт противоположный режим — "
                     + "менять настройку ради одной диктовки не нужно.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Настройки"
        window.contentView = NSHostingView(rootView: SettingsView(settings: .shared))
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
