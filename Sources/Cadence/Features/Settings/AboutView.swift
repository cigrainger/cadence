// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                if let icon = NSImage(contentsOf: AppResources.url("Brand/app-icon.png")) {
                    Image(nsImage: icon).resizable().frame(width: 72, height: 72).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Cadence").font(.system(size: 28, weight: .medium, design: .serif))
                    Text("A place to make music.").foregroundStyle(.secondary)
                    Text(
                        "Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Free to use, study, change and share.").font(.headline)
            Text(
                "Cadence is free, copyleft software under the GNU AGPL, version 3 or later. Its documentation and original visual identity use CC BY-SA 4.0. Bundled libraries and instrument samples retain their own licenses."
            )
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Link("Read the guide", destination: URL(string: "https://cigrainger.github.io/cadence/docs/")!)
                Link("Source & contributions", destination: URL(string: "https://github.com/cigrainger/cadence")!)
            }
            HStack {
                Button("App license") { NSWorkspace.shared.open(AppResources.url("Cadence-LICENSE.txt")) }
                Button("Third-party notices") { NSWorkspace.shared.open(AppResources.url("Third-party notices.txt")) }
            }
            Text(
                "Your library and practice history stay on this Mac. AI is optional: requests you choose to send use your own OpenRouter account. Microphone audio is analysed locally."
            )
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(
                "© 2026 Cadence contributors. Provided without warranty. You may redistribute and modify Cadence under its license."
            )
            .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding(18)
    }
}
