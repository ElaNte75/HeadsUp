"""
Builds HeadsUp/KnownDurations.lua: how long the effect of an ability lasts, and where it sits (on the enemy:
a debuff, a damage over time...; or on the player: a shield, a defensive, a damage boost), per class. It is the
game's own data, from the public wago.tools tables:

  SpellName, SpellClassOptions : the names of the spells and the class they belong to
  SpellEffect                  : what a spell does (applies an aura to an enemy, triggers another spell)
  SpellMisc + SpellDuration    : how long the aura lasts

The game does not say which debuff belongs to which ability (that is in its scripts), so the link is
found like this: the debuff is a spell of the same class with the SAME NAME as the ability that applies an
aura to an enemy (Judgment -> the Judgment debuff, Rake -> the Rake debuff), or a spell the ability
triggers itself. Where that finds nothing the add-on falls back to the description of the spell, and
abilities whose debuff has another name are listed in EXTRA below.

The result is a suggestion: a talent can change a duration. Run it again after each patch:
    python tools/make_durations.py
"""
import csv
import datetime
import os
import re
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "cache")
OUT = os.path.join(HERE, "..", "HeadsUp", "KnownDurations.lua")
BASE = "https://wago.tools/db2/%s/csv"

CLASS = {
    3: "MAGE", 4: "WARRIOR", 5: "WARLOCK", 6: "PRIEST", 7: "DRUID", 8: "ROGUE", 9: "HUNTER",
    10: "PALADIN", 11: "SHAMAN", 15: "DEATHKNIGHT", 53: "DEMONHUNTER", 223: "EVOKER", 224: "MONK",
}
SKIP = re.compile(r"\[DNT\]|\(OLD\)|Off-Hand|\bDNT\b|^zz|\btest\b|deprecated|unused|\(NYI\)", re.I)
# implicit targets that mean "an enemy" (target, any, area of enemies)
ENEMY = {6, 15, 16, 25, 53}
# the kinds of effect worth following (the aura types of the game): damage over time, more damage taken from
# the caster, a slow, a stun, a root, a silence, a fear. A taunt, a dummy and the like are left out.
EFFECTS = {3: "damage over time", 53: "damage over time", 89: "damage over time", 226: "damage over time",
           271: "more damage taken", 33: "slow", 12: "stun", 26: "root", 27: "silence", 7: "fear", 5: "confused"}
# the longest effect worth tracking, in seconds, and the shortest
MAX_SECONDS = 600
MIN_SECONDS = 2
# implicit target 1 = the caster himself: an aura applied there is a buff of the player

# other abilities that put the SAME effect on the enemy (the game's data does not say so; checked by hand):
# ability -> the abilities that also start / refresh its effect. A tracker restarts its timer on any of them.
ALSO_STARTED_BY = {
    # (empty for now: Divine Toll turned out to have a debuff counter of its own in the game, next to Judgment's)
}

# abilities whose debuff has another name (ability name -> seconds, per class). Checked by hand.
EXTRA = {
    "DEATHKNIGHT": {"Howling Blast": 24, "Outbreak": 24},   # Frost Fever / Virulent Plague
}


