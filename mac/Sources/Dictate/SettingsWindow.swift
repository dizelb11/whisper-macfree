import AppKit
import SwiftUI

/// Словарь состоит из двух независимых вещей, и это разделение важно:
/// «мои слова» не дают ошибке случиться, «исправления» чинят то, что
/// всё равно проскочило. Раньше это была одна таблица с необязательной
/// колонкой — понять, зачем она, было невозможно.
@MainActor
final class DictionaryModel: ObservableObject {
    @Published var words: [DaemonClient.Word] = []
    @Published var fixes: [DaemonClient.Fix] = []
    @Published var error: String?

    private var nextDraftID = -1
    private func draftID() -> Int { defer { nextDraftID -= 1 }; return nextDraftID }

    func reload() {
        do {
            words = try DaemonClient.words()
            fixes = try DaemonClient.fixes()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func addWord() { words.insert(.init(id: draftID(), word: ""), at: 0) }
    func addFix() { fixes.insert(.init(id: draftID(), heard: "", replacement: ""), at: 0) }

    func save(_ word: DaemonClient.Word) {
        guard !word.word.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            let id = try DaemonClient.wordSave(word)
            if let i = words.firstIndex(where: { $0.id == word.id }) { words[i].id = id }
        } catch { self.error = error.localizedDescription }
    }

    func save(_ fix: DaemonClient.Fix) {
        guard !fix.heard.trimmingCharacters(in: .whitespaces).isEmpty,
              !fix.replacement.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            let id = try DaemonClient.fixSave(fix)
            if let i = fixes.firstIndex(where: { $0.id == fix.id }) { fixes[i].id = id }
        } catch { self.error = error.localizedDescription }
    }

    func delete(word: DaemonClient.Word) {
        words.removeAll { $0.id == word.id }
        if word.id > 0 { try? DaemonClient.wordDelete(id: word.id) }
    }

    func delete(fix: DaemonClient.Fix) {
        fixes.removeAll { $0.id == fix.id }
        if fix.id > 0 { try? DaemonClient.fixDelete(id: fix.id) }
    }

    /// Сохранить всё несохранённое при закрытии окна.
    func flush() {
        words.forEach { save($0) }
        fixes.forEach { save($0) }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @StateObject private var dictionary = DictionaryModel()

    var body: some View {
        TabView {
            dictation.tabItem { Label("Диктовка", systemImage: "mic") }
            words.tabItem { Label("Мои слова", systemImage: "text.book.closed") }
            fixes.tabItem { Label("Исправления", systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(width: 580, height: 460)
        .onAppear { dictionary.reload() }
        .onDisappear { dictionary.flush() }
    }

    // MARK: - Диктовка

    private var dictation: some View {
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
                     + "менять настройку ради одной диктовки не нужно.\n\n"
                     + "Причёсывание убирает «э-э» и «короче», правит пунктуацию и "
                     + "пишет термины латиницей. Работает локальной моделью, никуда "
                     + "не отправляется.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Мои слова

    private var words: some View {
        section(
            title: "Слова, которые вы часто произносите",
            explanation: "Распознавание заранее узнает про них и перестанет коверкать. "
                + "Названия проектов, имена, термины, жаргон.\n"
                + "Например «Claude Code» — и вместо «клод кот» будет писаться правильно.",
            isEmpty: dictionary.words.isEmpty,
            emptyHint: "Пока пусто. Добавьте слово, которое распознаётся неверно.",
            onAdd: dictionary.addWord,
            footer: "Помещается около 120 слов — это ограничение модели распознавания."
        ) {
            ForEach($dictionary.words) { $word in
                HStack {
                    TextField("слово или название", text: $word.word)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { dictionary.save(word) }
                    deleteButton { dictionary.delete(word: word) }
                }
            }
        }
    }

    // MARK: - Исправления

    private var fixes: some View {
        section(
            title: "Когда подсказка не помогла",
            explanation: "Если слово всё равно распознаётся неверно — впишите слева, "
                + "как оно услышалось, справа то, на что заменить.\n"
                + "Загляните в историю диктовок: там видно, что именно было услышано.",
            isEmpty: dictionary.fixes.isEmpty,
            emptyHint: "Пока пусто. Это нормально — обычно хватает раздела «Мои слова».",
            onAdd: dictionary.addFix,
            footer: "Заменяется только слово целиком: «прот» → «прод» не тронет «напротив»."
        ) {
            ForEach($dictionary.fixes) { $fix in
                HStack(spacing: 6) {
                    TextField("услышалось", text: $fix.heard)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { dictionary.save(fix) }
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary).font(.caption)
                    TextField("заменить на", text: $fix.replacement)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { dictionary.save(fix) }
                    deleteButton { dictionary.delete(fix: fix) }
                }
            }
        }
    }

    // MARK: - Общая вёрстка разделов

    @ViewBuilder
    private func section<Rows: View>(
        title: String, explanation: String, isEmpty: Bool, emptyHint: String,
        onAdd: @escaping () -> Void, footer: String,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(explanation).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)

            if let error = dictionary.error {
                Text(error).font(.callout).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }

            if isEmpty {
                Text(emptyHint)
                    .font(.callout).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List { rows() }.listStyle(.inset(alternatesRowBackgrounds: true))
            }

            HStack {
                Button("Добавить", systemImage: "plus", action: onAdd)
                Spacer()
                Text(footer).font(.caption).foregroundStyle(.tertiary)
            }
            .padding(12)
        }
    }

    private func deleteButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
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
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 460),
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
