"""Pick DI2 animation clips by naming pattern and write clips.json files for merge_anims.py.

Dani (FemBerserker 1P rig): every standard attack phase, impact variants, heavies, kicks, dodges, blocks,
rebounds, throws, jumps, grapple/counter paired clips, fury, drop kick, knockback, for the bat (Medium2H
Sweeping), machete (Medium1H Slicing) and pistol classes.
Walker: locomotion, attacks, every directional hit reaction tier, stumbles, knockdowns + get-ups, launches,
recoveries, crawler reactions, status effects and the zombie side of paired grapple/counter clips.

Output: game/assets/di2/{dani,walker}/clips.json  (name -> sequence) and a list of sequences to export.
"""
import json
import re
import sys
from pathlib import Path

FILES = Path(r"extracted\files.txt")
OUT = Path(r"game\assets\di2")

DANI = [
    # (regex on sequence name, prefix to strip)
    r"A_1P_Medium2H_Sweeping_Attack_(Left_To_Right|Right_To_Left)_0[1-3]_(Antic|Attack|AttackDec|Recovery|Windup|WindupDec)",
    r"A_1P_Medium2H_Sweeping_Attack_(Up_To_Down|Down_To_Up)_[LR](_01)?_(Antic|Attack|AttackDec|Recovery)",
    r"A_1P_Medium2H_Sweeping_Attack_(Left_To_Right|Right_To_Left)_ImpactTo[LR](_AttackDec|_Recovery)?",
    r"A_1P_Medium2H_Sweeping_HeavyAttack_(Antic|Charge_Into|Charge_Loop|Charge_Lunge|Default|Head|Ground)_[LR]",
    r"A_1P_Medium2H_Sweeping_(Move_Sprint|Idle)",
    r"A_1P_Medium2H_Sweeping_Impact_(Left|Right)_(Rebound|Deflect)(_Recovery)?",
    r"A_1P_Medium2H_(Idle|Move_Walk_F|Select|Deselect|Quick_Select|Dodge_[FBLR](_Out)?|Knockback_(KickHigh|KickMid|KickLow|KickStomp|Shove)(_LeftChain)?|PlayerKnockback|Attack_Throw(_Into|_Loop|_Cancel)?|Jump_(Into|Loop|Falling_Loop|Land_Light_1m|Land_Med_3m))",
    r"A_1P_Medium1H_Slicing_Attack_(Left_To_Right|Right_To_Left)_0[1-3]_(Antic|Attack|AttackDec|Recovery|Windup|WindupDec)",
    r"A_1P_Medium1H_Slicing_Attack_(Up_To_Down|Down_To_Up)_[LR](_01)?_(Antic|Attack|AttackDec|Recovery)",
    r"A_1P_Medium1H_Slicing_Attack_(Left_To_Right|Right_To_Left)_ImpactTo[LR](_AttackDec|_Recovery)?",
    r"A_1P_Medium1H_Slicing_HeavyAttack_(Antic|Charge_Into|Charge_Loop|Charge_Lunge|Default|Head|Ground)_[LR]",
    r"A_1P_Medium1H_Slicing_Impact_(Left|Right)_(Rebound|Deflect)(_Recovery)?",
    r"A_1P_Medium1H_(Idle|Move_Walk_F|Move_Sprint|Select|Deselect|Quick_Select|Dodge_[FBLR](_Out)?|Knockback_(KickHigh|KickMid|KickLow|KickStomp|Shove)(_LeftChain)?|PlayerKnockback|PlayerHitReact|Throw(_Into|_Loop|_Cancel)?|Jump_(Into|Loop|Falling_Loop|Land_Light_1m|Land_Med_3m))",
    r"A_1P_Pistol_(Idle|Move_Walk_F|Move_Walk_F_ADS|Move_Sprint|Equip|Unequip|Quick_Select|ADS_In|ADS_Idle|ADS_Out|Shoot|Shoot_Out|Shoot_ADS|Shoot_ADS_Out|Reload|ReloadPartial|Knockback_(KickHigh|KickMid|KickLow|KickStomp)|Dodge_[FBLR](_Out)?|PlayerKnockback|Jump_(Into|Loop|Falling_Loop|Land_Light_1m|Land_Med_3m))",
    r"A_1P_Base_Skill_Blocking_(TwoHanded|OneHanded|OneHandedPistol)_(Idle|Success|PerfectBlock|Fail(_M2H)?|Transition_(FromM2H|ToM2H|FromS1H|ToS1H|FromPistol|ToPistol))",
    r"A_1P_Base_Skill_Blocking_M1H_Fail",
    r"A_1P_Base_Skill_(DropKick|GroundPound(_Into|_Loop|_Falling_Loop)?)",
    r"A_1P_Paired_Grapple_Walker_(Into|Loop_Close|Bite|Exit_Push|Exit_Death|Interrupt)",
    r"A_1P_Paired_Counter_M_2H_Sweeping_(Into|Into_B|Into_L|Into_R|Loop|Action|Kill|Push)",
    r"A_1P_Paired_Counter_M_1H_Slicing_(Into|Into_B|Into_L|Into_R|Loop|Action|Kill|Push)",
    r"A_1P_Base_Fury_(Scream|Overhead_Smash)",
    r"A_1P_Fury_(Idle|Move_Walk_F|Move_Sprint|Aimpose_F)",
    r"A_1P_Fury_Attack_(Left_To_Right|Right_To_Left)_0[1-2]_(Antic|Attack|AttackDec|Recovery)",
    r"A_1P_Carry1H_Throw_Grenade_Throw",
]

