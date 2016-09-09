//
//  ArduinoIO.swift
//  SyllableDetector
//
//  Created by Nathan Perkins on 1/8/16.
//  Copyright © 2016 Gardner Lab. All rights reserved.
//

import Foundation
import ORSSerial

let kStartupTime = 2.0
let kTimeoutDuration: TimeInterval = 0.5

/// The state of the arduino and serial port.
enum ArduinoIOState: Equatable {
    case closed
    case opened
    case waitingToOpen // Because of potential startup time, there is an inbetween period of 2 seconds during which requests are queued.
    //case WaitingToClose
    case error
    case uninitialized
}

/// Request information used to handle response.
private enum ArduinoIORequest {
    case sketchInitialize
    case readDigital(Int, (Bool?) -> Void)
    case readAnalog(Int, (UInt16?) -> Void)
}

/// Errors associated with input and output.
enum ArduinoIOError: Error, CustomStringConvertible {
    case unknownError
    case unableToOpenPath
    case portNotOpen
    case invalidPin(Int)
    case invalidMode // invalid pin mode
    case invalidValue
    
    var description: String {
        switch self {
        case .unknownError: return "Unknown error"
        case .unableToOpenPath: return "Unable to open path"
        case .portNotOpen: return "Port not open"
        case .invalidPin(let p): return "Invalid pin (\(p))"
        case .invalidMode: return "Invalid mode"
        case .invalidValue: return "Invalid value"
        }
    }
}


/// Used to track the Sketch type
enum ArduinoIOSketch: CustomStringConvertible {
    case unknown
    case io
    case encoderIO
    case servoEncoderIO
    case motorShield1
    case motorShield2
    
    var description: String {
        switch self {
        case .unknown: return "Unknown"
        case .io: return "Analog & Digital I/O (adio.pde)"
        case .encoderIO: return "Analog & Digital I/O + Encoder (arioe.pde)"
        case .servoEncoderIO: return "Analog & Digital I/O + Encoder + Servos (arioes.pde)"
        case .motorShield1: return "Motor Shield V1"
        case .motorShield2: return "Motor Shield V2"
        }
    }
}

enum ArduinoIOQueue {
    case request(ORSSerialRequest)
    case send(Data)
}

enum ArduinoIOPin: Int, CustomStringConvertible {
    case unassigned = -1
    case input = 0
    case output = 1
    
    var description: String {
        switch self {
        case .unassigned: return "Unassigned"
        case .input: return "Input"
        case .output: return "Output"
        }
    }
}

enum ArduinoIODevice {
    case detached
    case attached
}


protocol ArduinoIODelegate: class {
    //func arduinoStateChangedFrom(oldState: ArduinoIOState, newState: ArduinoIOState)
    
    func arduinoError(_ message: String, isPermanent: Bool)
}

///  An example of an extension of the ORSSerialPacketDescriptor that enables identifying delimited packets.
class DelimitedSerialPacketDescriptor: ORSSerialPacketDescriptor {
    var delimiter: Data?
    
    convenience init(delimiter: Data, maximumPacketLength maxPacketLength: UInt, userInfo: AnyObject?, responseEvaluator: @escaping ORSSerialPacketEvaluator) {
        self.init(maximumPacketLength: maxPacketLength, userInfo: userInfo, responseEvaluator: responseEvaluator)
        
        // set delimiter
        self.delimiter = delimiter
    }
    
    convenience init(delimiterString: String, maximumPacketLength maxPacketLength: UInt, userInfo: AnyObject?, responseEvaluator: @escaping ORSSerialPacketEvaluator) {
        self.init(maximumPacketLength: maxPacketLength, userInfo: userInfo, responseEvaluator: responseEvaluator)
        
        // set delimiter
        self.delimiter = delimiterString.data(using: String.Encoding.utf8)
    }
    
