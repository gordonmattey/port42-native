# PORT42 // SHELL — Form & Control Style Guide

**Status:** v1, 2026-07-02 (w/ gordon). The reference implementation is **`ShellNewCompanionView`**
(the "new companion" card in `ShellView.swift`) and `ShellSettingsView` (the space/companion box).
Everything here is *extracted from that screen*, not invented — when in doubt, read `card`, `seg`,
`boxField`, `label`, `promptBox` in `ShellView.swift` and match them.

This exists because reskins kept drifting. Any form/panel in the shell — Settings, Usage, future
panels — should be buildable from these primitives alone. If a control isn't specced here, add it
here first, then build it.

---

## 0. Core principles (the non-negotiables)

1. **Whole-element hit areas.** A selectable control is clickable across its *entire visual bounds*,
   never just the label text. Every tappable thing is a `Button { } label: { … }` whose label fills
   the frame, OR carries `.contentShape(Rectangle())` (or `Capsule()`) on the padded frame. If you
   can see it, you can click it. *(This is the #1 recurring bug — segmented options, rows, chips,
   accordion headers must all pass this.)*
2. **Spacing over dividers.** Sections are separated by whitespace (`VStack(spacing: 16)`) and a tiny
   uppercase label — **not** full-width `Divider()`s. Full-width dividers read as an old preferences
   form. The shell cards have zero of them.
3. **Translucent fills, never black.** Inputs/containers use `Color.white.opacity(0.04–0.06)`. Never
   `bgPrimary`/pure black — on the dark card it reads as a hole.
4. **Mono, always.** `Port42Theme.mono(_)` / `monoBold(_)`. No system fonts.
5. **Accent = the space accent** (`shell.accent`). It marks: selection, focus strokes, and the
   primary action. Everything else is `textPrimary` / `textSecondary`.
6. **One card chrome.** Floating panels are a `Port42Theme.shellCard` rounded-16 card with an accent
   hairline and a soft shadow, over a dim scrim, spring-animated in.

---

## 1. The card (any floating panel/overlay)

```swift
ZStack {
    Color.black.opacity(scrimOpacity).ignoresSafeArea().contentShape(Rectangle())
        .onTapGesture { dismiss() }                              // tap-away closes
    ScrollView(showsIndicators: false) { card.padding(22) }
        .frame(width: 400)                                       // 340–460 depending on content
        .background(Port42Theme.shellCard, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(accent.opacity(0.4), lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 40)
        .scaleEffect(cardScale).opacity(cardOpacity)             // 0.92→1, 0→1
}
// in: spring(response: 0.35, dampingFraction: 0.72) for scale/opacity; scrim easeOut 0.2 → 0.6
```

- Card body: `VStack(alignment: .leading, spacing: 16)`, `.padding(22)`.
- **Header row:** `Text("TITLE").monoBold(12).foregroundStyle(textSecondary).tracking(3)` + `Spacer()`
  + an `xmark` plain button. **Left-aligned tracking label — not a centered logo + name.**

## 2. Section label

```swift
Text("SECTION").font(Port42Theme.mono(9)).foregroundStyle(Port42Theme.textSecondary).tracking(2)
```
Uppercase, tracked, tiny. This is how sections are titled — one label, then the control(s), then
spacing before the next label. No divider.

## 3. Segmented control (`seg`) — mutually-exclusive choice

```swift
HStack(spacing: 0) {
    ForEach(options, id: \.self) { o in
        let on = o == selected
        Button { onTap(o) } label: {
            Text(o).font(Port42Theme.mono(10)).foregroundStyle(on ? accent : Port42Theme.textSecondary)
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .background(on ? accent.opacity(0.15) : Color.clear)
                .contentShape(Rectangle())     // REQUIRED: a `.clear` background is NOT hit-testable —
        }.buttonStyle(.plain)                  // without this only the text is tappable, not the segment
    }
}
.background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
.overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12), lineWidth: 1))
```
Each option is a full-width `Button` → the whole segment is clickable. Use this **instead of
`Picker(.segmented)`** (native segmented control is banned in the shell).

## 4. Chip / pill toggle — tags, presets (multi or single)

