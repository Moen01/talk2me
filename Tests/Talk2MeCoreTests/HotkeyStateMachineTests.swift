import Testing
@testable import Talk2MeCore

/// The default setup: one key (Fn) both holds to dictate and double-taps for hands-free.
private let both: ShortcutRoles = [.hold, .handsFree]

struct HotkeyStateMachineTests {
    @Test func holdingTheKeyRecordsUntilRelease() {
        var machine = HotkeyStateMachine()
        #expect(machine.shortcutDown(both, at: 10.0) == .startRecording)
        #expect(machine.shortcutUp(both, at: 12.0) == .stopRecording)
        #expect(machine.state == .idle)
    }

    @Test func quickTapIsDiscarded() {
        var machine = HotkeyStateMachine()
        #expect(machine.shortcutDown(both, at: 10.0) == .startRecording)
        #expect(machine.shortcutUp(both, at: 10.1) == .cancelRecording)
        #expect(machine.state == .idle)
    }

    @Test func doubleTapStartsHandsFreeAndTapEnds() {
        var machine = HotkeyStateMachine()
        _ = machine.shortcutDown(both, at: 10.0)
        #expect(machine.shortcutUp(both, at: 10.1) == .cancelRecording)
        #expect(machine.shortcutDown(both, at: 10.3) == .startRecording)
        #expect(machine.shortcutUp(both, at: 10.4) == nil)
        #expect(machine.state == .handsFree)

        #expect(machine.shortcutDown(both, at: 20.0) == .stopRecording)
        #expect(machine.shortcutUp(both, at: 20.1) == nil)
        #expect(machine.state == .idle)
    }

    @Test func enterFinishesHandsFree() {
        var machine = HotkeyStateMachine()
        _ = machine.shortcutDown(both, at: 10.0)
        _ = machine.shortcutUp(both, at: 10.1)
        _ = machine.shortcutDown(both, at: 10.3)
        _ = machine.shortcutUp(both, at: 10.4)
        #expect(machine.otherKeyDown(36, at: 15.0) == .stopRecording)
        #expect(machine.state == .idle)
    }

    @Test func escapeDiscardsHandsFree() {
        var machine = HotkeyStateMachine()
        _ = machine.shortcutDown(both, at: 10.0)
        _ = machine.shortcutUp(both, at: 10.1)
        _ = machine.shortcutDown(both, at: 10.3)
        _ = machine.shortcutUp(both, at: 10.4)
        #expect(machine.otherKeyDown(0, at: 11.0) == nil)
        #expect(machine.otherKeyDown(ShortcutKey.escapeKeyCode, at: 12.0) == .cancelRecording)
        #expect(machine.state == .idle)
    }

    @Test func slowSecondTapIsJustAnotherTap() {
        var machine = HotkeyStateMachine()
        _ = machine.shortcutDown(both, at: 10.0)
        _ = machine.shortcutUp(both, at: 10.1)
        _ = machine.shortcutDown(both, at: 12.0)
        #expect(machine.shortcutUp(both, at: 12.1) == .cancelRecording)
        #expect(machine.state == .idle)
    }

    @Test func keyUsedInAShortcutCancelsAndIgnoresRelease() {
        var machine = HotkeyStateMachine()
        #expect(machine.shortcutDown(both, at: 10.0) == .startRecording)
        #expect(machine.otherKeyDown(51, at: 10.5) == .cancelRecording)
        #expect(machine.shortcutUp(both, at: 11.0) == nil)
        #expect(machine.state == .idle)
    }

    @Test func handsFreeOffMeansDoubleTapDoesNothing() {
        var machine = HotkeyStateMachine()
        _ = machine.shortcutDown(.hold, at: 10.0)
        _ = machine.shortcutUp(.hold, at: 10.1)
        #expect(machine.shortcutDown(.hold, at: 10.3) == .startRecording)
        #expect(machine.shortcutUp(.hold, at: 10.4) == .cancelRecording)
        #expect(machine.state == .idle)
    }

    @Test func separateHandsFreeKeyStartsOnSecondTap() {
        var machine = HotkeyStateMachine()
        #expect(machine.shortcutDown(.handsFree, at: 10.0) == nil)
        #expect(machine.shortcutUp(.handsFree, at: 10.1) == nil)
        #expect(machine.shortcutDown(.handsFree, at: 10.3) == .startRecording)
        #expect(machine.state == .handsFree)
        #expect(machine.shortcutUp(.handsFree, at: 10.4) == nil)
        // Pressing the hold key finishes it too.
        #expect(machine.shortcutDown(.hold, at: 15.0) == .stopRecording)
        #expect(machine.shortcutUp(.hold, at: 15.1) == nil)
        #expect(machine.state == .idle)
    }

