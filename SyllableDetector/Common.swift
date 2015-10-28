//  Common.swift
//  VideoCapture
//
//  Created by L. Nathan Perkins on 7/2/15.
//  Copyright © 2015

import Foundation

/// A logging function that only executes in debugging mode.
func DLog(message: String, function: String = __FUNCTION__ ) {
    #if DEBUG
    print("\(function): \(message)")
    #endif
}
