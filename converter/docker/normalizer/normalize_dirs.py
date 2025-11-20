#!/usr/bin/env python3
# normalize_dirs.py
# Usage:
#   python3 normalize_dirs.py --source /path/to/aac --dest /path/to/aac
#   python3 normalize_dirs.py --dry-run --source src --dest dest

import argparse
import os
import shutil
from mutagen.mp4 import MP4
from collections import defaultdict
import re

def safe(s):
    if s is None:
        return ""
    # collapse whitespace, remove leading/trailing
    s = str(s).strip()
    # replace problematic filesystem characters
    s = re.sub(r'[\/\:\*\?\"<>\|]', '_', s)
    return s

def detect_release_type(tags):
    # tries several tags to derive type: 'album', 'single', 'ep', 'compilation', 'archive', 'live', ...
    # many tag namespaces exist; we check common keys
    candidates = []
    for k in ('albumtype', 'releasegroup_type', 'type', 'media'):
        if k in tags:
            candidates.append(safe(tags[k]))
    # Mutagen MP4 uses keys like '\xa9alb' for album; extra tags may be in '----:com.apple.itunes:...'
    # Look for 'compilation' flag
    if 'cpil' in tags:
        try:
            if tags['cpil'][0]:
                candidates.append('compilation')
        except Exception:
            pass
    # fallback: if total tracks small maybe single/EP (we avoid guessing too much)
    if candidates:
        return candidates[0].lower()
    return "album"

def get_tag_mp4(mp4, key):
    # common MP4 keys mapping
    mapping = {
        'artist': '\xa9ART', 'album': '\xa9alb', 'title': '\xa9nam', 'date': '\xa9day',
        'tracknumber': 'trkn', 'discnumber': 'disk', 'albumartist': 'aART', 'genre': '\xa9gen'
    }
    if key in mapping:
        k = mapping[key]
        if k in mp4:
            return mp4[k]
    # fallback: try plain key
    if key in mp4:
        return mp4[key]
    return None

def gather_album_info(filepaths):
    albums = defaultdict(list)
    for fp in filepaths:
        try:
            audio = MP4(fp)
        except Exception:
            audio = None
        if audio is None:
            continue
        # prefer albumartist then artist
        albumartist = get_tag_mp4(audio, 'albumartist') or get_tag_mp4(audio, 'artist') or ['Unknown Artist']
        # MP4 tags can be list
        if isinstance(albumartist, (list, tuple)):
            albumartist = albumartist[0] if albumartist else "Unknown Artist"
        album = get_tag_mp4(audio, 'album') or ['Unknown Album']
        if isinstance(album, (list, tuple)):
            album = album[0] if album else "Unknown Album"
        # identify album key
        key = (safe(albumartist), safe(album))
        albums[key].append((fp, audio))
    return albums

def build_target_for_album(artist, album, audio_files):
    # determine year: try to read date/year from first track
    year = None
    albumtype = None
    for fp, audio in audio_files:
        # date
        v = get_tag_mp4(audio, 'date') or get_tag_mp4(audio, 'year')
        if v:
            if isinstance(v, (list, tuple)):
                v = v[0]
            if isinstance(v, str):
                m = re.search(r'\d{4}', v)
                if m:
                    year = m.group(0)
                    break
            else:
                year = str(v)
                break
    if year is None:
        year = "????"
    # album type heuristic
    try:
        albumtype = detect_release_type(audio_files[0][1])
    except Exception:
        albumtype = "album"
    albumtype = albumtype or "album"
    # if albumtype indicates standard album/LP, do not show bracket
    bracket=""
    if albumtype not in ('album', 'lp', 'longplay'):
        bracket = f" [{albumtype}]"
    dirname = f"{artist} - ({year}) {album}{bracket}"
    # detect discs structure
    discs = {}
    for fp, audio in audio_files:
        disc = None
        track = None
        # check trkn and disk tags
        if 'trkn' in audio:
            trkn = audio.get('trkn')
            if trkn and isinstance(trkn[0], tuple):
                track = trkn[0][0]
                # track total = trkn[0][1]
        if 'disk' in audio:
            dk = audio.get('disk')
            if dk and isinstance(dk[0], tuple):
                disc = dk[0][0]
        # fallback to custom tags
        if disc is None:
            disc = 1
        if track is None:
            # fallback to filename ordering
            basename = os.path.basename(fp)
            m = re.match(r'(\d{1,2})', basename)
            track = int(m.group(1)) if m else 0
        discs.setdefault(disc, []).append((track, fp, audio))
    # sort tracks within discs
    for k in discs:
        discs[k].sort(key=lambda x: x[0])
    return dirname, discs

