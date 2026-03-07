import Testing
import Foundation
@testable import Port42Lib

@Suite("Agent Config")
struct AgentConfigTests {

    func makeDB() throws -> DatabaseService {
        try DatabaseService(inMemory: true)
    }

    // MARK: - Model (LLM mode)

    @Test("Create LLM agent config")
    func createLLMConfig() {
        let agent = AgentConfig.createLLM(
            ownerId: "user-1",
            displayName: "@ai-engineer",
            systemPrompt: "You are a senior engineer. Be concise.",
            provider: .anthropic,
            model: "claude-sonnet-4-20250514",
            trigger: .mentionOnly
        )
        #expect(agent.displayName == "@ai-engineer")
        #expect(agent.mode == .llm)
        #expect(agent.systemPrompt == "You are a senior engineer. Be concise.")
        #expect(agent.provider == .anthropic)
        #expect(agent.model == "claude-sonnet-4-20250514")
        #expect(agent.trigger == .mentionOnly)
        #expect(agent.command == nil)
        #expect(!agent.id.isEmpty)
    }

    // MARK: - Model (Command mode)

    @Test("Create command agent config")
    func createCommandConfig() {
        let agent = AgentConfig.createCommand(
            ownerId: "user-1",
            displayName: "@custom-bot",
            command: "/usr/local/bin/my-agent",
            args: ["--model", "claude"],
            trigger: .mentionOnly
        )
        #expect(agent.displayName == "@custom-bot")
        #expect(agent.mode == .command)
        #expect(agent.command == "/usr/local/bin/my-agent")
        #expect(agent.args == ["--model", "claude"])
        #expect(agent.systemPrompt == nil)
        #expect(agent.provider == nil)
        #expect(!agent.id.isEmpty)
    }

    @Test("Agent trigger modes")
    func triggerModes() {
        let mentionOnly = AgentConfig.createLLM(
            ownerId: "u", displayName: "@bot",
            systemPrompt: "help", provider: .anthropic, model: "claude-sonnet-4-20250514",
            trigger: .mentionOnly
        )
        let allMessages = AgentConfig.createLLM(
            ownerId: "u", displayName: "@watcher",
            systemPrompt: "watch", provider: .anthropic, model: "claude-sonnet-4-20250514",
            trigger: .allMessages
        )
        #expect(mentionOnly.trigger == .mentionOnly)
        #expect(allMessages.trigger == .allMessages)
    }

    @Test("Agent mode distinguishes LLM from Command")
    func agentModes() {
        let llm = AgentConfig.createLLM(
            ownerId: "u", displayName: "@llm",
            systemPrompt: "hi", provider: .anthropic, model: "claude-sonnet-4-20250514",
            trigger: .mentionOnly
        )
        let cmd = AgentConfig.createCommand(
            ownerId: "u", displayName: "@cmd",
            command: "/bin/bot", trigger: .mentionOnly
        )
        #expect(llm.mode == .llm)
        #expect(cmd.mode == .command)
        #expect(llm.mode != cmd.mode)
    }

    // MARK: - Database CRUD

    @Test("Save and retrieve LLM agent")
    func saveAndGetLLM() throws {
        let db = try makeDB()
        let user = AppUser.createLocal(displayName: "Test")
        try db.saveUser(user)

        let agent = AgentConfig.createLLM(
            ownerId: user.id,
            displayName: "@ai-engineer",
            systemPrompt: "You are an engineer.",
            provider: .anthropic,
            model: "claude-sonnet-4-20250514",
            trigger: .mentionOnly
        )
        try db.saveAgent(agent)

        let agents = try db.getAllAgents()
        #expect(agents.count == 1)
        #expect(agents.first?.displayName == "@ai-engineer")
        #expect(agents.first?.mode == .llm)
        #expect(agents.first?.systemPrompt == "You are an engineer.")
        #expect(agents.first?.provider == .anthropic)
        #expect(agents.first?.model == "claude-sonnet-4-20250514")
    }

    @Test("Save and retrieve command agent")
    func saveAndGetCommand() throws {
        let db = try makeDB()
        let user = AppUser.createLocal(displayName: "Test")
        try db.saveUser(user)

        let agent = AgentConfig.createCommand(
            ownerId: user.id,
            displayName: "@custom-bot",
            command: "/usr/local/bin/my-agent",
            args: ["--verbose"],
            workingDir: "/tmp/workspace",
            envVars: ["API_KEY": "sk-123"],
            trigger: .mentionOnly
        )
        try db.saveAgent(agent)

        let fetched = try db.getAllAgents().first!
        #expect(fetched.mode == .command)
        #expect(fetched.command == "/usr/local/bin/my-agent")
        #expect(fetched.args == ["--verbose"])
        #expect(fetched.workingDir == "/tmp/workspace")
        #expect(fetched.envVars?["API_KEY"] == "sk-123")
    }

