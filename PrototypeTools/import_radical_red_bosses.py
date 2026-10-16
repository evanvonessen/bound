#!/usr/bin/env python3
"""Import factual RR 4.1 Default teams from the source workbook's cached values.

No network access, sheet writes, Pokémon artwork, or game/save parsing.
The source's internal trainer-order hyperlinks supply caps and progression.
"""
import argparse
import collections
import hashlib
import json
import re
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

SOURCE_URL = "https://docs.google.com/spreadsheets/d/1ES8L4OzeJ8rCuMWFNvrDaZKArqR7Vys2ytFxjx2pbwE/edit"
TABS = ["Kanto Leaders", "Kanto Rematch", "Johto Leaders", "Rivals", "Team Rocket",
        "Mini Bosses", "Optional Bosses", "Indigo League", "Postgame"]
NS = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
STATS = ["HP", "ATK", "DEF", "SPA", "SPD", "SPE"]
SLOTS = [4, 9, 14, 19, 24, 29]


def column_index(address):
    letters = re.match(r"[A-Z]+", address).group()
    index = 0
    for letter in letters:
        index = index * 26 + ord(letter) - ord("A") + 1
    return index - 1


def read_workbook(path):
    with zipfile.ZipFile(path) as archive:
        shared = ET.fromstring(archive.read("xl/sharedStrings.xml"))
        strings = ["".join(n.itertext()) for n in shared.findall("m:si", NS)]
        workbook = ET.fromstring(archive.read("xl/workbook.xml"))
        sheets, links = {}, {}
        for index, sheet in enumerate(workbook.findall("m:sheets/m:sheet", NS), 1):
            title = sheet.attrib["name"]
            root = ET.fromstring(archive.read(f"xl/worksheets/sheet{index}.xml"))
            rows = {}
            for row in root.findall("m:sheetData/m:row", NS):
                values = {}
                for cell in row.findall("m:c", NS):
                    value = cell.find("m:v", NS)
                    if value is None:
                        continue
                    raw = value.text or ""
                    if cell.attrib.get("t") == "s":
                        raw = strings[int(raw)]
                    elif cell.attrib.get("t") == "e":
                        raise ValueError(f"Unresolved source formula: {title}!{cell.attrib['r']}: {raw}")
                    elif raw and cell.attrib.get("t", "n") == "n":
                        number = float(raw)
                        if number.is_integer():
                            raw = str(int(number))
                    values[column_index(cell.attrib["r"])] = raw.strip()
                rows[int(row.attrib["r"]) - 1] = values
            sheets[title] = rows
            links[title] = [dict(link.attrib) for link in root.findall("m:hyperlinks/m:hyperlink", NS)]
        return sheets, links


def title_case(value):
    return value.title().replace("Lt. Surge", "Lt. Surge").replace("Pkmn", "Pokémon")


def whole_number(value):
    number = float(value)
    assert number.is_integer(), f"Unexpected fractional stat: {value}"
    return int(number)


