"""DI2 gameplay fluids (blood / petrol / water / acid ...) -> game/data/fluids.json.

Sources (recon/RE_FLUIDS.md):
  BalancingData/EnvHazards/Fluids/DA_FluidTypeInfo_*   per fluid type, over UFluidTypeInfo's native defaults (ctor 0x141c13850)
  Core/Gameplay/EnvHazards/BP_Fluid_Droplet_*          droplet config: payload class / radius / states
  DefaultFluidManager.ini                              AFluidManager settings
  Curve_FluidConsumption                               merge reach multiplier by puddle radius
usage: python tools/build_fluids.py
"""
import configparser
import json
from pathlib import Path

ROOT = Path(r".")
J = ROOT / "extracted/json/DeadIsland/Content/DI2"
OUT = ROOT / "game/data/fluids.json"

# UFluidTypeInfo ctor 0x141c13850 (fields a type asset doesn't set).
TYPE_DEFAULTS = {
    "MinRadius": 32.0, "MaxRadius": 128.0, "VisualRadiusMultiplier": 1.4,
    "MinimumPuddleSizeForSkippingConsumption": 100.0, "SpawnDistanceRequirementWhenSkippingConsumption": 0.7,
    "bUseCurveForSpawnDistanceWhenSkippingConsmuption": False,
    "TimeIdleBeforeAutoEvaporate": -1.0, "EvaporationAreaPerSec": 32.0, "OpacityRestorationInterpolationSpeed": 2.0,
    "FlowRate": 400.0, "DecelerationPercentagePerMeter": 0.4, "FlowDirectionDegreesToleranceForConsume": 30.0,
    "VisualRadiusInterpolationSpeed": 3.33, "ImpactPointScaleMultiplier": 1.35,
    "MaxSurfaceNormalDeviationFromFlatForPoolingInDegrees": 20.0,
    "StartingDecalRadiusMultiplierIfActorIsChildFlow": 0.1, "StartingDecalRadiusMultiplierIfActorIsImpact": 0.5,
    "GibProbability": 1.0, "MinimumPuddleSizeForGibs": 1.0, "MinGibScale": 1.0, "MaxGibScale": 1.0,
    "GibAngleThreshold": 0.5, "UpdateRate": 3.0, "OpacityMultiplier": 1.0,
    "DecalSize": {"X": 4.0, "Y": 128.0, "Z": 128.0}, "MinOpacity": 0.75, "MaxOpacity": 1.0,
    "FadeInDelay": 0.0, "FadeInDuration": 0.0, "FadeOutDelay": 0.0, "FadeOutDuration": 2.0, "SpawnPriority": 1.0,
}
# FFluidSimDropletProjectileConfig ctor 0x141c0ffa0: CollidesWith {WorldStatic, WorldDynamic}.
DROPLET_DEFAULTS = {"MinUpdateInterval": 0.1, "Lifetime": 5.0, "CollidesWith": ["WorldStatic", "WorldDynamic"]}
# UStateTransmitterConfig ctor 0x141dfd640 (UFluidStateTransmitterConfig 0x141c0f720 adds only the map), recon/RE_FLUIDS.md §9.3.
STATE_CONFIG_DEFAULTS = {
    "bBeginWithStatusActive": False, "FiniteStatusLifetime": -1.0, "bIsTransmitter": True, "InitialTransmitRadius": 1.0,
    "bAddOwnerRadiusToTransmitRadius": True, "InitialTransmitTick": 1.0, "FirstTransmitDelay": 0.0,
    "bDirectedAcyclicTransmissions": False, "bIsTransmissionOrigin": False, "TransmissionOriginStrength": 1.0,
    "MaximumTransmissionDistance": 3.4e38, "bIsReceiver": True, "bAddOwnerRadiusToReceiveRadius": True,
    "AreaOfEffectClass": None, "AreaOfEffectResizePolicy": "EAreaOfEffectAutoResizePolicy::AutoResizeToOwnerCollisionRadius",
    "bRestrictRelativeVerticalAreaDimensions": False, "MaximumRelativeVerticalOffsetAllowed": 25.0,
    "MinimumRelativeVerticalOffsetAllowed": 0.0, "bUseOnlyCosmeticEffects": False, "CosmeticEffect": None,
    "DefaultParticleType": None, "OverloadTransmitRadius": 1.0, "OverloadTransmitTick": 1.0,
    "ForcedEvaporationAreaPerSecond": {},
}
# UAreaOfEffectBase ctor 0x14128f370 (recon/RE_FLUIDS.md §9.4).
AOE_DEFAULTS = {
    "EffectApplicationTickInterval": 1.0, "DelayTimeBeforeFirstEffectApplication": 0.0, "InitialEffectRadius": 100.0,
    "bAllowUseOfSuggestedInstigator": True, "MultipleOverlapRule": 0, "bRestrictRelativeVerticalAreaDimensions": False,
    "MaximumRelativeVerticalOffsetAllowed": 10.0, "MinimumRelativeVerticalOffsetAllowed": 0.0, "Strength": 1.0,
}
# AFluidSimProjectile ctor 0x14144bda0 (CollisionComp radius 5, payload 32) + AModularProjectileActor ctor 0x1415881f0
# (DIProjectileMovementComponent MaxSpeed 3000, no bounce) + UProjectileMovementComponent ctor (gravity scale 1, 0x143600047).
PROJECTILE_DEFAULTS = {"CollisionRadius": 5.0, "FluidPayloadRadius": 32.0, "MaxSpeed": 3000.0, "ProjectileGravityScale": 1.0,
                       "bShouldBounce": False, "CollidesWith": ["WorldStatic", "WorldDynamic"]}


