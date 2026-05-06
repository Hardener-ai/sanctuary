import PackagePlugin

@main
struct AgentRegistryPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let generator = try context.tool(named: "AgentRegistryGenerator")
        let input = context.package.directory.appending("agents.yaml")
        let output = context.pluginWorkDirectory.appending("GeneratedRegistry.swift")

        return [
            .buildCommand(
                displayName: "Generate Sanctuary agent registry",
                executable: generator.path,
                arguments: [input.string, output.string],
                inputFiles: [input],
                outputFiles: [output]
            )
        ]
    }
}
