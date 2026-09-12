import Foundation

/// Common reply path used by Wi‑Fi TCP sessions and BLE sessions.
protocol UnlockChannel: AnyObject {
    var secret: Data? { get set }
    func send(_ envelope: Envelope)
    func sendFail(_ reason: String)
}

extension UnlockChannel {
    func sendFail(_ reason: String) {
        let payload = UnlockFailPayload(reason: reason)
        let env = Envelope(type: .unlockFail, payload: try? ProtocolCodec.encode(payload))
        send(env)
    }
}
