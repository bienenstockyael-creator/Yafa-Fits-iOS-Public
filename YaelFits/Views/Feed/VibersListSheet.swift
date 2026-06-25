import SwiftUI

/// Sheet listing the users who vibed an outfit, or every user
/// who has ever vibed any of someone's outfits.
///
/// Two variants chosen by `source`:
///   - `.outfit(id)` — tap the fire-count badge on a feed card
///     to see who vibed that specific outfit (single sheet,
///     scoped to one outfit).
///   - `.user(id)`   — tap the "Vibes" stat on a profile to
///     see everyone who has ever vibed any of their outfits,
///     deduped, most-recent-vibe first.
///
/// Reuses `FollowListSheet`'s row layout (Instagram-style:
/// username primary, display name secondary, avatar lead) so
/// the visual language is consistent across all "list of
/// users" sheets in the app.
struct VibersListSheet: View {
    enum Source {
        case outfit(String)
        case user(UUID)
    }

    let source: Source

    @Environment(OutfitStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var profiles: [Profile] = []
    @State private var isLoading = true
    @State private var selectedUserId: IdentifiableUUID?

    private var title: String {
        switch source {
        case .outfit: return "Vibes"
        case .user:   return "Vibed by"
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if profiles.isEmpty {
                    VStack(spacing: LayoutMetrics.small) {
                        Text("No vibes yet")
                            .font(.system(size: 13))
                            .foregroundStyle(AppPalette.textMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(profiles) { profile in
                                row(for: profile)
                            }
                        }
                        .padding(.horizontal, LayoutMetrics.screenPadding)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .background(AppPalette.groupedBackground)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .font(.system(size: 13))
                        .foregroundStyle(AppPalette.textMuted)
                }
            }
            .task { await load() }
            .fullScreenCover(item: $selectedUserId) { wrapper in
                UserProfileView(userId: wrapper.id, onDismiss: { selectedUserId = nil })
                    .environment(store)
            }
        }
    }

    private func row(for profile: Profile) -> some View {
        Button {
            selectedUserId = IdentifiableUUID(id: profile.id)
        } label: {
            HStack(spacing: LayoutMetrics.small) {
                AvatarView(
                    url: profile.avatarUrl,
                    initial: profile.initial,
                    size: 40,
                    shadowRadius: 2,
                    shadowY: 1
                )
                VStack(alignment: .leading, spacing: 2) {
                    if let username = profile.username, !username.isEmpty {
                        Text(username)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppPalette.textPrimary)
                        if let dn = profile.displayName, !dn.isEmpty {
                            Text(dn)
                                .font(.system(size: 11))
                                .foregroundStyle(AppPalette.textFaint)
                        }
                    } else {
                        Text(profile.displayLabel)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppPalette.textPrimary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, LayoutMetrics.xSmall)
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    private func load() async {
        let loaded: [Profile]
        switch source {
        case .outfit(let id):
            loaded = (try? await VibesService.vibers(outfitId: id)) ?? []
        case .user(let userId):
            loaded = (try? await VibesService.vibersForUser(receiverId: userId)) ?? []
        }
        await MainActor.run {
            profiles = loaded
            isLoading = false
        }
    }
}

/// Local Identifiable wrapper so `.fullScreenCover(item:)` can
/// present off a UUID without needing UUID itself to conform
/// (which would conflict with other usages in the app).
private struct IdentifiableUUID: Identifiable {
    let id: UUID
}

// MARK: - Vibes leaderboard

/// Full-height sheet ranking users by vibes RECEIVED — two swipeable pages
/// (This week / All time) kept in sync with a segmented header. Opened from the
/// Vibes stat on a profile.
struct VibesLeaderboardSheet: View {
    @Environment(OutfitStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var window: VibeWindow = .thisWeek
    @Namespace private var tabUnderline
    @State private var weekEntries: [VibeRankEntry] = []
    @State private var allTimeEntries: [VibeRankEntry] = []
    @State private var weekLoading = true
    @State private var allTimeLoading = true
    @State private var selectedUserId: IdentifiableUUID?

    var body: some View {
        VStack(spacing: 0) {
            // Custom header (no nav bar): centered title + the app-standard
            // circular X on the left. A nav-bar toolbar item draws its OWN
            // circular glass background on iOS 26, which doubled up with our
            // `.appCircle()`; a plain header keeps a single circle like every
            // other X in the app.
            ZStack {
                Text("Best Dressed")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppPalette.textStrong)
                HStack {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        dismiss()
                    } label: {
                        AppIcon(glyph: .xmark, size: 12, color: AppPalette.iconPrimary)
                            .frame(width: 36, height: 36)
                            .appCircle()
                    }
                    .buttonStyle(SolidPressButtonStyle())
                    Spacer()
                }
            }
            .padding(.horizontal, LayoutMetrics.screenPadding)
            .padding(.top, LayoutMetrics.medium)
            .padding(.bottom, LayoutMetrics.xSmall)

            // Centered small all-caps tab labels, underline on the selected.
            HStack(spacing: LayoutMetrics.small) {
                tab("THIS WEEK", value: .thisWeek)
                tab("ALL TIME", value: .allTime)
            }
            .frame(maxWidth: .infinity)
            // Drives the underline slide for BOTH a tap and a page swipe.
            .animation(.spring(response: 0.34, dampingFraction: 0.82), value: window)
            .padding(.top, LayoutMetrics.small)
            .padding(.bottom, LayoutMetrics.small)

            // Two swipeable pages, in sync with the tabs above. The top
            // fade is a SIBLING layer on top of the pages (not inside the
            // ScrollView, where the TabView's clipping swallowed it) so it's
            // reliably anchored just under the tabs and dissolves rows as
            // they scroll up. No bottom fade — the list just clips at the
            // device edge.
            ZStack(alignment: .top) {
                TabView(selection: $window) {
                    page(entries: weekEntries, loading: weekLoading)
                        .tag(VibeWindow.thisWeek)
                    page(entries: allTimeEntries, loading: allTimeLoading)
                        .tag(VibeWindow.allTime)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                LinearGradient(
                    colors: [AppPalette.groupedBackground, AppPalette.groupedBackground.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 92)
                .allowsHitTesting(false)
            }
            // Bleed the paging area through the bottom safe area so the list
            // runs to — and clips at — the physical bottom of the device,
            // with no background strip above the home indicator.
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .background(AppPalette.groupedBackground.ignoresSafeArea())
        .task { await loadAll() }
        .fullScreenCover(item: $selectedUserId) { wrapper in
            UserProfileView(userId: wrapper.id, onDismiss: { selectedUserId = nil })
                .environment(store)
        }
    }

    private func tab(_ title: String, value: VibeWindow) -> some View {
        Button {
            window = value
        } label: {
            // The underline lives in a bottom overlay so it spans EXACTLY the
            // label's width, and slides + resizes between the two tabs via
            // matched geometry when the window changes.
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(window == value ? AppPalette.textStrong : AppPalette.textFaint)
                .padding(.bottom, 7)
                .overlay(alignment: .bottom) {
                    if window == value {
                        Capsule()
                            .fill(AppPalette.textStrong)
                            .frame(height: 2)
                            .matchedGeometryEffect(id: "tab-underline", in: tabUnderline)
                    }
                }
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    @ViewBuilder
    private func page(entries: [VibeRankEntry], loading: Bool) -> some View {
        if loading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
        } else if entries.isEmpty {
            VStack(spacing: LayoutMetrics.xSmall) {
                GradientFlameIcon(size: 40, stroked: true)
                Text("No vibes yet")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppPalette.textMuted)
                Text("Once people start vibing fits, the ranking shows up here.")
                    .font(.system(size: 12))
                    .foregroundStyle(AppPalette.textFaint)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, LayoutMetrics.xLarge)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        } else {
            ScrollView {
                LazyVStack(spacing: LayoutMetrics.small) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        row(rank: index + 1, entry: entry)
                    }
                }
                // Top padding clears the top fade so the first row reads crisply
                // at rest; small bottom inset so the list clips right at the
                // device edge (no fade, no gap).
                .padding(.horizontal, 40)
                .padding(.top, 94)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            // The TabView(.page) host (a UIPageViewController) insets its pages
            // to the safe area, which clips this ScrollView at the home-indicator
            // line. Make the scroll frame itself bleed to the physical bottom so
            // rows clip at the true device edge — no background strip below.
            .ignoresSafeArea(.container, edges: .bottom)
        }
    }

    private func row(rank: Int, entry: VibeRankEntry) -> some View {
        Button {
            selectedUserId = IdentifiableUUID(id: entry.profile.id)
        } label: {
            // Center the whole group and keep the rank+bust and the vibes pill
            // close together, instead of pushing them to opposite edges.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(spacing: -12) {
                    // The big Adieu rank number, with the bust laid on top of it
                    // (negative spacing = overlap; zIndex keeps the bust above).
                    HStack(spacing: -80) {
                        Text("\(rank)")
                            .font(.custom("GTFAdieuTRIAL-BlackSlanted", size: 92))
                            .foregroundStyle(AppPalette.textStrong)
                        VibesLeaderboardBust(profile: entry.profile, avatarSize: 130)
                            .zIndex(1)
                    }
                    // Vibe count in a frosted-glass pill, matching the app's pills.
                    HStack(spacing: 5) {
                        GradientFlameIcon(size: 20, stroked: false)
                        Text("\(entry.count)")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppPalette.textStrong)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .appCapsule(shadowRadius: 0, shadowY: 0)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(SolidPressButtonStyle())
        // Elegant staggered entrance — each row eases up + fades in, cascading
        // by rank, so the list assembles rather than snapping in.
        .modifier(StaggeredAppear(index: rank - 1))
    }

    private func loadAll() async {
        async let week = VibesService.leaderboard(window: .thisWeek)
        async let all = VibesService.leaderboard(window: .allTime)
        let loaded = await (week, all)
        await MainActor.run {
            // Crossfade the spinner out and the ranking in, rather than a snap.
            withAnimation(.easeInOut(duration: 0.35)) {
                weekEntries = loaded.0; weekLoading = false
                allTimeEntries = loaded.1; allTimeLoading = false
            }
        }
    }
}

/// Eases a view up and fades it in on first appearance, with a per-index delay
/// so a list cascades in. Delay is capped so rows that appear later via lazy
/// scrolling don't wait an awkwardly long time.
private struct StaggeredAppear: ViewModifier {
    let index: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)
            .onAppear {
                let delay = min(Double(index) * 0.06, 0.4)
                withAnimation(.easeOut(duration: 0.45).delay(delay)) {
                    shown = true
                }
            }
    }
}

/// Bust rendered to match the profile-header bust EXACTLY, just scaled to
/// `avatarSize` — same proportions and the same -7° rotated highlighter handle
/// (ratios mirror ProfileHeaderMetrics' live bust at avatarSize 132). Uses the
/// bg-removed cut-out when the person has one; otherwise frames their photo.
private struct VibesLeaderboardBust: View {
    let profile: Profile
    var avatarSize: CGFloat = 86

    /// A cut-out we generated on-the-fly for someone who didn't have one. Once
    /// set, it renders exactly like a native cut-out. (The server also persists
    /// it to their profile, so next time it arrives in `avatarCutoutUrl`.)
    @State private var generatedCutoutUrl: String?
    private var cutoutURL: String? { profile.avatarCutoutUrl ?? generatedCutoutUrl }

    private var s: CGFloat { avatarSize / 132 }            // liveAvatarSize
    private var frameWidth: CGFloat { 180 * s }            // liveBustFrameWidth
    private var extraHeight: CGFloat { 32 * s }            // liveBustExtraHeight
    private var highlighterFont: CGFloat { 18 * s }        // liveHighlighterFontSize
    private var highlighterOffset: CGFloat { avatarSize * 0.38 } // bustHighlighterOffsetRatio

    var body: some View {
        let accent = ProfileHeaderAccentColor.color(for: profile.headerAccentColor)
        let handle = profile.username.map { "@\($0)" } ?? profile.handle
        ZStack {
            bustImage
            HighlighterUsername(
                text: handle,
                color: accent,
                fontSize: highlighterFont,
                horizontalPadding: 3,
                rotation: -7,
                cornerRadius: 4
            )
            .offset(y: highlighterOffset)
            .allowsHitTesting(false)
        }
        .frame(width: frameWidth, height: avatarSize + extraHeight)
        .task {
            // No cut-out yet → generate + cache one server-side (idempotent;
            // only fires for rows that actually appear, via the LazyVStack).
            guard profile.avatarCutoutUrl == nil, generatedCutoutUrl == nil else { return }
            let url = await VibesService.ensureBustCutout(userId: profile.id)
            if let url { withAnimation(.easeOut(duration: 0.25)) { generatedCutoutUrl = url } }
        }
    }

    @ViewBuilder
    private var bustImage: some View {
        if let cutout = cutoutURL, let url = URL(string: cutout) {
            // True transparent bust — fit so hair / shoulders aren't clipped.
            // Transaction animation fades the cut-out in once it decodes.
            AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.35))) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fit)
                        .transition(.opacity)
                case .failure:
                    // Couldn't load the cut-out → fall back to the framed photo.
                    framedPhoto
                default:
                    // Still downloading → stay blank so we NEVER flash the photo
                    // with its background before the transparent cut-out arrives.
                    Color.clear
                }
            }
            .frame(width: frameWidth, height: avatarSize)
        } else if profile.avatarUrl != nil {
            framedPhoto
        } else {
            // Never set a photo → their gradient + initial, but shaped as a
            // bust silhouette instead of a flat square, so it sits in the row
            // like everyone else's bust.
            silhouetteBust
        }
    }

    /// Placeholder bust for users with no photo: a classical bust assigned by
    /// `PlaceholderBust` — best-guess gender from their name, then a stable
    /// per-user pick from that pool — in its original marble colors, so it sits
    /// in the row like everyone else's real cut-out.
    @ViewBuilder
    private var silhouetteBust: some View {
        if let bust = PlaceholderBust.image(for: profile) {
            Image(uiImage: bust)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: frameWidth, height: avatarSize)
        } else {
            // No bust assets at all → plain gradient block rather than nothing.
            AvatarGradients.gradient(for: profile.initial)
                .frame(width: avatarSize * 0.84, height: avatarSize)
                .clipShape(RoundedRectangle(cornerRadius: avatarSize * 0.18, style: .continuous))
        }
    }

    // No cut-out → frame the regular photo into a portrait bust crop.
    private var framedPhoto: some View {
        Group {
            if let avatar = profile.avatarUrl, let url = URL(string: avatar) {
                AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.35))) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                            .transition(.opacity)
                    } else {
                        initialFill
                    }
                }
            } else {
                initialFill
            }
        }
        .frame(width: avatarSize * 0.84, height: avatarSize)
        .clipShape(RoundedRectangle(cornerRadius: avatarSize * 0.18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: avatarSize * 0.18, style: .continuous)
                .strokeBorder(AppPalette.cardBorder, lineWidth: 0.75)
        )
    }

    private var initialFill: some View {
        ZStack {
            AppPalette.cardBorder.opacity(0.35)
            Text(profile.initial)
                .font(.system(size: avatarSize * 0.32, weight: .semibold))
                .foregroundStyle(AppPalette.textMuted)
        }
    }
}

