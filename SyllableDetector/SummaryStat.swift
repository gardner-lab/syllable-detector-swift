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
    mutating func appendValue(_ value: Double)
    func readStat() -> Double?
    mutating func resetStat()
}

struct StatMean: Stat
{
    var sum: Double = 0.0
    var count: Int = 0
    
    mutating func appendValue(_ value: Double) {
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
    
    mutating func appendValue(_ value: Double) {
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
    private var queue: DispatchQueue
    
    init(withStat stat: Stat) {
        self.stat = stat
        self.queue = DispatchQueue(label: "SummaryStat\(stat)", attributes: DispatchQueueAttributes.serial)
    }
    
    func writeValue(_ value: Double) {
        queue.async {
            self.stat.appendValue(value)
        }
    }
    
    func readStatAndReset() -> Double? {
        var ret: Double?
        queue.sync {
            ret = self.stat.readStat()
            self.stat.resetStat()
        }
        return ret
    }
}
