import AudioKit
import AudioKitEX
import AVFoundation
import SoundpipeAudioKit
import SwiftUI

@Observable
public class TunerConductor {
    public var data = TunerData()
    public var engineIsRunning: Bool = false
    public var errorMessage: String? = nil
    
    // set this to your logger / analytics capturing class
    public var Logger: LogsEvents.Type?
    
    public init(isMockingInput: Bool = false, Logger: LogsEvents.Type? = nil) {
        self.Logger = Logger
        engine = AudioEngine()
        if let input = engine.input, !isMockingInput {
            setupAudioChain(input: input)
            configureAudioSession()
        } else {
            setupMockDataGenerator()
        }
    }
    
    public func start() {
        if let mockDataGenerator {
            mockDataGenerator.startGenerating()
            engineIsRunning = true
        } else {
            do {
                try engine.start()
                tracker?.start()
                engineIsRunning = true
            } catch {
                Logger?.log(TunerEvent.audioEngineStart.rawValue, additionalContext: ["error": String(describing: error)])
                errorMessage = error.localizedDescription
                engineIsRunning = false
                tracker?.stop()
            }
        }
    }
    
    public func stop() {
        if let mockDataGenerator {
            mockDataGenerator.stopGenerating()
        } else {
            tracker?.stop()
            engine.stop()
        }
        engineIsRunning = false
        data = TunerData()
    }
    
    private var engine: AudioEngine
    private var wasRunningWhenAudioInterrupted: Bool = false
    private var tracker: PitchTap?
    private var mockDataGenerator: MockTunerDataGenerator?
    private let noteFrequencies = TunerPitch.allCases.map({ $0.noteFrequency })
    private let noteNames = TunerPitch.allCases.map({ $0.noteNameSharp })
    
    private func setupAudioChain(input: AudioEngine.InputNode) {
        // change buffer size to increase or decrease refresh rate of tracker
        tracker = PitchTap(input, bufferSize: 1024) { pitch, amp in
            self.update(pitch[0], amp[0])
        }

        // gain of zero to prevent feedback
        let fader = Fader(input, gain: 0)
        
        engine.output = fader
    }
    
    private func setupMockDataGenerator() {
        let mockDataGenerator = MockTunerDataGenerator()
        mockDataGenerator.onUpdate = update
        self.mockDataGenerator = mockDataGenerator
    }
    
    private func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord,
                                         mode: .measurement,
                                         options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
            try audioSession.setActive(true)
        } catch {
            Logger?.log(TunerEvent.setAudioSessionCategory.rawValue, additionalContext: ["error": String(describing: error)])
            errorMessage = error.localizedDescription
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(handleAudioSessionInterruption),
                                               name: AVAudioSession.interruptionNotification,
                                               object: audioSession)
    }
    
    private func update(_ pitch: AUValue, _ amp: AUValue) {
        guard amp > 0.025 else { return }

        var frequency = pitch
        while frequency > Float(noteFrequencies[noteFrequencies.count - 1]) {
            frequency /= 2.0
        }
        while frequency < Float(noteFrequencies[0]) {
            frequency *= 2.0
        }

        var minDistance: Float = 10000.0
        var index = 0

        for possibleIndex in 0 ..< noteFrequencies.count {
            let distance = fabsf(Float(noteFrequencies[possibleIndex]) - frequency)
            if distance < minDistance {
                index = possibleIndex
                minDistance = distance
            }
        }
        
        var octave = Int(log2f(pitch / frequency))
        var targetFrequency = noteFrequencies[index] * pow(2.0, Double(octave))
        var deviation = 1200 * log2(pitch / Float(targetFrequency))

        // Check if the deviation is significantly high and adjust the note, octave, and deviation accordingly
        if deviation > 50 {
            index = (index + 1) % noteFrequencies.count
            if index == 0 {
                octave += 1
            }
            targetFrequency = noteFrequencies[index] * pow(2.0, Double(Float(octave)))
            deviation = 1200 * log2(pitch / Float(targetFrequency))
        }

        DispatchQueue.main.async {
            self.data.pitch = pitch
            self.data.noteName = "\(self.noteNames[index])"
            self.data.octaveNumber = octave
            self.data.deviation = deviation
        }
    }
    
    @objc private func handleAudioSessionInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo else {
            Logger?.log(TunerEvent.audioEngineInterruptionUnknown.rawValue, additionalContext: nil)
            return
        }
        
        let stringKeyedUserInfo: [String: Any] = userInfo.reduce(into: [String: Any]()) { result, pair in
            if let key = pair.key as? String {
                result[key] = pair.value
            }
        }

        Logger?.log(TunerEvent.audioEngineInterruption.rawValue, additionalContext: stringKeyedUserInfo)
        
        guard let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        if type == .began {
            wasRunningWhenAudioInterrupted = engineIsRunning
            stop()
        } else if type == .ended {
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                Logger?.log(TunerEvent.audioSessionSetActiveFailed.rawValue, additionalContext: ["error": String(describing: error)])
            }
            
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt,
               AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume) {
                if wasRunningWhenAudioInterrupted {
                    start()
                }
            }
        }
    }
}

enum TunerEvent: String {
    case audioEngineStart = "Audio Engine Start",
         setAudioSessionCategory = "Set Audio Session Cateogry",
         audioEngineInterruption = "Audio Engine Interruption",
         audioEngineInterruptionUnknown = "Audio Engine Interruption Unknown",
         audioSessionSetActiveFailed = "Audio Session Set Active Failed"
}
