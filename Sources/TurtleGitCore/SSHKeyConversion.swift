// SPDX-License-Identifier: GPL-2.0-or-later
// Uses the pinned upstream PuTTYgen CLI for key-format and passphrase interoperability.
import Foundation
import Darwin

public struct SSHKeyConversionRequest: Sendable {
    public let source: URL
    public let destination: URL
    public var oldPassphrase = ""
    /// nil retains the input key's encryption; an empty string explicitly removes it.
    public var newPassphrase: String?
    /// nil preserves the original comment.
    public var comment: String?
    public init(source: URL, destination: URL) { self.source=source; self.destination=destination }
    public var valid: Bool {
        var shape=SSHKeyGenerationRequest(destination:destination)
        shape.passphrase=newPassphrase ?? oldPassphrase; shape.comment=comment ?? ""
        return shape.valid && source.isFileURL && source.path.hasPrefix("/") && !source.path.contains("\0") &&
            !oldPassphrase.contains("\0") && !oldPassphrase.contains("\n") && !oldPassphrase.contains("\r") && oldPassphrase.utf8.count < 65_000 &&
            !source.path.utf8.elementsEqual(destination.path.utf8)
    }
}
public enum SSHKeyConversionFailure: LocalizedError {
    case runtime, input, conversion, publication
    public var errorDescription:String? {
        switch self {
        case .runtime:return "The bundled PuTTY key converter is unavailable."
        case .input:return "Choose a regular PuTTY or OpenSSH private key and a different output filename."
        case .conversion:return "Could not import this key. Check its format and current passphrase."
        case .publication:return "Could not publish the converted key pair. Existing files have been preserved."
        }
    }
}
public enum SSHKeyConversion {
    public static func executable() throws -> URL {
        let file=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/PuTTY/bin/puttygen")
        guard FileManager.default.isExecutableFile(atPath:file.path) else { throw SSHKeyConversionFailure.runtime }
        return file
    }
    /// Import into a new pair; never overwrite or rewrite the selected source key.
    public static func convert(_ request:SSHKeyConversionRequest, converter:URL, keygen:URL, cancellation:OperationCancellation=OperationCancellation()) throws -> SSHKeyGenerationResult {
        guard request.valid else { throw SSHKeyConversionFailure.input };try cancellation.check()
        let destination=request.destination, publicDestination=URL(fileURLWithPath:destination.path+".pub")
        var info=stat()
        guard lstat(destination.path,&info) != 0, errno==ENOENT,
              lstat(publicDestination.path,&info) != 0, errno==ENOENT else { throw SSHKeyGenerationFailure.exists }
        let inputDescriptor=open(request.source.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
        guard inputDescriptor >= 0 else { throw SSHKeyConversionFailure.input }
        let input=FileHandle(fileDescriptor:inputDescriptor,closeOnDealloc:true);defer { try? input.close() }
        guard fstat(inputDescriptor,&info)==0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= 8*1024*1024 else { throw SSHKeyConversionFailure.input }
        let directory=destination.deletingLastPathComponent().appendingPathComponent("tg-key-import-"+UUID().uuidString,isDirectory:true)
        guard mkdir(directory.path,0o700)==0 else { throw SSHKeyConversionFailure.publication }
        defer { try? FileManager.default.removeItem(at:directory) }
        guard chmod(directory.path,0o700)==0 else { throw SSHKeyConversionFailure.publication }
        func write(_ name:String,_ data:Data) throws -> URL {
            let file=directory.appendingPathComponent(name),descriptor=open(file.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
            guard descriptor>=0 else { throw SSHKeyConversionFailure.publication }
            let writer=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
            do { guard fchmod(descriptor,0o600)==0 else { throw SSHKeyConversionFailure.publication };try writer.write(contentsOf:data);try writer.close() }
            catch { try? writer.close();throw error }
            return file
        }
        guard let sourceBytes=try input.read(upToCount:8*1024*1024+1), sourceBytes.count <= 8*1024*1024 else { throw SSHKeyConversionFailure.input }
        let snapshot=try write("source-key",sourceBytes)
        let old=try write("current-passphrase",Data((request.oldPassphrase+"\n").utf8))
        let key=directory.appendingPathComponent("identity"),publicKey=directory.appendingPathComponent("identity.pub")
        let output=try write("output",Data()),errors=try write("errors",Data())
        let out=try FileHandle(forWritingTo:output),err=try FileHandle(forWritingTo:errors)
        defer { try? out.close();try? err.close() }
        var environment=ProcessInfo.processInfo.environment
        environment["LC_ALL"]="C";environment.removeValue(forKey:"TURTLEGIT_SSH_CREDENTIAL_FILE")
        func run(_ executable:URL,_ arguments:[String]) throws {
            let code=try CancellableGitProcess.run(executable:executable,arguments:arguments,environment:environment,output:out.fileDescriptor,error:err.fileDescriptor,cancellation:cancellation)
            try cancellation.check();guard code==0 else { throw SSHKeyConversionFailure.conversion }
        }
        var arguments=[snapshot.path,"-O","private-openssh-new","-o",key.path,"--old-passphrase",old.path,"--reencrypt"]
        var publicPassphrase=old
        if let new=request.newPassphrase { publicPassphrase=try write("new-passphrase",Data((new+"\n").utf8)); arguments += ["--new-passphrase",publicPassphrase.path] }
        if let comment=request.comment { arguments += ["-C",comment] }
        try run(converter,arguments)
        // The public part needs no passphrase and cannot reveal private material.
        try run(converter,[key.path,"-O","public-openssh","-o",publicKey.path,"--old-passphrase",publicPassphrase.path])
        guard chmod(key.path,0o600)==0,chmod(publicKey.path,0o644)==0 else { throw SSHKeyConversionFailure.publication }
        let publicText=try String(contentsOf:publicKey,encoding:.utf8)
        guard publicText.utf8.count < 65_536, publicText.hasPrefix("ssh-") || publicText.hasPrefix("ecdsa-") else { throw SSHKeyConversionFailure.conversion }
        try run(keygen,["-l","-E","sha256","-f",publicKey.path])
        let fingerprint=try String(contentsOf:output,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)
        try cancellation.check()
        guard link(key.path,destination.path)==0 else { throw SSHKeyConversionFailure.publication }
        if link(publicKey.path,publicDestination.path) != 0 {
            var staged=stat(),published=stat()
            if lstat(key.path,&staged)==0,lstat(destination.path,&published)==0,
               staged.st_ino==published.st_ino,staged.st_dev==published.st_dev { _ = unlink(destination.path) }
            throw SSHKeyConversionFailure.publication
        }
        return .init(privateKey:destination,publicKey:publicDestination,publicText:publicText,fingerprint:fingerprint)
    }
}