WALKER = [
    r"A_ZMB_Walker_(Combat_Idle|Calm_Idle|Alert2Combat_01|Walk_(Slow|Med|Fast)|Combat_Strafe(Lwd|Rwd|Bwd)_(Slow|Fast)|Calm_TurnOnSpot_Fast_(L90|R90|L180|R180))",
    r"A_ZMB_Walker_Attack_Swipe_(LH|RH)_(Horiz|Vert|Upward)_Attack_(Short|Med|Long)",
    r"A_ZMB_Walker_Attack_(Bite_Attack_Med|Bite_Attack_Short|Grapple_IntoMoving_Med|Grapple_Miss_Med|Lurch_Attack_IntoMoving_Med)",
    r"A_ZMB_Base_Hit_(Light|Medium|Med)_(Head|Stomach|Torso|ArmL|ArmR|LegL|LegR)_[FBLRUD](_02)?",
    r"A_ZMB_Base_Hit_Stumble_(Small|Med)_(Head|Stomach|Torso|ArmL|ArmR|LegL|LegR)_[FBLRUD]",
    r"A_ZMB_Base_Ko_(Light|Med)_(Head|Stomach|Torso|ArmL|ArmR|LegL|LegR|LegLeft|LegRight)_[FBLRUD]",
    r"A_ZMB_Base_Ko_Recovery_(Fast|Slow)_[FBLR](_NoArms)?",
    r"A_ZMB_Base_Ko_Crawler_Leg(Left|Right)_[FBLR]",
    r"A_ZMB_Base_Hit_Launch_(Torso|Stomach)_[FBLRUD]",
    r"A_ZMB_Base_Hit_Recovery_OnFeet_[FBLRUD]",
    r"A_ZMB_Walker_Crawler_(Combat_Idle_(LH|RH)_01|Walk_(Slow|Med)_F_01|Attack_(LH_SwipeR|RH_SwipeL)_01)",
    r"A_ZMB_Base_Crawler_Hit_(Light|Med)_(LH|RH)_(Head|Torso|LegL|LegR|Legs)_[FBLRU]_01",
    r"A_ZMB_Base_StatusFX_(Disorientated_(Into|Idle_01|End)|Electrocuted_(Start|Loop|End)(_01)?)",
    r"A_ZMB_Paired_Grapple_Walker_(Into|Loop_Close|Bite|Exit_Push|Exit_Death)",
    r"A_ZMB_Walker_Paired_Counter_M_2H_Sweeping_(Into|Into_B|Into_L|Into_R|Loop|Action|Kill|Push)",
    r"A_ZMB_Walker_Paired_Counter_M_1H_Slicing_(Into|Into_B|Into_L|Into_R|Loop|Action|Kill|Push)",
]


def short(seq: str) -> str:
    s = re.sub(r"^A_(1P|ZMB)_", "", seq)
    s = s.replace("Walker_", "").replace("Base_", "")
    return s.lower()


def pick(patterns, names):
    out = {}
    for pat in patterns:
        rx = re.compile("^" + pat + "$")
        for n in names:
            if rx.match(n):
                out[short(n)] = n
    return out


def main():
    names = sorted({Path(l.strip()).stem for l in FILES.read_text().splitlines()
                    if l.endswith(".uasset") and "/Animation/" in l and Path(l.strip()).stem.startswith("A_")})
    sets = {"dani": pick(DANI, names), "walker": pick(WALKER, names)}
    for k, clips in sets.items():
        old = OUT / k / "clips.json"
        merged = json.loads(old.read_text()) if old.exists() else {}
        # Keep the hand-named clips the game already uses, add the full catalogue under DI2-style names.
        merged.update(clips)
        old.write_text(json.dumps(merged, indent=1))
        print(f"{k}: {len(clips)} catalogue clips, {len(merged)} total")
    every = sorted({v for c in sets.values() for v in c.values()})
    Path(r"extracted\clip_sequences.txt").write_text("\n".join(every))
    print("sequences:", len(every))


if __name__ == "__main__":
    sys.exit(main())