# The fluid compose's constants (recon/RE_FLUIDS.md §6):
#   FPostProcessSettings ctor 0x143a89db0 defaults (DI2's fluid colours; Tinted* = the same values), RGBA;
#   AFluidParamsUpdateActor ctor 0x1436ff060 defaults (levels may override: UNVERIFIED).
COMPOSE = {
    "colors": {"Blood": [0.88, 0.195553, 0.146666, 0.02], "Water": [0.95, 0.95, 0.95, 0.0],
               "FuelEdge": [0.947917, 0.69714, 0.16786, 0.0], "Fuel": [0.733507, 0.338542, 0.8125, 0.0],
               "AcidEdge": [0.782943, 1.0, 0.140625, 1.0], "Acid": [0.890017, 1.0, 0.057292, 0.05]},
    # Every level's BP_BasicTimeOfDay PostProcessComponent (priority 0, unbound, in every lighting scenario) overrides
    # FuelColor / FuelEdgeColor / TintedFuel* (recon/TEST_MAP.md "Level settings: fluids"); no level overrides the rest.
    "level_colors": {"Fuel": [0.642579, 0.574219, 0.65625, 0.0], "FuelEdge": [0.642579, 0.574219, 0.65625, 0.0]},
    "fluid_params": {"DetailSize": 55.0, "AbsorbencyRampEnd": 1.0, "AbsorbencyRampStart": 0.6, "MaxFluidOnWalls": 0.9,
                     "FluidDensity": 10.0, "NormalStrength": 0.05, "NormalFlatnessWalls": 0.96,
                     "NormalFlatnessFloors": 0.993, "FluidRoughness": 0.08},
    "specular": 0.35, "sharpen": 12.0,
}


def load(p):
    return json.load(open(p, encoding="utf-8"))


def name_of(ref):
    if not ref:
        return None
    s = ref.get("ObjectName", "")
    return s.split("'")[1].split(".")[-1] if "'" in s else s


def main():
    types = {}
    for f in sorted((J / "BalancingData/EnvHazards/Fluids").glob("DA_FluidTypeInfo_*.json")):
        p = load(f)[0]["Properties"]
        t = dict(TYPE_DEFAULTS)
        for k, v in p.items():
            if isinstance(v, dict) and "ObjectName" in v:
                v = name_of(v)
            elif isinstance(v, list) and v and isinstance(v[0], dict) and "ObjectName" in v[0]:
                v = [name_of(x) for x in v]
            t[k] = v
        # The decal material's "Fluid Type" (M_FluidDecal writes it into the fluid buffer's type target; FFluidComposePS
        # selects the colour by it, recon/RE_FLUIDS.md §5-6).
        mi = next((J.parent / "DIShared").rglob(f"{t.get('DecalMaterial')}.json"), None) if t.get("DecalMaterial") else None
        if mi:
            for e in load(mi):
                for v in (e.get("Properties") or {}).get("VectorParameterValues", []):
                    if v["ParameterInfo"]["Name"] == "Fluid Type":
                        pv = v["ParameterValue"]
                        t["FluidTypeColor"] = [pv["R"], pv["G"], pv["B"], pv["A"]]
        types[f.stem.replace("DA_FluidTypeInfo_", "")] = t
    droplets = {}
    for f in sorted((J / "Core/Gameplay/EnvHazards").glob("BP_Fluid_Droplet_*.json")):
        for e in load(f):
            cfg = e.get("Properties", {}).get("Config")
            if cfg:
                pay = cfg.get("PayloadParams", {})
                droplets[f.stem.replace("BP_Fluid_Droplet_", "")] = {
                    **DROPLET_DEFAULTS, **{k: v for k, v in (cfg.get("ProjectileParams") or {}).items()},
                    "FluidTypeInfo": name_of(cfg.get("FluidTypeInfo")),
                    "FluidPayloadClass": name_of(pay.get("FluidPayloadClass")),
                    "FluidPayloadRadius": pay.get("FluidPayloadRadius", 0.0)}
    ini = configparser.ConfigParser(strict=False)
    ini.optionxform = str
    ini.read(ROOT / "extracted/raw/DeadIsland/Config/DefaultFluidManager.ini")
    manager = {k: float(v) for k, v in ini["/Script/DeadIsland.FluidManager"].items()}
    curve = [[k["Time"], k["Value"]] for k in
             load(J / "BalancingData/EnvHazards/Fluids/Curve_FluidConsumption.json")[0]["Properties"]["FloatCurve"]["Keys"]]
    data = {"_doc": "DI2 fluids (tools/build_fluids.py, recon/RE_FLUIDS.md); units cm / s",
            "gravity_z": -980.0, "types": types, "droplets": droplets, "manager": manager,
            "consumption_curve": curve}
    data["compose"] = COMPOSE
    data.update(states_aoe_projectiles(types))
    OUT.write_text(json.dumps(data, indent=1))
    print(f"{OUT}: {len(types)} types {sorted(types)}, droplets {sorted(droplets)}, state configs "
          f"{sorted(data['state_configs'])}, aoe {sorted(data['aoe'])}, projectiles {sorted(data['projectiles'])}")


