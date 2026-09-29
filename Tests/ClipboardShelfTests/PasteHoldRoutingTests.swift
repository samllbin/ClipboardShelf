import Carbon
import CoreGraphics
import XCTest
@testable import ClipboardShelf

final class PasteHoldRoutingTests: XCTestCase {
    private func event(
        _ phase: PasteHoldRouting.Phase = .down,
        at time: TimeInterval = 0,
        keyCode: CGKeyCode = CGKeyCode(kVK_ANSI_V),
        flags: CGEventFlags = .maskCommand,
        repeat isRepeat: Bool = false,
        synthetic: Bool = false
    ) -> PasteHoldRouting.Event {
        .init(
            phase: phase, keyCode: keyCode, flags: flags,
            isRepeat: isRepeat, isSynthetic: synthetic, timestamp: time
        )
    }

    func testInitialCommandVStartsDeadlineAndCapturesPhysicalKey() {
        var routing = PasteHoldRouting()
        XCTAssertEqual(routing.route(event(), canIntercept: true), [.beginHold, .suppress])
        XCTAssertTrue(routing.isPending)
        XCTAssertTrue(routing.hasSuppressedV)
    }

    func testQuickReleasePastesImmediatelyWithoutWaitingForThreshold() {
        var routing = PasteHoldRouting()
        _ = routing.route(event(), canIntercept: true)
        XCTAssertEqual(routing.route(event(.up, at: 0.05), canIntercept: true), [.pasteCurrent, .suppress])
        XCTAssertFalse(routing.isPending)
        XCTAssertFalse(routing.hasSuppressedV)
        XCTAssertEqual(routing.advance(to: 1, canIntercept: true), [])
        XCTAssertEqual(routing.route(event(.up, at: 1), canIntercept: true), [.passThrough])
    }

    func testReleaseBeforeThresholdIsShortAndAtThresholdIsLong() {
        let boundaries: [(TimeInterval, PasteHoldRouting.Action)] = [
            (0.399, .pasteCurrent), (0.4, .showCandidates), (0.401, .showCandidates)
        ]
        for (release, action) in boundaries {
            var routing = PasteHoldRouting()
            _ = routing.route(event(), canIntercept: true)
            XCTAssertEqual(routing.route(event(.up, at: release), canIntercept: true), [action, .suppress])
            XCTAssertEqual(routing.advance(to: 2, canIntercept: true), [])
        }
    }

    func testTimerShowsCandidatesExactlyOnceWhileStillHeld() {
        var routing = PasteHoldRouting()
        _ = routing.route(event(at: 10), canIntercept: true)
        XCTAssertEqual(routing.advance(to: 10.399, canIntercept: true), [])
        XCTAssertTrue(routing.isPending)
        XCTAssertEqual(routing.advance(to: 10.4, canIntercept: true), [.showCandidates])
        XCTAssertFalse(routing.isPending)
        XCTAssertTrue(routing.hasSuppressedV)
        XCTAssertEqual(routing.advance(to: 11, canIntercept: true), [])
        XCTAssertEqual(routing.route(event(.up, at: 11), canIntercept: true), [.suppress])
        XCTAssertFalse(routing.hasSuppressedV)
    }

    func testShortReleaseWithoutCommandFlagStillPastes() {
        var routing = PasteHoldRouting()
        _ = routing.route(event(), canIntercept: true)
        XCTAssertEqual(routing.route(event(.up, at: 0.1, flags: []), canIntercept: true), [.pasteCurrent, .suppress])
    }

    func testCommandReleaseBeforeVCommitsPasteAndConsumesLaterVUp() {
        var routing = PasteHoldRouting()
        _ = routing.route(event(), canIntercept: true)
        XCTAssertEqual(routing.route(event(.flagsChanged, at: 0.1, keyCode: CGKeyCode(kVK_Command), flags: []), canIntercept: true), [.pasteCurrent, .passThrough])
        XCTAssertFalse(routing.isPending)
        XCTAssertTrue(routing.hasSuppressedV)
        XCTAssertEqual(routing.advance(to: 1, canIntercept: true), [])
        XCTAssertEqual(routing.route(event(.up, at: 1, flags: []), canIntercept: true), [.suppress])
    }

    func testCommandReleaseAfterDeadlineRecognizesLongPressWithDelayedTimer() {
        var routing = PasteHoldRouting()
        _ = routing.route(event(), canIntercept: true)
        XCTAssertEqual(routing.route(event(.flagsChanged, at: 0.5, keyCode: CGKeyCode(kVK_Command), flags: []), canIntercept: true), [.showCandidates, .passThrough])
        XCTAssertEqual(routing.advance(to: 1, canIntercept: true), [])
        XCTAssertEqual(routing.route(event(.up, at: 1, flags: []), canIntercept: true), [.suppress])
    }

