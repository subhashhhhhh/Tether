//
//  MotionPreference.swift
//  Tether
//
//  Reduce motion: Tether's own setting or the system's.
//

import SwiftUI

extension EnvironmentValues {
    /// Tether's Reduce motion setting or the system's, whichever is on.
    /// Set by `tetherMotionPreference()` at each window's root.
    @Entry var reducesMotion = false
}

enum MotionPreference {
    /// Settings › General › "Reduce motion". Off by default: Tether's few
    /// animations are short, and people who want them gone can say so here.
    static let key = "tether_reduce_motion"
}

struct MotionPreferenceModifier: ViewModifier {
    @AppStorage(MotionPreference.key) private var tetherReduceMotion = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    /// The system's Reduce Motion counts as well as Tether's own setting.
    private var reduceMotion: Bool { tetherReduceMotion || systemReduceMotion }

    func body(content: Content) -> some View {
        content.environment(\.reducesMotion, reduceMotion).transaction { transaction in
            if reduceMotion {
                transaction.disablesAnimations = true
                transaction.animation = nil
            }
        }
    }
}

extension View {
    /// Applies the user's Tether motion preference to this view and everything inside it.
    func tetherMotionPreference() -> some View {
        modifier(MotionPreferenceModifier())
    }
}
