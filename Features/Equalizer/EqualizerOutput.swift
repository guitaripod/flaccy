import AVFoundation
import Foundation
#if os(macOS)
import CoreAudio
#endif

/// Where Flaccy's sound is going right now, as far as the equalizer cares: a
/// stable identity to remember a profile against, and a name and kind to show.
struct EqualizerOutput: Equatable {

    enum Kind: String {
        case speaker
        case headphones
        case bluetooth
        case airPlay
        case usb
        case display
        case car
        case other
    }

    let id: String
    let name: String
    let kind: Kind
}

/// Reports the current output and calls back whenever it changes. iPhone reads
/// the audio session's route; the Mac listens to Core Audio's default output
/// device and its data source, which is how it tells speakers from the
/// headphone jack on the same built-in device.
@MainActor
final class EqualizerOutputWatcher {

    private(set) var current: EqualizerOutput?
    private let onChange: (EqualizerOutput?) -> Void
    private var token: NSObjectProtocol?

    init(onChange: @escaping (EqualizerOutput?) -> Void) {
        self.onChange = onChange
    }

    func start() {
        current = Self.read()
        #if os(iOS)
        token = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        #else
        installDeviceListeners()
        #endif
    }

    func refresh() {
        let output = Self.read()
        guard output != current else { return }
        current = output
        onChange(output)
    }

    #if os(iOS)
    private static func read() -> EqualizerOutput? {
        guard let port = AVAudioSession.sharedInstance().currentRoute.outputs.first else { return nil }
        let kind: EqualizerOutput.Kind
        let id: String
        switch port.portType {
        case .builtInSpeaker, .builtInReceiver:
            kind = .speaker
            id = "builtin.speaker"
        case .headphones:
            kind = .headphones
            id = "wired.headphones"
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP:
            kind = .bluetooth
            id = "bluetooth.\(port.uid)"
        case .airPlay:
            kind = .airPlay
            id = "airplay.\(port.uid)"
        case .usbAudio:
            kind = .usb
            id = "usb.\(port.uid)"
        case .HDMI, .displayPort:
            kind = .display
            id = "display.\(port.uid)"
        case .carAudio:
            kind = .car
            id = "car.\(port.uid)"
        default:
            kind = .other
            id = "other.\(port.portType.rawValue).\(port.uid)"
        }
        return EqualizerOutput(id: id, name: port.portName, kind: kind)
    }
    #else
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var observedDevice: AudioObjectID = AudioObjectID(kAudioObjectUnknown)

    private static func read() -> EqualizerOutput? {
        guard let device = defaultOutputDevice() else { return nil }
        let uid = stringProperty(device, kAudioDevicePropertyDeviceUID) ?? "unknown"
        let name = stringProperty(device, kAudioObjectPropertyName) ?? "Output"
        let transport = uint32Property(device, kAudioDevicePropertyTransportType)
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            let source = uint32Property(device, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
            if source == fourCharCode("hdpn") {
                return EqualizerOutput(id: "builtin.headphones", name: String(localized: "Headphones"), kind: .headphones)
            }
            return EqualizerOutput(id: "builtin.speaker", name: name, kind: .speaker)
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return EqualizerOutput(id: "bluetooth.\(uid)", name: name, kind: .bluetooth)
        case kAudioDeviceTransportTypeAirPlay:
            return EqualizerOutput(id: "airplay.\(uid)", name: name, kind: .airPlay)
        case kAudioDeviceTransportTypeUSB:
            return EqualizerOutput(id: "usb.\(uid)", name: name, kind: .usb)
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return EqualizerOutput(id: "display.\(uid)", name: name, kind: .display)
        default:
            return EqualizerOutput(id: "other.\(uid)", name: name, kind: .other)
        }
    }

    private func installDeviceListeners() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.observeCurrentDevice()
                    self?.refresh()
                }
            }
        }
        listenerBlock = block
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        observeCurrentDevice()
    }

    private func observeCurrentDevice() {
        guard let block = listenerBlock, let device = Self.defaultOutputDevice(), device != observedDevice else { return }
        observedDevice = device
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(device, &address, .main, block)
    }

    private static func defaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != AudioObjectID(kAudioObjectUnknown) ? device : nil
    }

    private static func stringProperty(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value?.takeRetainedValue() as String? : nil
    }

    private static func uint32Property(
        _ device: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value : 0
    }

    private static func fourCharCode(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
    #endif
}
