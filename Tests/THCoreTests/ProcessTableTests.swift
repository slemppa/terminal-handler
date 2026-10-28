import Testing
@testable import THCore

@Suite struct ProcessTableTests {
    @Test func picksClaudeOverChildrenAndIgnoresShells() {
        let ps = """
          500 ttys000  Ss   -zsh
        57144 ttys000  S+   claude
        57187 ttys000  S+   /Users/x/01 - Video/mcp/lightcraft-cli
          600 ttys001  Ss+  -zsh
          700 ttys002  S+   npm exec @playwright/mcp@latest
          650 ttys002  S+   node
          800 ??       S    /usr/libexec/foo
        """
        #expect(ProcessTable.parse(ps) == ["ttys000": "claude", "ttys002": "node"])
    }
}
