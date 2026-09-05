import AppKit
import SwiftUI

/// Модель словаря. Правки уезжают в демон сразу — отдельной кнопки
/// «сохранить» нет, чтобы не терять изменения при закрытии окна.
@MainActor
final class TermsModel: ObservableObject {
    @Published var terms: [DaemonClient.Term] = []
    @Published var error: String?

    func reload() {
        do {
            terms = try DaemonClient.terms()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func save(_ term: DaemonClient.Term) {
        guard !term.canonical.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            let id = try DaemonClient.termSave(term)
            if let index = terms.firstIndex(where: { $0.id == term.id }), term.id != id {
                terms[index].id = id
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Новым строкам даём временный отрицательный id: настоящий приходит
    /// от демона при сохранении. Иначе несколько новых строк неотличимы
    /// друг от друга и удаление задевает не ту.
    private var nextDraftID = -1

    func add() {
        terms.insert(DaemonClient.Term(id: nextDraftID, canonical: "", alias: "", enabled: true), at: 0)
        nextDraftID -= 1
    }

    func delete(_ term: DaemonClient.Term) {
        terms.removeAll { $0.id == term.id }
        guard term.id > 0 else { return }
        do { try DaemonClient.termDelete(id: term.id) } catch {
            self.error = error.localizedDescription
        }
    }

    /// Сохранить всё несохранённое — при закрытии окна.
    func flush() {
        for term in terms where !term.canonical.trimmingCharacters(in: .whitespaces).isEmpty {
            save(term)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @StateObject private var model = TermsModel()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("", selection: $settings.polishByDefault) {
                        Text("Обычная диктовка — около 0,6 секунды").tag(false)
                        Text("С причёсыванием — около 2,5 секунды").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                } header: {
                    Text("Что делает Fn")
                } footer: {
                    Text("Shift вместе с Fn всегда даёт противоположный режим — "
                         + "менять настройку ради одной диктовки не нужно.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .frame(height: 190)

            Divider()
            dictionary
        }
        .frame(minWidth: 560, minHeight: 520)
        .onAppear { model.reload() }
        .onDisappear { model.flush() }
    }

    private var dictionary: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Словарь").font(.headline)
                    Text("«Как надо» подсказывается распознаванию заранее. "
                         + "«Как слышится» заменяется в готовом тексте — заполняйте, "
                         + "когда слово упорно распознаётся неверно.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Добавить", systemImage: "plus") { model.add() }
            }
            .padding(12)

            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 6)
            }

            HStack(spacing: 8) {
                Text("Как слышится").frame(width: 190, alignment: .leading)
                Text("Как надо").frame(maxWidth: .infinity, alignment: .leading)
                Spacer().frame(width: 22)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12).padding(.bottom, 4)

            List {
                ForEach($model.terms) { $term in
                    HStack(spacing: 8) {
                        TextField("необязательно", text: $term.alias)
                            .frame(width: 190)
                            .onSubmit { model.save(term) }
                        TextField("термин", text: $term.canonical)
                            .onSubmit { model.save(term) }
                        Button {
                            model.delete(term)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .frame(width: 22)
                    }
                    .textFieldStyle(.roundedBorder)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            Text("Enter сохраняет строку; при закрытии окна сохранится всё. "
                 + "Изменения применяются со следующей диктовки. В подсказку "
                 + "помещается около 120 терминов — это ограничение модели.")
            .font(.caption).foregroundStyle(.tertiary)
            .padding(12)
        }
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
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 560),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Настройки"
        window.contentView = NSHostingView(rootView: SettingsView(settings: .shared))
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