// MARK: - No-photo bust placeholder pool

/// Assigns a classical-sculpture bust to a user who has no photo.
///
/// Pools are auto-discovered from the bundle by filename prefix — drop
/// `bust-m-<n>.webp` (men) and `bust-f-<n>.webp` (women) into Resources and
/// they're picked up automatically, no code change. Gender is a best-guess from
/// the user's name (display name, then username) via a common-first-name list;
/// unknown names fall back to a stable pseudo-random gender. Within the chosen
/// pool the bust is selected deterministically from the user's id, so the same
/// user always gets the same bust across sessions and devices.
enum PlaceholderBust {
    enum Gender { case male, female, unknown }

    static func image(for profile: Profile) -> UIImage? {
        let chosen = pool(for: guessGender(profile))
        guard !chosen.isEmpty else { return nil }
        return chosen[stableIndex(seed: profile.id.uuidString, count: chosen.count)]
    }

    // Pools, decoded once. `bust-m-*` = men, `bust-f-*` = women.
    private static let male: [UIImage] = loadPool(prefix: "bust-m-")
    private static let female: [UIImage] = loadPool(prefix: "bust-f-")
    private static var combined: [UIImage] { male + female }

    private static func pool(for gender: Gender) -> [UIImage] {
        switch gender {
        case .male:    return male.isEmpty ? female : male
        case .female:  return female.isEmpty ? male : female
        case .unknown: return combined
        }
    }

