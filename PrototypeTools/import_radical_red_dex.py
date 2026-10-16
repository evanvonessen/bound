#!/usr/bin/env python3
"""Normalize the RR 4.1 dex's data object; does not read ROMs or player saves.

Input: data.js and src/abilityRandomizer.js from JwowSquared/Radical-Red-Pokedex.
The published data object is parsed as literals; no downloaded code is executed.
"""
import argparse
import ast
import hashlib
import json
import re
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    data_path = args.source / "data.js"
    # This snapshot's JS object uses Python-compatible string/number literals.
    # Round-trip through JSON to normalize numeric dictionary keys to strings.
    raw = json.loads(json.dumps(ast.literal_eval(data_path.read_text())))
    randomizer = (args.source / "src/abilityRandomizer.js").read_text()
    def table(name):
        body = re.search(r"const " + name + r" = \[(.*?)\];", randomizer, re.S)[1]
        return [int(x, 16) for x in re.findall(r"0x[0-9A-Fa-f]+", body)]
    def item(i): return raw["items"][str(i)]["name"]
    def move(i): return raw["moves"][str(i)]["name"]
    def type_name(i): return raw["types"][str(i)]["name"]
    def method(e):
        kind, value, target, extra = e
        level = f"Level {value}"
        methods = {
            1: "Level up with high friendship", 2: "High friendship · day", 3: "High friendship · night",
            4: level, 8: level + " · Attack > Defense", 9: level + " · Attack = Defense",
            10: level + " · Attack < Defense", 11: level + " · 50% chance", 12: level + " · 50% chance",
            13: level, 14: "Evolve Nincada · empty party slot and Poké Ball",
            16: level + " · rain in the overworld", 20: level + " · male", 21: level + " · female",
            22: level + " · night", 23: level + " · day",
            28: level + " · " + ({1041: "day", 5144: "night"}.get(extra, "dusk")),
            30: level + " · Adamant, Brave, Docile, Hardy, Hasty, Impish, Jolly, Lax, Naive, Naughty, Rash, Quirky or Sassy nature",
            31: level + " · Bashful, Bold, Calm, Careful, Gentle, Lonely, Mild, Modest, Quiet, Relaxed, Serious or Timid nature",
        }
        if kind == 7: return item(value) + (" · female" if extra == 254 else " · male") if value == 101 else item(value)
        if kind == 17: return "High friendship · know a " + type_name(value) + " move"
        if kind == 18: return level + " · " + type_name(extra) + " Pokémon in party"
        if kind == 26: return "Level up knowing " + move(value)
        if kind == 27: return "Level up with " + raw["species"][str(value)]["key"] + " in party"
        if kind == 254: return "Know " + move(value) if extra == 2 else item(value)
        if kind not in methods: raise ValueError(f"Unknown evolution method: {e}")
        return methods[kind]
    species = []
    for p in raw["species"].values():
        sprite = raw["sprites"].get(str(p["ID"]), raw["sprites"]["0"])
        assert sprite.startswith("data:image/png;base64,")
        # Source order is HP, Atk, Def, Spe, SpA, SpD; the UI uses conventional order.
        species.append({"id": p["ID"], "name": p["key"], "dexNumber": p["dexID"],
                        "ancestorID": p.get("ancestor", p["ID"]), "types": list(dict.fromkeys(p["type"])),
                        "stats": [p["stats"][i] for i in [0, 1, 2, 4, 5, 3]],
                        "abilities": p["abilities"], "sprite": sprite.split(",", 1)[1],
                        "evolutions": [{"targetID": e[2], "method": method(e)} for e in p.get("evolutions", [])],
                        "learnset": ([{"moveID": m, "method": "Level up", "level": l} for m, l in p.get("levelupMoves", [])] +
                                     [{"moveID": raw["tmMoves"][str(m)], "method": "TM/HM", "level": None} for m in p.get("tmMoves", []) if str(m) in raw["tmMoves"]] +
                                     [{"moveID": raw["tutorMoves"][str(m)], "method": "Tutor", "level": None} for m in p.get("tutorMoves", []) if str(m) in raw["tutorMoves"]] +
                                     [{"moveID": m, "method": "Egg", "level": None} for m in p.get("eggMoves", [])] +
                                     [{"moveID": m, "method": "Pre-evolution", "level": None} for m in p.get("prevoMoves", [])] +
                                     [{"moveID": m, "method": "Event", "level": None} for m in p.get("eventMoves", [])])})
    result = {"schemaVersion": 1, "gameVersion": "4.1", "difficulty": "Normal",
              "sourceURL": "https://dex.radicalred.net/", "sourceRevision": subprocess.check_output(["git", "-C", str(args.source), "rev-parse", "HEAD"], text=True).strip(),
              "sourceSHA256": hashlib.sha256(data_path.read_bytes()).hexdigest(),
              "species": sorted(species, key=lambda p: p["id"]),
              "types": list(raw["types"].values()),
              # The upstream site shows each localized name variant with the
              # exact same ability description. Keep descriptions parallel to
              # names so consumers can resolve a randomized name consistently.
              "abilities": [{"ID": a["ID"], "names": a["names"],
                             "descriptions": [a["description"]] * len(a["names"])}
                            for a in raw["abilities"].values()],
              "moves": [{k: m[k] for k in ["ID", "name", "power", "accuracy", "pp", "type", "split"]} for m in raw["moves"].values()],
              "normalAbilities": table("ABILITIES_NORMAL"), "normalMoves": table("MOVES_NORMAL")}
    ids = {p["id"] for p in species}
    moves = {m["ID"] for m in result["moves"]}
    # Empty TM/tutor slots map to move 0, which the website omits.
    for p in species:
        p["learnset"] = [m for m in p["learnset"] if m["moveID"] != 0]
    assert len(ids) == len(species) == 1343
    assert all(e["targetID"] in ids for p in species for e in p["evolutions"])
    assert all(m["moveID"] in moves for p in species for m in p["learnset"])
    args.output.write_text(json.dumps(result, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"Imported {len(species)} forms, {len(moves)} moves; {args.output.stat().st_size:,} bytes")


if __name__ == "__main__":
    main()
