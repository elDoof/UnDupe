import Foundation
import Security

/// Decides whether a downloaded copy of UnDupe is allowed to replace this one.
///
/// This is the security boundary of the whole update feature. HTTPS only proves
/// the bytes came from GitHub; it says nothing about who built them. The rule
/// enforced here is stricter and doesn't depend on GitHub at all:
///
/// > an update may only be installed if it is validly code-signed by the same
/// > Apple Developer team that signed the copy already running.
///
/// A compromised GitHub account, a hijacked release, or a proxy that swaps the
/// download therefore still can't install anything, because none of them hold
/// the signing key.
public enum UpdateVerifier {

    /// The Developer team identifier a bundle is signed with, or `nil` for an
    /// unsigned or ad-hoc-signed build (which is what local `build-app.sh`
    /// produces without `--sign`).
    public static func teamIdentifier(ofBundleAt url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return nil }

        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }

        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Throws unless the bundle at `url` is a valid, unmodified, Apple-anchored
    /// build signed by `teamIdentifier`.
    ///
    /// - Note: verify the copy you are about to install, *after* copying it out
    ///   of the disk image — not the one still on the mounted image. Otherwise
    ///   the bytes that get verified aren't necessarily the bytes that get run.
    public static func verify(bundleAt url: URL, isSignedBy teamIdentifier: String) throws {
        guard !teamIdentifier.isEmpty else { throw UpdateError.unsignedBuild }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            throw UpdateError.signatureRejected("the downloaded app has no code signature")
        }

        // "anchor apple generic" pins the chain to Apple's root, so a self-signed
        // certificate claiming the same team identifier will not satisfy it.
        let requirementText = """
        anchor apple generic and certificate leaf[subject.OU] = "\(teamIdentifier)"
        """
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement)
                == errSecSuccess, let requirement else {
            throw UpdateError.signatureRejected("couldn't build the signing requirement")
        }

        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures
                               | kSecCSCheckNestedCode
                               | kSecCSStrictValidate)
        var unmanagedError: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &unmanagedError)

        guard status == errSecSuccess else {
            let detail = unmanagedError?.takeRetainedValue().localizedDescription
                ?? "signature check failed (OSStatus \(status))"
            throw UpdateError.signatureRejected(detail)
        }
    }
}
