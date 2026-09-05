import AppKit

/// Слежение за клавишей Fn (🌐) через CGEventTap.
///
/// Тап только слушает и ничего не перехватывает — иначе Fn сломалась бы для
/// всей системы. Из-за этого macOS продолжает обрабатывать её сама, поэтому в
/// Системных настройках нужно выставить «Нажатие 🌐» → «Ничего не делать».
final class HotKey {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false
    private var shiftSeen = false

    /// Shift отслеживается всю запись, а не только в момент нажатия Fn.
    /// Иначе привычный порядок «зажал Fn, потом добавил Shift» не срабатывает:
    /// когда приходит событие Shift, состояние Fn уже не меняется.
    ///
    /// Что Shift означает — решает приложение: здесь только факт нажатия.
    var onPress: (_ shift: Bool) -> Void = { _ in }
    var onShiftAdded: () -> Void = {}
    var onRelease: (_ shift: Bool) -> Void = { _ in }

    /// false — не выдано разрешение Input Monitoring / Универсальный доступ.
    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<HotKey>.fromOpaque(refcon).takeUnretainedValue()
                me.handle(flags: event.flags)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(flags: CGEventFlags) {
        let fn = flags.contains(.maskSecondaryFn)
        let shift = flags.contains(.maskShift)

        if fn && !isDown {
            isDown = true
            shiftSeen = shift
            DispatchQueue.main.async { [self] in onPress(shift) }
        } else if fn && isDown {
            // Shift добавили уже после Fn — самый частый порядок.
            guard shift, !shiftSeen else { return }
            shiftSeen = true
            DispatchQueue.main.async { [self] in onShiftAdded() }
        } else if !fn && isDown {
            isDown = false
            let shiftWasHeld = shiftSeen
            shiftSeen = false
            DispatchQueue.main.async { [self] in onRelease(shiftWasHeld) }
        }
    }
}
