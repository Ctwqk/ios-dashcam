import Foundation
import DashCamCore

// The configuration model, loop-buffer policy and other pure logic live in the
// DashCamCore package. This file only adds the app-side (localized) bits.

extension BufferDurationOption {
    var label: String {
        switch self {
        case .min15: return NSLocalizedString("buffer.15min", comment: "")
        case .min30: return NSLocalizedString("buffer.30min", comment: "")
        case .hr1: return NSLocalizedString("buffer.1hr", comment: "")
        case .hr2: return NSLocalizedString("buffer.2hr", comment: "")
        case .hr3: return NSLocalizedString("buffer.3hr", comment: "")
        case .hr6: return NSLocalizedString("buffer.6hr", comment: "")
        }
    }
}

enum RecordingState: Equatable {
    case idle
    case recording
    case paused
    case error(String)
}
