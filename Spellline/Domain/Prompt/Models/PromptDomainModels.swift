import Foundation
import SwiftUI
import UIKit

// MARK: - Canonical Document Model

struct PromptDocument {
    var plainText: String
    var tokens: [InlineToken]
}

struct InlineToken: Identifiable, Hashable {
    let id: UUID
    var kind: CheatKind
    var value: CheatValue
    var displayStyle: CheatDisplayStyle
    var semanticKey: String
    var plainRange: NSRange
    var matchedText: String
    var commitsOnDelimiter: Bool = false

    var label: String {
        switch (kind, value) {
        case (.tag, .tag(let name)):
            return name
        case (.count, .int(let count)):
            return "\(count)"
        case (.numberWithUnit, .angle(let value)):
            return "\(Int(value))°"
        case (.timer, .seconds(let value)):
            return "\(value)s"
        case (.preset, .preset(let preset)):
            return preset.rawValue
        case (.background, .percentage(let amount)):
            return "\(Int(amount * 100))%"
        case (.size, .size(let size)):
            return size.rawValue
        case (.status, .status(let message)):
            return message
        case (.clock, .timeOfDay(let h, let m, let pm)):
            return CheatValue.formatTimeOfDay(hour12: h, minute: m, isPM: pm)
        case (.station, .station(_, let name)):
            return name
        default:
            return matchedText
        }
    }

    var iconName: String {
        switch kind {
        case .tag:
            return "tag.fill"
        case .count:
            return "number.square.fill"
        case .numberWithUnit:
            return "rotate.3d.fill"
        case .timer:
            return "timer"
        case .preset:
            return "camera.filters"
        case .background:
            return "paintpalette.fill"
        case .size:
            return "arrow.up.left.and.arrow.down.right"
        case .status:
            return "exclamationmark.triangle.fill"
        case .clock:
            return "clock.fill"
        case .station:
            if case .station(let role, _) = value {
                return role == .from ? "arrow.right.circle.fill" : "flag.checkered.circle.fill"
            }
            return "tram.fill"
        }
    }

    var tint: Color {
        switch kind {
        case .tag:
            return Color(red: 0.25, green: 0.46, blue: 0.95)
        case .count:
            return Color(red: 0.15, green: 0.62, blue: 0.46)
        case .numberWithUnit:
            return Color(red: 0.91, green: 0.34, blue: 0.29)
        case .timer:
            return Color(red: 0.75, green: 0.47, blue: 0.14)
        case .preset:
            return Color(red: 0.49, green: 0.27, blue: 0.86)
        case .background:
            return Color(red: 0.02, green: 0.52, blue: 0.82)
        case .size:
            return Color(red: 0.83, green: 0.23, blue: 0.49)
        case .status:
            return Color(red: 0.48, green: 0.30, blue: 0.04)
        case .clock:
            return Color(red: 0.08, green: 0.52, blue: 0.48)
        case .station:
            return Color(red: 0.16, green: 0.38, blue: 0.82)
        }
    }

    var uiTint: UIColor {
        UIColor(tint)
    }

    var intValue: Int {
        switch value {
        case .int(let value):
            return value
        case .angle(let value):
            return Int(value)
        case .seconds(let value):
            return value
        default:
            return 0
        }
    }

    var doubleValue: Double {
        switch value {
        case .percentage(let value):
            return value
        default:
            return 0
        }
    }

    var plainTextValue: String {
        CheatNode.plainTextValue(for: value, semanticKey: semanticKey)
    }
}


// MARK: - Display Types

struct CheatNode: Identifiable, Hashable {
    let id: UUID
    var semanticKey: String
    var kind: CheatKind
    var value: CheatValue
    var displayStyle: CheatDisplayStyle
    var sourceRangeHint: NSRange?
    var label: String

    static func plainTextValue(for value: CheatValue, semanticKey: String) -> String {
        switch value {
        case .tag(let name):
            return name
        case .int(let count):
            return "\(count)"
        case .angle(let degrees):
            return "\(Int(degrees))°"
        case .seconds(let seconds):
            return "\(seconds)s"
        case .preset(let preset):
            return preset.rawValue
        case .percentage(let amount):
            if semanticKey.hasPrefix("percent:") {
                return "\(Int(round(amount * 100)))%"
            }
            return String(format: "%.1f", amount)
        case .size(let size):
            return size.rawValue.lowercased()
        case .status(let message):
            return message
        case .timeOfDay(let h, let m, let pm):
            return CheatValue.formatTimeOfDay(hour12: h, minute: m, isPM: pm)
        case .station(_, let name):
            return name
        }
    }
}

enum CheatKind: String, Hashable {
    case tag
    case size
    case count
    case numberWithUnit
    case timer
    case preset
    case background
    case status
    case clock
    case station
}

enum CheatValue: Hashable {
    case tag(String)
    case int(Int)
    case angle(Double)
    case seconds(Int)
    case preset(FilterPreset)
    case percentage(Double)
    case size(SizePreset)
    case status(String)
    case timeOfDay(hour12: Int, minute: Int, isPM: Bool)
    case station(role: StationRole, name: String)
}

enum StationRole: String, Hashable {
    case from
    case to
}

extension CheatValue {
    static func formatTimeOfDay(hour12: Int, minute: Int, isPM: Bool) -> String {
        let h = max(1, min(12, hour12))
        let m = max(0, min(59, minute))
        return "\(h):\(String(format: "%02d", m)) \(isPM ? "PM" : "AM")"
    }
}

enum CheatDisplayStyle: Hashable {
    case chip
    case stepper
    case slider
    case menu
    case badge
    case wheel
}

enum FilterPreset: String, CaseIterable, Hashable {
    case ascii = "ASCII"
    case bloom = "Bloom"
    case pixel = "Pixel"
    case crt = "CRT"
}

enum SizePreset: String, CaseIterable, Hashable {
    case smaller = "Smaller"
    case bigger = "Bigger"
}

// MARK: - Match Candidates

struct MatchCandidate: Identifiable, Hashable {
    let id: UUID
    let range: NSRange
    let semanticKey: String
    let kind: CheatKind
    let value: CheatValue
    let confidence: Double
    let displayStyle: CheatDisplayStyle
    let matchedText: String
    let commitsOnDelimiter: Bool

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: MatchCandidate, rhs: MatchCandidate) -> Bool {
        lhs.id == rhs.id
    }
}


extension NSRange {
    var upperBound: Int {
        location + length
    }
}
