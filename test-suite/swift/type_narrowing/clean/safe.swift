import Foundation

struct Profile {
    let email: String?
}

func optionalChainGuardSafe(profile: Profile?) {
    if profile?.email == nil {
        return
    }
    if let email = profile?.email {
        print("safe email \(email.lowercased())")
    }
}

func objcBridgeSafe(nsString: NSString?) {
    guard let ensured = nsString else {
        return
    }
    NSLog("length = \(ensured.length)")
}

func sendEmail(profile: Profile?) {
    guard let email = profile?.email else {
        print("missing email")
        return
    }
    print("Email ready for \(email.count) characters")
}

func displayName(raw: String?) {
    guard let name = raw else {
        print("empty name provided")
        return
    }
    print("Hello \(name)")
}
