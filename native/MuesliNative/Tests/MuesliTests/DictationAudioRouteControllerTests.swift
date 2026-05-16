import CoreAudio
import Testing
@testable import MuesliNativeApp

@Suite("DictationAudioRouteController")
struct DictationAudioRouteControllerTests {
    @Test("dictation prefers built-in mic for every output route")
    func dictationPrefersBuiltInMicForEveryOutputRoute() {
        for routeKind in [AudioOutputRouteKind.speakerLike, .headphoneLike, .unknown] {
            let inspector = FakeCoreAudioDeviceInspector(
                defaultOutputDeviceID: 10,
                outputRouteKind: routeKind,
                builtInInputDeviceID: 82
            )
            let controller = DictationAudioRouteController(
                inspector: inspector,
                queue: DispatchQueue(label: "test.dictation-audio-route.\(routeKind.description)"),
                observesDefaultOutputChanges: false
            )

            #expect(controller.preferredInputDeviceIDForDictation() == 82)
            #expect(controller.cachedPreferredInputDeviceIDForDictation() == 82)
        }
    }

    @Test("dictation falls back to default input when built-in mic is unavailable")
    func dictationFallsBackWhenBuiltInMicUnavailable() {
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .headphoneLike,
            builtInInputDeviceID: nil
        )
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: DispatchQueue(label: "test.dictation-audio-route.no-built-in"),
            observesDefaultOutputChanges: false
        )

        #expect(controller.preferredInputDeviceIDForDictation() == nil)
        #expect(controller.cachedPreferredInputDeviceIDForDictation() == nil)
    }
}

private final class FakeCoreAudioDeviceInspector: CoreAudioDeviceInspecting {
    var defaultOutputDeviceIDValue: AudioObjectID?
    var outputRouteKindValue: AudioOutputRouteKind
    var builtInInputDeviceIDValue: AudioObjectID?

    init(
        defaultOutputDeviceID: AudioObjectID?,
        outputRouteKind: AudioOutputRouteKind,
        builtInInputDeviceID: AudioObjectID?
    ) {
        self.defaultOutputDeviceIDValue = defaultOutputDeviceID
        self.outputRouteKindValue = outputRouteKind
        self.builtInInputDeviceIDValue = builtInInputDeviceID
    }

    func defaultOutputDeviceID() -> AudioObjectID? {
        defaultOutputDeviceIDValue
    }

    func defaultInputDeviceID() -> AudioObjectID? {
        nil
    }

    func setDefaultInputDeviceID(_ deviceID: AudioObjectID) -> Bool {
        false
    }

    func isDeviceAvailable(_ deviceID: AudioObjectID) -> Bool {
        true
    }

    func nominalSampleRate(for deviceID: AudioObjectID) -> Double? {
        nil
    }

    func outputRouteKind(for deviceID: AudioObjectID) -> AudioOutputRouteKind {
        outputRouteKindValue
    }

    func builtInInputDeviceID() -> AudioObjectID? {
        builtInInputDeviceIDValue
    }
}