def main():
    p = argparse.ArgumentParser(description="Normalize audio directory structure using tags (MP4/M4A)")
    p.add_argument('--source', required=True, help='source directory with audio files')
    p.add_argument('--dest', required=True, help='destination root for normalized layout (can equal source)')
    p.add_argument('--dry-run', action='store_true', help='do not move anything, just print actions')
    args = p.parse_args()

    # gather list of m4a/mp4 files under source
    files = []
    for root, _, fnames in os.walk(args.source):
        for f in fnames:
            if f.lower().endswith(('.m4a', '.mp4', '.m4b')):
                files.append(os.path.join(root, f))

    if not files:
        print("No m4a/mp4 files found under", args.source)
        return

    albums = gather_album_info(files)
    print(f"Found {len(albums)} album(s)")

    for (artist, album), items in albums.items():
        print(f"\nProcessing album: Artist='{artist}' Album='{album}' ({len(items)} tracks)")
        dirname, discs = build_target_for_album(artist, album, items)

        artist_dir = os.path.join(args.dest, artist)
        album_dir = os.path.join(artist_dir, dirname)

        # create album dir
        print(" -> Target album dir:", album_dir)
        if not args.dry_run:
            os.makedirs(album_dir, exist_ok=True)

        # if multiple discs, create CD1, CD2...
        if len(discs) > 1:
            for discno in sorted(discs.keys()):
                disc_label = f"CD{discno}"
                disc_path = os.path.join(album_dir, disc_label)
                if not args.dry_run:
                    os.makedirs(disc_path, exist_ok=True)
                for idx, (tracknum, fp, audio) in enumerate(discs[discno], start=1):
                    # create filename: NN. Title.m4a (optionally "Artist - title" if desired)
                    title = get_tag_mp4(audio, 'title') or os.path.splitext(os.path.basename(fp))[0]
                    if isinstance(title, (list,tuple)): title = title[0]
                    title = safe(title)
                    tracknum_s = f"{int(tracknum):02d}" if tracknum else f"{idx:02d}"
                    newname = f"{tracknum_s}. {title}.m4a"
                    destpath = os.path.join(disc_path, newname)
                    print(f"   move: {fp} -> {destpath}")
                    if not args.dry_run:
                        # avoid overwriting existing files accidentally
                        if os.path.exists(destpath):
                            print("     exists, appending suffix")
                            base, ext = os.path.splitext(newname)
                            i = 1
                            while True:
                                candidate = os.path.join(disc_path, f"{base} ({i}){ext}")
                                if not os.path.exists(candidate):
                                    destpath = candidate
                                    break
                                i += 1
                        shutil.move(fp, destpath)
        else:
            # single-disc album - place tracks in album_dir directly
            for idx, (tracknum, fp, audio) in enumerate(next(iter(discs.values())), start=1):
                title = get_tag_mp4(audio, 'title') or os.path.splitext(os.path.basename(fp))[0]
                if isinstance(title, (list,tuple)): title = title[0]
                title = safe(title)
                tracknum_s = f"{int(tracknum):02d}" if tracknum else f"{idx:02d}"
                # if you want the filename to be "Artist - title" use below, but based on example you prefer "NN. Title.m4a"
                newname = f"{tracknum_s}. {title}.m4a"
                destpath = os.path.join(album_dir, newname)
                print(f"   move: {fp} -> {destpath}")
                if not args.dry_run:
                    if os.path.exists(destpath):
                        base, ext = os.path.splitext(newname)
                        i = 1
                        while True:
                            candidate = os.path.join(album_dir, f"{base} ({i}){ext}")
                            if not os.path.exists(candidate):
                                destpath = candidate
                                break
                            i += 1
                    shutil.move(fp, destpath)

    # Optionally: remove empty original directories
    if not args.dry_run:
        for root, dirs, files in os.walk(args.source, topdown=False):
            # don't remove dest roots if dest == source; only remove empty directories
            try:
                if not os.listdir(root):
                    os.rmdir(root)
            except Exception:
                pass

if __name__ == "__main__":
    main()
