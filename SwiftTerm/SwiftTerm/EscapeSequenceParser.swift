//
//  EscapeSequenceParser.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/28/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

import Foundation

enum ParserState : UInt8 {
    case Ground
    case Escape
    case EscapeIntermediate
    case CsiEntry
    case CsiParam
    case CsiIntermediate
    case CsiIgnore
    case SosPmApcString
    case OscString
    case DcsEntry
    case DcsParam
    case DcsIgnore
    case DcsIntermediate
    case DcsPassthrough
}

typealias cstring = [UInt8]

class ParsingState {
    var position : Int
    var code : UInt8
    var currentState : ParserState
    var print : Int
    var dcs : Int
    var osc : cstring
    var collect : cstring
    var parameters : [Int32]
    var abort : Bool
    
    init ()
    {
        position = 0
        code = 0
        currentState = .Ground
        print = 0
        dcs = 0
        osc = []
        collect = []
        parameters = []
        abort = false
    }
}

enum ParserAction : UInt8 {
    case Ignore
    case Error
    case Print
    case Execute
    case OscStart
    case OscPut
    case OscEnd
    case CsiDispatch
    case Param
    case Collect
    case EscDispatch
    case Clear
    case DcsHook
    case DcsPut
    case DcsUnhook
}
class TransitionTable {
    // data is packed like this:
    // currentState << 8 | characterCode  -->  action << 4 | nextState
    var table : [UInt8]
    
    init (len : Int)
    {
        table = Array.init (repeating: 0, count: len)
    }
    
    func Add (code : UInt8, state : ParserState, action : ParserAction, next : ParserState)
    {
        let v = (UInt8 (action.rawValue) << 4) | state.rawValue
        table [Int (UInt8(state.rawValue << 8) | code)] = v
    }
    
    func Add (codes : [UInt8], state : ParserState, action : ParserAction, next : ParserState)
    {
        for c in codes {
            Add (code: c, state: state, action: action, next: next)
        }
    }
    
    subscript (idx : Int) -> UInt8 {
        get {
            return table [idx]
        }
    }
}

protocol  DcsHandler {
    func hook (collect : cstring, parameters : [Int],  flag : UInt8)
    func put (data : ArraySlice<UInt8>)
    func unhook ()
}

class EscapeSequenceParser {
    
    static func r (low : UInt8, high : UInt8) -> [UInt8]
    {
        let c = high-low
        var ret = [UInt8]()
        for x in 0..<c {
            ret.append(low + x)
        }
        return ret;
    }
    
    static func rinclusive (low: ParserState, high: ParserState)-> [ParserState]
    {
        let c = high.rawValue-low.rawValue
        var ret = [ParserState]()
        for x in 0...c {
            ret.append(ParserState (rawValue: low.rawValue + x)!)
        }
        return ret;
    }
    
    static var PRINTABLES : [UInt8] = r (low: 0x20, high: 0x7f)
    static var EXECUTABLES : [UInt8] = r (low: 0x00, high: 0x19) + r (low: 0x1c, high: 0x20)
    
    static let NonAsciiPrintable : UInt8 = 0xa0
    
