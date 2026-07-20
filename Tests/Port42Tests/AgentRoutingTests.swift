import Testing
import Foundation
@testable import Port42Lib

@Suite("Agent Message Routing")
struct AgentRoutingTests {

    // MARK: - Mention Extraction

    @Test("Extract single mention")
    func singleMention() {
        let mentions = MentionParser.extractMentions(from: "@ai-engineer review this")
        #expect(mentions == ["@ai-engineer"])
    }

    @Test("Extract multiple mentions")
    func multipleMentions() {
        let mentions = MentionParser.extractMentions(from: "@ai-engineer and @ai-muse what do you think?")
        #expect(mentions.count == 2)
        #expect(mentions.contains("@ai-engineer"))
        #expect(mentions.contains("@ai-muse"))
    }

    @Test("No mentions returns empty")
    func noMentions() {
        let mentions = MentionParser.extractMentions(from: "hello world")
        #expect(mentions.isEmpty)
    }

    @Test("Mention at start of message")
    func mentionAtStart() {
        let mentions = MentionParser.extractMentions(from: "@bot hello")
        #expect(mentions == ["@bot"])
    }

    @Test("Mention at end of message")
    func mentionAtEnd() {
        let mentions = MentionParser.extractMentions(from: "hey @bot")
        #expect(mentions == ["@bot"])
    }

    @Test("Mention with hyphens")
    func mentionWithHyphens() {
        let mentions = MentionParser.extractMentions(from: "@my-cool-agent do something")
        #expect(mentions == ["@my-cool-agent"])
    }

    @Test("Email addresses are not mentions")
    func emailNotMention() {
        let mentions = MentionParser.extractMentions(from: "email me at user@example.com")
        #expect(mentions.isEmpty)
    }

    @Test("Duplicate mentions deduplicated")
    func deduplicateMentions() {
        let mentions = MentionParser.extractMentions(from: "@bot hey @bot again")
        #expect(mentions == ["@bot"])
    }

    // MARK: - Routing Decision

    @Test("Message with agent mention routes to that agent")
    func routeToMentionedAgent() {
        let agents = [
            makeAgent(name: "ai-engineer", trigger: .mentionOnly),
            makeAgent(name: "ai-muse", trigger: .mentionOnly),
        ]
        let targets = AgentRouter.findTargetAgents(
            content: "@ai-engineer review this",
            agents: agents
        )
        #expect(targets.count == 1)
        #expect(targets.first?.displayName == "ai-engineer")
    }

    @Test("Message with no mention skips mention-only agents")
    func noRouteWithoutMention() {
        let agents = [
            makeAgent(name: "ai-engineer", trigger: .mentionOnly),
        ]
        let targets = AgentRouter.findTargetAgents(
            content: "hello everyone",
            agents: agents
        )
        #expect(targets.isEmpty)
    }

    // findTargetAgents is now membership/mention-based: a no-mention message targets the space's
    // MEMBERS (spaceAgentIds), and the .mentionOnly/.allMessages trigger no longer gates it here —
    // trigger selection moved up into the AppState pipeline (initiative exclusion + the LLM router).
    @Test("A no-mention message targets the space's members")
    func noMentionTargetsSpaceMembers() {
        let watcher = makeAgent(name: "watcher", trigger: .allMessages)
        let targets = AgentRouter.findTargetAgents(
            content: "hello everyone",
            agents: [watcher],
            spaceAgentIds: [watcher.id]
        )
        #expect(targets.count == 1)
        #expect(targets.first?.displayName == "watcher")
    }

    @Test("Mentions match by name; a no-mention message falls back to all space members")
    func mentionAndMembershipRouting() {
        let engineer = makeAgent(name: "ai-engineer", trigger: .mentionOnly)
        let watcher = makeAgent(name: "watcher", trigger: .allMessages)
        let agents = [engineer, watcher]
        let members: Set<String> = [engineer.id, watcher.id]

        // No mention → every space member is a candidate (who actually speaks is decided upstream).
        let noMention = AgentRouter.findTargetAgents(content: "hello", agents: agents, spaceAgentIds: members)
        #expect(Set(noMention.map { $0.displayName }) == ["ai-engineer", "watcher"])

        // Explicit mention → only the mentioned agent, regardless of membership or trigger.
        let mentioned = AgentRouter.findTargetAgents(content: "@ai-engineer hello", agents: agents, spaceAgentIds: members)
        #expect(mentioned.count == 1)
        #expect(mentioned.first?.displayName == "ai-engineer")
    }

    @Test("Multiple agents mentioned")
    func multipleMentioned() {
        let agents = [
            makeAgent(name: "ai-engineer", trigger: .mentionOnly),
            makeAgent(name: "ai-muse", trigger: .mentionOnly),
            makeAgent(name: "ai-analyst", trigger: .mentionOnly),
        ]
        let targets = AgentRouter.findTargetAgents(
            content: "@ai-engineer @ai-muse thoughts?",
            agents: agents
        )
        #expect(targets.count == 2)
    }

    // MARK: - Routing works for both LLM and Command agents

    @Test("LLM and command agents both route by mention")
    func mixedModeRouting() {
        let llmAgent = AgentConfig.createLLM(
            ownerId: "u", displayName: "ai-engineer",
            systemPrompt: "engineer", provider: .anthropic, model: "claude-sonnet-4-20250514",
            trigger: .mentionOnly
        )
        let cmdAgent = AgentConfig.createCommand(
            ownerId: "u", displayName: "custom-bot",
            command: "/bin/bot", trigger: .mentionOnly
        )
        let targets = AgentRouter.findTargetAgents(
            content: "@ai-engineer @custom-bot review this",
            agents: [llmAgent, cmdAgent]
        )
        #expect(targets.count == 2)
    }

    // MARK: - Autocomplete Matching

    @Test("Autocomplete matches prefix")
    func autocompletePrefix() {
        let agents = [
            makeAgent(name: "ai-engineer", trigger: .mentionOnly),
            makeAgent(name: "ai-muse", trigger: .mentionOnly),
            makeAgent(name: "ai-analyst", trigger: .mentionOnly),
        ]
        let matches = MentionParser.autocomplete(query: "@ai-e", agents: agents)
        #expect(matches.count == 1)
        #expect(matches.first?.displayName == "ai-engineer")
    }

    @Test("Autocomplete with just @ returns all")
    func autocompleteAll() {
        let agents = [
            makeAgent(name: "ai-engineer", trigger: .mentionOnly),
            makeAgent(name: "ai-muse", trigger: .mentionOnly),
        ]
        let matches = MentionParser.autocomplete(query: "@", agents: agents)
        #expect(matches.count == 2)
    }

    @Test("Autocomplete is case-insensitive")
    func autocompleteCaseInsensitive() {
        let agents = [
            makeAgent(name: "AI-Engineer", trigger: .mentionOnly),
        ]
        let matches = MentionParser.autocomplete(query: "@ai-eng", agents: agents)
        #expect(matches.count == 1)
    }

    @Test("Autocomplete no match returns empty")
    func autocompleteNoMatch() {
        let agents = [
            makeAgent(name: "ai-engineer", trigger: .mentionOnly),
        ]
        let matches = MentionParser.autocomplete(query: "@xyz", agents: agents)
        #expect(matches.isEmpty)
    }

    // MARK: - Helpers

    private func makeAgent(name: String, trigger: AgentTrigger) -> AgentConfig {
        AgentConfig.createLLM(
            ownerId: "user-1",
            displayName: name,
            systemPrompt: "test",
            provider: .anthropic,
            model: "claude-sonnet-4-20250514",
            trigger: trigger
        )
    }
}
