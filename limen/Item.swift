//
//  Item.swift
//  limen
//
//  Created by Juan Manuel Rada Leon on 1/1/26.
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
