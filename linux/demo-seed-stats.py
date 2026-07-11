#!/usr/bin/env python3
"""Seeds the --demo library database with a fictional year of listening
history so marketing screenshots show a saturated app: varied per-day
scrobble counts (heatmap), weighted top artists/albums/tracks, an evening
peak hour, an unbroken recent streak, loved tracks, and albumInfo
year/genre rows for every album. Usage: demo-seed-stats.py <library.sqlite>."""
import datetime
import random
import sqlite3
import sys

GENRES = {
    "Parallax Hours": ("2024", "Electronic"),
    "Vantablack Sun": ("2022", "Darkwave"),
    "Field Lines": ("2020", "Ambient"),
    "Ember & Ash": ("2023", "Indie Folk"),
    "Aurorae": ("2025", "Post-Rock"),
    "Overwinter": ("2023", "Post-Rock"),
    "Paper Cities": ("2022", "Dream Pop"),
    "Cassini": ("2024", "Space Ambient"),
    "Midnatt": ("2023", "Nordic Jazz"),
    "Ravine": ("2021", "Alt Rock"),
    "Meltwater": ("2024", "Alt Rock"),
}
ARTIST_WEIGHT = {
    "Meridian Wolde": 5.0,
    "The Hollowmen": 3.4,
    "Kestrel Vale": 2.6,
    "Marisol Vane": 1.8,
    "Solveig": 1.3,
    "Novaeu": 0.9,
    "Virelle": 0.6,
}
HOUR_WEIGHTS = [1, 1, 1, 1, 1, 1, 2, 3, 4, 4, 4, 5, 5, 5, 4, 4, 5, 6, 8, 10, 9, 7, 4, 2]


