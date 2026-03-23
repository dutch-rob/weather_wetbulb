//
//  Item.swift
//  weather_wetbulb
//
//  Created by Rob Boer on 3/23/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
