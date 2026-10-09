"""DI2 damage-effects propagation data -> game/data/body_proxies.json (recon/RE_PROPAGATION.md).

- BodyProxy_ZombieStandard (BodyProxyTreeAsset): every BodyNode with its bone (the parent BodyProxy's BoneName),
  its bone-local transform (node Transform x proxy Transform, as UDamageEffectsPropagationComponent's node builder
  0x141206130 composes them) converted to glTF bone space, its BodyNodeData (e.g. Size) and its Links (made
  symmetric, as BuildBodyNodes 0x1412026e0 does).
- The DamageEffectsPropagationComponent config on BP_Base_AI (effect name, CE, CE parameters, CosmeticEffect-
  Threshold, PropagationSpeed expression list).
Personal-use research data; nothing here is published.
usage: python tools/build_body_proxies.py
"""
import json
import math
import re
from pathlib import Path

ROOT = Path(r".")
J = ROOT / "extracted/json/DeadIsland/Content/DI2"


def ref_name(r):
    s = (r or {}).get("ObjectName", "")
    m = re.search(r"'([^']+)'", s)
    return m.group(1) if m else s


def qmul(a, b):
    """Hamilton product (x, y, z, w)."""
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (aw * bx + ax * bw + ay * bz - az * by, aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw, aw * bw - ax * bx - ay * by - az * bz)


def qrot(q, v):
    x, y, z, w = q
    p = qmul(qmul(q, (v[0], v[1], v[2], 0.0)), (-x, -y, -z, w))
    return p[:3]


def ue_xf(t):
    t = t or {}
    r, tr = t.get("Rotation", {}), t.get("Translation", {})
    q = (r.get("X", 0.0), r.get("Y", 0.0), r.get("Z", 0.0), r.get("W", 1.0))
    n = math.sqrt(sum(c * c for c in q)) or 1.0
    return tuple(c / n for c in q), (tr.get("X", 0.0), tr.get("Y", 0.0), tr.get("Z", 0.0))


def compose(child, parent):
    """UE FTransform child * parent (child expressed in parent space): q = qp * qc, t = qp(tc) + tp."""
    qc, tc = child
    qp, tp = parent
    rt = qrot(qp, tc)
    return qmul(qp, qc), (rt[0] + tp[0], rt[1] + tp[1], rt[2] + tp[2])


def to_gl(xf):
    """UE bone-local -> glTF bone-local (tools/build_viscera_parts.py gl_pos / gl_quat): (x, z, y) m, (x, z, y, -w)."""
    q, t = xf
    return {"t": [round(t[0] * 0.01, 6), round(t[2] * 0.01, 6), round(t[1] * 0.01, 6)],
            "q": [round(q[0], 7), round(q[2], 7), round(q[1], 7), round(-q[3], 7)]}


def main():
    tree = json.loads((J / "Art/Characters/ZombieMale/BodyProxy_ZombieStandard.json").read_text(encoding="utf-8"))
    proxies, nodes = {}, {}
    for e in tree:
        key = f"{e['Name']}"
        outer = ref_name(e.get("Outer")) if e.get("Outer") else ""
        if e.get("Type") == "BodyProxy":
            proxies[e["Name"]] = e
        elif e.get("Type") == "BodyNode":
            nodes[(outer, e["Name"]) if outer else ("", e["Name"])] = e
    # Nodes are referenced as 'Tree:Proxy.Node' or 'Tree:Node'; key them the same way.
    by_ref = {}
    for e in tree:
        if e.get("Type") != "BodyNode":
            continue
        outer = e.get("Outer")
        prefix = ""
        if outer:
            m = re.search(r"'([^']+)'", outer.get("ObjectName", ""))
            o = m.group(1) if m else ""
            prefix = (o.split(":", 1)[1] + ".") if ":" in o else ""
        by_ref[f"BodyProxy_ZombieStandard:{prefix}{e['Name']}"] = e
    order = list(by_ref.keys())
    out_nodes = []
    for ref in order:
        e = by_ref[ref]
        p = e.get("Properties", {})
        proxy = proxies.get(ref_name(p.get("Parent")).split(":")[-1], {})
        pp = proxy.get("Properties", {})
        local = compose(ue_xf(p.get("Transform")), ue_xf(pp.get("Transform")))
        links = [order.index(ref_name(l)) for l in p.get("Links", []) if ref_name(l) in by_ref]
        out_nodes.append({"name": p.get("Name", e["Name"]), "ref": ref, "bone": pp.get("BoneName", ""),
                          "gl": to_gl(local), "data": {d["Name"]: d.get("FloatData", 0.0) for d in p.get("BodyNodeData", [])},
                          "links": links})
    # BuildBodyNodes makes every link two-way.
    for i, n in enumerate(out_nodes):
        for j in n["links"]:
            if i not in out_nodes[j]["links"]:
                out_nodes[j]["links"].append(i)
    ai = json.loads((J / "Core/AI/BP_Base_AI.json").read_text(encoding="utf-8"))
    comp = next(e for e in ai if e.get("Type") == "DamageEffectsPropagationComponent")["Properties"]
    effects = []
    for fx in comp.get("Effects", []):
        effects.append({"name": fx["Name"], "enabled": fx.get("bEnabled", True), "ce": ref_name(fx.get("CosmeticEffect")),
                        "params": {k["Key"]: k["Value"] for k in fx.get("CosmeticEffectParameters", [])},
                        "threshold": fx.get("CosmeticEffectThreshold", 0.5),
                        "speed": [[s["Expression"]["Expression"], s["Value"]] for s in fx.get("PropagationSpeed", [])]})
    dest = ROOT / "game/data/body_proxies.json"
    dest.write_text(json.dumps({"BodyProxy_ZombieStandard": {"nodes": out_nodes},
                                "propagation": {"tree": ref_name(comp.get("BodyProxyTree")), "effects": effects}},
                               indent=1), encoding="utf-8")
    print(f"{len(out_nodes)} body nodes, {len(effects)} propagation effects -> {dest}")


if __name__ == "__main__":
    main()
