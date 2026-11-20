import Foundation
import Testing

@Suite("Script installer")
struct ScriptInstallerTests {
    private func bundled(_ text: String, in home: TemporaryHome) throws -> URL {
        let url = home.url.appending(path: "bundle/brew-updates.sh")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func installsWhenMissingAndMakesItExecutable() throws {
        let home = try TemporaryHome()
        let paths = AppPaths(home: home.url)
        let source = try bundled("echo v1\n", in: home)

        #expect(try ScriptInstaller(paths: paths).install(from: source))
        #expect(try String(contentsOf: paths.deployedScript, encoding: .utf8) == "echo v1\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.deployedScript.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o755)
    }

    @Test func installsTheLauncherNextToTheScript() throws {
        let home = try TemporaryHome()
        let paths = AppPaths(home: home.url)
        let source = home.url.appending(path: "bundle/brew-updates-launcher")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xCF, 0xFA, 0xED, 0xFE]).write(to: source)

        let installer = ScriptInstaller(paths: paths)
        #expect(try installer.installLauncher(from: source))
        #expect(try Data(contentsOf: paths.deployedLauncher) == Data([0xCF, 0xFA, 0xED, 0xFE]))
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.deployedLauncher.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o755)
        #expect(paths.deployedLauncher.deletingLastPathComponent() == paths.deployedScript.deletingLastPathComponent())
        #expect(try !installer.installLauncher(from: source))
    }

    @Test func removesTheCopyWithTheOldName() throws {
        let home = try TemporaryHome()
        let paths = AppPaths(home: home.url)
        try FileManager.default.createDirectory(at: paths.supportDirectory, withIntermediateDirectories: true)
        try Data("echo old\n".utf8).write(to: paths.retiredDeployedScript)

        let installer = ScriptInstaller(paths: paths)
        try installer.install(from: try bundled("echo v1\n", in: home))
        #expect(FileManager.default.fileExists(atPath: paths.retiredDeployedScript.path))
        installer.removeRetiredCopy()
        #expect(!FileManager.default.fileExists(atPath: paths.retiredDeployedScript.path))
        #expect(FileManager.default.fileExists(atPath: paths.deployedScript.path))
    }

    @Test func leavesAnIdenticalCopyAlone() throws {
        let home = try TemporaryHome()
        let installer = ScriptInstaller(paths: AppPaths(home: home.url))
        let source = try bundled("echo v1\n", in: home)
        try installer.install(from: source)
        #expect(try !installer.install(from: source))
    }

    @Test func replacesADifferentCopy() throws {
        let home = try TemporaryHome()
        let paths = AppPaths(home: home.url)
        let installer = ScriptInstaller(paths: paths)
        try installer.install(from: try bundled("echo v1\n", in: home))

        #expect(try installer.install(from: try bundled("echo v2\n", in: home)))
        #expect(try String(contentsOf: paths.deployedScript, encoding: .utf8) == "echo v2\n")
    }
}