    @Test func separateHandsFreeKeySingleTapDoesNothing() {
        var machine = HotkeyStateMachine()
        _ = machine.shortcutDown(.handsFree, at: 10.0)
        _ = machine.shortcutUp(.handsFree, at: 10.1)
        #expect(machine.shortcutDown(.handsFree, at: 12.0) == nil)
        #expect(machine.state == .tapping(since: 12.0))
    }

    @Test func releasingTheOtherKeyDoesNotEndAHold() {
        var machine = HotkeyStateMachine()
        #expect(machine.shortcutDown(.hold, at: 10.0) == .startRecording)
        #expect(machine.shortcutDown(.handsFree, at: 10.5) == nil)
        #expect(machine.shortcutUp(.handsFree, at: 10.6) == nil)
        #expect(machine.state == .holding(since: 10.0, roles: .hold))
        #expect(machine.shortcutUp(.hold, at: 12.0) == .stopRecording)
    }

    @Test func releasingTheHoldKeyIsNotAHandsFreeTap() {
        var machine = HotkeyStateMachine()
        #expect(machine.shortcutDown(.handsFree, at: 10.0) == nil)
        #expect(machine.shortcutDown(.hold, at: 10.05) == nil)
        #expect(machine.shortcutUp(.hold, at: 10.1) == nil)
        #expect(machine.state == .tapping(since: 10.0))
    }

    @Test func handsFreeKeyUsedAsModifierIsNotATap() {
        var machine = HotkeyStateMachine()
        _ = machine.shortcutDown(.handsFree, at: 10.0)
        #expect(machine.otherKeyDown(8, at: 10.05) == nil)
        _ = machine.shortcutUp(.handsFree, at: 10.1)
        #expect(machine.shortcutDown(.handsFree, at: 10.3) == nil)
    }

    @Test func repeatedKeyDownIsIgnored() {
        var machine = HotkeyStateMachine()
        _ = machine.shortcutDown(both, at: 10.0)
        #expect(machine.shortcutDown(both, at: 10.5) == nil)
    }
}

struct ShortcutKeyTests {
    @Test func tellsLeftAndRightModifiersApart() {
        let leftOptionDown: UInt64 = 0x80000 | 0x20 // Option flag + left device bit
        #expect(ShortcutKey.rightOption.isDown(flags: leftOptionDown) == false)
        #expect(ShortcutKey.leftOption.isDown(flags: leftOptionDown))
        #expect(ShortcutKey.rightOption.isDown(flags: 0x80000 | 0x40))
        #expect(ShortcutKey.rightCommand.isDown(flags: 0x100000 | 0x10))
        #expect(ShortcutKey.rightControl.isDown(flags: 0x40000 | 0x2000))
    }

    @Test func fnMatchesTheGlobeKeyToo() {
        #expect(ShortcutKey.fn.matches(63))
        #expect(ShortcutKey.fn.matches(179))
        #expect(ShortcutKey.fn.isDown(flags: 0x80_0000))
        #expect(!ShortcutKey.rightOption.matches(63))
    }

    @Test func regularKeysAreNotModifiers() {
        let f13 = ShortcutKey(keyCode: 105)
        #expect(!f13.isModifier)
        #expect(f13.builtInName == "F13")
        #expect(!f13.isDown(flags: .max))
    }

    @Test func reservedKeysAreNotAllowed() {
        #expect(!ShortcutKey.isAllowed(keyCode: 53)) // Escape
        #expect(!ShortcutKey.isAllowed(keyCode: 57)) // Caps Lock
        #expect(!ShortcutKey.isAllowed(keyCode: 36)) // Return
        #expect(!ShortcutKey.isAllowed(keyCode: 76)) // keypad Enter
        #expect(ShortcutKey.isAllowed(keyCode: 61))
        #expect(ShortcutKey.isAllowed(keyCode: 105))
    }

    @Test func presetsAreNamedModifiers() {
        for key in ShortcutKey.presets {
            #expect(key.builtInName != nil)
            #expect(key.isModifier)
        }
    }

    @Test func bindingsMergeRolesForOneKey() {
        #expect(ShortcutBindings.make(hold: .fn, handsFree: .fn) == [.fn: [.hold, .handsFree]])
        #expect(ShortcutBindings.make(hold: .fn, handsFree: nil) == [.fn: .hold])
        #expect(ShortcutBindings.make(hold: .fn, handsFree: .rightOption) == [.fn: .hold, .rightOption: .handsFree])
    }
}
