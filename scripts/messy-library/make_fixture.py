"""Writes a messy FLAC library for --exercise-library-walk: discs of one album under two album
artists, a compilation sharing a title with an artist's own album, editions, a single beside its
album, 5000 px PNG covers, non-square, 1 px and corrupt covers, unicode and blank tags, odd track
numbers, plus BULK generic albums. Needs ffmpeg, metaflac and Pillow.

Usage: python3 make_fixture.py OUT_DIR [BULK_ALBUMS]   (the music lands in OUT_DIR/Music)
"""
import os, shutil, subprocess, sys, random, pathlib
from PIL import Image, ImageDraw

out = pathlib.Path(sys.argv[1])
bulk_albums = int(sys.argv[2]) if len(sys.argv) > 2 else 150
if out.exists():
    shutil.rmtree(out)
music = out / "Music"
art_dir = out / "_art"
music.mkdir(parents=True)
art_dir.mkdir()
rng = random.Random(7)

base = out / "_base.flac"
subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo", "-t", "1", "-c:a", "flac", str(base)], check=True)

def art(name, w, h, fmt="JPEG", seed=0):
    path = art_dir / f"{name}.{ 'png' if fmt == 'PNG' else 'jpg'}"
    if path.exists():
        return path
    r = random.Random(seed)
    img = Image.new("RGB", (w, h), (r.randrange(256), r.randrange(256), r.randrange(256)))
    d = ImageDraw.Draw(img)
    for i in range(12):
        x0, y0 = r.randrange(w), r.randrange(h)
        d.ellipse([x0, y0, x0 + w // 3, y0 + h // 3], fill=(r.randrange(256), r.randrange(256), r.randrange(256)))
    d.rectangle([0, 0, w - 1, h - 1], outline=(255, 255, 255), width=max(1, min(w, h) // 40))
    img.save(path, fmt, quality=85) if fmt == "JPEG" else img.save(path, fmt)
    return path

def track(folder, filename, tags, picture=None):
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / filename
    shutil.copyfile(base, path)
    args = ["metaflac", "--remove-all-tags"]
    for key, value in tags:
        args.append(f"--set-tag={key}={value}")
    if picture is not None:
        mime = "image/png" if str(picture).endswith(".png") else "image/jpeg"
        dims = "640x640x24" if "garbage" in str(picture) else ""
        args.append(f"--import-picture-from=3|{mime}||{dims}|{picture}")
    args.append(str(path))
    subprocess.run(args, check=True)

count = 0
def album(folder, title, album_artist, tracks, picture=None, every_track_art=True, year=None, extra=()):
    global count
    for i, (number, ttitle, tartist) in enumerate(tracks):
        tags = [("TITLE", ttitle), ("ARTIST", tartist), ("ALBUM", title)]
        if album_artist is not None:
            tags.append(("ALBUMARTIST", album_artist))
        if number is not None:
            tags.append(("TRACKNUMBER", str(number)))
        if year:
            tags.append(("DATE", year))
        tags.extend(extra)
        pic = picture if (every_track_art or i == 0) else None
        track(music / folder, f"{i+1:02d} {ttitle[:60].replace('/', '_')}.flac", tags, pic)
        count += 1

beatles = art("beatles", 1200, 1200, seed=1)
album("The Beatles/White Album CD1", "The White Album", "The Beatles",
      [(1, "Back in the U.S.S.R.", "The Beatles"), (2, "Dear Prudence", "The Beatles"), (3, "Glass Onion", "The Beatles")], beatles, year="1968")
album("The Beatles/White Album CD2", "The White Album", "Beatles",
      [(1, "Birthday", "The Beatles"), (2, "Yer Blues", "The Beatles")], beatles, year="1968")
album("Beatles, The/Abbey Road", "Abbey Road", "The Beatles", [(1, "Come Together", "The Beatles"), (2, "Something", "The Beatles")], art("abbey", 1200, 1000, seed=2), year="1969")
album("Beatles, The/Abbey Road Remastered", "Abbey Road (Remastered)", "The Beatles", [(1, "Come Together", "The Beatles"), (2, "Something", "The Beatles")], art("abbey-r", 1000, 1200, seed=3), year="2009")
album("Beatles, The/Abbey Road Deluxe", "Abbey Road (Super Deluxe Edition)", "The Beatles", [(1, "Come Together", "The Beatles"), (2, "Something", "The Beatles"), (3, "Come Together (Take 5)", "The Beatles")], art("abbey-d", 3000, 300, seed=4), year="2019")
album("Beatles/Abbey Road (other credit)", "Abbey Road", "Beatles", [(3, "Maxwell's Silver Hammer", "The Beatles")], art("abbey2", 600, 1500, seed=5))

album("Queen/Greatest Hits", "Greatest Hits", "Queen", [(1, "Bohemian Rhapsody", "Queen"), (2, "Another One Bites the Dust", "Queen")], art("queen", 800, 800, seed=6))
album("Compilations/Greatest Hits", "Greatest Hits", "Various Artists",
      [(1, "Bohemian Rhapsody", "Queen"), (2, "Song Two", "The Longer Named Band"), (3, "Song Three", "Another Much Longer Artist")], art("va", 1400, 900, seed=7))

harbor = art("harbor", 900, 900, seed=8)
album("Aurelia Vance/Glass Harbor - Single", "Glass Harbor - Single", "Aurelia Vance", [(1, "Glass Harbor", "Aurelia Vance")], harbor)
album("Aurelia Vance/Tidewater", "Tidewater", "Aurelia Vance", [(1, "Low Tide", "Aurelia Vance"), (2, "Glass Harbor", "Aurelia Vance"), (3, "Glass Harbor (2011 Remaster)", "Aurelia Vance")], art("tidewater", 1500, 1100, seed=9))

for k in range(10):
    album(f"Huge/Huge Cover {k}", f"Huge Cover {k}", "Mammoth Covers", [(n, f"Huge Song {k}.{n}", "Mammoth Covers") for n in range(1, 4)], art(f"huge{k}", 5000, 5000, "PNG", seed=100 + k))
album("Odd/Tiny Cover", "Tiny Cover", "Pixel Person", [(1, "Small Thing", "Pixel Person")], art("tiny", 16, 16, seed=11))
album("Odd/Thin Banner", "Thin Banner", "Banner Band", [(1, "Wide Song", "Banner Band")], art("banner", 3200, 1, seed=12))
album("Odd/Tall Strip", "Tall Strip", "Strip Act", [(1, "Tall Song", "Strip Act")], art("strip", 1, 2400, seed=13))
album("Odd/No Art", "No Art", "Bare Artist", [(1, "Bare Song", "Bare Artist")])

album("Unicode/東京事変", "大人 (アダルト)", "東京事変", [(1, "林檎の唄", "東京事変"), (2, "喧嘩上等", "東京事変")], art("tokyo", 1000, 800, seed=14))
album("Unicode/فيروز", "بيروت", "فيروز", [(1, "لبيروت", "فيروز")], art("fairuz", 700, 700, seed=15))
album("Unicode/Emoji", "🌊 Waves 🌊", "👩‍🎤 Singer", [(1, "🔥 Fire 🔥", "👩‍🎤 Singer"), (2, "été combining", "👩‍🎤 Singer")], art("emoji", 640, 480, seed=16))
long_title = "An Extraordinarily Long Song Title That Keeps Going " * 6
album("Unicode/Long", "A Very Long Album Title " * 5, "Prolix Ensemble with Guest Orchestra and Choir of the Northern Lights", [(1, long_title.strip(), "Prolix Ensemble with Guest Orchestra and Choir of the Northern Lights")], art("long", 900, 600, seed=17))

album("Tags/Missing Everything", "", None, [(None, "", "")])
album("Tags/Whitespace", "   ", "   ", [(1, "   ", "   ")])
album("Tags/Numbers", "Odd Numbers", "Count Basie Jr", [(0, "Zero", "Count Basie Jr"), (99, "Ninety Nine", "Count Basie Jr"), ("3/12", "Three of Twelve", "Count Basie Jr"), (1, "One A", "Count Basie Jr"), (1, "One B", "Count Basie Jr")], art("numbers", 500, 500, seed=18))
album("Tags/Feat", "Collabs", "50 Cent", [(1, "In Da Club", "50 Cent"), (2, "Patiently Waiting", "50 Cent feat. Eminem"), (3, "Many Men", "50 Cent & Friends")], art("feat", 1000, 1000, seed=19))

with open(art_dir / "garbage.jpg", "wb") as f:
    f.write(bytes(rng.randrange(256) for _ in range(4096)))
album("Odd/Corrupt Picture", "Corrupt Picture", "Glitch", [(1, "Broken Cover", "Glitch")], art_dir / "garbage.jpg")

shapes = [(1000, 1000), (1200, 1000), (1000, 1200), (1500, 500), (600, 600), (1400, 1400)]
for k in range(bulk_albums):
    w, h = shapes[k % len(shapes)]
    artist = f"Artist {k % 40:02d}"
    pic = art(f"bulk{k}", w, h, seed=1000 + k) if k % 9 else None
    album(f"Bulk/{artist}/Album {k:03d}", f"Album {k:03d}", artist, [(n, f"Track {k:03d}-{n:02d}", artist if n % 4 else f"{artist} feat. Guest {n}") for n in range(1, 11)], pic, every_track_art=False, year=str(1970 + k % 50))

shutil.rmtree(art_dir)
base.unlink()
print(f"{count} tracks in {music}")
