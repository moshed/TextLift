import AppKit
import Carbon.HIToolbox

/// Thin wrapper around the Carbon `RegisterEventHotKey` API so we can register a
/// system-wide keyboard shortcut without needing Accessibility permissions.
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var eventHandler: EventHandlerRef?
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1

    private init() {
        installHandler()
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, userData) -> OSStatus in
            guard let userData = userData, let event = event else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hkID)
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            manager.actions[hkID.id]?()
            return noErr
        }, 1, &spec, selfPtr, &eventHandler)
    }

    /// Register a hot key. `modifiers` uses Carbon masks (cmdKey, optionKey, …).
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x54584C46) /* 'TXLF' */, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref = ref else { return false }
        hotKeyRefs[id] = ref
        actions[id] = action
        return true
    }

    private var primaryID: UInt32?

    /// Register (or re-register) the app's single primary hot key, replacing any
    /// previous one. Returns false if the OS rejected the combination.
    @discardableResult
    func setPrimary(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        if let id = primaryID {
            if let ref = hotKeyRefs[id] { UnregisterEventHotKey(ref) }
            hotKeyRefs[id] = nil
            actions[id] = nil
            primaryID = nil
        }
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x54584C46) /* 'TXLF' */, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref = ref else { return false }
        hotKeyRefs[id] = ref
        actions[id] = action
        primaryID = id
        return true
    }
}
