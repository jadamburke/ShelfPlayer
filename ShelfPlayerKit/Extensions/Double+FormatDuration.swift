//
//  Double+FormatDuration.swift
//  ShelfPlayer
//
//  Created by Rasmus Krämer on 29.08.24.
//

import Foundation

public struct DurationComponentsFormatter: FormatStyle {
    var unitsStyle: DateComponentsFormatter.UnitsStyle
    var allowedUnits: NSCalendar.Unit
    var maximumUnitCount: Int
    var formattingContext: Formatter.Context
    
    init(unitsStyle: DateComponentsFormatter.UnitsStyle = .abbreviated, allowedUnits: NSCalendar.Unit = [.hour, .minute], maximumUnitCount: Int = 2, formattingContext: Formatter.Context = .unknown) {
        self.unitsStyle = unitsStyle
        self.allowedUnits = allowedUnits
        self.maximumUnitCount = maximumUnitCount
        self.formattingContext = formattingContext
    }
    
    public func format(_ value: TimeInterval) -> String {
        guard value.isFinite && !value.isNaN else {
            return "?"
        }
        
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = unitsStyle
        formatter.allowedUnits = allowedUnits
        formatter.collapsesLargestUnit = false
        formatter.maximumUnitCount = maximumUnitCount
        
        formatter.formattingContext = formattingContext
        
        if unitsStyle == .positional {
            formatter.zeroFormattingBehavior = .pad
        }
        
        formatter.allowsFractionalUnits = false
        
        return formatter.string(from: value) ?? "?"
    }
}

public extension Double {
    func formatted<Style: FormatStyle>(_ style: Style) -> Style.FormatOutput where Style.FormatInput == Duration {
        Duration.seconds(self).formatted(style)
    }
}
public extension FormatStyle where Self == DurationComponentsFormatter {
    static var duration: DurationComponentsFormatter {
        .init()
    }
    static func duration(unitsStyle: DateComponentsFormatter.UnitsStyle = .abbreviated, allowedUnits: NSCalendar.Unit = [.hour, .minute], maximumUnitCount: Int = 2, formattingContext: Formatter.Context = .unknown) -> DurationComponentsFormatter {
        .init(unitsStyle: unitsStyle, allowedUnits: allowedUnits, maximumUnitCount: maximumUnitCount, formattingContext: formattingContext)
    }
}

extension NSCalendar.Unit: @retroactive Codable, @retroactive Hashable {}
extension DateComponentsFormatter.UnitsStyle: @retroactive Codable, @retroactive Hashable {}
extension Formatter.Context: @retroactive Codable {}
