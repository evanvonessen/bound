#!/usr/bin/env python3
"""Bundle unchanged game trainer sprites with explicit per-encounter mappings.

Uses Pokémon Showdown's original game sprites; does not fetch artist-credited
custom sprites. Unknown custom trainers use a generic Ace Trainer class icon.
Existing boss teams, type icons and reference descriptions are preserved.
"""
import argparse
import base64
import concurrent.futures
import hashlib
import json
import re
import subprocess
from pathlib import Path

SOURCE = "https://play.pokemonshowdown.com/sprites/trainers/"
NAMED = {
    "Brock": "brock-gen3", "Misty": "misty-gen3", "Lt. Surge": "ltsurge-gen3",
    "Erika": "erika-gen3", "Sabrina": "sabrina-gen3", "Koga": "koga-gen3",
    "Blaine": "blaine-gen3", "Clair": "clair", "Falkner": "falkner",
    "Bugsy": "bugsy", "Whitney": "whitney", "Morty": "morty", "Chuck": "chuck",
    "Pryce": "pryce", "Jasmine": "jasmine", "Rival": "blue-gen3",
    "Brendan": "brendan-gen3", "May": "may-gen3", "Archer": "archer",
    "Ariana": "ariana", "Giovanni": "giovanni-gen3", "Lance": "lance-gen3",
    "Lorelei": "lorelei-gen3", "Bruno": "bruno-gen3", "Agatha": "agatha-gen3",
    "Oak": "oak-gen3", "Red": "red-gen3",
}
PAIRS = {
    "Ariana & Archer": ["ariana", "archer"],
    "Ann & Brooks": ["lass-gen3", "gentleman-gen3"],
    "Edmond & Trevor": ["sailor-gen3", "sailor-gen3"],
    "Lola & Sheila": ["beauty-gen3", "beauty-gen3"],
}
CLASSES = {
    "ACE TRAINER": "acetrainer-gen3", "SUPER NERD": "supernerd-gen3",
    "BUG CATCHER": "bugcatcher-gen3", "YOUNGSTER": "youngster-gen3",
    "LASS": "lass-gen3", "CAMPER": "camper-gen3", "GENTLEMAN": "gentleman-gen3",
    "SAILOR": "sailor-gen3", "PICNICKER": "picnicker-gen3", "ROCKER": "rocker-gen3",
    "FISHERMAN": "fisherman-gen3", "BIRD KEEPER": "birdkeeper-gen3",
    "BEAUTY": "beauty-gen3", "BIKER": "biker-gen3", "CUE BALL": "cueball-gen3",
    "DRAGON TAMER": "dragontamer-gen3", "BLACK BELT": "blackbelt-gen3",
    "BURGLAR": "burglar-gen3", "SWIMMER": "swimmerm-gen3", "CRUSH KIN": "crushkin-gen3",
    "CRUSH GIRL": "crushgirl-gen3", "RANGER": "pokemonranger-gen3",
    "TWINS": "twins-gen3", "AROMA LADY": "aromalady-gen3", "TUBER": "tuber-gen3",
    "CHANNELER": "channeler-gen3",
}


def icons_for(team):
    if team["name"] in PAIRS:
        return PAIRS[team["name"]]
    if team["name"] in NAMED:
        return [NAMED[team["name"]]]
    if team["category"] == "Team Rocket":
        return ["teamrocketgruntm-gen3"]
    label = team["sourceLabel"]
    return [next((icon for role, icon in CLASSES.items() if role in label), "acetrainer-gen3")]


def download(url):
    return subprocess.check_output(["curl", "--fail", "--silent", "--show-error", "--location", "--max-time", "30", url])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--cache-dir", type=Path, required=True)
    args = parser.parse_args()
    catalog = json.loads(args.catalog.read_text())
    reference = json.loads(args.reference.read_text())
    mappings = {team["id"]: icons_for(team) for team in catalog["teams"]}
    keys = sorted({key for values in mappings.values() for key in values})
    args.cache_dir.mkdir(parents=True, exist_ok=True)
    index = download(SOURCE + "index.php").decode()

    def fetch(key):
        figure = re.search(r'<figure id="' + re.escape(key) + r'\.png">(.*?)</figure>', index, re.S)
        if not figure or "by " in figure.group(1):
            raise ValueError("Expected an uncredited original game sprite: " + key)
        path = args.cache_dir / (key + ".png")
        if not path.exists():
            path.write_bytes(download(SOURCE + key + ".png"))
        data = path.read_bytes()
        if not data.startswith(b"\x89PNG\r\n\x1a\n"):
            raise ValueError("Invalid trainer PNG: " + key)
        return key, {"pngBase64": base64.b64encode(data).decode(),
                     "sha256": hashlib.sha256(data).hexdigest(), "sourceURL": SOURCE + key + ".png"}

    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
        icons = dict(pool.map(fetch, keys))
    reference.update({
        "trainerIconSource": SOURCE,
        "trainerIconAttribution": "Original game trainer sprites, unchanged, from Pokemon Showdown. "
                                  "Pokemon artwork belongs to Nintendo / Game Freak / The Pokemon Company. "
                                  "Generic opponents use trainer-class icons; custom trainers without a matching portrait use Ace Trainer.",
        "trainerIcons": icons,
        "trainerIconsByTeam": mappings,
    })
    args.reference.write_text(json.dumps(reference, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"icons": len(icons), "teams": len(mappings), "reference": str(args.reference)}))


if __name__ == "__main__":
    main()