    private func packetMatchingExcludingFinalDelimiter(_ buffer: Data) -> Data? {
        // only use log if delimiter is provided (should only be called if delimiter exists)
        guard let delimiter = delimiter else {
            return nil
        }
        
        // empty buffer? potentially valid
        if buffer.count == 0 {
            if dataIsValidPacket(buffer) {
                return buffer
            }
            return nil
        }
        
        // work back from the end of the buffer
        for i in 0...buffer.count {
            // check for delimiter if not reading from the beginning of the buffer
            if i < buffer.count {
                // not enough space for the delimiter
                if i + delimiter.count > buffer.count {
                    continue
                }
                
                // check for proceeding delimiter
                // (could be more lenient and just check for the end of the delimiter)
                let windowDel = buffer.subdata(in: (buffer.count - i - delimiter.count)..<delimiter.count)
                
                // does not match? continue
                if windowDel != delimiter {
                    continue
                }
            }
            
            // make window
            let window = buffer.subdata(in: (buffer.count - i)..<i)
            if dataIsValidPacket(window) {
                return window
            }
        }
        
        return nil
    }
    
    override func packetMatching(atEndOfBuffer buffer: Data?) -> Data? {
        // only use log if delimiter is provided
        guard let delimiter = delimiter else {
            // otherwise inherit normal behavior
            return super.packetMatching(atEndOfBuffer: buffer)
        }
        
        // unwrap buffer
        guard let buffer = buffer else { return nil }
        
        // space for delimiter
        if buffer.count < delimiter.count {
            return nil
        }
        
        // ensure buffer ends with delimiter
        let windowFinalDel = buffer.subdata(in: (buffer.count - delimiter.count)..<delimiter.count)
        if !windowFinalDel.elementsEqual(delimiter) {
            return nil
        }
        
        return packetMatchingExcludingFinalDelimiter(buffer.subdata(in: 0..<(buffer.count - delimiter.count)))
    }
}

/// An arduinio input output class based off of the
/// [MATLAB ArduinoIO package](http://www.mathworks.com/matlabcentral/fileexchange/32374-matlab-support-for-arduino--aka-arduinoio-package-),
/// which provides a serial interface taht allows controlling pins on an Arduino device. This is meant to work with the exact sketches included
/// in the MATLAB implementation. Currently, the class only supports the "adio.pde" sketch (although some of the groundwork has been laid for broader support).
class ArduinoIO: NSObject, ORSSerialPortDelegate {
    // delegate
    weak var delegate: ArduinoIODelegate?
    
    // serial port
    private(set) var serial: ORSSerialPort? {
        didSet {
            oldValue?.delegate = nil
            serial?.delegate = self
        }
    }
    
    // is port open
    private(set) var state: ArduinoIOState = .uninitialized {
        didSet {
            //self.delegate?.arduinoStateChangedFrom(oldValue, newState: state)
        }
    }
    
    // sketch id
    var sketch = ArduinoIOSketch.unknown
    
    // board information
    private var pins = [ArduinoIOPin](repeating: ArduinoIOPin.unassigned, count: 70) // 0 and 1 are invalid pins
    private var servos = [ArduinoIODevice](repeating: ArduinoIODevice.detached, count: 69)
    private var encoders = [ArduinoIODevice](repeating: ArduinoIODevice.detached, count: 3)
    private var motors = [UInt8](repeating: UInt8(0), count: 4)
    private var steppers = [UInt8](repeating: UInt8(0), count: 2)
    
    lazy private var responseDescription: ORSSerialPacketDescriptor = DelimitedSerialPacketDescriptor(delimiter: "\r\n".data(using: String.Encoding.ascii)!, maximumPacketLength: 16, userInfo: nil, responseEvaluator: {
        (d: Data?) -> Bool in
        guard let data = d else {
            return false
        }
        return data.count > 0
    })
    
    // used to hold requests while waiting to open
    private var pendingConnection: [ArduinoIOQueue] = []
    private var requestInfo = [Int: ArduinoIORequest]()
    private var requestInfoId = 1
    
    class func getSerialPorts() -> [ORSSerialPort] {
        return ORSSerialPortManager.shared().availablePorts
    }
    
