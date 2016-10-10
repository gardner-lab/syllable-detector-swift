//
//  OutputStream.swift
//  SyllableDetector
//
//  Created by Nathan Perkins on 6/2/16.
//  Copyright © 2016 Gardner Lab. All rights reserved.
//

import Foundation

extension TextOutputStream {
    mutating func writeLine(string: String) {
        self.write("\(string)\n")
    }
}

extension FileHandle {
    func writeLine(_ string: String) {
        write("\(string)\n".data(using: String.Encoding.utf8)!)
    }
}
