// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Classification grants authority; it never rewrites Git's argv, environment,
/// remote configuration or OpenSSH configuration. Unknown transports retain the
/// conservative permission path rather than silently ignoring selected grants.
enum SSHConfigurationTransport {
    static func needsAccess(endpoint:String)->Bool {
        if endpoint.isEmpty || endpoint.utf8.contains(0) {return true}
        let lower=endpoint.lowercased()
        if ["https://","http://","git://","file://"].contains(where:lower.hasPrefix) {return false}
        if ["ssh://","git+ssh://","ssh+git://"].contains(where:lower.hasPrefix) {return true}
        if endpoint.contains("://") || endpoint.contains("::") {return true}
        if endpoint.hasPrefix("/") || endpoint.hasPrefix("./") || endpoint.hasPrefix("../") {return false}
        if let colon=endpoint.firstIndex(of:":") {
            if endpoint[..<colon].contains("/") {return false}
            return true // Includes SCP-style aliases, users and bracketed IPv6.
        }
        return false // A literal relative filesystem path.
    }
    static func identityArguments(_ arguments:[String])->[String] {
        var result=arguments
        while let first=result.first,["--turtlegit-source-fetch","--turtlegit-transfer-notifications"].contains(first) {result.removeFirst()}
        return result
    }
    static func positionals(_ arguments:[String],valueOptions:Set<String>)->[String] {
        var result=[String](),index=0
        while index<arguments.count {
            let value=arguments[index]
            if value=="--" {result.append(contentsOf:arguments.dropFirst(index+1));break}
            if valueOptions.contains(value) {index+=2;continue}
            if !value.hasPrefix("-") {result.append(value)}
            index+=1
        }
        return result
    }
    static func options(_ arguments:[String],valueOptions:Set<String>)->[String] {
        var result=[String](),index=0
        while index<arguments.count {
            let value=arguments[index]
            if value=="--" {break}
            if value.hasPrefix("-") {result.append(value)}
            index += valueOptions.contains(value) ? 2:1
        }
        return result
    }
}

