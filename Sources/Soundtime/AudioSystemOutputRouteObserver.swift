import CoreAudio
import Foundation

struct AudioSystemOutputRouteChange: Sendable {
    let reasons: [String]
    let outputDeviceID: AudioDeviceID?
}

@MainActor
final class AudioSystemOutputRouteObserver {
    private enum ChangeReason: String, Hashable {
        case defaultOutputDevice = "default-output-device"
        case deviceList = "device-list"
        case dataSource = "output-data-source"
        case dataSourceList = "output-data-source-list"
        case deviceConfiguration = "output-device-configuration"
        case deviceAlive = "output-device-alive"
        case nominalSampleRate = "output-device-sample-rate"
    }

    private struct Registration {
        let objectID: AudioObjectID
        let address: AudioObjectPropertyAddress
        let listener: AudioObjectPropertyListenerBlock
    }

    private let onRouteChanged: (AudioSystemOutputRouteChange) -> Void
    private var systemRegistrations: [Registration] = []
    private var outputDeviceRegistrations: [Registration] = []
    private var monitoredOutputDeviceID: AudioDeviceID?
    private var pendingReasons: Set<ChangeReason> = []
    private var pendingDeliveryWorkItem: DispatchWorkItem?
    private var isStarted = false

    init(onRouteChanged: @escaping (AudioSystemOutputRouteChange) -> Void) {
        self.onRouteChanged = onRouteChanged
    }

    func start() {
        guard !isStarted else {
            return
        }
        isStarted = true
        registerSystemProperty(
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            reason: .defaultOutputDevice
        )
        registerSystemProperty(
            selector: kAudioHardwarePropertyDevices,
            reason: .deviceList
        )
        rebuildOutputDeviceRegistrations()
    }

    func stop() {
        guard isStarted else {
            return
        }
        isStarted = false
        pendingDeliveryWorkItem?.cancel()
        pendingDeliveryWorkItem = nil
        pendingReasons.removeAll()
        removeRegistrations(&outputDeviceRegistrations)
        removeRegistrations(&systemRegistrations)
        monitoredOutputDeviceID = nil
    }

    private func registerSystemProperty(
        selector: AudioObjectPropertySelector,
        reason: ChangeReason
    ) {
        register(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            reason: reason,
            into: &systemRegistrations
        )
    }

    private func rebuildOutputDeviceRegistrations() {
        removeRegistrations(&outputDeviceRegistrations)
        monitoredOutputDeviceID = AudioDeviceRegistry.defaultOutputDeviceID()
        guard let monitoredOutputDeviceID else {
            return
        }

        registerOutputDeviceProperty(
            objectID: monitoredOutputDeviceID,
            selector: kAudioDevicePropertyDataSource,
            scope: kAudioDevicePropertyScopeOutput,
            reason: .dataSource
        )
        registerOutputDeviceProperty(
            objectID: monitoredOutputDeviceID,
            selector: kAudioDevicePropertyDataSources,
            scope: kAudioDevicePropertyScopeOutput,
            reason: .dataSourceList
        )
        registerOutputDeviceProperty(
            objectID: monitoredOutputDeviceID,
            selector: kAudioDevicePropertyDeviceHasChanged,
            scope: kAudioObjectPropertyScopeGlobal,
            reason: .deviceConfiguration
        )
        registerOutputDeviceProperty(
            objectID: monitoredOutputDeviceID,
            selector: kAudioDevicePropertyDeviceIsAlive,
            scope: kAudioObjectPropertyScopeGlobal,
            reason: .deviceAlive
        )
        registerOutputDeviceProperty(
            objectID: monitoredOutputDeviceID,
            selector: kAudioDevicePropertyNominalSampleRate,
            scope: kAudioObjectPropertyScopeGlobal,
            reason: .nominalSampleRate
        )
    }

    private func registerOutputDeviceProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        reason: ChangeReason
    ) {
        register(
            objectID: objectID,
            address: AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            ),
            reason: reason,
            into: &outputDeviceRegistrations
        )
    }

    private func register(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        reason: ChangeReason,
        into registrations: inout [Registration]
    ) {
        var mutableAddress = address
        guard AudioObjectHasProperty(objectID, &mutableAddress) else {
            return
        }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.propertyDidChange(reason)
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            objectID,
            &mutableAddress,
            .main,
            listener
        )
        guard status == noErr else {
            SoundtimeDiagnostics.shared.record(
                category: .device,
                severity: .warning,
                name: "output-route-listener-registration-failed",
                message: "Soundtime could not monitor an output route property.",
                fields: [
                    "reason": reason.rawValue,
                    "status": "\(status)",
                ]
            )
            return
        }

        registrations.append(Registration(
            objectID: objectID,
            address: address,
            listener: listener
        ))
    }

    private func removeRegistrations(_ registrations: inout [Registration]) {
        for registration in registrations {
            var address = registration.address
            _ = AudioObjectRemovePropertyListenerBlock(
                registration.objectID,
                &address,
                .main,
                registration.listener
            )
        }
        registrations.removeAll()
    }

    private func propertyDidChange(_ reason: ChangeReason) {
        guard isStarted else {
            return
        }
        if reason == .defaultOutputDevice || reason == .deviceList {
            rebuildOutputDeviceRegistrations()
        }
        pendingReasons.insert(reason)
        pendingDeliveryWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.deliverPendingChange()
        }
        pendingDeliveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: workItem)
    }

    private func deliverPendingChange() {
        pendingDeliveryWorkItem = nil
        guard isStarted, !pendingReasons.isEmpty else {
            return
        }
        let reasons = pendingReasons.map(\.rawValue).sorted()
        pendingReasons.removeAll()
        onRouteChanged(AudioSystemOutputRouteChange(
            reasons: reasons,
            outputDeviceID: AudioDeviceRegistry.defaultOutputDeviceID()
        ))
    }
}
