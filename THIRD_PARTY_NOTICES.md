# swift-grok

- Source: https://github.com/0xSMW/swift-grok
- Revision: `09ee2adf062b709d812a9fe68426cc89d1519eaa`
- Retrieved: 2026-11-06
- Copyright (c) 2025 Klu, Inc.
- License: MIT, full text in [Vendor/swift-grok/LICENSE](Vendor/swift-grok/LICENSE).

Only `Sources/GrokClient` is vendored. The CLI, proxy, their dependencies, credentials, and cookie extraction scripts are not included.

Local modifications:

1. `GrokClientCore.swift`: optional `userAgent` initializer parameter; when supplied, use that browser's User-Agent and remove conflicting Chrome client-hint headers. Existing callers remain source-compatible.
2. `Endpoints/GrokClient+Conversations.swift`: add `listConversationPage(pageSize:pageToken:searchQuery:)` to preserve `nextPageToken`, and `assetMetadata(id:)` to resolve legacy attachment IDs. The upstream `listConversations` method remains unchanged.
3. `GrokHTTPValidation.swift`: recognize Cloudflare HTML challenge markers in HTTP 403 responses as browser verification errors, so the UI offers session renewal instead of a misleading model-access error.
4. `Models/ConversationModels.swift`: accept absent or null message text and creation time; retain source cards, images, attachment metadata, reasoning steps, thinking timestamps and stream errors for native rendering.
5. `Endpoints/GrokClient+Account.swift`: read the authenticated display name and profile image path from `/rest/auth/get-user`.
6. `Endpoints/GrokClient+Conversations.swift`: add partial `PUT` updates for conversation titles and starred status, using the same request format as the public Grok web client.
7. `Endpoints/GrokClient+Conversations.swift`: publish the selected response path, retain existing team access, and obtain the public URL from sharing metadata rather than the internal share-link ID. Use an English fallback error that the app can localize into Russian.
8. `Endpoints/GrokClient+Chat.swift`: disable Grok memory when the request is temporary. `Streaming/GrokStreamParser.swift` and `Models/ConversationModels.swift`: retain final response metadata so temporary chats can show sources and attachments without reloading saved history.
9. `Endpoints/GrokClient+Workspaces.swift`: add a name-only PUT for project renaming, preserving other project fields. Native project actions also use the existing workspace deletion and conversation-assignment endpoints.
10. `Endpoints/GrokClient+Conversations.swift`: optional `workspaceId` filter for paginated project chat lists, matching the public Grok frontend request schema.
11. `Endpoints/GrokClient+Workspaces.swift`: remove a conversation's project membership with DELETE `/workspaces/{workspaceId}/conversations/{conversationId}`. New project conversations use the library's existing `workspaceIds` message option.
12. `Endpoints/GrokClient+Conversations.swift`: optional `excludeProjects` query flag; general history uses it to exclude project conversations, while workspace-filtered lists keep them visible.
13. Mode discovery retains `iconHint` and `badgeText`, recognizes `availability.comingSoon`, and accepts an optional locale in `/rest/modes` requests. The native client preserves disabled modes and renders their metadata in a SwiftUI popover with SF Symbols.

The native app and its core adapter use the library's request builder, endpoint models, HTTP error validation, NDJSON/SSE parser, and cancellable streaming transport. The vendored library retains upstream's Swift 5 language mode; it is compiled by a Swift 6 toolchain.

# Grok brand assets

`Configuration/Assets.xcassets/AppIcon.appiconset` and `Sources/SwiftyGrok/Resources/BrandAssets.xcassets/GrokLogo.imageset` use artwork extracted from the user-supplied Grok iOS 1.4.61 IPA. The app icon is the 1024-pixel `AppIcon` rendition; the empty-chat logo is the `GrokLogo` image in the main asset catalog. The catalog contains PNG representations adapted to the macOS canvas with transparent corners and margins. Xcode generates the packaged ICNS from these sources. This artwork belongs to xAI and is not covered by this repository's MIT license. SwiftyGrok remains an unofficial client.

`Sources/SwiftyGrok/Resources/AppIconLight.icns` is the light-appearance icon supplied separately by the user as `Grok(light).icns`. It is used for the Dock, minimized-window badges, and the About panel when the selected appearance is light. The existing generated `AppIcon.icns` is used for dark and black appearances. Both variants depict Grok brand artwork owned by xAI.

Workspace listing additionally preserves and submits page tokens so the native project list can load all pages. Project icon IDs and their `l:<icon>:<color>` encoding were checked against the public Grok frontend; the app uses native SF Symbols to display them.

# SwiftMath

- Source: https://github.com/mgriebling/SwiftMath
- Version: 1.7.3, retrieved 2026-11-06.
- Archive SHA-256: `31d0834df4a4c1031171c00bae190ea0c87499e1240d9d630b4ba02095f352ed`.
- Copyright (c) 2023 Computer Inspirations; MIT license in `Vendor/SwiftMath/LICENSE`.

The Swift sources and `mathFonts.bundle` are vendored as a local macOS-only package dependency. The upstream test target is omitted from its manifest. SwiftyGrok adds support for the AMS `dfrac` and `tfrac` commands in `MTMathListBuilder.swift`, preserving their scoped display/text styles. Font licenses (including GUST and SIL OFL) are retained inside `mathFonts.bundle`. Formulas render locally without a web view, script execution or network requests.

# Devicon

- Source: https://github.com/devicons/devicon
- Revision: `32fe1d3b3f36ad11f90ab94f7db59738139c2bf6`
- Retrieved: 2026-11-07.
- Copyright (c) 2015 konpa.
- License: MIT, full text in [Sources/SwiftyGrok/Resources/Devicon-LICENSE.txt](Sources/SwiftyGrok/Resources/Devicon-LICENSE.txt), also included in the app bundle.

`Sources/SwiftyGrok/Resources/CodeLanguageIcons.xcassets` contains 34 unmodified SVG icons selected from Devicon's `icons/` directory. Each filename retains the upstream icon name and variant. SwiftyGrok renders them as monochrome template images in code-block headers; the icons are bundled locally and require no network requests. The logos identify their respective languages and tools, belong to their respective owners, and do not imply endorsement.