    func testAddingModifierBeforeThresholdResolvesOrdinaryPaste() {
        var routing = PasteHoldRouting()
        _ = routing.route(event(), canIntercept: true)
        XCTAssertEqual(routing.route(event(.flagsChanged, at: 0.1, keyCode: CGKeyCode(kVK_Shift), flags: [.maskCommand, .maskShift]), canIntercept: true), [.pasteCurrent, .passThrough])
        XCTAssertEqual(routing.advance(to: 1, canIntercept: true), [])
        XCTAssertEqual(routing.route(event(.up, at: 1), canIntercept: true), [.suppress])
    }

    func testCapsLockAndNonModifierFlagsDoNotEndHold() {
        let combinations: [CGEventFlags] = [
            [.maskCommand, .maskAlphaShift], [.maskCommand, .maskNonCoalesced],
            [.maskCommand, .maskAlphaShift, .maskNonCoalesced]
        ]
        for flags in combinations {
            var routing = PasteHoldRouting()
            XCTAssertEqual(routing.route(event(flags: flags), canIntercept: true), [.beginHold, .suppress])
            XCTAssertEqual(routing.route(event(.flagsChanged, at: 0.1, keyCode: CGKeyCode(kVK_CapsLock), flags: flags), canIntercept: true), [.passThrough])
            XCTAssertEqual(routing.advance(to: 0.4, canIntercept: true), [.showCandidates])
        }
    }

    func testOtherShortcutModifiersAndPlainTypingAreUntouched() {
        let combinations: [CGEventFlags] = [
            [], .maskControl, .maskAlternate, .maskShift,
            [.maskCommand, .maskShift], [.maskCommand, .maskControl],
            [.maskCommand, .maskAlternate], [.maskCommand, .maskSecondaryFn],
            [.maskCommand, .maskHelp], [.maskCommand, .maskNumericPad]
        ]
        for flags in combinations {
            var routing = PasteHoldRouting()
            XCTAssertEqual(routing.route(event(flags: flags), canIntercept: true), [.passThrough])
            XCTAssertEqual(routing.route(event(.up, at: 0.2, flags: flags), canIntercept: true), [.passThrough])
            XCTAssertEqual(routing.advance(to: 1, canIntercept: true), [])
            XCTAssertFalse(routing.hasSuppressedV)
        }
        var routing = PasteHoldRouting()
        XCTAssertEqual(routing.route(event(keyCode: CGKeyCode(kVK_ANSI_C)), canIntercept: true), [.passThrough])
    }

    func testRepeatsCannotPasteOrOpenAnotherPicker() {
        var routing = PasteHoldRouting()
        _ = routing.route(event(), canIntercept: true)
        XCTAssertEqual(routing.route(event(at: 0.1, repeat: true), canIntercept: true), [.suppress])
        XCTAssertEqual(routing.route(event(at: 0.4, repeat: true), canIntercept: true), [.showCandidates, .suppress])
        XCTAssertEqual(routing.route(event(at: 0.5, repeat: true), canIntercept: true), [.suppress])
        XCTAssertEqual(routing.route(event(at: 0.6, flags: [], repeat: true), canIntercept: true), [.suppress])
        XCTAssertEqual(routing.advance(to: 1, canIntercept: true), [])
        XCTAssertEqual(routing.route(event(.up, at: 1), canIntercept: true), [.suppress])
    }

    func testUncapturedRepeatsAndKeyUpDoNotStartHold() {
        var routing = PasteHoldRouting()
        XCTAssertEqual(routing.route(event(repeat: true), canIntercept: true), [.passThrough])
        XCTAssertEqual(routing.route(event(.up, at: 1), canIntercept: true), [.passThrough])
        XCTAssertEqual(routing.advance(to: 2, canIntercept: true), [])
    }

    func testUnrelatedKeyDownCommitsPasteBeforeFollowingShortcut() {
        var routing = PasteHoldRouting()
        _ = routing.route(event(), canIntercept: true)
        XCTAssertEqual(routing.route(event(at: 0.05, keyCode: CGKeyCode(kVK_ANSI_C)), canIntercept: true), [.pasteCurrent, .passThrough])
        XCTAssertEqual(routing.route(event(at: 0.1, keyCode: CGKeyCode(kVK_ANSI_A), flags: []), canIntercept: true), [.passThrough])
        XCTAssertEqual(routing.advance(to: 1, canIntercept: true), [])
        XCTAssertEqual(routing.route(event(.up, at: 1), canIntercept: true), [.suppress])
    }