    static func BuildVt500TransitionTable () -> TransitionTable
    {
        let table = TransitionTable(len: 4095)
        let states = rinclusive(low: .Ground, high: .DcsPassthrough)
        
        // table with default transition
        for state in states {
            for code in 0..<NonAsciiPrintable {
                table.Add(code: code, state: state, action: .Error, next: .Ground)
            }
        }
        
        // printables
        table.Add (codes: PRINTABLES, state: .Ground, action: .Print, next: .Ground)
        
        // global anywhere rules
        for state in states {
            table.Add (codes: [0x18, 0x1a, 0x99, 0x9a], state: state, action: .Execute, next: .Ground);
            table.Add (codes: r (low: 0x80, high: 0x90), state: state, action: .Execute, next: .Ground);
            table.Add (codes: r (low: 0x90, high: 0x98), state: state, action: .Execute, next: .Ground);
            table.Add (code: 0x9c, state: state, action: .Ignore, next: .Ground); // ST as terminator
            table.Add (code: 0x1b, state: state, action: .Clear, next: .Escape);  // ESC
            table.Add (code: 0x9d, state: state, action: .OscStart, next: .OscString);  // OSC
            table.Add (codes: [0x98, 0x9e, 0x9f], state: state, action: .Ignore, next: .SosPmApcString);
            table.Add (code: 0x9b, state: state, action: .Clear, next: .CsiEntry);  // CSI
            table.Add (code: 0x90, state: state, action: .Clear, next: .DcsEntry);  // DCS
        }
        // rules for executable and 0x7f
        table.Add (codes: EXECUTABLES, state: .Ground, action: .Execute, next: .Ground);
        table.Add (codes: EXECUTABLES, state: .Escape, action: .Execute, next: .Escape);
        table.Add (code: 0x7f, state: .Escape, action: .Ignore, next: .Escape);
        table.Add (codes: EXECUTABLES, state: .OscString, action: .Ignore, next: .OscString);
        table.Add (codes: EXECUTABLES, state: .CsiEntry, action: .Execute, next: .CsiEntry);
        table.Add (code: 0x7f, state: .CsiEntry, action: .Ignore, next: .CsiEntry);
        table.Add (codes: EXECUTABLES, state: .CsiParam, action: .Execute, next: .CsiParam);
        table.Add (code: 0x7f, state: .CsiParam, action: .Ignore, next: .CsiParam);
        table.Add (codes: EXECUTABLES, state: .CsiIgnore, action: .Execute, next: .CsiIgnore);
        table.Add (codes: EXECUTABLES, state: .CsiIntermediate, action: .Execute, next: .CsiIntermediate);
        table.Add (code: 0x7f, state: .CsiIntermediate, action: .Ignore, next: .CsiIntermediate);
        table.Add (codes: EXECUTABLES, state: .EscapeIntermediate, action: .Execute, next: .EscapeIntermediate);
        table.Add (code: 0x7f, state: .EscapeIntermediate, action: .Ignore, next: .EscapeIntermediate);
        // osc
        table.Add (code: 0x5d, state: .Escape, action: .OscStart, next: .OscString);
        table.Add (codes: PRINTABLES, state: .OscString, action: .OscPut, next: .OscString);
        table.Add (code: 0x7f, state: .OscString, action: .OscPut, next: .OscString);
        table.Add (codes: [0x9c, 0x1b, 0x18, 0x1a, 0x07], state: .OscString, action: .OscEnd, next: .Ground);
        table.Add (codes: r (low: 0x1c, high: 0x20), state: .OscString, action: .Ignore, next: .OscString);
        // sos/pm/apc does nothing
        table.Add (codes: [0x58, 0x5e, 0x5f], state: .Escape, action: .Ignore, next: .SosPmApcString);
        table.Add (codes: PRINTABLES, state: .SosPmApcString, action: .Ignore, next: .SosPmApcString);
        table.Add (codes: EXECUTABLES, state: .SosPmApcString, action: .Ignore, next: .SosPmApcString);
        table.Add (code: 0x9c, state: .SosPmApcString, action: .Ignore, next: .Ground);
        table.Add (code: 0x7f, state: .SosPmApcString, action: .Ignore, next: .SosPmApcString);
        // csi entries
        table.Add (code: 0x5b, state: .Escape, action: .Clear, next: .CsiEntry);
        table.Add (codes: r (low: 0x40, high: 0x7f), state: .CsiEntry, action: .CsiDispatch, next: .Ground);
        table.Add (codes: r (low: 0x30, high: 0x3a), state: .CsiEntry, action: .Param, next: .CsiParam);
        table.Add (code: 0x3b, state: .CsiEntry, action: .Param, next: .CsiParam);
        table.Add (codes: [0x3c, 0x3d, 0x3e, 0x3f], state: .CsiEntry, action: .Collect, next: .CsiParam);
        table.Add (codes: r (low: 0x30, high: 0x3a), state: .CsiParam, action: .Param, next: .CsiParam);
        table.Add (code: 0x3b, state: .CsiParam, action: .Param, next: .CsiParam);
        table.Add (codes: r (low: 0x40, high: 0x7f), state: .CsiParam, action: .CsiDispatch, next: .Ground);
        table.Add (codes: [0x3a, 0x3c, 0x3d, 0x3e, 0x3f], state: .CsiParam, action: .Ignore, next: .CsiIgnore);
        table.Add (codes: r (low: 0x20, high: 0x40), state: .CsiIgnore, action: .Ignore, next: .CsiIgnore);
        table.Add (code: 0x7f, state: .CsiIgnore, action: .Ignore, next: .CsiIgnore);
        table.Add (codes: r (low: 0x40, high: 0x7f), state: .CsiIgnore, action: .Ignore, next: .Ground);
        table.Add (code: 0x3a, state: .CsiEntry, action: .Ignore, next: .CsiIgnore);
        table.Add (codes: r (low: 0x20, high: 0x30), state: .CsiEntry, action: .Collect, next: .CsiIntermediate);
        table.Add (codes: r (low: 0x20, high: 0x30), state: .CsiIntermediate, action: .Collect, next: .CsiIntermediate);
        table.Add (codes: r (low: 0x30, high: 0x40), state: .CsiIntermediate, action: .Ignore, next: .CsiIgnore);
        table.Add (codes: r (low: 0x40, high: 0x7f), state: .CsiIntermediate, action: .CsiDispatch, next: .Ground);
        table.Add (codes: r (low: 0x20, high: 0x30), state: .CsiParam, action: .Collect, next: .CsiIntermediate);
        // escIntermediate
        table.Add (codes: r (low: 0x20, high: 0x30), state: .Escape, action: .Collect, next: .EscapeIntermediate);
        table.Add (codes: r (low: 0x20, high: 0x30), state: .EscapeIntermediate, action: .Collect, next: .EscapeIntermediate);
        table.Add (codes: r (low: 0x30, high: 0x7f), state: .EscapeIntermediate, action: .EscDispatch, next: .Ground);
        table.Add (codes: r (low: 0x30, high: 0x50), state: .Escape, action: .EscDispatch, next: .Ground);
        table.Add (codes: r (low: 0x51, high: 0x58), state: .Escape, action: .EscDispatch, next: .Ground);
        table.Add (codes: [0x59, 0x5a, 0x5c], state: .Escape, action: .EscDispatch, next: .Ground);
        table.Add (codes: r (low: 0x60, high: 0x7f), state: .Escape, action: .EscDispatch, next: .Ground);
        // dcs entry
        table.Add (code: 0x50, state: .Escape, action: .Clear, next: .DcsEntry);
        table.Add (codes: EXECUTABLES, state: .DcsEntry, action: .Ignore, next: .DcsEntry);
        table.Add (code: 0x7f, state: .DcsEntry, action: .Ignore, next: .DcsEntry);
        table.Add (codes: r (low: 0x1c, high: 0x20), state: .DcsEntry, action: .Ignore, next: .DcsEntry);
        table.Add (codes: r (low: 0x20, high: 0x30), state: .DcsEntry, action: .Collect, next: .DcsIntermediate);
        table.Add (code: 0x3a, state: .DcsEntry, action: .Ignore, next: .DcsIgnore);
        table.Add (codes: r (low: 0x30, high: 0x3a), state: .DcsEntry, action: .Param, next: .DcsParam);
        table.Add (code: 0x3b, state: .DcsEntry, action: .Param, next: .DcsParam);
        table.Add (codes: [0x3c, 0x3d, 0x3e, 0x3f], state: .DcsEntry, action: .Collect, next: .DcsParam);
        table.Add (codes: EXECUTABLES, state: .DcsIgnore, action: .Ignore, next: .DcsIgnore);
        table.Add (codes: r (low: 0x20, high: 0x80), state: .DcsIgnore, action: .Ignore, next: .DcsIgnore);
        table.Add (codes: r (low: 0x1c, high: 0x20), state: .DcsIgnore, action: .Ignore, next: .DcsIgnore);
        table.Add (codes: EXECUTABLES, state: .DcsParam, action: .Ignore, next: .DcsParam);
        table.Add (code: 0x7f, state: .DcsParam, action: .Ignore, next: .DcsParam);
        table.Add (codes: r (low: 0x1c, high: 0x20), state: .DcsParam, action: .Ignore, next: .DcsParam);
        table.Add (codes: r (low: 0x30, high: 0x3a), state: .DcsParam, action: .Param, next: .DcsParam);
        table.Add (code: 0x3b, state: .DcsParam, action: .Param, next: .DcsParam);
        table.Add (codes: [0x3a, 0x3c, 0x3d, 0x3e, 0x3f], state: .DcsParam, action: .Ignore, next: .DcsIgnore);
        table.Add (codes: r (low: 0x20, high: 0x30), state: .DcsParam, action: .Collect, next: .DcsIntermediate);
        table.Add (codes: EXECUTABLES, state: .DcsIntermediate, action: .Ignore, next: .DcsIntermediate);
        table.Add (code: 0x7f, state: .DcsIntermediate, action: .Ignore, next: .DcsIntermediate);
        table.Add (codes: r (low: 0x1c, high: 0x20), state: .DcsIntermediate, action: .Ignore, next: .DcsIntermediate);
        table.Add (codes: r (low: 0x20, high: 0x30), state: .DcsIntermediate, action: .Collect, next: .DcsIntermediate);
        table.Add (codes: r (low: 0x30, high: 0x40), state: .DcsIntermediate, action: .Ignore, next: .DcsIgnore);
        table.Add (codes: r (low: 0x40, high: 0x7f), state: .DcsIntermediate, action: .DcsHook, next: .DcsPassthrough);
        table.Add (codes: r (low: 0x40, high: 0x7f), state: .DcsParam, action: .DcsHook, next: .DcsPassthrough);
        table.Add (codes: r (low: 0x40, high: 0x7f), state: .DcsEntry, action: .DcsHook, next: .DcsPassthrough);
        table.Add (codes: EXECUTABLES, state: .DcsPassthrough, action: .DcsPut, next: .DcsPassthrough);
        table.Add (codes: PRINTABLES, state: .DcsPassthrough, action: .DcsPut, next: .DcsPassthrough);
        table.Add (code: 0x7f, state: .DcsPassthrough, action: .Ignore, next: .DcsPassthrough);
        table.Add (codes: [0x1b, 0x9c], state: .DcsPassthrough, action: .DcsUnhook, next: .Ground);
        table.Add (code: NonAsciiPrintable, state: .OscString, action: .OscPut, next: .OscString);
        return table
    }
    