def find_asset(name):
    hits = list(J.rglob(name + ".json"))
    return hits[0] if hits else None


def cdo(path):
    """(CDO properties, super class asset name or None) of a Blueprint export file."""
    props, sup = {}, None
    for e in load(path):
        if e.get("Type") == "BlueprintGeneratedClass":
            s = (e.get("Super") or e.get("SuperStruct") or {}).get("ObjectPath", "")
            sup = s.split("/")[-1].split(".")[0] if s.startswith("/Game/") else None
        elif e.get("Name", "").startswith("Default__"):
            props = e.get("Properties") or {}
    return props, sup


def bp_chain(name):
    """A Blueprint's CDO properties merged down its Blueprint parents (child wins)."""
    chain = []
    while name:
        f = find_asset(name)
        if not f:
            break
        p, name = cdo(f)
        chain.append(p)
    out = {}
    for p in reversed(chain):
        out.update(p)
    return out


def plain(v):
    if isinstance(v, dict) and "ObjectName" in v:
        return name_of(v)
    if isinstance(v, list):
        return [plain(x) for x in v]
    if isinstance(v, dict):
        return {k: plain(x) for k, x in v.items()}
    return v


def states_aoe_projectiles(types):
    """recon/RE_FLUIDS.md §9: the types' state-transmitter configs (DA_FluidEnvMessageRelay_*), their AOE classes, the
    fluid-sim projectiles (BP_*Fluid_Projectile_*) and the molotov's projectile spawn responses."""
    configs, aoes = {}, {}
    for t in types.values():
        for kv in t.get("StateTransmitterConfigs") or []:
            n = name_of(kv["Value"]) if isinstance(kv.get("Value"), dict) else kv.get("Value")
            if n and n not in configs:
                c = dict(STATE_CONFIG_DEFAULTS)
                for k, v in load(find_asset(n))[0]["Properties"].items():
                    c[k] = plain(v)
                if isinstance(c["ForcedEvaporationAreaPerSecond"], list):
                    c["ForcedEvaporationAreaPerSecond"] = {kv2["Key"].split("::")[-1]: kv2["Value"]
                                                           for kv2 in c["ForcedEvaporationAreaPerSecond"]}
                configs[n] = c
    for c in configs.values():
        a = c.get("AreaOfEffectClass")
        if a and a not in aoes:
            bp = a[:-2] if a.endswith("_C") else a
            aoes[a] = {**AOE_DEFAULTS, **plain(bp_chain(bp))}
            aoes[a].pop("UberGraphFrame", None)
    projectiles = {}
    for f in sorted((J / "Core/Gameplay/EnvHazards").glob("BP_Fluid_Projectile_*.json")):
        p = plain(bp_chain(f.stem))
        projectiles[f.stem + "_C"] = {**PROJECTILE_DEFAULTS, **{k: p[k] for k in ("FluidTypeInfo", "FluidPayloadRadius") if k in p},
                                      "PointImpactParams": p.get("PointImpactParams")}
    # BP_MolotovCocktail_Projectile: InvokeCollisionLocationResponse -> ProjectileResponseSpawnProjectile (+ creation
    # params + burst method, resolved by export index).
    mol = load(J / "Items/ThrowableWeapons/MolotovCocktail/BP_MolotovCocktail_Projectile.json")
    def ref(r):
        return mol[int(r["ObjectPath"].rsplit(".", 1)[1])].get("Properties") or {} if r else {}
    spawns = []
    for e in mol:
        if e.get("Type") == "ProjectileResponseSpawnProjectile":
            p = e.get("Properties") or {}
            spawns.append({"ProjectileType": name_of(p.get("ProjectileType")),
                           "CreationParams": plain(ref(p.get("CreationParams"))),
                           "FractionOfParentVelocityToInherit": p.get("FractionOfParentVelocityToInherit", 0.0),
                           "SpawnDirectionAxis": p.get("SpawnDirectionAxis", "EAxis::X"),
                           "CustomSpawnMethod": {"_type": "SpawnMethodBurstProjectile", **plain(ref(p.get("CustomSpawnMethod")))}})
    return {"state_configs": configs, "aoe": aoes, "projectiles": projectiles, "molotov_spawns": spawns}


if __name__ == "__main__":
    main()