    private static func loadPool(prefix: String) -> [UIImage] {
        let urls = Bundle.main.urls(forResourcesWithExtension: "webp", subdirectory: nil) ?? []
        return urls
            .filter { $0.deletingPathExtension().lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { UIImage(data: $0) }
    }

    // MARK: Gender guess

    /// Explicit per-handle overrides for usernames that aren't real names and
    /// would otherwise fall to the coin-flip (or guess wrong). Keyed by the
    /// lowercased username.
    private static let handleOverrides: [String: Gender] = [
        "jaytel": .male,
        "cobo": .male,
    ]

    private static func guessGender(_ profile: Profile) -> Gender {
        // 1. Hand-set overrides for specific handles.
        if let handle = profile.username?.lowercased(), let g = handleOverrides[handle] {
            return g
        }
        // 2. Best-guess from a real first name (display name, then username).
        for raw in [profile.displayName, profile.username].compactMap({ $0 }) {
            if let g = gender(forName: raw) { return g }
        }
        // 3. No match → stable coin-flip: consistent per user, roughly balanced.
        return (fnv1a(profile.id.uuidString) & 1 == 0) ? .male : .female
    }

    /// Looks up the leading alphabetic token of a name in the lists.
    private static func gender(forName raw: String) -> Gender? {
        let token = raw.lowercased().split { !$0.isLetter }.first.map(String.init) ?? ""
        guard token.count >= 2 else { return nil }
        if maleNames.contains(token) { return .male }
        if femaleNames.contains(token) { return .female }
        return nil
    }

    // MARK: Stable hashing (FNV-1a — survives relaunches, unlike hashValue)

    private static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return h
    }
    private static func stableIndex(seed: String, count: Int) -> Int {
        count <= 0 ? 0 : Int(fnv1a(seed) % UInt64(count))
    }