    // Array of parameters, and "collect" string
    typealias CsiHandler = ([Int],cstring) -> ()
    typealias CsiHandlerFallback = ([Int],cstring,UInt8) -> ()
    
    // String with payload
    typealias OscHandler = ([String]) -> ()
    
    // Collect + flag
    typealias EscHandler = (cstring, UInt8) -> ()
    
    // Range of bytes to print out
    typealias PrintHandler = (ArraySlice<UInt8>) -> ()
    
    typealias ExecuteHandler = () -> ()
    
    // Handlers
    var csiHandlers : [UInt8:CsiHandler] = [:]
    var oscHandler : [Int:OscHandler] = [:]
    var executeHandlers : [UInt8:ExecuteHandler] = [:]
    var escHandlers : [cstring:EscHandler] = [:]
    var dcsHandlers : [cstring:DcsHandler] = [:]
    var activeDcsHandler : DcsHandler? = nil
    var errorHandler : (ParsingState) -> ParsingState = { (state : ParsingState) -> ParsingState in return state; }
    
    var initialState : ParserState = .Ground
    var currentState : ParserState = .Ground
    
    // buffers over several calls
    var _osc : cstring
    var _pars : [Int]
    var _collect : cstring
    var printHandler : PrintHandler = { (slice : ArraySlice<UInt8>) -> () in
    }
    var table : TransitionTable
    
