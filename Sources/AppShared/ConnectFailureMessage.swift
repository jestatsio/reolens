import Foundation
import ReolinkAPI

/// Single source of truth for the user-facing wording of a camera connect /
/// transport failure. Folds what used to be three disagreeing mappers
/// (`CameraSession.connectionFailureMessage`, the inline auth string, and
/// `CameraSession+RecordingsLoader.friendlyTransportMessage`) into one pure,
/// `nonisolated` function so every surface shows the same message for the same
/// error.
///
/// Every returned string is **credential- and host-free** (AGENTS.md §3) — the
/// raw transport error is logged separately at `.public`; the user only ever
/// sees a sanitized, actionable sentence. GitHub #76.
public enum ConnectFailureMessage {

    /// The category of a connect failure, derived from the typed error. Reuses
    /// `CameraSession`'s canonical classifiers for the two cases the retry loop
    /// also keys on, so there's exactly one definition of each.
    enum Reason {
        case refusedPort     // answered but refused the CGI port (web API off)
        case timedOut        // no answer in time (unreachable / wrong network)
        case hostNotFound    // no route / DNS failure (wrong IP or hostname)
        case tls             // HTTPS handshake / certificate failure
        case offline         // this device isn't on a usable network
        case authRejected    // wrong username / password
        case generic         // anything else
    }

    static func classify(_ error: any Error) -> Reason {
        // Canonical classifiers (also drive the connect retry decision).
        if CameraSession.isAuthFailure(error) { return .authRejected }
        if CameraSession.suggestsClosedAPIPort(error) { return .refusedPort }

        // Unwrap a transport URLError, whether raw or wrapped by the CGI client.
        let urlError: URLError? = {
            if let urlError = error as? URLError { return urlError }
            if let reolink = error as? ReolinkClientError,
               case let .transport(inner) = reolink {
                return inner as? URLError
            }
            return nil
        }()
        guard let urlError else { return .generic }
        switch urlError.code {
        case .timedOut:
            return .timedOut
        case .cannotFindHost, .dnsLookupFailed:
            return .hostNotFound
        case .secureConnectionFailed, .serverCertificateUntrusted:
            return .tls
        case .notConnectedToInternet, .networkConnectionLost:
            return .offline
        default:
            return .generic
        }
    }

    /// The message to show for a failed connect. Pass `bothWebPortsRefused` when
    /// *both* HTTP and HTTPS were refused at the port (and the Baichuan fallback
    /// also failed to bring the session up) so the wording points at the web-API
    /// toggle and mentions the Baichuan retry instead of a single port.
    public static func text(for error: any Error, bothWebPortsRefused: Bool = false) -> String {
        if bothWebPortsRefused {
            return "Reolens couldn't reach this camera's web API on HTTP or HTTPS — it may be turned off. Open the Reolink app: Network → Advanced → Port Settings, enable HTTP/HTTPS, turn off Privacy Mode, then reconnect. (Reolens also tries the camera's Baichuan port automatically.)"
        }
        switch classify(error) {
        case .refusedPort:
            return "The camera refused the connection. If you recently updated its firmware, its HTTP/HTTPS API may be off — open the Reolink app, enable HTTP/HTTPS under Network → Advanced → Port Settings, turn off Privacy Mode, then try again."
        case .timedOut:
            return "Reolens couldn't reach the camera in time. Check that it's powered on and on the same Wi-Fi, then try again."
        case .hostNotFound:
            return "Reolens couldn't find the camera at that address. Double-check the IP or hostname in Settings → Cameras."
        case .tls:
            return "The camera's HTTPS certificate couldn't be verified — it may have changed. Remove and re-add the camera to trust the new certificate."
        case .offline:
            return "Your device isn't on the camera's network. Reconnect to the same Wi-Fi, then try again."
        case .authRejected:
            return "The camera rejected the saved password. Update it in Settings → Cameras."
        case .generic:
            return "Couldn't reach the camera. Check that it's powered on and on the same network, then try again."
        }
    }
}