    init(serial: ORSSerialPort) {
        super.init()
        
        // set delegate
        serial.delegate = self
        
        // store and open
        self.serial = serial
        self.open()
    }
    
    deinit {
        // close
        close()
    }
    
    convenience init(path: String) throws {
        if let port = ORSSerialPort(path: path) {
            self.init(serial: port)
            return
        }
        throw ArduinoIOError.unableToOpenPath
    }
    
    private func send(_ data: Data, withRequest req: ArduinoIORequest) {
        requestInfoId += 1
        let num: Int = requestInfoId
        requestInfo[num] = req
        
        // send request
        let serialReq = ORSSerialRequest(dataToSend: data, userInfo: num as AnyObject, timeoutInterval: kTimeoutDuration, responseDescriptor: responseDescription)
        send(serialReq)
    }
    
    private func send(_ req: ORSSerialRequest) {
        if state == .opened {
            if let serialPort = serial {
                serialPort.send(req)
            }
        }
        else if state == .waitingToOpen {
            pendingConnection.append(ArduinoIOQueue.request(req))
        }
    }
    
    private func send(_ data: Data) {
        if state == .opened {
            if let serialPort = serial {
                serialPort.send(data)
            }
        }
        else if state == .waitingToOpen {
            pendingConnection.append(ArduinoIOQueue.send(data))
        }
    }
    