```swift
Button { toggle() } label: {
    HStack(spacing: 6) { Image(systemName: icon); Text(name).font(Port42Theme.mono(11)) }
        .foregroundStyle(on ? accent : Port42Theme.textPrimary)
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background((on ? accent.opacity(0.12) : Color.white.opacity(0.04)), in: Capsule())
        .overlay(Capsule().stroke(on ? accent.opacity(0.7) : Color.white.opacity(0.12), lineWidth: 1))
}.buttonStyle(.plain)
```
Whole capsule tappable.

## 5. Text field (`boxField`)

```swift
TextField(placeholder, text: $text).textFieldStyle(.plain)
    .font(Port42Theme.mono(12)).foregroundStyle(Port42Theme.textPrimary)
    .padding(.horizontal, 10).padding(.vertical, 7)
    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(accent.opacity(0.3), lineWidth: 1))
```
`SecureField` is identical. Multiline = `TextEditor` (`.scrollContentBackground(.hidden)`, fixed
height ~84) with the same fill + stroke.

## 6. Toggle (boolean)

```swift
HStack { label("OPTION"); Spacer()
    Toggle("", isOn: $on).labelsHidden().toggleStyle(.switch).tint(accent) }
```
The native switch **tinted with accent** is the shell toggle — keep it. (Untinted / non-`.switch`
toggles and bare checkboxes are the non-shell version.)

## 7. Buttons

- **Primary (commit):** `Text.monoBold(13)`, `foregroundStyle(.black)` on `accent` fill, rounded 10.
  Disabled → `textSecondary` on `Color.white.opacity(0.06)`.
- **Secondary:** plain text/icon in `textSecondary`, `.buttonStyle(.plain)`.
- **Destructive:** `.red` (or `Color.red.opacity(0.9)`), often with a two-step confirm inline.

## 8. Menu / dropdown (many options, compact)

Native `Picker(.menu)` is banned. Use a `Menu` with a box-field label:

```swift
Menu { ForEach(opts) { Button($0.title) { sel = $0 } } } label: {
    HStack(spacing: 5) { Text(sel.title).font(Port42Theme.mono(11)).foregroundStyle(Port42Theme.textPrimary)
        Spacer(minLength: 2); Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(Port42Theme.textSecondary) }
    .padding(.horizontal, 8).padding(.vertical, 6)
    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
}.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
```

---

## 9. GAPS — patterns we didn't have a spec for (decide + build to these)

### 9a. Accordion / collapsible section
The Settings panel uses accordions; they should feel like the card, not a form.
- **Header** = a full-width `Button` (whole row clickable, `.contentShape(Rectangle())`): a section
  **label** (§2 style, `mono(9)` tracked, or `mono(13)` textSecondary for a top-level group) +
  `Spacer()` + a `chevron.down/up` at `size: 9` in `textSecondary`. No border box on the header.
- **Expanded body**: indented content with `VStack(spacing: …)`, separated from the next section by
  **spacing, not a full-width divider**. If a separator is truly needed, a hairline
  `Color.white.opacity(0.08)` inset to the content width — never edge-to-edge.
- Animate with `.easeInOut(duration: 0.2)` on the expand flag; content `.transition(.opacity)`.

### 9b. Selectable list row (secrets, accounts, members)
- The **whole row** is the hit target (`Button` or `.contentShape(Rectangle())`), padded
  `.horizontal 8 / .vertical 5`.
- Hover/selected highlight: `RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06))`.
- Trailing affordances (delete ✕, status dot) sit after a `Spacer()`; the ✕ is its own small button.

### 9c. Stat / key-value row
`HStack { Text(label).mono(...).textSecondary; Spacer(); Text(value).monoBold(...).textPrimary }`.
No dividers between stat rows — group them in a `VStack(spacing: 10)`.

---

## 10. Reskin checklist (apply to Settings, Usage, any panel)

- [ ] Card = `shellCard` + rounded-16 + accent hairline + shadow (via the overlay wrapper).
- [ ] No `Picker(.segmented)` / `Picker(.menu)` — use §3 `seg` / §8 menu.
- [ ] No `Divider()` between sections — spacing + §2 labels.
- [ ] No `bgPrimary`/black fills — `white.opacity(0.04–0.06)`.
- [ ] Every selectable element passes the **whole-hit-area** test (§0.1).
- [ ] Header is a left-aligned tracking label, not a centered logo/name.
- [ ] Toggles `.tint(accent)`; primary action is accent-filled; destructive is red.
- [ ] Fonts all `Port42Theme.mono/monoBold`; accent = `shell.accent`.
