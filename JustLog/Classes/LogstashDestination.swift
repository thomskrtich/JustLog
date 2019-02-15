//
//  LogstashDestination.swift
//  JustLog
//
//  Created by Shabeer Hussain on 06/12/2016.
//  Copyright © 2017 Just Eat. All rights reserved.
//

import Foundation
import SwiftyBeaver
import CocoaAsyncSocket

public class LogstashDestination: BaseDestination  {
    
    public var logzioToken: String?
    
    var logsToShip = [Int : [String : Any]]()
    fileprivate var completionHandler: ((_ error: Error?) -> Void)?
    private let logzioTokenKey = "token"
    
    var logActivity: Bool = false
    let logDispatchQueue = OperationQueue()
    var socketManager: AsyncSocketManager!
    private var useHttpPost: Bool = false
    private var postUrl: URL!
    
    @available(*, unavailable)
    override init() {
        fatalError()
    }
    
    public required init(host: String, port: UInt16, timeout: TimeInterval, logActivity: Bool, allowUntrustedServer: Bool = false) {
        super.init()
        self.logActivity = logActivity
        self.logDispatchQueue.maxConcurrentOperationCount = 1
        self.useHttpPost = URL(string: host)?.scheme!.starts(with: "http") ?? false
        
        self.socketManager = AsyncSocketManager(host: host, port: port, timeout: timeout, delegate: self, logActivity: logActivity, allowUntrustedServer: allowUntrustedServer)
        
        if (self.useHttpPost) {
            self.postUrl = URL(string: host)
        }
    }
    
    deinit {
        cancelSending()
    }
    
    public func cancelSending() {
        self.logDispatchQueue.cancelAllOperations()
        self.socketManager.disconnect()
    }
    
    // MARK: - Log dispatching

    override public func send(_ level: SwiftyBeaver.Level, msg: String, thread: String, file: String,
                              function: String, line: Int, context: Any? = nil) -> String? {
        
        if let dict = msg.toDictionary() {
            var flattened = dict.flattened()
            if let logzioToken = logzioToken {
                flattened = flattened.merged(with: [logzioTokenKey: logzioToken])
            }
            
            let now = Date()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            flattened["@timestamp"] = formatter.string(from: now)
            
            addLog(flattened)
        }
        
        return nil
    }

    public func forceSend(_ headers: [String:String]?, _ completionHandler: @escaping (_ error: Error?) -> Void  = {_ in }) {
        
        if self.logsToShip.count != 0 && self.useHttpPost {
            self.postLogs(headers, completionHandler)
            return
        }
        
        if self.logsToShip.count == 0 || self.socketManager.isConnected() {
            completionHandler(nil)
            return
        }

        self.completionHandler = completionHandler
        
        logDispatchQueue.addOperation { [weak self] in
            self?.socketManager.send()
        }
    }
    
    func writeLogs() {
        
        self.logDispatchQueue.addOperation{ [weak self] in
            
            guard let `self` = self else { return }
            
            for log in self.logsToShip.sorted(by: { $0.0 < $1.0 }) {
                let logData = self.dataToShip(log.1)
                self.socketManager.write(logData, withTimeout: self.socketManager.timeout, tag: log.0)
            }
            
            self.socketManager.disconnectSafely()
        }
    }
    
    func postLogs(_ headers: [String:String]?, _ completionHandler: @escaping (_ error: Error?) -> Void  = {_ in }) {
        
        self.logDispatchQueue.addOperation{ [weak self] in
            
            guard let `self` = self else { return }
            
            let filename = self.getDocumentsDirectory().appendingPathComponent("justlog_\(arc4random()).log")
            var outputData = Data()
            var sentKeys = [Int]()
            var sendHeaders = headers
            
            if let token = self.logzioToken {
                sendHeaders?[self.logzioTokenKey] = token
            }
            
            // which lets the caller move editing to any position within the file by supplying an offset
            for log in self.logsToShip.sorted(by: { $0.0 < $1.0 }) {
                let logData = self.dataToShip(log.1)
                outputData.append(logData)
                sentKeys.append(log.0)
            }
            
            do {
                try outputData.write(to: filename, options: [])
                self.socketManager.post(url: self.postUrl, headers: sendHeaders, filename: filename, timeout: 5, completionHandler: { error in
                    // remove our log file
                    try? FileManager.default.removeItem(at: filename)
                    
                    // alert our caller
                    guard error == nil else {
                        completionHandler(error)
                        return
                    }
                    
                    // purge our log dictionary
                    for key in sentKeys {
                        self.logsToShip.removeValue(forKey: key)
                    }
                    completionHandler(nil)
                })

            } catch {
                print(error.localizedDescription)
            }
            
        }
        
    }
    
    func addLog(_ dict: [String: Any]) {
        let time = mach_absolute_time()
        let logTag = Int(truncatingIfNeeded: time)
        logsToShip[logTag] = dict
    }
    
    func dataToShip(_ dict: [String: Any]) -> Data {
        
        var data = Data()
        
        do {
            data = try JSONSerialization.data(withJSONObject:dict, options:[])
            
            if let encodedData = "\n".data(using: String.Encoding.utf8) {
                data.append(encodedData)
            }
        } catch {
            print(error.localizedDescription)
        }
        
        return data
    }
 
    func getDocumentsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0]
    }
}


// MARK: - GCDAsyncSocketManager Delegate

extension LogstashDestination: AsyncSocketManagerDelegate {
    
//    func socketDidConnect(_ socket: GCDAsyncSocket) {
//        self.postLogs()
//    }
    
    func socket(_ socket: GCDAsyncSocket, didWriteDataWithTag tag: Int) {
        logDispatchQueue.addOperation {
            self.logsToShip[tag] = nil
        }
        
        if let completionHandler = self.completionHandler {
            completionHandler(nil)
        }
        
        completionHandler = nil
    }
    
    func socketDidSecure(_ socket: GCDAsyncSocket) {
        self.writeLogs()
    }
    
    func socket(_ socket: GCDAsyncSocket, didDisconnectWithError error: Error?) {
        
        if let completionHandler = self.completionHandler {
            completionHandler(error)
        }
        
        completionHandler = nil
    }
}
 