    private func open() {
        guard state == .uninitialized else {
            return
        }
        guard let serialPort = serial else {
            return
        }
        
        // open serial port
        serialPort.baudRate = 115200
        serialPort.open()
        
        // set waiting to open state
        state = .waitingToOpen
        
        // setup timer
        Timer.scheduledTimer(timeInterval: kStartupTime, target: self, selector: #selector(ArduinoIO.completeOpen(_:)), userInfo: nil, repeats: false)
    }
    
    /// Opening process takes 2~6 seconds. Inital requests are held until Arduino is online.
    func completeOpen(_ timer: Timer!) {
        guard self.state == .waitingToOpen else {
            return
        }
        
        DLog("ARDUINO OPEN")
        
        // set state to opened
        state = .opened
        
        // send request to complete opening process
        let data = "99".data(using: String.Encoding.ascii)!
        send(data, withRequest: ArduinoIORequest.sketchInitialize)
    }
    
    private func runPendingConnectionQueue() {
        guard let serialPort = serial else {
            return
        }
        guard self.state == .opened else {
            pendingConnection.removeAll()
            return
        }
        
        
        // clear pending requests
        for entry in pendingConnection {
            switch entry {
            case ArduinoIOQueue.send(let data):
                serialPort.send(data)
            case ArduinoIOQueue.request(let req):
                serialPort.send(req)
            }
        }
        pendingConnection.removeAll()
    }
    
    func canInteract() -> Bool {
        return state == .opened || state == .waitingToOpen
    }
    
    func isOpen() -> Bool {
        return state == .opened
    }
    
    func close() {
        switch state {
        case .closed, .error:
            return
        case .uninitialized:
            state = .closed
            return
        case .opened:
            // leave in a good state
            for i in 2...69 {
                do {
                    switch pins[i] {
                    case .unassigned: continue
                    case .output:
                        try writeTo(i, digitalValue: false)
                    case .input:
                        try setPinMode(i, to: ArduinoIOPin.output)
                        try writeTo(i, digitalValue: false)
                    }
                }
                catch {
                    break
                }
            }
            
            serial?.close()
            serial = nil
            state = .closed
            
            return
        case .waitingToOpen:
            serial?.close()
            serial = nil
            state = .closed
            return
        }
    }
    
    // MARK: - Interface
    
    private func isValidPin(_ pin: Int) -> Bool {
        return pin >= 2 && pin <= 69
    }
    
    func setPinMode(_ pin: Int, to: ArduinoIOPin) throws {
        guard canInteract() else {
            throw ArduinoIOError.portNotOpen
        }
        guard isValidPin(pin) else {
            throw ArduinoIOError.invalidPin(pin)
        }
        guard to != .unassigned else {
            throw ArduinoIOError.invalidMode
        }
        guard nil != serial else {
            throw ArduinoIOError.portNotOpen
        }
        
        DLog("ARDUINO CONFIG \(pin): \(to)")
        
        // build data to change pin mode
        let dataBytes: [UInt8] = [48, 97 + UInt8(pin), 48 + UInt8(to.rawValue)]
        let data = Data(bytes: UnsafePointer<UInt8>(dataBytes), count: dataBytes.count)
        send(data)
        
        // set the internal representation
        pins[pin] = to
        
        // TODO: potentially dettach servo
    }
    
    func getPinMode(_ pin: Int) -> ArduinoIOPin {
        if pin >= 2 && pin <= 69 {
            return pins[pin]
        }
        return .unassigned
    }
    
    func writeTo(_ pin: Int, digitalValue: Bool) throws {
        guard canInteract() else {
            throw ArduinoIOError.portNotOpen
        }
        guard isValidPin(pin) else {
            throw ArduinoIOError.invalidPin(pin)
        }
        guard pins[pin] == .output else {
            throw ArduinoIOError.invalidMode
        }
        guard nil != serial else {
            throw ArduinoIOError.portNotOpen
        }
        
        // build data to change pin mode
        let dataBytes: [UInt8] = [50, 97 + UInt8(pin), 48 + UInt8(digitalValue ? 1 : 0)]
        let data = Data(bytes: UnsafePointer<UInt8>(dataBytes), count: dataBytes.count)
        send(data)
        
        DLog("ARDUINO WRITE \(pin): \(digitalValue)")
    }
    
    func readDigitalValueFrom(_ pin: Int, andExecute cb: @escaping (Bool?) -> Void) throws {
        guard canInteract() else {
            throw ArduinoIOError.portNotOpen
        }
        guard isValidPin(pin) else {
            throw ArduinoIOError.invalidPin(pin)
        }
        guard pins[pin] == .input else {
            throw ArduinoIOError.invalidMode
        }
        guard nil != serial else {
            throw ArduinoIOError.portNotOpen
        }
        
        // build data to change pin mode
        let dataBytes: [UInt8] = [49, 97 + UInt8(pin)]
        let data = Data(bytes: UnsafePointer<UInt8>(dataBytes), count: dataBytes.count)
        send(data, withRequest: ArduinoIORequest.readDigital(pin, cb))
    }
    
    func writeTo(_ pin: Int, analogValue: UInt8) throws {
        guard canInteract() else {
            throw ArduinoIOError.portNotOpen
        }
        guard (pin >= 2 && pin <= 13) || (pin >= 44 && pin <= 46) else {
            throw ArduinoIOError.invalidPin(pin)
        }
        guard pins[pin] == .output else {
            throw ArduinoIOError.invalidMode
        }
        guard nil != serial else {
            throw ArduinoIOError.portNotOpen
        }
        
        // build data to change pin mode
        let dataBytes: [UInt8] = [52, 97 + UInt8(pin), analogValue]
        let data = Data(bytes: UnsafePointer<UInt8>(dataBytes), count: dataBytes.count)
        send(data)
        
        DLog("ARDUINO WRITE \(pin): \(analogValue)")
    }
    
    func readAnalogValueFrom(_ pin: Int, andExecute cb: @escaping (UInt16?) -> Void) throws {
        guard canInteract() else {
            throw ArduinoIOError.portNotOpen
        }
        guard pin >= 0 && pin <= 15 else {
            throw ArduinoIOError.invalidPin(pin)
        }
        guard pin < 2 || pins[pin] == .input else {
            throw ArduinoIOError.invalidMode
        }
        guard nil != serial else {
            throw ArduinoIOError.portNotOpen
        }
        
        // build data to change pin mode
        let dataBytes: [UInt8] = [51, 97 + UInt8(pin)]
        let data = Data(bytes: UnsafePointer<UInt8>(dataBytes), count: dataBytes.count)
        send(data, withRequest: ArduinoIORequest.readAnalog(pin, cb))
    }
    
    // MARK: - ORSSerialPortDelegate
    
    func serialPortWasOpened(_ serialPort: ORSSerialPort) {
        DLog("SERIAL OPENED: \(serialPort)")
    }
    
    func serialPortWasClosed(_ serialPort: ORSSerialPort) {
        DLog("SERIAL CLOSED: \(serialPort)")
    }
    
    func serialPort(_ serialPort: ORSSerialPort, didReceive data: Data) {
        // debugging
        //        if let string = NSString(data: data, encoding: NSUTF8StringEncoding) {
        //            DLog("SERIAL \(serialPort) RECEIVED: \(string)")
        //        }
    }
    
    func serialPort(_ serialPort: ORSSerialPort, didReceiveResponse responseData: Data, to request: ORSSerialRequest) {
        guard let info = request.userInfo, let reqId = info as? Int, let reqType = requestInfo[reqId] else {
            return
        }
        
        // remove value
        requestInfo.removeValue(forKey: reqId)
        
        // convert to NSString
        guard let s = NSString(data: responseData, encoding: String.Encoding.ascii.rawValue) else {
            return
        }
        
        let dataAsString: String = (s as String).trimmingCharacters(in: CharacterSet.newlines)
        
        switch reqType {
        case .sketchInitialize:
            // get sketch identifier
            switch dataAsString {
            case "0": sketch = .io
            case "1": sketch = .encoderIO
            case "2": sketch = .servoEncoderIO
            case "3": sketch = .motorShield1
            case "4": sketch = .motorShield2
            default: sketch = .unknown
            }
            
            // log sketch
            DLog("ARDUINO SKETCH: \(sketch)")
            
            if sketch == .unknown {
                // send to delegate
                delegate?.arduinoError("Unknown Sketch", isPermanent: true)
                
                // close connection
                close()
            }
            
            // run queue
            runPendingConnectionQueue()
            
        case .readDigital(let pin, let cb):
            DLog("ARDUINO READ \(pin): \(dataAsString)")
            switch dataAsString {
            case "0": cb(false)
            case "1": cb(true)
            default: cb(nil)
            }
            
        case .readAnalog(let pin, let cb):
            DLog("ARDUINO READ \(pin): \(dataAsString)")
            if let val = Int(dataAsString), val >= 0 && val <= 1023 {
                cb(UInt16(val))
            }
            else {
                cb(nil)
            }
        }
    }
    
    func serialPort(_ serialPort: ORSSerialPort, requestDidTimeout request: ORSSerialRequest) {
        guard let info = request.userInfo, let reqId = info as? Int, let reqType = requestInfo[reqId] else {
            return
        }
        
        // remove value
        requestInfo.removeValue(forKey: reqId)
        
        // log it
        DLog("ARDUINO TIMEOUT: \(reqType)")
        
        switch reqType {
        case .sketchInitialize:
            // send to delegate
            delegate?.arduinoError("Initialization Timeout", isPermanent: true)
            
            // close connection
            close()
            
        case .readAnalog(_, let cb):
            // send to delegate
            delegate?.arduinoError("Timeout \(reqType)", isPermanent: false)
            
            // callback with no value
            cb(nil)
            
        case .readDigital(_, let cb):
            // send to delegate
            delegate?.arduinoError("Timeout \(reqType)", isPermanent: false)
            
            // callback with no value
            cb(nil)
        }
    }
    
    func serialPortWasRemoved(fromSystem serialPort: ORSSerialPort) {
        DLog("SERIAL \(serialPort) REMOVED")
        
        if state == .waitingToOpen || state == .opened {
            // send to delegate
            delegate?.arduinoError("Disconnected", isPermanent: true)
        }
        
        // close everything
        serial = nil
        close()
    }
    
    func serialPort(_ serialPort: ORSSerialPort, didEncounterError error: Error) {
        DLog("SERIAL \(serialPort) ERROR: \(error)")
        
        // send to delegate
        delegate?.arduinoError("Error: \(error.localizedDescription)", isPermanent: false)
    }
}
