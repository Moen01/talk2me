import Testing
@testable import Talk2MeCore

struct HotkeyStateMachineTests {
    @Test func holdingFnRecordsUntilRelease() {
        var machine = HotkeyStateMachine()
        #expect(machine.fnDown(at: 10.0) == .startRecording)
        #expect(machine.fnUp(at: 12.0) == .stopRecording)
        #expect(machine.state == .idle)
    }

    @Test func quickTapIsDiscarded() {
        var machine = HotkeyStateMachine()
        #expect(machine.fnDown(at: 10.0) == .startRecording)
        #expect(machine.fnUp(at: 10.1) == .cancelRecording)
        #expect(machine.state == .idle)
    }

    @Test func doubleTapStartsHandsFreeAndTapEnds() {
        var machine = HotkeyStateMachine()
        _ = machine.fnDown(at: 10.0)
        #expect(machine.fnUp(at: 10.1) == .cancelRecording)
        #expect(machine.fnDown(at: 10.3) == .startRecording)
        #expect(machine.fnUp(at: 10.4) == nil)
        #expect(machine.state == .handsFree)

        #expect(machine.fnDown(at: 20.0) == .stopRecording)
        #expect(machine.fnUp(at: 20.1) == nil)
        #expect(machine.state == .idle)
    }

    @Test func slowSecondTapIsJustAnotherTap() {
        var machine = HotkeyStateMachine()
        _ = machine.fnDown(at: 10.0)
        _ = machine.fnUp(at: 10.1)
        _ = machine.fnDown(at: 12.0)
        #expect(machine.fnUp(at: 12.1) == .cancelRecording)
        #expect(machine.state == .idle)
    }

    @Test func escapeDiscardsHandsFree() {
        var machine = HotkeyStateMachine()
        _ = machine.fnDown(at: 10.0)
        _ = machine.fnUp(at: 10.1)
        _ = machine.fnDown(at: 10.3)
        _ = machine.fnUp(at: 10.4)
        #expect(machine.otherKeyDown(0, at: 11.0) == nil)
        #expect(machine.otherKeyDown(HotkeyStateMachine.escapeKeyCode, at: 12.0) == .cancelRecording)
        #expect(machine.state == .idle)
    }

    @Test func fnUsedAsModifierCancelsAndIgnoresRelease() {
        var machine = HotkeyStateMachine()
        #expect(machine.fnDown(at: 10.0) == .startRecording)
        #expect(machine.otherKeyDown(51, at: 10.5) == .cancelRecording)
        #expect(machine.fnUp(at: 11.0) == nil)
        #expect(machine.state == .idle)
    }

    @Test func repeatedFnDownIsIgnored() {
        var machine = HotkeyStateMachine()
        _ = machine.fnDown(at: 10.0)
        #expect(machine.fnDown(at: 10.5) == nil)
    }
}