    @Test("Delete agent")
    func deleteAgent() throws {
        let db = try makeDB()
        let user = AppUser.createLocal(displayName: "Test")
        try db.saveUser(user)

        let agent = AgentConfig.createLLM(
            ownerId: user.id, displayName: "@bot",
            systemPrompt: "help", provider: .anthropic, model: "claude-sonnet-4-20250514",
            trigger: .mentionOnly
        )
        try db.saveAgent(agent)
        #expect(try db.getAllAgents().count == 1)

        try db.deleteAgent(id: agent.id)
        #expect(try db.getAllAgents().count == 0)
    }

    @Test("Update agent")
    func updateAgent() throws {
        let db = try makeDB()
        let user = AppUser.createLocal(displayName: "Test")
        try db.saveUser(user)

        var agent = AgentConfig.createLLM(
            ownerId: user.id, displayName: "@bot",
            systemPrompt: "v1", provider: .anthropic, model: "claude-sonnet-4-20250514",
            trigger: .mentionOnly
        )
        try db.saveAgent(agent)

        agent.systemPrompt = "v2 improved prompt"
        agent.trigger = .allMessages
        try db.saveAgent(agent)

        let fetched = try db.getAllAgents()
        #expect(fetched.count == 1)
        #expect(fetched.first?.systemPrompt == "v2 improved prompt")
        #expect(fetched.first?.trigger == .allMessages)
    }

    @Test("Multiple agents for same user")
    func multipleAgents() throws {
        let db = try makeDB()
        let user = AppUser.createLocal(displayName: "Test")
        try db.saveUser(user)

        try db.saveAgent(AgentConfig.createLLM(
            ownerId: user.id, displayName: "@ai-engineer",
            systemPrompt: "engineer", provider: .anthropic, model: "claude-sonnet-4-20250514",
            trigger: .mentionOnly
        ))
        try db.saveAgent(AgentConfig.createCommand(
            ownerId: user.id, displayName: "@custom-bot",
            command: "/bin/bot", trigger: .mentionOnly
        ))

        let agents = try db.getAllAgents()
        #expect(agents.count == 2)
        let modes = Set(agents.map { $0.mode })
        #expect(modes.contains(.llm))
        #expect(modes.contains(.command))
    }

    // MARK: - Agent Invite Link

    @Test("Generate invite link from LLM agent")
    func generateInviteLink() {
        let agent = AgentConfig.createLLM(
            ownerId: "user-1",
            displayName: "@ai-engineer",
            systemPrompt: "You are an engineer.",
            provider: .anthropic,
            model: "claude-sonnet-4-20250514",
            trigger: .mentionOnly
        )

        let link = AgentInvite.generateLink(from: agent)
        #expect(link.hasPrefix("port42://agent?"))
        #expect(link.contains("ai-engineer"))
    }

    @Test("Parse invite link back to config")
    func parseInviteLink() throws {
        let agent = AgentConfig.createLLM(
            ownerId: "user-1",
            displayName: "@ai-engineer",
            systemPrompt: "You are an engineer.",
            provider: .anthropic,
            model: "claude-sonnet-4-20250514",
            trigger: .mentionOnly
        )

        let link = AgentInvite.generateLink(from: agent)
        let parsed = try AgentInvite.parse(link: link)

        #expect(parsed.displayName == "@ai-engineer")
        #expect(parsed.systemPrompt == "You are an engineer.")
        #expect(parsed.provider == .anthropic)
        #expect(parsed.model == "claude-sonnet-4-20250514")
    }

    @Test("Invite link does not contain auth credentials")
    func inviteLinkNoAuth() {
        let agent = AgentConfig.createLLM(
            ownerId: "user-1",
            displayName: "@bot",
            systemPrompt: "help",
            provider: .anthropic,
            model: "claude-sonnet-4-20250514",
            trigger: .mentionOnly
        )

        let link = AgentInvite.generateLink(from: agent)
        #expect(!link.contains("sk-"))
        #expect(!link.contains("oauth"))
        #expect(!link.contains("token"))
    }

    @Test("Command agents cannot be shared via invite")
    func commandAgentNotShareable() {
        let agent = AgentConfig.createCommand(
            ownerId: "user-1",
            displayName: "@custom-bot",
            command: "/usr/local/bin/my-agent",
            trigger: .mentionOnly
        )

        let link = AgentInvite.generateLink(from: agent)
        // Command agents return nil or empty since they can't be shared
        #expect(link.isEmpty)
    }
}
