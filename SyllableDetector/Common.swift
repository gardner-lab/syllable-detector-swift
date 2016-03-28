//  Common.swift
//  VideoCapture
//
//  Created by L. Nathan Perkins on 7/2/15.
//  Copyright © 2015

import Foundation

/// A logging function that only executes in debugging mode.
func DLog(message: String, function: String = #function ) {
    #if DEBUG
    print("\(function): \(message)")
    #endif
}

extension String {
    func trim() -> String {
        return self.stringByTrimmingCharactersInSet(NSCharacterSet.whitespaceAndNewlineCharacterSet())
    }
    
    func splitAtCharacter(char: Character) -> [String] {
        return self.characters.split { $0 == char } .map(String.init)
    }
}

extension Int {
    func isPowerOfTwo() -> Bool {
        return (self != 0) && (self & (self - 1)) == 0
    }
}
