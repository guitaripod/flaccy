import AppKit
import FlaccyCore

/// The hero and the Jump Back In panel, side by side in a wide page and one
/// over the other in a narrower one.
final class MacHomeTopRow: NSView {

    static let gap: CGFloat = 24

    private var hero: NSView?
    private var panel: MacHomeJumpBackInPanel?
    private var modeConstraints: [NSLayoutConstraint] = []
    private var isWide: Bool?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setHero(_ view: NSView) {
        hero = view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
    }

    func setPanel(_ view: MacHomeJumpBackInPanel) {
        panel = view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
    }

    func setWide(_ wide: Bool) {
        guard wide != isWide else { return }
        isWide = wide
        NSLayoutConstraint.deactivate(modeConstraints)
        modeConstraints = wide ? wideConstraints() : stackedConstraints()
        NSLayoutConstraint.activate(modeConstraints)
    }

    private func wideConstraints() -> [NSLayoutConstraint] {
        switch (hero, panel) {
        case let (hero?, panel?):
            return [
                hero.topAnchor.constraint(equalTo: topAnchor),
                hero.leadingAnchor.constraint(equalTo: leadingAnchor),
                hero.trailingAnchor.constraint(lessThanOrEqualTo: panel.leadingAnchor, constant: -Self.gap),
                hero.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
                panel.topAnchor.constraint(equalTo: topAnchor),
                panel.trailingAnchor.constraint(equalTo: trailingAnchor),
                panel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
                panel.widthAnchor.constraint(equalToConstant: MacHomeJumpBackInPanel.width),
                heightAnchor.constraint(greaterThanOrEqualTo: hero.heightAnchor),
                heightAnchor.constraint(greaterThanOrEqualTo: panel.heightAnchor),
            ]
        case let (hero?, nil):
            return [
                hero.topAnchor.constraint(equalTo: topAnchor),
                hero.leadingAnchor.constraint(equalTo: leadingAnchor),
                hero.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
                hero.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
        case let (nil, panel?):
            return panelAlone(panel)
        case (nil, nil):
            return [heightAnchor.constraint(equalToConstant: 0)]
        }
    }

    private func stackedConstraints() -> [NSLayoutConstraint] {
        switch (hero, panel) {
        case let (hero?, panel?):
            return [
                hero.topAnchor.constraint(equalTo: topAnchor),
                hero.leadingAnchor.constraint(equalTo: leadingAnchor),
                hero.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
                panel.topAnchor.constraint(equalTo: hero.bottomAnchor, constant: 28),
                panel.leadingAnchor.constraint(equalTo: leadingAnchor),
                panel.trailingAnchor.constraint(equalTo: trailingAnchor),
                panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
        case let (hero?, nil):
            return [
                hero.topAnchor.constraint(equalTo: topAnchor),
                hero.leadingAnchor.constraint(equalTo: leadingAnchor),
                hero.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
                hero.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
        case let (nil, panel?):
            return panelAlone(panel) + [panel.trailingAnchor.constraint(equalTo: trailingAnchor)]
        case (nil, nil):
            return [heightAnchor.constraint(equalToConstant: 0)]
        }
    }

    private func panelAlone(_ panel: NSView) -> [NSLayoutConstraint] {
        [
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            panel.widthAnchor.constraint(equalToConstant: MacHomeJumpBackInPanel.width),
        ]
    }
}

extension MacHomeViewController {

    func heroView(_ feed: HomeFeed) -> NSView {
        if feed.promo?.placement == .replacesHero, let card = promoView(feed) { return card }
        let hero = MacHomeHeroView()
        if let model = heroModel(feed) { hero.configure(model) }
        return hero
    }

    private func heroModel(_ feed: HomeFeed) -> MacHomeHeroModel? {
        switch feed.hero {
        case .resume: feed.resume.map(resumeModel)
        case .upNext: feed.upNext.map { upNextModel($0, isPlaying: feed.facts.isPlaying) }
        case .dayOne: feed.dayOne.map(dayOneModel)
        case .empty: nil
        }
    }

    private func resumeModel(_ resume: HomeFeed.Resume) -> MacHomeHeroModel {
        let context = resume.context
        let point = resume.point
        let track = resume.currentTrack
        let album = resume.album
        let queue = AudioPlayer.shared.queue
        let isAlbum = context.kind == .album && album != nil
        let title = context.title.isEmpty ? (album?.title ?? track.title) : context.title
        let artist = isAlbum ? (album?.artist ?? track.artist) : track.artist
        let recency = ResumeRecency.of(point.savedAt, now: Date(), calendar: .current)

        var model = MacHomeHeroModel(
            cover: coverSubject(for: context, album: album, queue: queue),
            kicker: HomeCopy.resumeKicker(recency),
            title: title,
            subtitle: artist,
            segments: point.segments(),
            trackLine: HomeCopy.trackLine(index: point.trackIndex + 1, title: track.title),
            remaining: HomeCopy.remaining(point.remainingSeconds)
        )
        model.onSubtitleClick = { LibraryNavigator.revealArtist(artist) }
        model.onCoverClick = { [weak self] in self?.goToContext(context, album: album) }
        if isAlbum, let album {
            model.badge = hiResBadge(for: album)
            model.metaText = [album.year, album.genre].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        } else {
            model.metaText = HomeCopy.songCount(point.trackCount)
        }
        if model.metaText?.isEmpty == true { model.metaText = nil }
        model.actions = resumeActions(context: context, album: album, queue: queue)
        return model
    }

    private func resumeActions(context: PlaybackContext, album: Album?, queue: [Track]) -> [MacHomeHeroModel.Action] {
        let isAlbum = context.kind == .album && album != nil
        let shuffleLabel = isAlbum ? HomeCopy.shuffleAlbum : HomeCopy.shuffle
        return [
            .init(kind: .primary(title: HomeCopy.resume, symbol: "play.fill"), run: {
                if !AudioPlayer.shared.isPlaying { AudioPlayer.shared.togglePlayPause() }
            }),
            .init(kind: .circle(symbol: "shuffle", label: shuffleLabel), run: {
                if isAlbum, let album {
                    MacHomeActions.play(album, shuffled: true)
                } else {
                    AudioPlayer.shared.play(queue.shuffled(), startingAt: 0, context: context)
                }
            }),
            .init(kind: .menu(symbol: "ellipsis", label: HomeCopy.more), menu: { [weak self] in
                self?.resumeMenu(context: context, album: album, queue: queue)
            }),
        ]
    }

    private func resumeMenu(context: PlaybackContext, album: Album?, queue: [Track]) -> NSMenu {
        let menu = NSMenu()
        switch context.kind {
        case .album where album != nil:
            menu.addItem(ClosureMenuItem(title: MacHomeCopy.goToAlbum, systemImage: "square.stack") { [weak self] in
                self?.goToContext(context, album: album)
            })
        case .playlist:
            menu.addItem(ClosureMenuItem(title: MacHomeCopy.goToPlaylist, systemImage: "music.note.list") { [weak self] in
                self?.goToContext(context, album: album)
            })
        default:
            break
        }
        menu.addItem(ClosureMenuItem(title: MacHomeCopy.playFromBeginning, systemImage: "backward.end.fill") {
            if context.kind == .album, let album {
                MacHomeActions.play(album, shuffled: false)
            } else {
                AudioPlayer.shared.play(queue, startingAt: 0, context: context)
            }
        })
        return menu
    }

    private func goToContext(_ context: PlaybackContext, album: Album?) {
        switch context.kind {
        case .album:
            if let album { LibraryNavigator.revealAlbum(title: album.title, artist: album.artist) }
        case .playlist:
            if let id = Int64(context.id) { LibraryNavigator.revealPlaylist(id: id) }
        default:
            break
        }
    }

    private func coverSubject(for context: PlaybackContext, album: Album?, queue: [Track]) -> MacHomeCoverView.Subject {
        if context.kind == .album, let album {
            return .init(albums: [album], seed: album.id, playlistID: nil)
        }
        let index = MacHomeCoverIndex(albums: Library.shared.albums)
        let albums = index.albums(for: queue)
        return .init(
            albums: albums.isEmpty ? (album.map { [$0] } ?? []) : albums,
            seed: context.key,
            playlistID: context.kind == .playlist ? Int64(context.id) : nil
        )
    }

    private func hiResBadge(for album: Album) -> String? {
        let isHiRes = album.tracks.contains { ($0.bitDepth ?? 0) > 16 || ($0.sampleRate ?? 0) > 48_000 }
        return isHiRes ? DetailChip.albumQualitySummary(tracks: album.tracks) : nil
    }

    private func upNextModel(_ upNext: HomeFeed.UpNext, isPlaying: Bool) -> MacHomeHeroModel {
        let mix = upNext.mix
        let seconds = mix.tracks.reduce(0) { $0 + $1.duration }
        var lines = [HomeCopy.mixMeta(count: mix.tracks.count, seconds: seconds)]
        var names: [String] = []
        for track in mix.tracks where names.count < 3 && !names.contains(track.artist) {
            names.append(track.artist)
        }
        if let starts = HomeCopy.startsWith(names) { lines.append(starts) }
        var model = MacHomeHeroModel(
            cover: .init(albums: upNext.albums, seed: mix.id, playlistID: nil),
            kicker: HomeCopy.upNextKicker(isPlaying: isPlaying),
            title: mix.title,
            subtitle: mix.subtitle,
            lines: lines
        )
        model.onCoverClick = { MacHomeActions.play(mix, shuffled: false) }
        let window = view.window
        model.actions = [
            .init(kind: .primary(title: HomeCopy.play, symbol: "play.fill"), run: { MacHomeActions.play(mix, shuffled: false) }),
            .init(kind: .secondary(title: MacHomeCopy.playNext, symbol: "text.line.first.and.arrowtriangle.forward"), run: {
                MacHomeActions.playNext(mix, in: window)
            }),
            .init(kind: .circle(symbol: "shuffle", label: HomeCopy.shuffle), run: { MacHomeActions.play(mix, shuffled: true) }),
        ]
        return model
    }

    private func dayOneModel(_ dayOne: HomeFeed.DayOne) -> MacHomeHeroModel {
        var lines = [HomeCopy.dayOneCounts(songs: dayOne.songs, albums: dayOne.albums)]
        if dayOne.hiRes > 0 { lines.append(HomeCopy.hiResCount(dayOne.hiRes)) }
        var model = MacHomeHeroModel(
            cover: .init(albums: dayOne.coverAlbums, seed: "day-one", playlistID: nil),
            kicker: HomeCopy.dayOneKicker,
            title: HomeCopy.dayOneTitle,
            lines: lines
        )
        model.actions = [
            .init(kind: .primary(title: HomeCopy.shuffleLibrary, symbol: "shuffle"), run: { MacHomeActions.shuffleLibrary() }),
            .init(kind: .secondary(title: HomeCopy.radio, symbol: "dot.radiowaves.left.and.right"), run: {
                AudioPlayer.shared.playLibraryRadio()
            }),
        ]
        return model
    }

    func jumpBackInPanel(_ feed: HomeFeed) -> MacHomeJumpBackInPanel {
        let panel = MacHomeJumpBackInPanel()
        let mixes = feed.mixes
        panel.configure(items: feed.jumpBackIn, actions: MacHomeJumpActions(
            open: { MacHomeActions.open($0, mixes: mixes) },
            play: { MacHomeActions.play($0, shuffled: $1, mixes: mixes) },
            remove: { RecentContextStore.shared.remove(key: $0.context.key) }
        ))
        return panel
    }

    func memoryCard(_ feed: HomeFeed) -> NSView? {
        guard let memory = feed.onThisDay else { return nil }
        let album = memory.album
        return MacHomeMemoryCard(
            memory: memory,
            onOpen: { LibraryNavigator.revealAlbum(title: album.title, artist: album.artist) },
            onPlay: { MacHomeActions.play(album, shuffled: false) }
        )
    }

    func weekCard(_ feed: HomeFeed) -> NSView? {
        guard let week = feed.week else { return nil }
        return MacHomeWeekCard(week: week, onOpenRecap: { MacHomeActions.openRecap() })
    }

    func madeForYou(_ feed: HomeFeed, index: MacHomeCoverIndex) -> NSView {
        let header = MacHomeSectionHeader(
            title: HomeCopy.title(for: .madeForYou), actionTitle: HomeCopy.seeAll
        ) { MacHomeActions.showSection(.playlists) }

        let window = view.window
        var cards: [NSView] = feed.mixes.prefix(5).map { mix in
            let card = MacHomeCard(
                side: 164, cornerRadius: 10,
                subject: .init(albums: index.albums(for: mix.tracks), seed: mix.id, playlistID: nil),
                title: mix.title, subtitle: mix.subtitle, hasMenu: true
            )
            card.onClick = { MacHomeActions.play(mix, shuffled: false) }
            card.menuProvider = { [weak self] in self?.mixMenu(mix, window: window) }
            return card
        }
        let radio = MacHomeCard(
            side: 164, cornerRadius: 10,
            subject: .init(albums: Array(Library.shared.albums.prefix(4)), seed: "library-radio", playlistID: nil),
            title: HomeCopy.libraryRadio, subtitle: HomeCopy.libraryRadioSubtitle,
            hasMenu: false, glyph: "dot.radiowaves.left.and.right"
        )
        radio.onClick = { AudioPlayer.shared.playLibraryRadio() }
        cards.append(radio)
        if feed.mixes.count < 2 {
            cards.append(MacHomePlaceholderCard(side: 164, text: HomeCopy.moreMixes))
        }
        return section(header: header, shelf: MacHomeShelf(cards: cards, spacing: 16))
    }

    private func mixMenu(_ mix: SuggestedPlaylist, window: NSWindow?) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: HomeCopy.play, systemImage: "play.fill") { MacHomeActions.play(mix, shuffled: false) })
        menu.addItem(ClosureMenuItem(title: HomeCopy.shuffle, systemImage: "shuffle") { MacHomeActions.play(mix, shuffled: true) })
        menu.addItem(ClosureMenuItem(title: MacHomeCopy.playNext, systemImage: "text.line.first.and.arrowtriangle.forward") {
            MacHomeActions.playNext(mix, in: window)
        })
        menu.addItem(ClosureMenuItem(title: MacHomeCopy.addToQueue, systemImage: "text.append") {
            MacHomeActions.addToQueue(mix, in: window)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: MacHomeCopy.saveAsPlaylist, systemImage: "text.badge.plus") {
            PlaylistActions.promptForNewPlaylist(adding: mix.tracks, suggestedName: mix.title, in: window)
        })
        return menu
    }

