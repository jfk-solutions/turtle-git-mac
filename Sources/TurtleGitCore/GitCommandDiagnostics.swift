import Foundation

/// Local, opt-in command metadata. This never receives stdin, environment,
/// stdout or stderr. Installing nil disables observation immediately.
public enum GitCommandDiagnostics {
    public typealias Sink = @Sendable (GitCommandDiagnosticEvent) -> Void
    private final class Registry: @unchecked Sendable {
        let lock=NSLock()
        var sink:Sink?
        func read()->Sink? {lock.lock();defer{lock.unlock()};return sink}
        func set(_ value:Sink?) {lock.lock();sink=value;lock.unlock()}
    }
    private static let registry=Registry()
    public static func installSink(_ sink:Sink?) {registry.set(sink)}

    /// Suitable for the native diagnostic preview as well as process events.
    /// All URL query/fragment data is removed, including unknown secret keys.
    public static func sanitizedText(_ text:String)->String {
        var value=text
        if let expression=try? NSRegularExpression(pattern:"[A-Za-z][A-Za-z0-9+.-]*://[^\\s\\\"'<>]+") {
            let matches=expression.matches(in:value,range:NSRange(value.startIndex...,in:value))
            for match in matches.reversed() {
                guard let range=Range(match.range,in:value) else{continue}
                let wire=String(value[range])
                if var components=URLComponents(string:wire) {
                    components.user=nil;components.password=nil
                    if components.query != nil {components.query="redacted"}
                    if components.fragment != nil {components.fragment="redacted"}
                    value.replaceSubrange(range,with:components.string ?? "<redacted-url>")
                } else {value.replaceSubrange(range,with:"<redacted-url>")}
            }
        }
        // One event is one printable line; terminal control sequences and
        // user-controlled newlines cannot forge another diagnostic record.
        value=String(value.unicodeScalars.map{CharacterSet.controlCharacters.contains($0) ? " ":String($0)}.joined().prefix(256))
        return value
    }
    public static func sanitizedArguments(_ arguments:[String])->[String] {
        var result=[String](),hideNext=false,configNext=false,afterPaths=false
        let normalized=arguments.flatMap { value -> [String] in
            value.hasPrefix("-c") && !value.hasPrefix("--") && value.count>2 ? ["-c",String(value.dropFirst(2))]:[value]
        }
        var nativeCommand:String?
        for (index,value) in arguments.enumerated() {
            let lower=value.lowercased()
            if lower.hasPrefix("/command:") {nativeCommand=String(lower.dropFirst(9))}
            else if lower.hasPrefix("--command=") {nativeCommand=String(lower.dropFirst(10))}
            else if lower=="--command",arguments.indices.contains(index+1) {nativeCommand=arguments[index+1].lowercased()}
        }
        let command=nativeCommand ?? GitCommandIdentity(normalized).command
        let nativeSecrets:Set<String>=["logmsg","logmsgfile","msg","message","log-message","message-file","password","passwd","token","access-token","authorization","credential","credentials","push-option","server-option"]
        let secretOptions:Set<String>=["--message","--file","--password","--passwd","--token","--access-token","--authorization","--credential","--credentials","--push-option","--server-option","--config-env","--username","--user","--header","--extra-header","--oauth2-bearer"]
        for argument in arguments.prefix(64) {
            if hideNext {result.append("<redacted>");hideNext=false;continue}
            if configNext {
                let key=argument.split(separator:"=",maxSplits:1,omittingEmptySubsequences:false).first.map(String.init) ?? ""
                result.append(sanitizedText(key)+"=<redacted>");configNext=false;continue
            }
            if argument=="--" {afterPaths=true;result.append(argument);continue}
            if !afterPaths {
                // PrimaryCommandInvocation accepts Windows /key:value and
                // native --key=value / --key value. Parse only the option key;
                // a value may contain any number of colons or equals signs.
                let legacy=argument.hasPrefix("/") && argument.contains(":")
                if legacy || argument.hasPrefix("--") {
                    let body=argument.dropFirst(legacy ? 1:2)
                    let separator:Character=legacy ? ":":"="
                    let pieces=body.split(separator:separator,maxSplits:1,omittingEmptySubsequences:false)
                    let key=pieces.first.map{String($0).lowercased()} ?? ""
                    let sensitive=nativeSecrets.contains(key) || ["password","passwd","token","credential","authorization","secret","header"].contains(where:key.contains)
                    if sensitive {
                        let prefix=(legacy ? "/":"--")+key
                        result.append(prefix+(pieces.count>1 ? String(separator)+"<redacted>":""))
                        hideNext=pieces.count==1;continue
                    }
                }
                if argument=="-c" {result.append(argument);configNext=true;continue}
                if argument.hasPrefix("-c"),argument.count>2,!argument.hasPrefix("--") {result.append("-c<redacted>");continue}
                let option=argument.split(separator:"=",maxSplits:1).first.map(String.init) ?? argument
                // Long/legacy option keys were parsed above. Do not classify
                // arbitrary positional URLs or attached short-option payloads
                // as keys merely because their contents include “secret”.
                // They must reach URL and -m/-o payload sanitization below.
                if secretOptions.contains(option.lowercased()) {
                    result.append(option+(argument.contains("=") ? "=<redacted>":""));hideNext = !argument.contains("=");continue
                }
                if ["commit","tag","notes"].contains(command ?? ""),argument.hasPrefix("-"),!argument.hasPrefix("--"),let marker=argument.dropFirst().firstIndex(of:"m") {
                    let option=String(argument[...marker])
                    result.append(option+(argument.index(after:marker)==argument.endIndex ? "":"<redacted>"));hideNext=argument.index(after:marker)==argument.endIndex;continue
                }
                if command=="push",argument.hasPrefix("-o"),!argument.hasPrefix("--") {
                    result.append(argument=="-o" ? "-o":"-o<redacted>");hideNext=argument=="-o";continue
                }
            }
            result.append(sanitizedText(argument))
        }
        // Config payloads may be positional (including section/key renames,
        // get-regexp patterns and credential helper commands). Do not guess
        // their sensitivity from a finite list of configuration key names.
        if command=="config",let index=result.firstIndex(of:"config") {
            for i in result.indices where i>index {
                if !result[i].hasPrefix("-") {result[i]="<redacted>"}
                else if let separator=result[i].firstIndex(of:"=") {result[i]=String(result[i][...separator])+"<redacted>"}
            }
        }
        if arguments.count>64 {result.append("<additional arguments omitted>")}
        return result
    }
    struct Span {
        let id=UUID(),start=ProcessInfo.processInfo.systemUptime
        let executable:String,arguments:[String]
    }
    static func begin(executable:URL,arguments:[String],opaqueArgumentIndices:Set<Int>)->Span? {
        guard let sink=registry.read() else{return nil}
        let captions=arguments.enumerated().map{opaqueArgumentIndices.contains($0.offset) ? "<raw argument>":$0.element}
        let span=Span(executable:sanitizedText(executable.path),arguments:sanitizedArguments(captions))
        sink(.init(id:span.id,phase:.started,executable:span.executable,arguments:span.arguments,elapsed:nil,exitCode:nil,cancelled:false))
        return span
    }
    static func finish(_ span:Span?,exitCode:Int32?,cancelled:Bool) {
        guard let span,let sink=registry.read() else{return}
        sink(.init(id:span.id,phase:.finished,executable:span.executable,arguments:span.arguments,elapsed:max(0,ProcessInfo.processInfo.systemUptime-span.start),exitCode:exitCode,cancelled:cancelled))
    }
}

public struct GitCommandDiagnosticEvent:Sendable {
    public enum Phase:String,Sendable {case started,finished}
    public let id:UUID,phase:Phase,executable:String,arguments:[String],elapsed:TimeInterval?,exitCode:Int32?,cancelled:Bool
    public var rendered:String {
        let command=([executable]+arguments).map{String(reflecting:$0)}.joined(separator:" ")
        let end=phase == .finished ? " exit=\(exitCode.map(String.init) ?? "unavailable") cancelled=\(cancelled) elapsed=\(String(format:"%.3f",elapsed ?? 0))s":""
        return "Git \(phase.rawValue) [\(id.uuidString)] \(command)\(end)"
    }
}
