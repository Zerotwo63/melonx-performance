//
//  OnboardingGateTests.swift
//  MeloNXTests
//

import Testing
@testable import MeloNX

/// OnboardingGate is the actual decision logic behind Bug 1: "keys and
/// firmware both show green but setup never advances." These tests pin
/// down that the decision is a pure function of the current keys/firmware
/// state — not of how or in what order they got there, and not of any
/// prior "did something change" history — since the original bug was
/// exactly that nothing ever re-ran this decision when it should have.
struct OnboardingGateTests {
    @Test func freshInstallBlocksOnKeysFirst() {
        let gate = OnboardingGate(keysValid: false, firmwareValid: false)

        #expect(!gate.requirementsSatisfied)
        #expect(gate.currentStep == .keys)
        #expect(gate.blockedReason == "keys and firmware not imported")
    }

    @Test func keysOnlyBlocksOnFirmware() {
        let gate = OnboardingGate(keysValid: true, firmwareValid: false)

        #expect(!gate.requirementsSatisfied)
        #expect(gate.currentStep == .firmware)
        #expect(gate.blockedReason == "firmware not imported")
    }

    @Test func firmwareOnlyBlocksOnKeys() {
        // The real import-firmware button is disabled until keys are
        // imported, but the decision logic itself must not assume that
        // order — it has to be correct no matter which one lands first.
        let gate = OnboardingGate(keysValid: false, firmwareValid: true)

        #expect(!gate.requirementsSatisfied)
        #expect(gate.currentStep == .keys)
        #expect(gate.blockedReason == "keys not imported")
    }

    @Test func bothValidSatisfies() {
        let gate = OnboardingGate(keysValid: true, firmwareValid: true)

        #expect(gate.requirementsSatisfied)
        #expect(gate.currentStep == .complete)
        #expect(gate.blockedReason == nil)
    }

    /// This is the actual invariant that was missing before the fix:
    /// "both already true" must satisfy immediately, with no dependency
    /// on a prior false->true transition — covers reopening the setup
    /// screen or relaunching the app with keys/firmware already imported
    /// from a previous session, where nothing ever "changes" to trigger
    /// an onChange handler.
    @Test func reevaluatingWithNoPriorChangeStillSatisfies() {
        let reopened = OnboardingGate(keysValid: true, firmwareValid: true)
        #expect(reopened.requirementsSatisfied)
        #expect(reopened.blockedReason == nil)
    }
}