    // MARK: Name lists (lowercased first names; ambiguous unisex names omitted
    // so they fall through to the stable coin-flip rather than guess wrong).

    static let maleNames: Set<String> = [
        "aaron","adam","adrian","ahmed","alan","albert","alejandro","alessandro","alexander",
        "andreas","andrew","andy","anthony","antoine","antonio","arda","arjun","arnaud","arthur",
        "arvid","asher","august","axel","aziz","bart","ben","benjamin","bernard","bilal","bjorn",
        "blake","boris","brad","bradley","brandon","brendan","brett","brian","bruce","bruno","bryan",
        "caleb","calvin","cameron","carl","carlos","cedric","cesar","chad","charles","chris",
        "christian","christopher","claude","clement","cody","colin","connor","conor","craig","curtis",
        "dale","damian","daniel","danny","dante","darren","dave","david","dean","declan","dennis",
        "derek","diego","dimitri","dinesh","dmitri","dominic","donald","douglas","dries","dylan",
        "eduardo","edward","edwin","elias","elliot","emil","emir","emmanuel","enzo","eric","erik",
        "ernesto","esteban","ethan","eugene","evan","ezra","fabian","fabio","felix","ferdinand",
        "fernando","filip","finn","florian","francesco","francis","francisco","frank","franklin",
        "fred","frederick","gabriel","gael","gareth","gary","gavin","geoffrey","george","gerald",
        "gerard","giovanni","glenn","gordon","graham","grant","greg","gregory","guillaume","gustav",
        "hans","harald","harold","harry","harvey","hassan","hayden","hector","henrik","henry",
        "herbert","hugo","hunter","ian","ibrahim","igor","ilya","imran","isaac","ismael","ivan",
        "jack","jackson","jacob","jake","james","jan","jared","jason","javier","jay","jeff","jeffrey",
        "jens","jeremy","jerome","jerry","jesse","jim","jimmy","joachim","joaquin","joel","johan",
        "john","johnny","jon","jonas","jonathan","joonas","jorge","jose","joseph","josh","joshua",
        "juan","jude","julian","julien","justin","kai","kamil","karan","karl","kasper","keith",
        "kenneth","kevin","khalid","kieran","kjell","klaus","kris","kristian","kurt","kyle","lars",
        "laurent","lawrence","leo","leon","leonard","leonardo","levi","lewis","liam","lionel","logan",
        "lorenzo","louis","luca","lucas","luigi","luis","luka","lukas","luke","mads","magnus","malik",
        "manuel","marc","marcel","marco","marcos","marcus","mario","mark","markus","marlon","martin",
        "marvin","mason","mateo","mathias","mathieu","matt","matteo","matthew","matthias","mattias",
        "maurice","mauricio","max","maxim","maximilian","mehmet","melvin","micah","michael","miguel",
        "mikael","mike","mikko","milan","miles","milo","mitchell","mohamed","mohammed","moritz",
        "murat","mustafa","nate","nathan","nathaniel","neil","nelson","nicholas","nick","nico",
        "nicolas","niels","nigel","nikhil","niklas","nikola","nikolai","noah","noel","norman",
        "oliver","olivier","omar","oscar","otto","owen","pablo","paolo","pascal","patrick","paul",
        "pedro","peter","philip","philippe","pierre","piotr","pranav","preston","quentin","rafael",
        "rahul","ralph","ramon","randy","raphael","rasmus","raymond","reece","remy","rene","ricardo",
        "richard","rick","rishi","robert","roberto","rodrigo","roger","roland","roman","ronald",
        "ronan","rory","ross","roy","ruben","russell","ryan","salman","samir","samuel","sander",
        "santiago","scott","sean","sebastian","sergei","sergio","seth","shane","shaun","shawn",
        "simon","soren","spencer","stanley","stefan","stephen","steve","steven","stuart","sven",
        "ted","terence","terry","theo","theodore","thomas","tim","timo","timothy","tobias","toby",
        "todd","tom","tomas","tomasz","tommy","tony","travis","trevor","tristan","tyler","umar",
        "valentin","victor","vihaan","vincent","vladimir","wade","walter","warren","wayne","wesley",
        "william","wilson","wolfgang","xander","xavier","yann","yannick","yusuf","zachary","zane",
    ]