extension GitRepository {
    func sshConfigurationNeeded(_ arguments:[String],argumentBytes:[Int:Data]=[:],environment:[String:String],cancellation:OperationCancellation?)throws->Bool {
        let actual=arguments.enumerated().map {index,value in argumentBytes[index].map{String(data:$0,encoding:.utf8) ?? "unknown::opaque-endpoint"} ?? value}
        let normalized=SSHConfigurationTransport.identityArguments(actual),identity=GitCommandIdentity(normalized)
        guard let command=identity.command else{return false}
        let tail=identity.arguments
        let action=tail.first{!$0.hasPrefix("-")}
        var signingValues:Set<String>=["-m","--message","-F","--file","--author","--date","--cleanup","--fixup","--squash","-C","-c","--reuse-message","--reedit-message","--local-user","--exec","--onto","--strategy","--strategy-option","-X"]
        if command=="tag" {signingValues.insert("-u")}
        if command=="rebase" {signingValues.insert("-x")}
        if ["merge","rebase","pull"].contains(command) {signingValues.insert("-s")}
        let options=SSHConfigurationTransport.options(tail,valueOptions:signingValues)
        let verifies=["verify-commit","verify-tag"].contains(command) || (["show","log"].contains(command) && options.contains("--show-signature")) || (command=="tag" && options.contains(where:{["-v","--verify"].contains($0)})) || (command=="merge" && options.contains("--verify-signatures"))
        // Verification selects the signature format from the object, not the
        // current signing preference. It can read an allowed-signers file.
        if verifies {return true}
        let signingFamily=GitAskpassRuntime.mayRequestSSHSignature(normalized)
        guard GitAskpassRuntime.mayAuthenticate(normalized) || signingFamily else{return false}
        // These commands cannot invoke a transport despite sharing the command
        // family with network actions. Nested authority discovery uses only them.
        if command=="ls-remote",tail.contains("--get-url") {return false}
        if command=="credential" {return false}
        if command=="submodule",let action,["status","summary","init","sync","deinit","absorbgitdirs"].contains(action) {return false}
        if command=="lfs",let action,["version","env","install","uninstall","track","untrack","ls-files","status","pointer"].contains(action) {return false}
        if command=="remote",tail.contains("-n") || tail.contains("--no-query") {return false}
        let prefix=Array(normalized.prefix(normalized.count-tail.count-1))
        func read(_ args:[String],opaque:Set<Int>=[])throws->GitResult {
            try cancellation?.check()
            var display=prefix+args,bytes=[Int:Data]()
            for index in opaque {bytes[prefix.count+index]=Data(args[index].utf8);display[prefix.count+index]="<transport-endpoint>"}
            return try run(display,argumentBytes:bytes,environmentOverrides:environment,successfulExitCodes:0...255,cancellation:cancellation)
        }
        func text(_ args:[String],opaque:Set<Int>=[])throws->String? {
            let result=try read(args,opaque:opaque)
            guard result.exitCode==0,var value=String(data:result.stdout,encoding:.utf8) else{return nil}
            if value.last=="\n" {value.removeLast()};return value
        }
        func config(_ key:String)throws->String? {try text(["config","--get",key])}
        if signingFamily {
            guard try config("gpg.format")?.lowercased()=="ssh" else{return false}
            // No-op/listing/abort and dry-run forms cannot create a signature.
            if options.contains(where:{["--dry-run","--abort","--quit","--show-current-patch","--edit-todo"].contains($0)}) {return false}
            if ["merge","cherry-pick","revert"].contains(command),options.contains(where:{["--no-commit","-n"].contains($0)}) {return false}
            if command=="tag",options.contains(where:{["-l","--list","-d","--delete"].contains($0)}) {return false}
            var explicit:Bool?
            for option in options {
                if option=="--no-gpg-sign" || option=="--no-sign" {explicit=false}
                else if option=="--gpg-sign" || option.hasPrefix("--gpg-sign=") || option=="-S" || option.hasPrefix("-S") && option.count>2 {explicit=true}
                else if command=="tag",option=="-s" || option=="--sign" || option=="-u" || option.hasPrefix("-u") && option.count>2 || option=="--local-user" || option.hasPrefix("--local-user=") {explicit=true}
            }
            if let explicit {return explicit}
            // A continuing sequencer can retain -S from its accepted start,
            // even when today's default commit.gpgsign is false.
            if ["rebase","cherry-pick","revert","am"].contains(command),options.contains(where:{["--continue","--skip"].contains($0)}) {return true}
            if command=="commit-tree" {return false}
            let value=try config(command=="tag" ? "tag.gpgsign":"commit.gpgsign")
            return value.map{!["false","no","off","0"].contains($0.lowercased())} ?? false
        }
        func defaultRemote(push:Bool)throws->String {
            let branch=try text(["symbolic-ref","--quiet","--short","HEAD"])
            if push,let branch,let value=try config("branch."+branch+".pushRemote"),!value.isEmpty {return value}
            if push,let value=try config("remote.pushDefault"),!value.isEmpty {return value}
            if let branch,let value=try config("branch."+branch+".remote"),!value.isEmpty {return value}
            return "origin"
        }
        func endpoint(_ value:String,push:Bool=false)throws->Bool {
            if value=="." {return false}
            // Git performs insteadOf/pushInsteadOf expansion, including -c and
            // --config-env overrides, without contacting any remote server.
            let namedArgs=["remote","get-url"]+(push ? ["--push"]:[])+["--all","--",value]
            let named=try read(namedArgs,opaque:[namedArgs.count-1])
            if named.exitCode==0,let urls=String(data:named.stdout,encoding:.utf8) {
                let values=urls.split(separator:"\n",omittingEmptySubsequences:false).dropLast()
                guard !values.isEmpty else{return true}
                return values.contains{SSHConfigurationTransport.needsAccess(endpoint:String($0))}
            }
            if push {
                // remote get-url rejects a command-only synthetic remote.
                // Match Git remote.c add_url_alias/alias_url for an anonymous
                // URL: longest raw pushInsteadOf prefix first, otherwise the
                // normal insteadOf alias. Base groups retain first-seen order.
                let result=try read(["config","--null","--get-regexp","^url\\..*\\.pushinsteadof$"])
                guard [0,1].contains(result.exitCode) else{return true}
                var groups=[(base:Data,prefixes:[Data])](),indices=[Data:Int]()
                for record in result.stdout.split(separator:0) {
                    guard let separator=record.firstIndex(of:10) else{return true}
                    let key=Data(record[..<separator]),suffix=Data(".pushinsteadof".utf8)
                    guard key.starts(with:Data("url.".utf8)),key.suffix(suffix.count)==suffix,key.count>=4+suffix.count else{return true}
                    let base=Data(key.dropFirst(4).dropLast(suffix.count)),from=Data(record[record.index(after:separator)...])
                    if let index=indices[base] {groups[index].prefixes.append(from)}
                    else {indices[base]=groups.count;groups.append((base,[from]))}
                }
                let raw=Data(value.utf8);var longest:(base:Data,count:Int)?
                for group in groups {for from in group.prefixes where raw.starts(with:from) {
                    if longest==nil || from.count>longest!.count {longest=(group.base,from.count)}
                }}
                if let longest {
                    let resolved=longest.base+raw.dropFirst(longest.count)
                    guard let url=String(data:resolved,encoding:.utf8) else{return true}
                    return SSHConfigurationTransport.needsAccess(endpoint:url)
                }
            }
            guard let resolved=try text(["ls-remote","--get-url","--",value],opaque:[3]) else{return true}
            return SSHConfigurationTransport.needsAccess(endpoint:resolved)
        }
        func allRemotes()throws->Bool {
            guard let names=try text(["remote"]) else{return true}
            let values=names.split(separator:"\n")
            guard !values.isEmpty else{return true}
            for value in values {if try endpoint(String(value)) {return true}}
            return false
        }
        func remoteOrGroup(_ name:String)throws->Bool {
            let result=try read(["config","--get-all","remotes."+name])
            if result.exitCode==0,let text=String(data:result.stdout,encoding:.utf8) {
                let names=text.split(whereSeparator:{$0==" " || $0=="\t" || $0=="\n"})
                guard !names.isEmpty else{return true}
                for value in names {if try endpoint(String(value)) {return true}}
                return false
            }
            return try endpoint(name)
        }
        let positionals=SSHConfigurationTransport.positionals(tail,valueOptions:["-b","--branch","-o","--origin","--depth","--shallow-since","--shallow-exclude","--reference","--reference-if-able","--separate-git-dir","--template","--config","-c","--upload-pack","--receive-pack","--exec","--server-option","--filter","--jobs","-j","--recurse-submodules-default","--deepen","--negotiation-tip","--refmap","--push-option","--repo","--bundle-uri","--revision","--name","--strategy","-s","--strategy-option","-X","--cleanup","--remote"])
        let optionArguments=Array(tail.prefix(while:{$0 != "--"}))
        func childrenMayUseSSH()throws->Bool {
            guard ["clone","fetch","pull","push"].contains(command) || (command=="remote" && action=="update") else{return false}
            var explicit:String?
            for option in optionArguments {
                if ["--no-recurse-submodules","--no-recursive"].contains(option) {explicit="no"}
                else if option=="--recurse-submodules" || option=="--recursive" {explicit="yes"}
                else if option.hasPrefix("--recurse-submodules=") {explicit=command=="clone" ? "yes":String(option.dropFirst(21))}
            }
            func disabled(_ value:String)->Bool {["no","false","0","off"].contains(value.lowercased()) || (command=="push" && value.lowercased()=="check")}
            if command=="clone" {
                if optionArguments.contains(where:{["--bare","--mirror","--no-checkout","-n"].contains($0)}) {return false}
                return explicit.map{!disabled($0)} ?? false
            }
            if let explicit {return !disabled(explicit)}
            let submoduleDefault=try config("submodule.recurse")
            if command=="push" {
                if let value=try config("push.recurseSubmodules") {return !disabled(value)}
                return submoduleDefault.map{!disabled($0)} ?? false
            }
            // Fetch (also remote-update and Pull's fetch) defaults to
            // on-demand. Existing submodule URLs can name another transport,
            // and the fetched child can itself reveal further SSH children.
            let local=try read(["config","--get-regexp","^submodule\\..*\\.(url|fetchrecursesubmodules)$"])
            let modules=try read(["config","--file",".gitmodules","--get-regexp","^submodule\\..*\\.(url|fetchrecursesubmodules)$"])
            if ![0,1].contains(local.exitCode) || ![0,1].contains(modules.exitCode) {return true}
            let hasChildren=local.exitCode==0 || modules.exitCode==0
            if command=="pull",let submoduleDefault,!disabled(submoduleDefault) {return true}
            if let value=try config("fetch.recurseSubmodules") {
                if !disabled(value) {return hasChildren}
                // Per-submodule settings can override a disabled default.
                for data in [local.stdout,modules.stdout] {
                    guard let records=String(data:data,encoding:.utf8) else{return true}
                    for row in records.split(separator:"\n") {
                        let fields=row.split(maxSplits:1,whereSeparator:{$0==" " || $0=="\t"})
                        if fields.count==2,fields[0].lowercased().hasSuffix(".fetchrecursesubmodules"),!disabled(String(fields[1])) {return true}
                    }
                }
                return false
            }
            return hasChildren
        }
        if try childrenMayUseSSH() {return true}
        switch command {
        case "clone","ls-remote":
            guard let source=positionals.first else{return true};return try endpoint(source)
        case "fetch":
            if tail.contains("--all") {return try allRemotes()}
            if tail.contains("--multiple") {for source in positionals {if try remoteOrGroup(source) {return true}};return positionals.isEmpty}
            return try endpoint(positionals.first ?? defaultRemote(push:false))
        case "pull","push":
            var repositoryOption:String?
            if command=="push" {
                for (index,option) in optionArguments.enumerated() {
                    if option=="--repo",optionArguments.indices.contains(index+1) {repositoryOption=optionArguments[index+1]}
                    else if option.hasPrefix("--repo=") {repositoryOption=String(option.dropFirst(7))}
                }
            }
            return try endpoint(repositoryOption ?? positionals.first ?? defaultRemote(push:command=="push"),push:command=="push")
        case "request-pull":guard positionals.count>=2 else{return true};return try endpoint(positionals[1])
        case "remote":
            guard let action=positionals.first else{return true}
            if action=="update" {
                if positionals.count==1 {return try allRemotes()}
                for source in positionals.dropFirst() {if try remoteOrGroup(source) {return true}}
                return false
            }
            guard positionals.count>=2 else{return true};return try endpoint(positionals[1])
        case "lfs":
            if action=="migrate" {return true}
            if let url=try config("lfs.url"),!url.isEmpty {return try endpoint(url)}
            for (index,value) in tail.enumerated() {
                if value=="--remote",tail.indices.contains(index+1) {return try endpoint(tail[index+1],push:action=="push")}
                if value.hasPrefix("--remote=") {return try endpoint(String(value.dropFirst(9)),push:action=="push")}
            }
            if ["fetch","pull","push"].contains(action ?? ""),positionals.count>1 {return try endpoint(positionals[1],push:action=="push")}
            return try endpoint(defaultRemote(push:false))
        case "submodule":
            if positionals.first=="add",positionals.count>1 {return try endpoint(positionals[1])}
            // Recursive updates may discover another transport in an uncreated
            // child. Preserve selected authority conservatively; no Includes or
            // account SSH files are inspected to guess what it will do.
            return true
        default:return true
        }
    }
}