    func testOtherKeyUpDoesNotResolveHoldOrConsumeVPairing() {
        var routing = PasteHoldRouting()
        _ = routing.route(event(), canIntercept: true)
        XCTAssertEqual(routing.route(event(.up, at: 0.1, keyCode: CGKeyCode(kVK_ANSI_C)), canIntercept: true), [.passThrough])
        XCTAssertTrue(routing.isPending)
        XCTAssertTrue(routing.hasSuppressedV)
        XCTAssertEqual(routing.route(event(.up, at: 0.2), canIntercept: true), [.pasteCurrent, .suppress])
    }

    func testEscapeCancelsPendingPasteAndConsumesEscapePair() {
        var routing = PasteHoldRouting()
        _ = routing.route(event(), canIntercept: true)
        XCTAssertEqual(routing.route(event(at: 0.1, keyCode: CGKeyCode(kVK_Escape)), canIntercept: true), [.cancel, .suppress])
        XCTAssertFalse(routing.isPending)
        XCTAssertEqual(routing.route(event(at: 0.2, keyCode: CGKeyCode(kVK_Escape), repeat: true), canIntercept: true), [.suppress])
        XCTAssertEqual(routing.route(event(.up, at: 0.3, keyCode: CGKeyCode(kVK_Escape)), canIntercept: true), [.suppress])
        XCTAssertEqual(routing.route(event(.up, at: 0.3, keyCode: CGKeyCode(kVK_Escape)), canIntercept: true), [.passThrough])
        XCTAssertEqual(routing.advance(to: 1, canIntercept: true), [])
        XCTAssertEqual(routing.route(event(.up, at: 1), canIntercept: true), [.suppress])
    }

    func testEscapeAfterPickerOpenedPassesToPicker() {
        var routing = PasteHoldRouting()
        _ = routing.route(event(), canIntercept: true)
        _ = routing.advance(to: 0.4, canIntercept: true)
        XCTAssertEqual(routing.route(event(at: 0.5, keyCode: CGKeyCode(kVK_Escape)), canIntercept: true), [.passThrough])
        XCTAssertEqual(routing.route(event(.up, at: 0.6), canIntercept: true), [.suppress])
    }

    func testEscapePairRemainsTrackedAfterVWasReleased() {
        var routing = PasteHoldRouting()
        XCTAssertFalse(routing.isTracking)
        _ = routing.route(event(), canIntercept: true)
        XCTAssertTrue(routing.isTracking)
        _ = routing.route(event(at: 0.1, keyCode: CGKeyCode(kVK_Escape)), canIntercept: true)
        XCTAssertEqual(routing.route(event(.up, at: 0.2), canIntercept: true), [.suppress])
        XCTAssertFalse(routing.hasSuppressedV)
        XCTAssertFalse(routing.isPending)
        XCTAssertTrue(routing.isTracking)
        XCTAssertEqual(routing.route(event(.up, at: 0.3, keyCode: CGKeyCode(kVK_Escape)), canIntercept: true), [.suppress])
        XCTAssertFalse(routing.isTracking)
    }

    func testRapidTapThenTapKeepsIndependentDeadlines() {
        var routing = PasteHoldRouting()
        XCTAssertEqual(routing.route(event(), canIntercept: true), [.beginHold, .suppress])
        XCTAssertEqual(routing.route(event(.up, at: 0.04), canIntercept: true), [.pasteCurrent, .suppress])
        XCTAssertEqual(routing.route(event(at: 0.08), canIntercept: true), [.beginHold, .suppress])
        XCTAssertEqual(routing.advance(to: 0.1, canIntercept: true), [])
        XCTAssertEqual(routing.route(event(.up, at: 0.12), canIntercept: true), [.pasteCurrent, .suppress])
        XCTAssertEqual(routing.advance(to: 1, canIntercept: true), [])
    }

    func testOldTimerCannotOpenPickerBeforeNewHoldDeadline() {
        var routing = PasteHoldRouting()
        _ = routing.route(event(), canIntercept: true)
        _ = routing.route(event(.up, at: 0.05), canIntercept: true)
        _ = routing.route(event(at: 0.3), canIntercept: true)
        XCTAssertEqual(routing.advance(to: 0.4, canIntercept: true), [])
        XCTAssertTrue(routing.isPending)
        XCTAssertEqual(routing.advance(to: 0.7, canIntercept: true), [.showCandidates])
        XCTAssertEqual(routing.route(event(.up, at: 0.8), canIntercept: true), [.suppress])
    }

