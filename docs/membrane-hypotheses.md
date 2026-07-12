# The Membrane — Hypothesis Map

*2026-07-11 — the bets underneath the membrane, and what would validate or kill each. The design
questions (triage function, gradient, etc.) can't be answered from an armchair because they rest on
these. De-risk the cheapest, riskiest bets first — most are learnable by **observation**, before any
build.*

Read order of risk: a false Tier-0 bet kills the whole thing; a false Tier-1 bet changes the shape;
a false Tier-2 bet changes the primitive. Test them in that order — never build a Tier-2 probe while
a Tier-0 bet is still unexamined.

---

## Tier 0 — Foundational bets (if any is false, there is no membrane)

**H1 — The world runs on *many concurrent, autonomous* agent loops per person.**
Not one better assistant used on-demand — a *swarm* running in parallel without you.
- *Kills if false:* no swarm → no supervision problem → no membrane. Back to a chat tool.
- *Learn by observation (now):* Is the frontier actually heading toward many-concurrent-autonomous
  per person? Signals: are power users (Gordon included — Claude Code instances, Port42 companions,
  nexus) *already* running agents in parallel, or serially one-at-a-time? Where are the labs pushing —
  parallel autonomy or single-thread reliability?

**H2 — Supervising many agent loops is a *real, felt* pain, not a hypothetical.**
- *Kills if false:* if "fire an agent, check back later" feels fine, there's nothing to solve.
- *Learn by observation (now):* Gordon is the primary subject — he already runs multiple agents.
  Where does it actually hurt today? Lost track of one? Missed something that needed him? Drowned in
  output? Afraid to let one run? Log the *felt* friction over a week of real multi-agent work.

**H3 — The binding constraint in an agentic world is human *attention/judgment*, not agent capability.**
The membrane bets the scarce resource becomes the human's ability to watch/steer/trust.
- *Kills if false:* if agents just get reliable enough to not need oversight, the membrane is moot.
- *Learn by reasoning + observation:* As agents get more capable, does oversight *shrink* (they need
  you less) or *shift* (they do more, so there's more to oversee, and the stakes rise)? Watch whether
  more-capable agents reduce or increase the felt supervision load.

**H3a — Broad personal intent is made tractable by *depth-of-knowing-the-person*, not by narrowing
the domain. (The personal-AI bet.)**
A person's intent across all their projects is a broad, shifting, interrelated cloud — you cannot
triage or steer against a stated goal. Narrowing to one domain would make it tractable but would
destroy the thing that makes it a *personal* AI: the cross-project richness *is* the value. So the
bet is that the membrane triages the whole broad life against an *accumulated model of the person*
(the relationship layer: fold/creases/engravings), not against a goal.
- *Kills if false:* if deep person-knowledge can't actually triage broad intent well enough to trust,
  there is no personal AI — only narrow tools. This is the deepest bet; if it fails the thesis fails.
- *Consequence if true:* the relationship layer is not a feature — it is the **triage engine**. The
  breadth that looks like the problem is the spec, and Port42's odd assets (accumulated person-model,
  device/environment access, shell owning the periphery) are exactly the three things needed to do it:
  *know the person, sense the environment, own the periphery* — none of which a narrow-domain competitor
  has or can get by narrowing.
- *Learn:* over Gordon's real cross-project week — could a system that knew him well have predicted,
  at each interruption, whether he'd want to be pulled out? Retro-score: for each real interruption,
  was "should this have reached me?" answerable from a deep model of him, or genuinely unpredictable?

**H3b — Triaging against attention requires sensing attention across the whole *environment*, not
just inside Port42.**
Attention is narrow at any instant, but it roams the entire machine and the physical room — you may
be heads-down in another app, on a call, or away from the desk. The membrane cannot triage against
attention it cannot see.
- *Kills if false / forces:* if the membrane can only see its own surfaces, attention-triage is blind
  whenever you're elsewhere — which is most of the time. Requires environmental presence-sensing
  (focused window, at-machine, on-a-call) — which needs the device access and the shell/ambient model.