    static let femaleNames: Set<String> = [
        "abigail","ada","adele","adriana","agnes","aida","aimee","aisha","alana","alba","alexandra",
        "alice","alicia","alina","alison","allison","alma","amanda","amber","amelia","amelie","amy",
        "ana","anais","anastasia","angela","angelica","angelina","anika","anita","anja","ann","anna",
        "annabel","anne","annette","annie","anouk","antonia","april","ariana","ashley","asia","astrid",
        "aurora","ava","ayse","beatrice","beatriz","becky","belen","bella","bernadette","beth","bethany",
        "bianca","birgit","bonnie","brenda","bridget","brittany","brooke","camila","camille","candice",
        "cara","carla","carmen","carol","carolina","caroline","carrie","catalina","catherine","cecilia",
        "celeste","celia","celine","charlotte","chelsea","cheryl","chiara","chloe","christina","christine",
        "cindy","claire","clara","claudia","colette","connie","cora","courtney","cristina","crystal",
        "daisy","daniela","daphne","darlene","dawn","debbie","deborah","delia","delphine","denise",
        "diana","diane","dilara","dina","dolores","donna","dora","dorothy","ebru","edith","eileen",
        "ela","elaine","eleanor","elena","eliana","elif","elin","elisa","elisabeth","eliza","elizabeth",
        "ella","ellen","ellie","eloise","elsa","elvira","emilia","emily","emma","emmanuelle","erica",
        "erika","erin","esther","eva","evelyn","fabienne","faith","fatima","fatma","felicia","fernanda",
        "fiona","flora","florence","frances","francesca","freya","gabriela","gabrielle","gail","gemma",
        "genevieve","georgia","gina","giulia","gloria","grace","greta","gwen","hailey","hana","hanna",
        "hannah","harriet","hayley","hazel","heather","heidi","helen","helena","henrietta","hilda",
        "holly","hope","ida","ines","ingrid","irene","iris","isabel","isabella","isabelle","ivana",
        "jacqueline","jade","jana","jane","janet","janice","jasmine","jeanne","jenna","jennifer","jenny",
        "jessica","jill","joan","joanna","joanne","jocelyn","johanna","josephine","joy","judith","judy",
        "julia","juliana","julie","juliet","juliette","june","kaitlyn","kara","karen","karin","karina",
        "kate","katherine","kathleen","kathryn","kathy","katie","katrina","katy","kayla","kelly","kelsey",
        "kendra","kerstin","kimberly","kira","klara","kristen","kristin","kristina","lana","lara","laura",
        "lauren","laurie","lea","leah","lena","leona","leonie","lila","lili","lilian","lillian","lily",
        "linda","lindsey","lisa","liv","livia","lola","lorena","lorraine","lottie","louise","luana",
        "lucia","lucie","lucy","luisa","luna","lydia","lynn","mabel","madeleine","madison","mae","maeve",
        "magda","magdalena","maggie","maite","malin","manon","mara","margaret","margarita","margaux",
        "margot","maria","mariam","mariana","marie","marielle","marina","marion","marisa","marissa",
        "marlene","marta","martha","martina","mary","maryam","mathilde","maud","maureen","maya","megan",
        "meghan","mei","melanie","melike","melinda","melisa","melissa","mercedes","meredith","mia",
        "michaela","michele","michelle","mila","mildred","milena","mina","mira","miranda","miriam","molly",
        "mona","monica","monika","muriel","nadia","nadine","nancy","naomi","natalia","natalie","natasha",
        "nazli","nell","nessa","nia","nicole","nika","nina","noemi","nora","norah","nour","nova","nuria",
        "odette","olga","olive","olivia","ophelia","paige","pamela","paola","patricia","paula","pauline",
        "pearl","peggy","penelope","petra","phoebe","pia","polly","priya","rachel","ramona","raquel",
        "rebecca","regina","renata","renee","rhea","rita","roberta","rochelle","romy","rosa","rosalie",
        "rose","rosemary","roxana","ruby","ruth","sabine","sabrina","sadie","salma","samantha","sandra",
        "sandy","sara","sarah","saskia","savannah","scarlett","selin","selina","selma","serena","sevda",
        "shannon","sharon","sheila","shelby","shirley","sibel","silvia","sina","sofia","sofie","sonia",
        "sonja","sophia","sophie","stacey","stella","stephanie","summer","susan","susanna","suzanne",
        "sylvia","tamara","tania","tanya","tara","tatiana","teresa","tessa","thea","theresa","tina",
        "tracy","ulla","ursula","valentina","valerie","vanessa","vera","veronica","vicky","victoria",
        "viktoria","violet","virginia","vivian","viviana","wanda","wendy","whitney","willow","wilma",
        "xenia","yara","yasmin","yelena","yvette","yvonne","zara","zoe","zoey","zuzanna",
    ]
}

