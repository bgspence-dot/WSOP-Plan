//
//  Item.swift
//  WSOP Plan
//
//  Created by Bob Spence on 4/29/26.
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
