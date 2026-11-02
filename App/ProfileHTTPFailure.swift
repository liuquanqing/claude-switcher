import Foundation

/// An HTTP rejection requests native confirmation, never proves revocation by itself.
struct ProfileHTTPFailure:LocalizedError {
    let code:Int
    var errorDescription:String? {code==401 ? "登录已过期，请在对应客户端确认登录后重试。" : "API error \(code)"}
    var needsNativeConfirmation:Bool {code==401 || code==403}
}
