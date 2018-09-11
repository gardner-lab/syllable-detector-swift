//  Common.swift
//  VideoCapture
//
//  Created by L. Nathan Perkins on 7/2/15.
//  Copyright © 2015

import Foundation

/// A logging function that only executes in debugging mode.
func DLog(_ message: String, function: String = #function ) {
    #if DEBUG
    print("\(function): \(message)")
    #endif
}

extension String {
    func trim() -> String {
        return self.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }
    
    func splitAtCharacter(_ char: Character) -> [String] {
        return self.split { $0 == char } .map(String.init)
    }
}

extension Int {
    func isPowerOfTwo() -> Bool {
        return (self != 0) && (self & (self - 1)) == 0
    }
}
