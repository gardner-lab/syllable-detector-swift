//
//  OutputStream.swift
//  SyllableDetector
//
//  Created by Nathan Perkins on 6/2/16.
//  Copyright © 2016 Gardner Lab. All rights reserved.
//

import Foundation

extension OutputStreamType {
    mutating func writeLine(string: String) {
        self.write("\(string)\n")
    }
}

class StandardOutputStream: OutputStreamType {
    func write(string: String) {
        let stdout = NSFileHandle.fileHandleWithStandardOutput()
        stdout.writeData(string.dataUsingEncoding(NSUTF8StringEncoding)!)
    }
}

class StandardErrorOutputStream: OutputStreamType {
    func write(string: String) {
        let stderr = NSFileHandle.fileHandleWithStandardError()
        stderr.writeData(string.dataUsingEncoding(NSUTF8StringEncoding)!)
    }
}
