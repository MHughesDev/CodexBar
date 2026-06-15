import Foundation

public enum CLIProbeSessionResetter {
    public static func resetAll() async {
        #if canImport(Darwin) || os(Linux)
        await ClaudeCLISession.shared.reset()
        await CodexCLISession.shared.reset()
        await AntigravityCLISession.shared.reset()
        #endif
    }
}
