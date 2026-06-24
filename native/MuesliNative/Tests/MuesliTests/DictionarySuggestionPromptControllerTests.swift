import Testing
@testable import MuesliNativeApp

@Suite("DictionarySuggestionPromptController")
struct DictionarySuggestionPromptControllerTests {
    @Test("Auto-dismiss decision is made when timer fires")
    @MainActor
    func autoDismissDecisionIsMadeWhenTimerFires() {
        #expect(DictionarySuggestionPromptController.shouldAutoDismissFromTimer(isPausedWhenTimerFires: false))
        #expect(!DictionarySuggestionPromptController.shouldAutoDismissFromTimer(isPausedWhenTimerFires: true))
    }

    @Test("Auto-dismiss completion re-checks pause state after fade")
    @MainActor
    func autoDismissCompletionRechecksPauseStateAfterFade() {
        #expect(DictionarySuggestionPromptController.shouldCompleteAutoDismissAfterFade(isPausedAtCompletion: false))
        #expect(!DictionarySuggestionPromptController.shouldCompleteAutoDismissAfterFade(isPausedAtCompletion: true))
    }

    @Test("Paused fade recovery restarts a bounded countdown")
    @MainActor
    func pausedFadeRecoveryRestartsBoundedCountdown() {
        #expect(DictionarySuggestionPromptController.resumedAutoDismissDurationAfterPausedFade(totalDuration: 15) == 5)
        #expect(DictionarySuggestionPromptController.resumedAutoDismissDurationAfterPausedFade(totalDuration: 0.15) == 0.1)
    }
}
