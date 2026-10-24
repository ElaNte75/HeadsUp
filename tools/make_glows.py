"""
Builds HeadsUpAuras/KnownGlows.lua: which abilities can "light up" (proc glow), per class, and which
buffs make them light up. The data is the game's own, from the public wago.tools tables:

  SpellActivationOverlay : buff (SpellID) -> mask of the spell families to highlight
  SpellClassOptions      : spell -> its class and its spell family mask
  SpellName              : names (to skip test and duplicate entries)

A spell can light up when it is of the same class as the buff and its family mask shares a bit
with the mask of the buff. The result is a little wider than what really happens in the game (a
talent may be needed); the add-on also learns by itself which abilities really light up.

Run it again after each patch:   python tools/make_glows.py
"""
import csv
import datetime
import io
import os
import re
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "cache")
OUT = os.path.join(HERE, "..", "HeadsUpAuras", "KnownGlows.lua")
BASE = "https://wago.tools/db2/%s/csv"
MASK32 = 0xFFFFFFFF

# SpellClassSet -> class token
CLASS = {
    3: "MAGE", 4: "WARRIOR", 5: "WARLOCK", 6: "PRIEST", 7: "DRUID", 8: "ROGUE", 9: "HUNTER",
    10: "PALADIN", 11: "SHAMAN", 15: "DEATHKNIGHT", 53: "DEMONHUNTER", 223: "EVOKER", 224: "MONK",
}
# names that are not real player abilities
SKIP = re.compile(r"\[DNT\]|\(OLD\)|Off-Hand|\bDNT\b|^zz|\btest\b|deprecated|unused|\(NYI\)", re.I)


def table(name):
    """The rows of a wago.tools table (downloaded once, kept in tools/cache)."""
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, name + ".csv")
    if not os.path.exists(path):
        print("downloading", name, "...")
        request = urllib.request.Request(BASE % name, headers={"User-Agent": "HeadsUp-tools"})
        with urllib.request.urlopen(request, timeout=300) as response, open(path, "wb") as f:
            f.write(response.read())
    with open(path, encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))


def main():
    names = {int(r["ID"]): r["Name_lang"] for r in table("SpellName")}
    options = {}
    for r in table("SpellClassOptions"):
        masks = [int(r["SpellClassMask_%d" % i]) & MASK32 for i in range(4)]
        options[int(r["SpellID"])] = (int(r["SpellClassSet"]), masks)

    by_class = {}
    for r in table("SpellActivationOverlay"):
        mask = [int(r["IconHighlightSpellClassMask_%d" % i]) & MASK32 for i in range(4)]
        if not any(mask):
            continue
        aura = int(r["SpellID"])
        if aura not in options or options[aura][0] not in CLASS:
            continue
        class_set = options[aura][0]
        token = CLASS[class_set]
        for spell, (spell_set, spell_mask) in options.items():
            if spell_set != class_set or not any(spell_mask[i] & mask[i] for i in range(4)):
                continue
            name = names.get(spell, "")
            if not name or SKIP.search(name):
                continue
            by_class.setdefault(token, {}).setdefault(spell, set()).add(aura)

    lines = [
        "-- HeadsUp Auras: abilities that can light up (proc glow), per class, and the buffs that make them",
        "-- light up. MADE BY tools/make_glows.py FROM THE GAME'S OWN DATA: do not edit by hand.",
        "-- Made on %s. Format: HeadsUpAurasGlows[CLASS][ability id] = { buff id, buff id, ... }" % datetime.date.today(),
        "",
        "HeadsUpAurasGlows = {",
    ]
    total = 0
    for token in sorted(by_class):
        lines.append("    %s = {" % token)
        for spell in sorted(by_class[token]):
            auras = ", ".join(str(a) for a in sorted(by_class[token][spell]))
            lines.append("        [%d] = { %s }," % (spell, auras))
            total += 1
        lines.append("    },")
    lines.append("}")
    lines.append("")
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))
    print("wrote", os.path.normpath(OUT), "-", total, "abilities,", len(by_class), "classes")


if __name__ == "__main__":
    sys.exit(main())