    func recentlyAdded(_ feed: HomeFeed) -> NSView {
        let header = MacHomeSectionHeader(title: HomeCopy.title(for: .recentlyAdded))
        let cards: [NSView] = feed.recentlyAdded.map { album in
            let card = MacHomeCard(
                side: 140, cornerRadius: 8,
                subject: .init(albums: [album], seed: album.id, playlistID: nil),
                title: album.title, subtitle: album.artist, badge: hiResBadge(for: album), hasMenu: true
            )
            card.onClick = { LibraryNavigator.revealAlbum(title: album.title, artist: album.artist) }
            card.onPlay = { MacHomeActions.play(album, shuffled: false) }
            card.menuProvider = { [weak card] in MacTrackMenuFactory.menu(for: album, anchor: card) }
            return card
        }
        return section(header: header, shelf: MacHomeShelf(cards: cards, spacing: 16))
    }

    private func section(header: NSView, shelf: NSView) -> NSView {
        let stack = NSStackView(views: [header, shelf])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        shelf.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }
}

extension MacHomeViewController {

    /// The card, or the line, the feed's promo asks for, worded by the shared
    /// `HomePromoContent` and wired to this page.
    func promoView(_ feed: HomeFeed) -> NSView? {
        guard let promo = feed.promo else { return nil }
        let content = HomePromoContent.make(for: promo, proof: feed.proofLines, gettingStartedBody: HomeCopy.getStartedBodyMac)
        switch content {
        case .getStarted(let started):
            let card = MacHomePromoCard()
            card.configure(getStarted: started)
            card.onAction = { [weak self] action in self?.perform(action) }
            return card
        case .plan(let plan):
            let card = MacHomePromoCard()
            card.configure(plan: plan)
            card.onAction = { [weak self] action in self?.perform(action) }
            return card
        case .note(let text):
            return MacHomePromoNote(text: text)
        }
    }

    private func perform(_ action: MacHomePromoAction) {
        switch action {
        case .chooseFolder:
            NSApp.sendAction(#selector(MacAppDelegate.chooseMusicFolder(_:)), to: nil, from: self)
        case .importFiles:
            NSApp.sendAction(#selector(MacAppDelegate.importFiles(_:)), to: nil, from: self)
        case .playSample:
            MacHomeActions.downloadSample(in: view.window)
        case .seePlans, .getLifetime:
            PurchaseManager.shared.requestPaywall()
        case .restorePurchases:
            MacHomeActions.restorePurchases(in: view.window)
        }
    }
}
