import Foundation

public struct TunerData {
    public var pitch: Float = 0.0
    public var noteName = "-"
    public var octaveNumber: Int?
    public var deviation: Float = 0.0 // Deviation from the target pitch in cents
}
