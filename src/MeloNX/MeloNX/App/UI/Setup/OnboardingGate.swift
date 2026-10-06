//
//  OnboardingGate.swift
//  MeloNX
//

import Foundation

enum OnboardingStep: Equatable {
    case keys
    case firmware
    case complete
}

/// Pure decision logic for whether setup can advance. Kept out of
/// SetupView on purpose: the real bug was that nothing ever re-evaluated
/// this decision when keysValid/firmwareValid changed, so putting the
/// decision itself in a plain struct makes that reachable from a test
/// without needing a live SwiftUI hierarchy.
struct OnboardingGate: Equatable {
    var keysValid: Bool
    var firmwareValid: Bool

    var requirementsSatisfied: Bool { keysValid && firmwareValid }

    var currentStep: OnboardingStep {
        if !keysValid { return .keys }
        if !firmwareValid { return .firmware }
        return .complete
    }

    /// nil means nothing is blocking — requirementsSatisfied is true.
    var blockedReason: String? {
        switch (keysValid, firmwareValid) {
        case (false, false): return "keys and firmware not imported"
        case (false, true): return "keys not imported"
        case (true, false): return "firmware not imported"
        case (true, true): return nil
        }
    }
}
