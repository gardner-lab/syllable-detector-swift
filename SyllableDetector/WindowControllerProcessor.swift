//
//  WindowControllerProcessor.swift
//  SyllableDetector
//
//  Created by Nathan Perkins on 11/1/15.
//  Copyright © 2015 Gardner Lab. All rights reserved.
//

import Cocoa

protocol WindowControllerProcessorDelegate: class {
    func windowControllerDone(_ controller: WindowControllerProcessor)
}

class WindowControllerProcessor: NSWindowController, NSWindowDelegate {
    weak var delegate: WindowControllerProcessorDelegate?
    
    override func windowDidLoad() {
        super.windowDidLoad()
        
        window?.delegate = self
    }
    
    func windowWillClose(_ notification: Notification) {
        // when window will close, pass it up the chain
        delegate?.windowControllerDone(self)
    }
}
