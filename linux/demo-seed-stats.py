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
    db.commit()
    print(f"seeded {len(rows)} scrobbles, playlists, lyrics, loved flags, albumInfo year/genre")


if __name__ == "__main__":
    main()
