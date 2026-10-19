// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// A separately gated Git transport protocol sharing the bounded native
/// credential/certificate payload, never SVN's persistence or client-key modes.
public enum GitRemoteAuthenticationPrompt{
    public static let prefix="TurtleGit Git transport prompt v1:"
    public static func decode(_ text:String,enabled:Bool)throws->GitSVNAuthenticationPrompt?{
        guard enabled,text.hasPrefix(prefix) else{return nil}
        guard text.utf8.count<=65_535,let prompt=try GitSVNAuthenticationPrompt.decode(GitSVNAuthenticationPrompt.prefix+String(text.dropFirst(prefix.count)),enabled:true) else{throw GitSVNAuthenticationFailure.malformed}
        try validate(prompt);return prompt
    }
    public static func encoded(_ prompt:GitSVNAuthenticationPrompt)throws->String{
        try validate(prompt)
        return prefix+String(try prompt.encoded().dropFirst(GitSVNAuthenticationPrompt.prefix.count))
    }
    private static func validate(_ prompt:GitSVNAuthenticationPrompt)throws{
        guard !prompt.maySave,prompt.kind == .credentials || prompt.kind == .trust else{throw GitSVNAuthenticationFailure.malformed}
        if prompt.kind == .trust{guard prompt.certificate != nil,try prompt.certificateDetails() != nil else{throw GitSVNAuthenticationFailure.malformed}}
    }
}