def table(name):
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
    class_of = {int(r["SpellID"]): int(r["SpellClassSet"]) for r in table("SpellClassOptions")}
    seconds_of = {int(r["ID"]): int(r["Duration"]) for r in table("SpellDuration")}
    duration_index = {}
    for r in table("SpellMisc"):
        if r["DifficultyID"] == "0":
            duration_index[int(r["SpellID"])] = int(r["DurationIndex"])
    effects = {}
    for r in table("SpellEffect"):
        if r["DifficultyID"] in ("0", ""):
            effects.setdefault(int(r["SpellID"]), []).append(r)

    def own_seconds(spell, side):
        """The seconds the spell's own aura lasts, when it applies an aura to an enemy ("enemy": damage over time,
        more damage taken, a slow...) or to the player himself ("self": any aura); else None."""
        if side == "enemy":
            applies = any(
                r["Effect"] == "6" and int(r["EffectAura"] or 0) in EFFECTS
                and (int(r["ImplicitTarget_0"]) in ENEMY or int(r["ImplicitTarget_1"]) in ENEMY)
                for r in effects.get(spell, [])
            )
        else:
            applies = any(r["Effect"] == "6" and int(r["ImplicitTarget_0"]) == 1 for r in effects.get(spell, []))
        if not applies:
            return None
        ms = seconds_of.get(duration_index.get(spell, 0), 0)
        if ms < MIN_SECONDS * 1000 or ms > MAX_SECONDS * 1000:
            return None
        return ms / 1000.0

    # spells by (class set, name)
    by_name = {}
    for spell, class_set in class_of.items():
        name = names.get(spell, "")
        if class_set in CLASS and name and not SKIP.search(name):
            by_name.setdefault((class_set, name), []).append(spell)

    result = {}
    for (class_set, name), spells in by_name.items():
        # an effect on the enemy wins over one on the player (Judgment: the enemy takes more damage).
        # 1. a spell the ability triggers itself (the surest link); 2. a spell of the same name
        chosen = None
        for side in ("enemy", "self"):
            triggered, same_name = [], []
            for spell in spells:
                value = own_seconds(spell, side)
                if value:
                    same_name.append((value, spell))
                for r in effects.get(spell, []):
                    trigger = int(r["EffectTriggerSpell"] or 0)
                    if r["Effect"] == "64" and trigger:
                        value = own_seconds(trigger, side)
                        if value:
                            triggered.append((value, trigger))
            # (on the enemy the triggered spell is surest; for the player's buffs the most common one of that name)
            found = (triggered or same_name) if side == "enemy" else (same_name or triggered)
            if found:
                # the most common value; when they are equally common, the one of the oldest spell (lowest id)
                values = [v for v, _ in found]
                best = max(set(values), key=lambda v: (values.count(v), -min(i for x, i in found if x == v)))
                chosen = (best, side)
                break
        if not chosen:
            continue
        result.setdefault(CLASS[class_set], {})[name] = chosen
    for token, extra in EXTRA.items():
        for name, value in extra.items():
            result.setdefault(token, {})[name] = (value, "enemy")

    lines = [
        "-- HeadsUp: how long the effect of an ability lasts on an enemy (a debuff, a damage over time...),",
        "-- per class, in seconds. MADE BY tools/make_durations.py FROM THE GAME'S OWN DATA: do not edit by hand.",
        "-- Made on %s. Format: HeadsUpDurations[CLASS][\"Ability name\"] = { seconds, \"enemy\" or \"self\" }" % datetime.date.today(),
        "-- A suggestion: a talent can change a duration.",
        "",
        "HeadsUpDurations = {",
    ]
    total = 0
    for token in sorted(result):
        lines.append("    %s = {" % token)
        for name in sorted(result[token]):
            value, side = result[token][name]
            text = ("%d" % value) if value == int(value) else ("%.1f" % value)
            lines.append("        [\"%s\"] = { %s, \"%s\" }," % (name.replace("\\", "\\\\").replace("\"", "\\\""), text, side))
            total += 1
        lines.append("    },")
    lines.append("}")
    lines.append("")
    lines.append("-- Other abilities that put the same effect on the enemy: HeadsUpAlsoStartedBy[CLASS][\"Ability\"] = { \"Other ability\", ... }")
    lines.append("HeadsUpAlsoStartedBy = {")
    for token in sorted(ALSO_STARTED_BY):
        lines.append("    %s = {" % token)
        for name in sorted(ALSO_STARTED_BY[token]):
            others = ", ".join("\"%s\"" % o for o in ALSO_STARTED_BY[token][name])
            lines.append("        [\"%s\"] = { %s }," % (name, others))
        lines.append("    },")
    lines.append("}")
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print("wrote", total, "abilities in", len(result), "classes ->", os.path.normpath(OUT))


if __name__ == "__main__":
    sys.exit(main())
