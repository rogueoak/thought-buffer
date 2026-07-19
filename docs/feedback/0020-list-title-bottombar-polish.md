# Feedback 0020 - List title size, bottom-bar grouping, instant title render

Device feedback from Matthew (2026-07-19) on the list screens (root "Thoughts" and each folder), three
items. All touch the list-screen chrome (title + persistent bottom bar) and one SwiftUI runtime warning;
they were shipped together in one PR.

## 1. The list title is too big

- **Symptom.** The below-the-toolbar "Thoughts" header (root) and each folder's list title read one step
  too large - roughly an H2 where an H3 would sit more calmly under the toolbar.
- **Root cause.** The title used the SYSTEM large navigation title (`.navigationBarTitleDisplayMode(.large)`
  with no font override), which renders at the platform large-title size (~34pt bold), between the Canopy
  `sizeX3xl` (30) and `sizeX4xl` (36) steps. Nothing tied it to the Canopy scale, so it read a step big.
- **Fix.** A shared `View.streamListTitle(_:)` modifier bundles `.navigationTitle` +
  `.navigationBarTitleDisplayMode(.large)` (placement from spec 0021 unchanged) with a Canopy-sized
  large-title font, dropping the header ONE Canopy step to `sizeX3xl` (the H3-equivalent, 30pt bold). The
  size is applied via a scoped `UINavigationBarAppearance` (SwiftUI exposes no large-title font modifier),
  installed by a zero-size host on `viewWillAppear` so it does not leak into the inline Settings /
  Move-to-folder bars. All four folder-screen title sites (compact root + folder, split sidebar + content)
  now call `.streamListTitle(...)`, so the size lives in ONE place. The step choice is the pure, tested
  `StreamListTitle.fontSize`.

## 2. Bottom-bar buttons read as INSIDE the search field

- **Symptom.** On the persistent bottom bar the new-thought and mic/record icons looked like they were
  INSIDE the search field's container, not separate actions beside it.
- **Root cause.** `BottomBar.body` wrapped BOTH the search field and the `trailing` action buttons in ONE
  shared capsule (`.background(surface).clipShape(Capsule())`), so the field's rounded background visually
  enclosed the buttons.
- **Fix.** The surface + border + shadow pill moved OFF the outer HStack and ONTO the search field itself,
  so the field is its own bounded rounded field and the action buttons sit BESIDE it on the bare bar,
  visually OUTSIDE the field's background. Same actions, same accessibility labels; only the visual grouping
  changed. Because every screen (list, folder, detail) and the iPad lifted bottom stack share this one
  `BottomBar`, the change holds everywhere.

## 3. The list title renders with a visible delay

- **Symptom.** On navigation, the list title ("Thoughts" / folder name) appeared with a visible lag rather
  than immediately.
- **Root cause.** A SwiftUI runtime warning - "Modifying state during view update, this will cause undefined
  behavior" - was firing from `UndoManagerHost.makeUIViewController`, which is invoked DURING SwiftUI's
  view-update pass. It called `onManager(...)` synchronously, and that callback mutates the composition
  root's `@State undoManagerInjected` (and injects the deletion controller's manager) mid-update. Mutating
  observed state during the update pass makes SwiftUI re-run the pass, which deferred the navigation-bar
  title commit to a later frame - the lazy title render.
- **Fix.** `makeUIViewController` now hands the vended manager back on the NEXT main-actor tick
  (`DispatchQueue.main.async`) instead of synchronously, so no state is mutated during the update pass. The
  manager is only needed when a shake happens (long after first render), so deferring it costs nothing and
  removes the warning; the title renders on the first pass.
- **Learning.** A `UIViewControllerRepresentable`/`UIViewRepresentable`'s `make...`/`update...` runs DURING
  SwiftUI's view-update pass, so any callback it fires that mutates `@State`/`@Published` must be deferred
  (a runloop tick) - doing it synchronously triggers "Modifying state during view update" and can make
  unrelated UI (here, the nav title) lazy-render as SwiftUI re-runs the pass. When a title or other chrome
  renders a beat late, suspect a state mutation during update, not the title code itself.