def main() -> None:
    random.seed(42)
    db = sqlite3.connect(sys.argv[1])
    tracks = db.execute(
        "SELECT title, artist, albumTitle, duration FROM tracks"
    ).fetchall()
    if not tracks:
        raise SystemExit("no tracks — run demo-seed.sh and scan first")

    db.execute("DELETE FROM scrobbles")
    track_weights = [
        ARTIST_WEIGHT.get(t[1], 1.0) * random.uniform(0.5, 2.2) for t in tracks
    ]
    now = datetime.datetime.now(datetime.timezone.utc)
    rows = []
    for day in range(365):
        if day > 9 and random.random() < 0.16:
            continue
        date = now - datetime.timedelta(days=day)
        busy = 1.6 if date.weekday() >= 5 else 1.0
        for _ in range(int(random.randint(3, 13) * busy)):
            t = random.choices(tracks, weights=track_weights)[0]
            hour = random.choices(range(24), weights=HOUR_WEIGHTS)[0]
            ts = date.replace(
                hour=hour, minute=random.randint(0, 59), second=random.randint(0, 59)
            )
            duration = int(t[3]) if random.random() > 0.25 else 0
            rows.append(
                (t[0], t[1], t[2], ts.strftime("%Y-%m-%d %H:%M:%S.000"), duration, 1)
            )
    db.executemany(
        "INSERT INTO scrobbles (trackTitle, artist, albumTitle, timestamp, duration, submitted)"
        " VALUES (?,?,?,?,?,?)",
        rows,
    )

    db.execute(
        "UPDATE tracks SET playCount = abs(random()) % 60,"
        " lastPlayed = datetime('now', '-' || (abs(random()) % 45) || ' days')"
    )
    db.execute(
        "UPDATE tracks SET loved = 1 WHERE rowid IN"
        " (SELECT rowid FROM tracks ORDER BY random() LIMIT 9)"
    )
    db.execute("DELETE FROM playlists")
    db.execute("DELETE FROM playlistTracks")
    playlists = {
        "Late Night Drive": ["Slow Machine", "Vantablack Sun", "Midnatt", "Cassini",
                             "Night Arithmetic", "Umbra", "Frost", "Rings"],
        "Morning Frost": ["Overwinter", "Snowline", "Aurorae", "Paper Cities",
                          "Field Lines", "Thaw", "Sommarnatt"],
        "Deep Focus": ["Tidal Glass", "Almagest", "Solenoid", "Meltwater",
                       "Ionosphere", "Springtide"],
        "Golden Hour": ["Greenhouse Hymns", "Saltwater Gospel", "Ember & Ash",
                        "Southern Cross", "Ledger", "Peony"],
        "Lossless Showcase": ["Parallax Hours", "Southern Cross", "Vantablack Sun",
                              "Tidal Glass", "Field Lines", "Confluence"],
        "Rainy Windows": ["Radio Silence", "Statuary", "Longshore Drift",
                          "Paper Cities", "Tallow Light"],
        "Coastlines": ["Longshore Drift", "Foreshore", "Harbor Lantern", "Brine",
                       "Neap", "Estuary", "Sealskin"],
    }
    for name, titles in playlists.items():
        cur = db.execute(
            "INSERT INTO playlists (name, createdAt) VALUES (?, datetime('now'))", (name,)
        )
        pid = cur.lastrowid
        position = 0
        for title in titles:
            row = db.execute(
                "SELECT fileURL FROM tracks WHERE title = ?", (title,)
            ).fetchone()
            if row:
                db.execute(
                    "INSERT INTO playlistTracks (playlistId, trackFileURL, position)"
                    " VALUES (?,?,?)",
                    (pid, row[0], position),
                )
                position += 1

    lrc_lines = [
        "Cold light through the terminal glass",
        "Counting stations as the hours pass",
        "A slow machine hums beneath the floor",
        "Carries me to where you were before",
        "Parallax, the platforms slide",
        "Two horizons, side by side",
        "Every window frames a former year",
        "The slow machine will take me there",
        "Signal lamps along the line",
        "Trade the darkness one for nine",
        "I fold the map, I close my eyes",
        "The slow machine outruns the sunrise",
    ]
    lrc = "\n".join(
        f"[00:{2*i+1:02d}.{(37*i)%100:02d}]{line}" for i, line in enumerate(lrc_lines)
    )
    db.execute(
        "INSERT INTO lyrics (trackTitle, artist, syncedLyrics, plainLyrics, instrumental)"
        " VALUES (?,?,?,?,0)"
        " ON CONFLICT(trackTitle, artist) DO UPDATE SET syncedLyrics = excluded.syncedLyrics,"
        " plainLyrics = excluded.plainLyrics",
        ("Slow Machine", "Meridian Wolde", lrc, "\n".join(lrc_lines)),
    )

    for album, (year, genre) in GENRES.items():
        db.execute(
            "UPDATE albumInfo SET year = ?, genre = ?, lastFetched = datetime('now')"
            " WHERE title = ?",
            (year, genre, album),
        )
    GENRES.setdefault("Statuary", ("2021", "Dream Pop"))
    GENRES.setdefault("First Transmissions", ("2019", "Space Ambient"))
    for album, (year, genre) in GENRES.items():
        db.execute(
            "UPDATE albumInfo SET year = ?, genre = ?, lastFetched = datetime('now')"
            " WHERE title = ?",
            (year, genre, album),
        )

    bios = {
        "Meridian Wolde": "Meridian Wolde is a fictional electronic composer whose long-form pieces trace commuter rail lines through imagined cities. Parallax Hours, the 2024 breakthrough, was recorded entirely between midnight and dawn.",
        "Kestrel Vale": "Kestrel Vale is a fictional post-rock quartet from a coastal town that does not exist, known for glacial crescendos and field recordings of weather that never happened.",
        "The Hollowmen": "The Hollowmen are a fictional alt-rock trio whose riverside recording cabin lends every record its water-worn texture.",
    }
    for name, bio in bios.items():
        db.execute(
            "INSERT INTO artists (name, bio, lastFetched) VALUES (?, ?, datetime('now'))"
            " ON CONFLICT(name) DO UPDATE SET bio = excluded.bio",
            (name, bio),
        )

    similar = {
        "Meridian Wolde": [("Virelle", 0.82), ("Novaeu", 0.71), ("Solveig", 0.55)],
        "Kestrel Vale": [("The Hollowmen", 0.77), ("Meridian Wolde", 0.52)],
    }
    for artist, entries in similar.items():
        for name, match in entries:
            db.execute(
                'INSERT INTO similarArtistCache (artist, similarName, "match", fetchedAt)'
                " VALUES (?,?,?,datetime('now'))"
                ' ON CONFLICT(artist, similarName) DO UPDATE SET "match" = excluded."match",'
                " fetchedAt = excluded.fetchedAt",
                (artist, name, match),
            )

    wantlist = [
        ("album\x00meridianwolde\x00halationtapes", "album", "Halation Tapes", "Meridian Wolde", "history", 620.0, "48 plays on Last.fm", 48),
        ("album\x00kestrelvale\x00driftstations", "album", "Drift Stations", "Kestrel Vale", "history", 410.0, "31 plays on Last.fm", 31),
        ("track\x00solveig\x00vinternatt", "track", "Vinternatt", "Solveig", "loved", 500.0, "Loved on Last.fm", 0),
        ("artist\x00\x00lumenfjord", "artist", "Lumen Fjord", "Lumen Fjord", "discovery", 96.0, "Because you play Meridian Wolde", 0),
        ("album\x00lumenfjord\x00harbourlight", "album", "Harbour Light", "Lumen Fjord", "discovery", 96.0, "Because you play Meridian Wolde", 0),
    ]
    for norm_key, kind, title, artist, source, score, reason, plays in wantlist:
        db.execute(
            "INSERT INTO wantlist (normKey, kind, title, artist, state, source, score, reason, playCount, addedAt)"
            " VALUES (?,?,?,?,'wanted',?,?,?,?,datetime('now'))"
            " ON CONFLICT(normKey) DO UPDATE SET score = excluded.score",
            (norm_key, kind, title, artist, source, score, reason, plays),
        )

    releases = [
        ("Meridian Wolde", "Terminal Glass EP", 12),
        ("The Hollowmen", "Undertow", 33),
    ]
    for artist, album, days_ago in releases:
        db.execute(
            "INSERT INTO newReleaseCache (artist, albumTitle, releaseDate, fetchedAt)"
            " VALUES (?,?,datetime('now', ?),datetime('now'))"
            " ON CONFLICT(artist, albumTitle) DO UPDATE SET releaseDate = excluded.releaseDate,"
            " fetchedAt = excluded.fetchedAt",
            (artist, album, f"-{days_ago} days"),
        )

    db.commit()
    print(f"seeded {len(rows)} scrobbles, playlists, lyrics, loved flags, albumInfo, artists, wantlist, releases")


if __name__ == "__main__":
    main()
