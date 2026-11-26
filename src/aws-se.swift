// aws-se: 用 Secure Enclave 密钥（需 Touch ID）保护 AKSK
//   aws-se init                  生成 SE 密钥（已存在则拒绝）
//   aws-se encrypt <name>        从 stdin 读 "AK SK"，用公钥加密（不需要指纹）
//   aws-se decrypt <name>        Touch ID 后输出 "AK SK"
import Foundation
import CryptoKit
import LocalAuthentication
let base = NSString(string: "~/.aws/vault").expandingTildeInPath
let fm = FileManager.default
try? fm.createDirectory(atPath: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let keyPath = base + "/se-key.bin", pubPath = base + "/se-pub.bin"
let info = Data("aws-se-v1".utf8)
func fail(_ s: String) -> Never { FileHandle.standardError.write(("aws-se: " + s + "\n").data(using: .utf8)!); exit(1) }
func write600(_ d: Data, _ p: String) throws {
    try d.write(to: URL(fileURLWithPath: p), options: .atomic)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p)
}
let a = CommandLine.arguments
guard a.count >= 2 else { fail("用法: init | encrypt <name> | decrypt <name>") }
switch a[1] {
case "init":
    if fm.fileExists(atPath: keyPath) { fail("SE 密钥已存在，拒绝覆盖") }
    var e: Unmanaged<CFError>?
    guard let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], &e) else { fail("ACL 失败") }
    do {
        let k = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: ac)
        try write600(k.dataRepresentation, keyPath)
        try write600(k.publicKey.x963Representation, pubPath)
        print("init ok")
    } catch { fail("init 失败: \(error)") }
case "encrypt":
    guard a.count >= 3 else { fail("缺少 name") }
    guard let input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), input.split(separator: " ").count == 2 else { fail("stdin 需为 'AK SK'") }
    do {
        let pub = try P256.KeyAgreement.PublicKey(x963Representation: Data(contentsOf: URL(fileURLWithPath: pubPath)))
        let eph = P256.KeyAgreement.PrivateKey()
        let sym = try eph.sharedSecretFromKeyAgreement(with: pub).hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: info, outputByteCount: 32)
        let box = try AES.GCM.seal(Data(input.utf8), using: sym)
        try write600(eph.publicKey.x963Representation + box.combined!, base + "/\(a[2]).enc")
    } catch { fail("encrypt 失败: \(error)") }
case "decrypt":
    guard a.count >= 3 else { fail("缺少 name") }
    do {
        let ctx = LAContext(); ctx.localizedReason = "AWS 凭证：\(a[2])"
        let k = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: Data(contentsOf: URL(fileURLWithPath: keyPath)), authenticationContext: ctx)
        let blob = try Data(contentsOf: URL(fileURLWithPath: base + "/\(a[2]).enc"))
        let ephPub = try P256.KeyAgreement.PublicKey(x963Representation: blob.prefix(65))
        let sym = try k.sharedSecretFromKeyAgreement(with: ephPub).hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: info, outputByteCount: 32)
        let pt = try AES.GCM.open(AES.GCM.SealedBox(combined: blob.dropFirst(65)), using: sym)
        FileHandle.standardOutput.write(pt)
    } catch { fail("decrypt 失败: \(error)") }
default: fail("未知命令")
}