def import_workbook(path, modified_time=None):
    sheets, links = read_workbook(path)
    with zipfile.ZipFile(path) as archive:
        comments = {}
        if "xl/comments1.xml" in archive.namelist():
            root = ET.fromstring(archive.read("xl/comments1.xml"))
            comments = {note.attrib["ref"]: " ".join(t.text or "" for t in note.findall(".//m:t", NS))
                        for note in root.findall("m:commentList/m:comment", NS)}
    teams = []
    for tab in TABS:
        rows = sheets[tab]
        def cell(r, c):
            return rows.get(r, {}).get(c, "")
        headers = [r for r in sorted(rows) if cell(r, 2) and cell(r, 4)
                   and cell(r + 12, 4) == "BASE STATS" and cell(r + 13, 4) == "HP"]
        assert len(headers) == sum(cell(r, 4) == "BASE STATS" for r in rows), f"Unparsed teams in {tab}"
        for block_index, r in enumerate(headers):
            raw_label = cell(r, 2)
            parts = [p.strip() for p in raw_label.splitlines() if p.strip()]
            name = parts[-1]
            if "&" in parts:
                amp = parts.index("&")
                name = parts[amp - 1] + " & " + parts[-1]
            elif len(parts) >= 2 and parts[-2].startswith("GOON"):
                name = parts[-2] + " " + parts[-1]
            location = " · ".join(title_case(p) for p in parts[:-1])
            speed_context = None
            if cell(r + 18, 2) == "IF YOU'RE":
                level_match = re.fullmatch(r"LEVEL\s+(\d+)\s*->>?", cell(r + 19, 2))
                if not level_match:
                    raise ValueError(f"Unparsed conditional speed level in {tab} row {r + 1}")
                speed_context = f"IF YOU'RE LEVEL {level_match.group(1)}"
            annotations = []
            previous_end = headers[block_index - 1] + 20 if block_index else 0
            for rr in range(previous_end, r):
                for c, v in rows.get(rr, {}).items():
                    if c not in [2, 4] or not v or v == "IF YOU'RE" or v.startswith("LEVEL "):
                        continue
                    if c == 4 and cell(rr, 7):  # Previous team's additional speed figures.
                        continue
                    if v.startswith(("(!)", "(!!)")) or "BATTLE EFFECT:" in v or "SPEED STATS" in v:
                        annotations.append(re.sub(r"^\s*\(!+\)\s*", "", v))
            variant = next((v for v in annotations if not v.startswith("BATTLE EFFECT:")
                            and "SPEED STATS" not in v), "")
            pokemon = []
            for slot in SLOTS:
                if not cell(r, slot):
                    continue
                assert cell(r + 12, slot) == "BASE STATS", (tab, r, slot)
                stats = []
                for offset, label in enumerate(STATS, 13):
                    assert cell(r + offset, slot) == label, (tab, r, slot, label)
                    base = cell(r + offset, slot + 1)
                    ev = cell(r + offset, slot + 3)
                    stats.append({"name": label, "base": whole_number(base) if base else None,
                                  "ev": whole_number(ev) if ev else 0})
                speed = []
                block_end = headers[block_index + 1] if block_index + 1 < len(headers) else max(rows) + 1
                for rr in range(r + 19, block_end):
                    if cell(rr, slot + 3) and cell(rr, slot):
                        speed.append({"label": cell(rr, slot), "value": cell(rr, slot + 3)})
                pokemon.append({"species": cell(r, slot), "level": cell(r + 1, slot),
                                "nature": cell(r + 4, slot), "ability": cell(r + 5, slot),
                                "item": cell(r + 6, slot),
                                "moves": [cell(r + offset, slot) or "-" for offset in range(7, 11)],
                                "stats": stats, "speed": speed})
            assert pokemon and all(mon["level"] for mon in pokemon), (tab, r)
            teams.append({"id": re.sub(r"[^a-z0-9]+", "-", tab.lower()) + f"-{r + 1}",
                          "category": tab, "name": title_case(name), "location": location,
                          "sourceLabel": raw_label, "sourceRow": r + 1,
                          "variant": title_case(variant), "notes": annotations,
                          "speedContext": speed_context,
                          "levelCap": 100 if tab == "Postgame" else None,
                          "order": 1000 + len(teams), "pokemon": pokemon})
    # Exported hyperlinks point to the row immediately above the trainer header.
    # Resolve them against the actual imported row rather than matching names.
    order_rows = sheets["Trainer Order"]
    trainer_order = []
    last_cap = None
    for index, link in enumerate(links["Trainer Order"]):
        r = int(re.search(r"\d+", link["ref"]).group()) - 1
        label = order_rows.get(r, {}).get(3, "")
        raw_cap = order_rows.get(r, {}).get(5, "")
        if raw_cap:
            last_cap = whole_number(raw_cap)
        match = re.fullmatch(r"('?)(.+?)\1!\$?C\$?(\d+)", link.get("location", ""))
        assert match, link
        tab, anchor = match.group(2).replace("''", "'"), int(match.group(3))
        candidates = [t for t in teams if t["category"] == tab and anchor <= t["sourceRow"] <= anchor + 2]
        assert len(candidates) == 1, (link, candidates)
        target = candidates[0]
        target["levelCap"], target["order"] = last_cap, index
        documented_location = order_rows.get(r + 1, {}).get(3, "")
        if documented_location:
            target["location"] = title_case(documented_location)
        note = comments.get(f"F{r + 1}")
        if note:
            target["notes"].append(note)
        trainer_order.append({"name": title_case(label),
                              "location": title_case(order_rows.get(r + 1, {}).get(3, "")),
                              "levelCap": last_cap, "teamID": target["id"], "note": note})
    for team in teams:
        if team["order"] < 1000 or team["category"] == "Postgame":
            continue
        siblings = [t for t in teams if t["category"] == team["category"]
                    and t["sourceLabel"] == team["sourceLabel"] and t["order"] < 1000]
        # Alternate team variants share the fight's cap. A later progression
        # variant (e.g. post-Surge Bugsy) keeps its scaling rule without a guessed cap.
        if siblings and not any(word in team["variant"] for word in ["Post ", "Postgame"]):
            closest = min(siblings, key=lambda t: abs(t["sourceRow"] - team["sourceRow"]))
            team["levelCap"], team["order"] = closest["levelCap"], closest["order"]
            team["location"] = closest["location"]
    main = sheets["Main"]
    caps = []
    for row in main.values():
        value = row.get(4, "")
        match = re.fullmatch(r"(.+) \((\d+)\)", value)
        if match:
            caps.append({"stage": match.group(1), "level": int(match.group(2))})
    assert len(caps) == 18
    assert len(teams) == 167, f"Source coverage changed: {len(teams)} teams"
    counts = dict(collections.Counter(t["category"] for t in teams))
    workbook_sha256 = hashlib.sha256(path.read_bytes()).hexdigest()
    return {"schemaVersion": 1, "gameVersion": "4.1", "difficulty": "Default",
            "sourceTitle": "Default Mode Bosses v4.1 (with EVs) - Radical Red",
            "sourceURL": SOURCE_URL, "sourceModifiedTime": modified_time,
            "sourceSHA256": workbook_sha256, "speedContextSourceSHA256": workbook_sha256,
            "categories": TABS, "categoryCounts": counts, "levelCaps": caps,
            "trainerOrder": trainer_order, "teams": teams}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workbook", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source-modified-time")
    args = parser.parse_args()
    result = import_workbook(args.workbook, args.source_modified_time)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"teams": len(result["teams"]),
                      "pokemon": sum(len(t["pokemon"]) for t in result["teams"]),
                      "categories": result["categoryCounts"],
                      "trainerOrderEntries": len(result["trainerOrder"]),
                      "output": str(args.output)}, indent=2))