- *Consequence:* "you're heads-down elsewhere" is a first-class triage input (*don't* knock), not a
  blind spot. Presence sensing (screen.windows, camera, activity) becomes core, not incidental.
- *Learn:* over the week, at each moment an agent needed him — where was his attention? How often was
  it *outside* anything Port42 could see? That fraction is how blind attention-triage is without
  environment sensing.

---

## Tier 1 — Shape bets (thesis holds, but *how* the membrane works)

Each stated as a concrete moment + a prediction + the tell it's wrong. Several have a *precedent
where the bet already failed* — those are the ones to watch hardest.

**H4 — When an agent is mid-run, you want to look inside and change its course — not just wait.**
- *Concrete:* Gordon fires Claude Code on a refactor. The bet: partway through he'll want to see
  "it's 3 files in, going the wrong way" and *redirect it live* — an ongoing process he supervises.
- *Wrong if:* he only ever cares about before (the prompt) and after (the result), never wants to
  look mid-run, and "is it done yet?" is his only in-flight thought. Then it's a *task queue*, not a
  loop — dispatch-and-collect, and the whole watching/steering frame is overbuilt.
- *Watch for:* moments he *wishes* he could intervene mid-run but the tool only lets him kill-and-restart.

**H5 — When you spot an agent going slightly wrong, you fix it right where you're looking.**
- *Concrete:* he sees, in whatever shows agent activity, that forge is about to do the wrong thing.
  The bet: he reaches in and corrects it *there*, in the same view.
- *Wrong if:* he naturally leaves that view to go issue the correction somewhere else (a prompt box, a
  config). Then watching and steering are two surfaces, not one motion.
- *Watch for:* the gap between "notices problem" and "acts" — is it zero-travel or a context-switch?

**H6 — Given a view of all agents, you glance and leave — you don't sit and stare.**
- *Concrete:* he has a way to see the whole swarm. The bet: he checks it, sees calm, closes it, and
  trusts it'll knock if needed.
- *Wrong if:* he keeps it open and monitors it, or *not knowing* what an agent is doing makes him
  anxious enough to keep checking. Then he needs an active dashboard, not a calm periphery.
- *Precedent that failed:* **email.** It's ambient — arrives in the background — and people still
  check it obsessively. Ambient delivery did not produce calm; it produced compulsive checking. If
  the swarm-view goes the same way, calm-tech is the wrong model here too.

**H7 — When you delegate, you think in graded permission ("do X freely, check with me on Y"), and
you'll actually set it.**
- *Concrete:* handing forge a job, the bet is he wants "autonomous on CSS, ask-me on the database"
  and will take the two seconds to say so.
- *Wrong if:* he thinks purely binary ("go" / "stop"), OR he wants the granularity in principle but
  never actually tunes it. Then the trust dial is a config screen nobody touches.
- *Precedent that failed:* **notification settings.** Every app offers granular per-type controls;
  almost nobody adjusts them. Fine-grained trust may die the same way — wanted in theory, ignored in
  practice. The tell: does he *set* autonomy per task, or leave it at whatever the default is?

---

## Tier 2 — Knock bets (the specific primitive)

**H8 — You'll let something else decide which agent-needs reach you — and survive the first time it's
wrong.**
- *Concrete:* the membrane suppresses a knock it judged unimportant. The bet: Gordon accepts the
  membrane as his attention's gatekeeper, and a wrong suppression costs him a little but doesn't break
  his trust in it.
- *Wrong if:* the *first* false-negative that matters (it hid something he needed) makes him turn
  triage off and go back to seeing everything. Then no membrane can gate attention — the whole knock
  premise fails.
- *Precedent that failed:* **the spam folder.** People don't trust filters with important mail; they
  check spam anyway. If the knock's triage is a spam filter for attention, people will "check the
  spam folder" — i.e. want to see everything — and triage buys nothing.
- *The number to find:* how many good-suppressions does it take to earn trust, vs how many
  false-negatives to lose it? (Almost certainly asymmetric and brutal — one bad miss ≫ many good hides.)

**H9 — A signal that *builds pressure* gets attended-when-ready; it doesn't become a new nag.**
- *Concrete:* an agent's knock slowly grows more insistent in the periphery. The bet: Gordon feels
  "I'll get to it" and attends on his own schedule — pressure as information, not interruption.
- *Wrong if:* the building signal is itself a low-grade stressor ("something's nagging at me") and he
  mutes it to make it stop — recreating the exact noise we're escaping.
- *Watch for:* does a growing signal get *attended* or *muted*? Muted = gradient is just a slower ping.

**H10 — Most of what needs you is a *repeat* of a decision you've already made.**
- *Concrete:* over a week, categorize every moment an agent needed Gordon. The bet: the large
  majority are "same situation as before, he did the same thing" — so learning can retire them.
- *Wrong if:* most needs are *genuinely novel* (new context, new judgment each time). Then there's
  nothing to learn, the knock-rate never falls, and it's a notification with extra steps.
- *The number to find:* of N agent-needs in a week, what fraction are repeats of a prior decision?
  >~60% → learning converges. <~30% → it never does.

**H11 — There are real moments where async with an agent fails and you'd rather just talk.**
- *Concrete:* the bet is Gordon will hit moments where he types a long clarification, or goes 5+
  rounds because the thing is hard to convey in text, or gives up — moments a synchronous "call"
  would have saved.
- *Wrong if:* async always suffices; he never wishes he could talk it through. Then the call is a
  novelty.
- *Watch for:* count the >5-round clarification spirals and the give-ups. Those are the call's market.

---

## What this means for sequencing

- **Tier 0 is highest-risk and cheapest to test** — pure observation, no build. That is the lean
  move: de-risk the assumptions that kill everything, before spending anything. **Gordon's own
  multi-agent week is the primary experiment** — he is already living the H1/H2/H3 conditions.
- **Tier 1 is learnable mostly by listening** — how people frame and want to work, watchable in real
  usage and conversation. Still cheap.
- **Tier 2 needs a minimal probe** — but a *crude* one: a thing that triages signals from a few real
  running agents and renders them as a gradient peek would teach H8/H9/H10 fast. Do **not** build the
  full membrane to test these; build the smallest thing that produces a false-negative you can feel.

**The one experiment to run first:** instrument Gordon's real multi-agent work for a week and record
the *felt* friction — where he lost track, missed something, drowned, or hesitated to delegate. That
single log tests H1, H2, H3 at once, and its texture (what actually needed him, when, and why) is the
raw material for the triage function we couldn't answer from the armchair.

## How the design questions map back

The unanswerable design questions from `the-knock.md` are downstream of these bets:

| Design question | Hypothesis it depends on | Learn it by |
|---|---|---|
| the triage function (what earns your calm) | H8 (+ H2, H3) | the friction log — what actually needed him |
| rendering the gradient | H9 | a crude gradient-peek probe |
| how a knock fades | H10 | approval-pattern data over time |
| what "the call" is | H11 | catching the moments async fails |
| composition rules | H8 | the friction log — when did multiple needs pile up |

You don't design the triage function. You *watch what needs you* until its shape is obvious.