    init ()
    {
        table = EscapeSequenceParser.BuildVt500TransitionTable()
        _osc = []
        _pars = [0]
        _collect = []
        // "\"
        SetEscHandler([92], callback: EscHandlerFallback)
    }
    
    func EscHandlerFallback (collect : cstring, flag : UInt8) {}
    
    func SetEscHandler (_ flag : cstring, callback : @escaping EscHandler)
    {
        escHandlers [flag] = callback
    }
    
    var executeHandlerFallback : ExecuteHandler = { () -> () in
    }
    
    var csiHandlerFallback : CsiHandlerFallback = { (pars : [Int], collect : cstring, code : UInt8) -> () in
        print ("Cannot handle ESC-\(code)")
    }
    
    func Reset ()
    {
        currentState = initialState
        _osc = []
        _pars = [0]
        _collect = []
        activeDcsHandler = nil
    }

    func Parse (data : [UInt8], end : Int)
    {
        var code : UInt8 = 0
        var transition = 0
        var error = false
        var currentState = self.currentState
        var print = -1
        var dcs = -1
        var osc = self._osc
        var collect = self._collect
        var pars = self._pars
        var dcsHandler = activeDcsHandler
        
        // process input string
        var i = 0
        var len = data.count
        while i < end {
            code = data [i]
            
            if (currentState == .Ground && code > 0x1f){
                print = (~print != 0) ? print : i
                repeat {
                    i += 1
                } while (i < len && data [i] > 0x1f)
                continue;
            }
            
            // shortcut for CSI params
            if (currentState == .CsiParam && (code > 0x2f && code < 0x39)) {
                pars [pars.count - 1] = pars [pars.count - 1] * 10 + Int(code) - 48
                i += 1
                continue
            }
            
            // Normal transition and action loop
            var transition = table [Int(currentState.rawValue << 8 | UInt8 ((code < 0xa0 ? code : EscapeSequenceParser.NonAsciiPrintable)))]
            let action = ParserAction (rawValue: transition >> 4)!
            switch action {
            case .Print:
                print = (~print != 0) ? print : i
            case .Execute:
                if ~print != 0 {
                    printHandler (data [print..<i])
                    print = -1
                }
                if let callback = executeHandlers [code] {
                    callback ()
                } else {
                    // executeHandlerFallback (code)
                }
            case .Ignore:
                // handle leftover print or dcs chars
                if ~print != 0 {
                    printHandler (data [print..<i])
                    print = -1
                } else {
                    dcsHandler!.put (data: data [dcs..<i])
                    dcs = -1
                }
            case .Error:
                // chars higher than 0x9f are handled by this action
                // to keep the transition table small
                if code > 0x9f {
                    switch (currentState) {
                    case .Ground:
                        print = (~print != 0) ? print : i;
                    case .CsiIgnore:
                        transition |= ParserState.CsiIgnore.rawValue;
                    case .DcsIgnore:
                        transition |= ParserState.DcsIgnore.rawValue;
                    case .DcsPassthrough:
                        dcs = (~dcs != 0) ? dcs : i;
                        transition |= ParserState.DcsPassthrough.rawValue;
                        break;
                    default:
                        error = true;
                        break;
                    }
                } else {
                    error = true;
                }
                // if we end up here a real error happened
                if (error) {
                    var state = ParsingState ()
                    state.position = i
                    state.code = code
                    state.currentState = currentState
                    state.print = print
                    state.dcs = dcs
                    state.osc = osc
                    state.collect = collect
                    let inject = errorHandler (state);
                    if inject.abort {
                        return;
                    }
                    error = false;
                }
            case .CsiDispatch:
                // Trigger CSI handler
                if let handler = csiHandlers [code] {
                    handler (pars, collect);
                } else {
                    csiHandlerFallback (pars, collect, code)
                }
            case .Param:
                if code == 0x3b {
                    pars.append (0)
                } else {
                    pars [pars.count - 1] = pars [pars.count - 1] * 10 + Int(code) - 48
                }
            case .EscDispatch:
                if let handler = escHandlers [collect + [code]] {
                    handler (collect, code)
                } else {
                    EscHandlerFallback(collect: collect, flag: code)
                }
            case .Collect:
                collect.append (code)
            case .Clear:
                if ~print != 0 {
                    printHandler (data [print..<i])
                    print = -1
                }
                osc = []
                pars = [0]
                collect = []
                dcs = -1
            case .DcsHook:
                if let dcs = dcsHandlers [collect + [code]] {
                    dcsHandler = dcs
                    dcs.hook (collect: collect, parameters: pars, flag: code)
                }
                // FIXME: perhaps have a fallback?
                break
            case .DcsPut:
                dcs = (~dcs != 0) ? dcs : i
            case .DcsUnhook:
                if let d = dcsHandler {
                    if ~dcs != 0 {
                        d.put (data: data[dcs..<i])
                        d.unhook ()
                        dcsHandler = nil
                    }
                }
                if code == 0x1b {
                    transition |= ParserState.Escape.rawValue
                }
                osc = []
                pars = [0]
                collect = []
                dcs = -1
            case .OscStart:
                if ~print != 0 {
                    printHandler (data[print..<i])
                    print = -1
                }
                osc = []
            case .OscPut:
                var j = i + 1
                while (j < len){
                    let c = data [j]
                    if c == ControlCodes.BEL || c == ControlCodes.CAN || c == ControlCodes.ESC {
                        break
                    } else if (c >= 0x20) {
                        osc.append (c)
                    }
                    j += 1
                }
                i = j - 1
            case .OscEnd:
                if osc.count != 0 && code != ControlCodes.CAN && code != ControlCodes.SUB {
                    // NOTE: OSC subparsing is not part of the original parser
                    // we do basic identifier parsing here to offer a jump table for OSC as well
                    if let idx = osc.firstIndex (of: UInt8(';')){
                        
                        THE CODE BELOW IS WRONG - VTE ALLOWS OSC StrINGS THAT HAVE NUMBER BEL and ARE NOT TERMINATED WITH A SEMICOLON
                        
                        // Note: NaN is not handled here
                        // either catch it with the fallback handler
                        // or with an explicit NaN OSC handler
                        //var identifier = 0;
                        //Int32.TryParse (osc.Substring (0, idx), out identifier);
                        //var content = osc.Substring (idx + 1);
                        // Trigger OSC handler
                        //int c = -1;
                        //if (OscHandlers.TryGetValue (identifier, out var ohandlers)) {
                        //    c = ohandlers.Count - 1;
                        //    for (; c >= 0; c--) {
                        //        ohandlers [c] (content);
                        //        break;
                        //    }
                        //}
                        //if (c < 0)
                        //OscHandlerFallback (identifier, content);
                    } else {
                        // OscHandlerFallback (-1, osc); // this is an error mal-formed OSC
                    }
                }
                if code == 0x1b {
                    transition |= ParserState.Escape.rawValue
                }
                osc = []
                pars = [0]
                collect = []
                dcs = -1
            }
            currentState = ParserState (rawValue: transition & 15)!
            i += 1
        }
        // push leftover pushable buffers to terminal
        if (currentState == .Ground && (~print != 0)){
            printHandler (data [print..<len])
        } else if (currentState == .DcsPassthrough && (~dcs != 0) && dcsHandler != nil){
            dcsHandler!.put (data [dcs..<len])
        }
        
        // save non pushable buffers
        _osc = osc
        _collect = collect
        _pars = pars
        
        // save active dcs handler reference
        activeDcsHandler = dcsHandler
        
        // save state
        this.currentState = currentState
    }
}