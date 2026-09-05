import Foundation
import SwiftUI

/// Настройки приложения.
///
/// Режим Fn выбирается один раз, а Shift всегда даёт противоположный —
/// так в обычной работе нажимается одна клавиша, а исключение остаётся
/// доступным без похода в настройки.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private static let polishKey = "polishByDefault"

    @Published var polishByDefault: Bool {
        didSet { UserDefaults.standard.set(polishByDefault, forKey: Self.polishKey) }
    }

    private init() {
        polishByDefault = UserDefaults.standard.bool(forKey: Self.polishKey)
    }

    /// Итоговый режим: Shift инвертирует значение по умолчанию.
    func polish(shiftHeld: Bool) -> Bool {
        polishByDefault != shiftHeld
    }
}
