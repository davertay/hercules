import Foundation
import SwiftUI
import UISupport

// The disclosure for the one thing an untrusting Workflow silently stops doing: running the repository's
// own Claude Code hooks. Both halves live here — the condition that decides whether anything is actually
// being suppressed, and the notice that says so.

/// Whether either of the Worktree's `.claude` settings files declares `hooks` — shell commands that would
/// run inside this Workflow's Harnesses if it trusted the repository's settings.
///
/// Both files are asked because the trust toggle governs both: it moves `--setting-sources` between `user`
/// and `user,project,local`, and `local` is `settings.local.json` — the uncommitted file Claude Code writes
/// for machine-local settings, and so a very ordinary place for a developer's own hooks to live.
///
/// Every failure answers `false` for that file: no file, an unreadable one, malformed JSON, or a root that
/// isn't an object. This is asked only to decide whether to show a notice, so a file we can't parse is not
/// worth warning about — and warning on the hypothetical rather than the actual is how a notice stops being
/// read. Never throws, so it can't get in the way of opening a Workflow.
func repositorySettingsDeclareHooks(worktree: URL) -> Bool {
    let claude = worktree.appending(path: ".claude")
    return ["settings.json", "settings.local.json"].contains { file in
        settingsFileDeclaresHooks(claude.appending(path: file))
    }
}

private func settingsFileDeclaresHooks(_ settings: URL) -> Bool {
    guard
        let data = try? Data(contentsOf: settings),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return false }
    return object["hooks"] != nil
}

/// A notice above the Phase content when the repository declares hooks this Workflow isn't loading. A
/// `PhaseBanner`, like the Execute Phase's own banners, and neither red nor dismissible-looking: nothing
/// has failed, the user just can't otherwise tell that something they wrote into the repo is being
/// ignored. Its detail is left untruncated — a fixed two-line sentence that has to be read in full — and
/// the button goes to the toggle that changes it.
struct RepositoryHooksBanner: View {
    let onOpenSettings: () -> Void

    var body: some View {
        PhaseBanner(
            systemImage: "bolt.slash.fill",
            tint: .orange,
            headline: "This repository's Claude Code hooks aren't running",
            detail: """
                Its .claude settings declare hooks. Turn on “Trust this repository's Claude Code \
                settings” in Workflow Settings to let them run.
                """
        ) {
            Button("Workflow Settings…", action: onOpenSettings)
        }
    }
}

#if DEBUG
#Preview("Repository hooks suppressed") {
    RepositoryHooksBanner(onOpenSettings: {})
        .frame(width: 640)
        .padding()
}
#endif
