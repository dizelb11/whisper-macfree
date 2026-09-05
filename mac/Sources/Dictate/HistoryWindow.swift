import AppKit
import SwiftUI

/// Окно истории диктовок с правкой прямо в списке.
///
/// Правка здесь — не косметика: пара «было/стало» уезжает в демон и станет
/// материалом для словаря. Это единственный способ учить систему, не заставляя
/// владельца редактировать текстовые файлы руками.
@MainActor
final class HistoryModel: ObservableObject {
    @Published var items: [DaemonClient.Dictation] = []
    @Published var error: String?
    @Published var savedID: Int?

    func reload() {
        do {
            items = try DaemonClient.history(limit: 100)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func save(_ item: DaemonClient.Dictation) {
        do {
            try DaemonClient.correct(id: item.id, text: item.final)
            savedID = item.id
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct HistoryView: View {
    @ObservedObject var model: HistoryModel

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.red.opacity(0.08))
            }

            if model.items.isEmpty {
                ContentUnavailableView("Пока пусто",
                                       systemImage: "waveform",
                                       description: Text("Зажми Fn и скажи что-нибудь"))
            } else {
                List($model.items) { $item in
                    row(for: $item)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 520, minHeight: 380)
        .onAppear { model.reload() }
    }

    @ViewBuilder
    private func row(for item: Binding<DaemonClient.Dictation>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(time(item.wrappedValue.createdAt))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if item.wrappedValue.polished {
                    Text("причёсано").font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.tint.opacity(0.15), in: Capsule())
                }
                Text("\(item.wrappedValue.ms) мс")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if model.savedID == item.wrappedValue.id {
                    Text("сохранено").font(.caption2).foregroundStyle(.green)
                }
            }

            TextField("", text: item.final, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .onSubmit { model.save(item.wrappedValue) }

            detail(for: item.wrappedValue)
        }
        .padding(.vertical, 4)
    }

    /// Работа модели должна быть видна целиком: и что услышал Whisper, и что
    /// предложила модель, и почему предложение отклонили. Иначе отклонённая
    /// правка невидима — в тексте лежит исходник, и не понять, что произошло.
    @ViewBuilder
    private func detail(for item: DaemonClient.Dictation) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if item.raw != item.final {
                label("Whisper", item.raw, color: .secondary)
            }
            if !item.rejected.isEmpty {
                label("модель предлагала", item.proposal, color: .secondary)
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
                    Text("правка отклонена: \(item.rejected)").font(.caption2)
                }
                .foregroundStyle(.orange)
            }
        }
    }

    private func label(_ title: String, _ text: String, color: HierarchicalShapeStyle) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.caption)
                .foregroundStyle(color)
                .textSelection(.enabled)
        }
    }

    private func time(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        guard let date = parser.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.dateFormat = "d MMM HH:mm"
        out.locale = Locale(identifier: "ru_RU")
        return out.string(from: date)
    }
}

@MainActor
final class HistoryWindowController {
    static let shared = HistoryWindowController()
    private var window: NSWindow?
    private let model = HistoryModel()

    func show() {
        model.reload()
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "История диктовок"
        window.contentView = NSHostingView(rootView: HistoryView(model: model))
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
