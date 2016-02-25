//
//  SummaryStat.swift
//  SyllableDetector
//
//  Created by Nathan Perkins on 11/11/15.
//  Copyright © 2015 Gardner Lab. All rights reserved.
//

import Foundation

protocol Stat
{
    mutating func appendValue(value: Double)
    func readStat() -> Double?
    mutating func resetStat()
}

struct StatMean: Stat
{
    var sum: Double = 0.0
    var count: Int = 0
    
    mutating func appendValue(value: Double) {
        sum += value
        count += 1
    }
    
    func readStat() -> Double? {
        guard 0 < count else { return nil }
        return sum / Double(count)
    }
    
    mutating func resetStat() {
        sum = 0.0
        count = 0
    }
}

struct StatMax: Stat
{
    var largest: Double?
    
    mutating func appendValue(value: Double) {
        if let cur = largest {
            if value > cur {
                largest = value
            }
        }
        else {
            largest = value
        }
    }
    
    func readStat() -> Double? {
        return largest
    }
    
    mutating func resetStat() {
        largest = nil
    }
}

class SummaryStat
{
    private var stat: Stat
    private var queue: dispatch_queue_t
    
    init(withStat stat: Stat) {
        self.stat = stat
        self.queue = dispatch_queue_create("SummaryStat\(stat)", DISPATCH_QUEUE_SERIAL)
    }
    
    func writeValue(value: Double) {
        dispatch_async(queue) {
            self.stat.appendValue(value)
        }
    }
    
    func readStatAndReset() -> Double? {
        var ret: Double?
        dispatch_sync(queue) {
            ret = self.stat.readStat()
            self.stat.resetStat()
        }
        return ret
    }
}
