import UIKit

final class LyricsViewController: UIViewController {

    private var tableView: UITableView!
    private var plainTextView: UITextView!
    private var statusLabel: UILabel!
    private var spinner: UIActivityIndicatorView!
    private var lyrics: [LyricLine] = []
    private var plainText: String?
    private var currentLineIndex: Int = -1
    private var trackTitle: String
    private var artistName: String
    private var albumName: String
    private let trackLabel = UILabel()
    private let artistLabel = UILabel()
    private var progressObserver: NSObjectProtocol?
    private var trackObserver: NSObjectProtocol?
    private var loadGeneration = 0
    private var isUserScrolling = false
    private var scrollResumeWorkItem: DispatchWorkItem?

    init(track: String, artist: String, album: String) {
        self.trackTitle = track
        self.artistName = artist
        self.albumName = album
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupUI()
        startTrackObservation()
        loadLyrics()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if let observer = progressObserver {
            NotificationCenter.default.removeObserver(observer)
            progressObserver = nil
        }
        if let observer = trackObserver {
            NotificationCenter.default.removeObserver(observer)
            trackObserver = nil
        }
    }

    private func startTrackObservation() {
        trackObserver = NotificationCenter.default.addObserver(
            forName: AudioPlayer.trackDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleTrackChange()
        }
    }

    private func handleTrackChange() {
        guard let track = AudioPlayer.shared.currentTrack else {
            dismiss(animated: true)
            return
        }
        guard track.title != trackTitle || track.artist != artistName || track.albumTitle != albumName else { return }
        trackTitle = track.title
        artistName = track.artist
        albumName = track.albumTitle
        trackLabel.text = trackTitle
        artistLabel.text = artistName
        resetContent()
        loadLyrics()
    }

    private func resetContent() {
        lyrics = []
        plainText = nil
        currentLineIndex = -1
        tableView.isHidden = true
        tableView.reloadData()
        plainTextView.isHidden = true
        statusLabel.isHidden = true
    }

    private func setupUI() {
        let doneButton = UIButton(type: .system)
        doneButton.setTitle("Done", for: .normal)
        doneButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        doneButton.tintColor = .white
        doneButton.addAction(UIAction { [weak self] _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self?.dismiss(animated: true)
        }, for: .touchUpInside)

        trackLabel.text = trackTitle
        trackLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        trackLabel.textColor = .white.withAlphaComponent(0.8)
        trackLabel.textAlignment = .center
        trackLabel.lineBreakMode = .byTruncatingTail

        artistLabel.text = artistName
        artistLabel.font = .systemFont(ofSize: 13, weight: .regular)
        artistLabel.textColor = .white.withAlphaComponent(0.5)
        artistLabel.textAlignment = .center
        artistLabel.lineBreakMode = .byTruncatingTail

        let titleStack = UIStackView(arrangedSubviews: [trackLabel, artistLabel])
        titleStack.axis = .vertical
        titleStack.spacing = 2
        titleStack.alignment = .center

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let headerSpacer = UIView()
        headerSpacer.widthAnchor.constraint(equalToConstant: 60).isActive = true

        let topRow = UIStackView(arrangedSubviews: [headerSpacer, titleStack, doneButton])
        topRow.alignment = .center
        topRow.distribution = .fill
        topRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topRow)

        NSLayoutConstraint.activate([
            doneButton.widthAnchor.constraint(equalToConstant: 60),
            topRow.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            topRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            topRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])

        spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        statusLabel = UILabel()
        statusLabel.font = .systemFont(ofSize: 20, weight: .medium)
        statusLabel.textColor = .white.withAlphaComponent(0.5)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
        ])

        tableView = UITableView(frame: .zero, style: .plain)
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.showsVerticalScrollIndicator = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(LyricCell.self, forCellReuseIdentifier: LyricCell.reuseID)
        tableView.isHidden = true
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 16),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])

        plainTextView = UITextView()
        plainTextView.backgroundColor = .clear
        plainTextView.isEditable = false
        plainTextView.font = .systemFont(ofSize: 20, weight: .medium)
        plainTextView.textColor = .white.withAlphaComponent(0.8)
        plainTextView.textContainerInset = UIEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        plainTextView.isHidden = true
        plainTextView.showsVerticalScrollIndicator = false
        plainTextView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(plainTextView)

        NSLayoutConstraint.activate([
            plainTextView.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 16),
            plainTextView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            plainTextView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            plainTextView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    private func loadLyrics() {
        loadGeneration += 1
        let generation = loadGeneration
        spinner.startAnimating()

        Task {
            let result = await LyricsService.shared.fetchLyrics(
                track: trackTitle,
                artist: artistName,
                album: albumName
            )
            guard generation == loadGeneration else { return }
            spinner.stopAnimating()

            guard let result else {
                showStatus("No lyrics available")
                return
            }

            if result.isInstrumental {
                showInstrumental()
                return
            }

            if let syncedLines = result.syncedLines, !syncedLines.isEmpty {
                showSyncedLyrics(syncedLines)
            } else if let plain = result.plainText, !plain.isEmpty {
                showPlainLyrics(plain)
            } else {
                showStatus("No lyrics available")
            }
        }
    }

    private func showStatus(_ text: String) {
        statusLabel.text = text
        statusLabel.isHidden = false
    }

    private func showInstrumental() {
        let attachment = NSTextAttachment()
        attachment.image = UIImage(
            systemName: "music.note",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 32, weight: .medium)
        )?.withTintColor(.white.withAlphaComponent(0.5), renderingMode: .alwaysOriginal)

        let attributed = NSMutableAttributedString(attachment: attachment)
        attributed.append(NSAttributedString(
            string: "\nInstrumental",
            attributes: [
                .font: UIFont.systemFont(ofSize: 20, weight: .medium),
                .foregroundColor: UIColor.white.withAlphaComponent(0.5),
            ]
        ))

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        attributed.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: attributed.length))

        statusLabel.attributedText = attributed
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = false
    }

    private func showSyncedLyrics(_ lines: [LyricLine]) {
        lyrics = lines
        tableView.isHidden = false
        tableView.reloadData()

        let topInset = view.bounds.height / 3
        let bottomInset = view.bounds.height / 3
        tableView.contentInset = UIEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)

        startProgressObservation()
        updateCurrentLine()
    }

    private func showPlainLyrics(_ text: String) {
        plainText = text
        plainTextView.text = text
        plainTextView.isHidden = false
    }

    private func startProgressObservation() {
        guard progressObserver == nil else { return }
        progressObserver = NotificationCenter.default.addObserver(
            forName: AudioPlayer.playbackProgressDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateCurrentLine()
        }
    }

    private func updateCurrentLine() {
        guard !lyrics.isEmpty else { return }

        let time = AudioPlayer.shared.currentTime
        var newIndex = -1

        for (index, line) in lyrics.enumerated() {
            if line.time <= time {
                newIndex = index
            } else {
                break
            }
        }

        guard newIndex != currentLineIndex else { return }

        let previousIndex = currentLineIndex
        currentLineIndex = newIndex

        var indexPathsToReload: [IndexPath] = []
        if previousIndex >= 0 && previousIndex < lyrics.count {
            indexPathsToReload.append(IndexPath(row: previousIndex, section: 0))
        }
        if newIndex >= 0 && newIndex < lyrics.count {
            indexPathsToReload.append(IndexPath(row: newIndex, section: 0))
        }

        if !indexPathsToReload.isEmpty {
            tableView.reloadRows(at: indexPathsToReload, with: .fade)
        }

        guard newIndex >= 0, !isUserScrolling else { return }

        tableView.scrollToRow(
            at: IndexPath(row: newIndex, section: 0),
            at: .middle,
            animated: true
        )
    }
}

extension LyricsViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        lyrics.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: LyricCell.reuseID, for: indexPath) as! LyricCell
        let isCurrent = indexPath.row == currentLineIndex
        cell.configure(text: lyrics[indexPath.row].text, isCurrent: isCurrent)
        return cell
    }
}

extension LyricsViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let line = lyrics[indexPath.row]
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        AudioPlayer.shared.seek(to: line.time)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        scrollResumeWorkItem?.cancel()
        isUserScrolling = true
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            scheduleScrollResume()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scheduleScrollResume()
    }

    private func scheduleScrollResume() {
        scrollResumeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.isUserScrolling = false
        }
        scrollResumeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: workItem)
    }
}

private final class LyricCell: UITableViewCell {

    static let reuseID = "LyricCell"

    private let lyricLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        lyricLabel.numberOfLines = 0
        lyricLabel.adjustsFontForContentSizeCategory = true
        lyricLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(lyricLabel)

        NSLayoutConstraint.activate([
            lyricLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            lyricLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            lyricLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            lyricLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func configure(text: String, isCurrent: Bool) {
        lyricLabel.text = text
        if isCurrent {
            lyricLabel.font = .scaled(.title1, size: 28, weight: .bold)
            lyricLabel.textColor = .white
            lyricLabel.transform = .identity
        } else {
            lyricLabel.font = .scaled(.title3, size: 20, weight: .medium)
            lyricLabel.textColor = .white.withAlphaComponent(0.3)
            lyricLabel.transform = .identity
        }
    }
}