    func testNewPressAfterLongGestureStartsFreshHold() {
        var routing = PasteHoldRouting()
        _ = routing.route(event(), canIntercept: true)
        _ = routing.advance(to: 0.4, canIntercept: true)
        _ = routing.route(event(.up, at: 0.5), canIntercept: true)
        XCTAssertEqual(routing.route(event(at: 1), canIntercept: true), [.beginHold, .suppress])
        XCTAssertEqual(routing.route(event(.up, at: 1.1), canIntercept: true), [.pasteCurrent, .suppress])
    }

    func testSyntheticReplayDoesNotResolvePhysicalHoldOrConsumePairing() {
        var routing = PasteHoldRouting()
        XCTAssertEqual(routing.route(event(synthetic: true), canIntercept: true), [.passThrough])
        _ = routing.route(event(), canIntercept: true)
        XCTAssertEqual(routing.route(event(at: 0.1, synthetic: true), canIntercept: true), [.passThrough])
        XCTAssertEqual(routing.route(event(.up, at: 0.1, synthetic: true), canIntercept: true), [.passThrough])
        XCTAssertEqual(routing.route(event(.flagsChanged, at: 0.2, flags: [], synthetic: true), canIntercept: true), [.passThrough])
        XCTAssertEqual(routing.route(event(.up, at: 0.3, synthetic: true), canIntercept: false), [.passThrough])
        XCTAssertTrue(routing.isPending)
        XCTAssertTrue(routing.hasSuppressedV)
        XCTAssertEqual(routing.advance(to: 0.4, canIntercept: true), [.showCandidates])
        XCTAssertEqual(routing.route(event(.up, at: 0.5), canIntercept: true), [.suppress])
    }

    func testUnavailableInputPassesThroughAndResetsPendingState() {
        var routing = PasteHoldRouting()
        XCTAssertEqual(routing.route(event(), canIntercept: false), [.passThrough])
        _ = routing.route(event(), canIntercept: true)
        XCTAssertEqual(routing.route(event(at: 0.1, repeat: true), canIntercept: false), [.passThrough])
        XCTAssertFalse(routing.isPending)
        XCTAssertFalse(routing.hasSuppressedV)
        XCTAssertEqual(routing.route(event(.up, at: 0.2), canIntercept: true), [.passThrough])
        XCTAssertEqual(routing.advance(to: 1, canIntercept: true), [])
    }

    func testPermissionLossAtDeadlineNeverShowsCandidates() {
        var routing = PasteHoldRouting()
        _ = routing.route(event(), canIntercept: true)
        XCTAssertEqual(routing.advance(to: 0.4, canIntercept: false), [])
        XCTAssertFalse(routing.isPending)
        XCTAssertFalse(routing.hasSuppressedV)
        XCTAssertEqual(routing.advance(to: 1, canIntercept: true), [])
    }

    func testCancelPendingPreservesCapturedVPairWithoutPasting() {
        var routing = PasteHoldRouting()
        _ = routing.route(event(), canIntercept: true)
        XCTAssertEqual(routing.cancelPending(), [])
        XCTAssertFalse(routing.isPending)
        XCTAssertTrue(routing.hasSuppressedV)
        XCTAssertEqual(routing.advance(to: 1, canIntercept: true), [])
        XCTAssertEqual(routing.route(event(at: 1, repeat: true), canIntercept: true), [.suppress])
        XCTAssertEqual(routing.route(event(.up, at: 1.1), canIntercept: true), [.suppress])
    }

    func testResetClearsDeadlineAndCapturedKeyPairing() {
        var routing = PasteHoldRouting()
        _ = routing.route(event(), canIntercept: true)
        routing.reset()
        XCTAssertFalse(routing.isPending)
        XCTAssertFalse(routing.hasSuppressedV)
        XCTAssertEqual(routing.advance(to: 1, canIntercept: true), [])
        XCTAssertEqual(routing.route(event(.up, at: 1), canIntercept: true), [.passThrough])
    }

    func testFreshPlainVRecoversFromMissingOldKeyUp() {
        var routing = PasteHoldRouting()
        _ = routing.route(event(), canIntercept: true)
        XCTAssertEqual(routing.route(event(at: 0.1, flags: []), canIntercept: true), [.passThrough])
        XCTAssertFalse(routing.isPending)
        XCTAssertFalse(routing.hasSuppressedV)
        XCTAssertEqual(routing.route(event(.up, at: 0.2, flags: []), canIntercept: true), [.passThrough])
        XCTAssertEqual(routing.advance(to: 1, canIntercept: true), [])
    }
}
