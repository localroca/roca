@preconcurrency import ApplicationServices
@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech
import RocaCore

public protocol PermissionsServicing: Sendable {
    func isAccessibilityTrusted() async -> Bool
    func requestAccessibilityIfNeeded() async -> Bool
    func microphonePermissionStatus() async -> MicrophonePermissionStatus
    func requestMicrophoneIfNeeded() async -> Bool
    func speechRecognitionPermissionStatus() async -> SpeechRecognitionPermissionStatus
    func requestSpeechRecognitionIfNeeded() async -> Bool
}

public enum MicrophonePermissionStatus: String, Sendable, Equatable {
    case allowed
    case denied
    case notDetermined
    case restricted
}

public enum SpeechRecognitionPermissionStatus: String, Sendable, Equatable {
    case allowed
    case denied
    case notDetermined
    case restricted
}

public struct DefaultPermissionsService: PermissionsServicing {
    public init() {}

    public func isAccessibilityTrusted() async -> Bool {
        AXIsProcessTrusted()
    }

    public func requestAccessibilityIfNeeded() async -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public func microphonePermissionStatus() async -> MicrophonePermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            .allowed
        case .denied:
            .denied
        case .notDetermined:
            .notDetermined
        case .restricted:
            .restricted
        @unknown default:
            .denied
        }
    }

    public func requestMicrophoneIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            true
        case .denied, .restricted:
            false
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .audio)
        @unknown default:
            false
        }
    }

    public func speechRecognitionPermissionStatus() async -> SpeechRecognitionPermissionStatus {
        Self.speechRecognitionPermissionStatus()
    }

    public func requestSpeechRecognitionIfNeeded() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            true
        case .denied, .restricted:
            false
        case .notDetermined:
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        @unknown default:
            false
        }
    }

    private static func speechRecognitionPermissionStatus() -> SpeechRecognitionPermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            .allowed
        case .denied:
            .denied
        case .notDetermined:
            .notDetermined
        case .restricted:
            .restricted
        @unknown default:
            .denied
        }
    }
}
