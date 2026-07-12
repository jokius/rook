import Testing
@testable import rookCore

struct CLIInstallTests {
    @Test func installPathIsToolUnderInstallDir() {
        #expect(CLIInstall.installPath == "/usr/local/bin/rookctl")
    }

    @Test func shellQuoteWrapsPlainValue() {
        #expect(CLIInstall.shellQuote("/Applications/rook.app") == "'/Applications/rook.app'")
    }

    @Test func shellQuoteEscapesSingleQuotes() {
        #expect(CLIInstall.shellQuote("a'b") == "'a'\\''b'")
    }

    @Test func privilegedCommandLinksSourceToInstallPath() {
        let cmd = CLIInstall.privilegedInstallCommand(source: "/Apps/rook.app/Contents/MacOS/rookctl")
        #expect(cmd == "mkdir -p '/usr/local/bin' && ln -sf '/Apps/rook.app/Contents/MacOS/rookctl' '/usr/local/bin/rookctl'")
    }

    @Test func privilegedCommandQuotesSourceWithSpaces() {
        let cmd = CLIInstall.privilegedInstallCommand(source: "/My Apps/rook.app/Contents/MacOS/rookctl")
        #expect(cmd.contains("ln -sf '/My Apps/rook.app/Contents/MacOS/rookctl' '/usr/local/bin/rookctl'"))
    }
}
