"""Reference implementation of DI2's dismember / bone-break / clear / soft-influence / rupture logic, transcribed
literally from the decompiled shipping exe and DXBC (see recon/RE_DISMEMBER.md for addresses and derivations).
Pure python, no dependencies; the port (Rust/Godot) should mirror these functions 1:1.

Conventions (UE4.27): FMatrix rows, row vectors (p' = p . M), row 3 = translation. Units cm. "Ref space" =
component space of the reference (bind) pose. Section bits = material slot index (UDIEngineMaterialMasks).
Personal-use research; nothing here is shipped.

Run `python dismember_ref.py --selftest` for a sanity check on the Walker's sockets and skeleton (extracted JSON)."""
import json
import math
import struct
import sys

# ---------------------------------------------------------------------------------------------------------------
# small FMatrix helpers (UE semantics)
# ---------------------------------------------------------------------------------------------------------------
IDENTITY = [[1.0, 0, 0, 0], [0, 1.0, 0, 0], [0, 0, 1.0, 0], [0, 0, 0, 1.0]]


def mmul(a, b):
    """UE FMatrix operator* : (a*b)[i][j] = sum_k a[i][k] b[k][j] (apply a, then b)."""
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def det3(m):
    return (m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
            + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]))


def inverse(m):
    """FUN_140a0f420 (FMatrix::Inverse): identity when rows 0..2 are all ~0, else the full 4x4 inverse."""
    if all(abs(m[r][c]) <= 1e-8 for r in range(3) for c in range(3)):
        return [row[:] for row in IDENTITY]
    # general 4x4 inverse (Gauss-Jordan); matches UE's cofactor inverse up to float rounding
    a = [row[:] + [1.0 if i == j else 0.0 for j in range(4)] for i, row in enumerate(m)]
    for c in range(4):
        p = max(range(c, 4), key=lambda r: abs(a[r][c]))
        a[c], a[p] = a[p], a[c]
        piv = a[c][c]
        if abs(piv) < 1e-30:
            return [row[:] for row in IDENTITY]
        a[c] = [v / piv for v in a[c]]
        for r in range(4):
            if r != c:
                f = a[r][c]
                a[r] = [vr - f * vc for vr, vc in zip(a[r], a[c])]
    return [row[4:] for row in a]


def norm(v):
    return math.sqrt(sum(x * x for x in v))


def safe_normal(v):
    """FVector::GetSafeNormal (as inlined in DI2): unchanged if |v|^2 == 1, zero if |v|^2 < 1e-8, else v/|v|."""
    s = v[0] * v[0] + v[1] * v[1] + v[2] * v[2]
    if s == 1.0:
        return list(v)
    if s < 1e-8 or not math.isfinite(s):
        return [0.0, 0.0, 0.0]
    k = 1.0 / math.sqrt(s)
    return [v[0] * k, v[1] * k, v[2] * k]


def unit_axis(m, axis):
    """FUN_140a0e080 GetUnitAxis: axis 1=X (row0), 2=Y (row1), 3=Z (row2)."""
    return safe_normal(m[axis - 1][:3])


def cross(a, b):
    return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def xform_vec(v, m):
    """vector (w=0) through m (row vector convention)."""
    return [v[0] * m[0][j] + v[1] * m[1][j] + v[2] * m[2][j] for j in range(3)]


def xform_pos(p, m):
    return [p[0] * m[0][j] + p[1] * m[1][j] + p[2] * m[2][j] + m[3][j] for j in range(3)]


def quat_from_rotator(pitch, yaw, roll):
    """FRotator::Quaternion (UE4.27), degrees."""
    r = math.pi / 180.0 / 2.0
    sp, cp = math.sin(pitch * r), math.cos(pitch * r)
    sy, cy = math.sin(yaw * r), math.cos(yaw * r)
    sr, cr = math.sin(roll * r), math.cos(roll * r)
    return (cr * sp * sy - sr * cp * cy, -cr * sp * cy - sr * cp * sy, cr * cp * sy - sr * sp * cy,
            cr * cp * cy + sr * sp * sy)


def transform_matrix(q, t, s=(1.0, 1.0, 1.0)):
    """FTransform::ToMatrixWithScale (rows scaled by Scale3D)."""
    x, y, z, w = q
    x2, y2, z2 = x + x, y + y, z + z
    xx, xy, xz = x * x2, x * y2, x * z2
    yy, yz, zz = y * y2, y * z2, z * z2
    wx, wy, wz = w * x2, w * y2, w * z2
    return [[(1 - (yy + zz)) * s[0], (xy + wz) * s[0], (xz - wy) * s[0], 0.0],
            [(xy - wz) * s[1], (1 - (xx + zz)) * s[1], (yz + wx) * s[1], 0.0],
            [(xz + wy) * s[2], (yz - wx) * s[2], (1 - (xx + yy)) * s[2], 0.0],
            [t[0], t[1], t[2], 1.0]]


def rotation_matrix(pitch, yaw, roll, loc=(0.0, 0.0, 0.0)):
    """FRotationTranslationMatrix (rows = X, Y, Z axes)."""
    m = transform_matrix(quat_from_rotator(pitch, yaw, roll), loc)
    return m


# ---------------------------------------------------------------------------------------------------------------
# 1. Bone topology (USkeletalMesh PostLoad 0x143ada2d0 -> 0x143adbb30 / 0x143ae13c0; read by 0x143ad3870)
# ---------------------------------------------------------------------------------------------------------------
BRANCH_ROOTS = {"clavicle_l": 2, "clavicle_r": 4, "thigh_l": 8, "thigh_r": 16, "neck_01": 32}


def bone_topology(names, parents):
    """Per bone: (depth u16, branch_mask u16, flagged byte, break_bone int). Literal port of the recursion:
    root depth 0, mask = table or 1; a child gets depth+1 unless an ancestor (or the parent itself) is a
    'twist'/'Volume'/'head' bone ('head' stops the increment but does not set the flag); mask inherits unless the
    inherited mask < 2 and the bone is a branch root. break_bone = first child (bone order) without the flag."""
    n = len(names)
    children = [[] for _ in range(n)]
    for i, p in enumerate(parents):
        if p >= 0:
            children[p].append(i)
    depth, mask, flag = [0] * n, [1] * n, [False] * n

    def visit(i, d, m, f):
        if m < 2:
            m = BRANCH_ROOTS.get(names[i], m)
        mask[i], depth[i] = m, d
        if "twist" in names[i] or "Volume" in names[i]:   # strstr, case-sensitive
            flag[i] = True
            f = True
        if "head" in names[i]:
            f = True
        for c in children[i]:
            visit(c, d + (0 if f else 1), m, f)

    for r in [i for i, p in enumerate(parents) if p < 0]:
        m = BRANCH_ROOTS.get(names[r], 1)
        mask[r], depth[r] = m, 0
        f = False
        if "twist" in names[r] or "Volume" in names[r]:
            flag[r] = True
            f = True
        if "head" in names[r]:
            f = True
        for c in children[r]:
            visit(c, 0 + (0 if f else 1), m, f)
    brk = []
    for i in range(n):
        b = -1
        for c in children[i]:
            if not flag[c]:
                b = c
                break
        brk.append(b)
    return [{"depth": depth[i], "branch": mask[i], "flag": flag[i], "break_bone": brk[i]} for i in range(n)]


# ---------------------------------------------------------------------------------------------------------------
# 2. Safe-region placement (0x140a05050, candidate 0x140a06270, safe region matrix 0x140a05c90)
# ---------------------------------------------------------------------------------------------------------------
CVAR_SAFE_REGION_OFFSET = 50.0    # r.Splatter.SafeRegionMatrixOffset  "Safe region matrix offset (after plane constraint)"
CVAR_SAFE_REGION_SCALE = 1.333    # r.Splatter.SafeRegionMatrixScale   "Safe region matrix scale for diagonal cuts"


def safe_region_matrix(scaled_socket_ref, use_cvars):
    """0x140a05c90: SafeRegionMatrix = inverse(P . M), M = socket matrix WITH scale in ref space."""
    m = scaled_socket_ref
    a = max(math.sqrt(m[0][0] ** 2 + m[0][1] ** 2 + m[0][2] ** 2), 1e-5)
    s = (1.0 / a) * 1000.0
    p = [[s, 0.0, 0.0, 0.0], [0.0, 1.0, 0.0, 0.0], [0.0, 0.0, 1.0, 0.0], [1.0 - s, 0.0, 0.0, 1.0]]
    if use_cvars:
        p[3][0] = CVAR_SAFE_REGION_OFFSET * (1.0 / a) + (1.0 - s)
        p[1][1] *= CVAR_SAFE_REGION_SCALE
        p[2][2] *= CVAR_SAFE_REGION_SCALE
    return inverse(mmul(p, m))


def evaluate_candidate(frame_ref, ref_bone, socket):
    """0x140a06270. frame_ref = decal frame in ref space (rows X, Y, Z, origin); ref_bone = composed ref-pose
    matrix of the socket's bone; socket = dict(loc, rot(pitch,yaw,roll), scale, branch_mask).
    Returns dict(frame=4x4 [G, N, H, O], safe_region=4x4, branch_mask, score)."""
    q = socket["quat"] if "quat" in socket else quat_from_rotator(*socket["rot"])
    sx, sy, sz = socket["scale"]
    w_scaled = mmul(transform_matrix(q, socket["loc"], (sx, sy, sz)), ref_bone)    # fStack_158..
    u = mmul(transform_matrix(q, socket["loc"]), ref_bone)                         # fStack_1a8.. (no scale)
    uinv = inverse(u)
    dx = safe_normal(xform_vec(unit_axis(frame_ref, 1), uinv))
    n0 = safe_normal(xform_vec(unit_axis(frame_ref, 2), uinv))     # decal Y in socket space = initial normal
    dz = safe_normal(xform_vec(unit_axis(frame_ref, 3), uinv))
    o = xform_pos(frame_ref[3][:3], uinv)
    b2, c2 = sy * sy, sz * sz
    if sy <= sz:
        f = math.sqrt(c2 - b2)
        f1, f2 = (0.0, 0.0, f), (0.0, 0.0, -f)
    else:
        g = math.sqrt(b2 - c2)
        f1, f2 = (0.0, g, 0.0), (0.0, -g, 0.0)
    n = list(n0)
    if abs(n[0]) < 0.001:                                  # nudge a plane parallel to the socket X axis
        n[0] += 0.05
        l2 = n[0] * n[0] + n[1] * n[1] + n[2] * n[2]
        if l2 > 1e-8:
            k = 1.0 / math.sqrt(l2)
            n = [n[0] * k, n[1] * k, n[2] * k]
    t = dot(o, n) / n[0]                                   # plane meets the socket X axis at (t,0,0)
    if abs(t) > sx * 0.95:
        t = math.copysign(1.0, t) * sx * 0.95 if t != 0 else 0.0
    nn, g_axis, h_axis = list(n), dx, dz                   # defaults when no end-cap correction happens
    r = math.sqrt(n[2] * n[2] + n[1] * n[1])
    corrected = False
    if r > 1e-8:
        ey, ez = n[2] / r, -n[1] / r
        w = [ey * n[2] - ez * n[1], ez * n[0], -(ey * n[0])]      # (r, ez*nx, -ey*nx): socket X projected in plane
        l2 = w[0] ** 2 + w[1] ** 2 + w[2] ** 2
        if l2 > 1e-8:
            k = 1.0 / math.sqrt(l2)
            w = [w[0] * k, w[1] * k, w[2] * k]
        ends = [(-sx, 0.0, 0.0), (sx, 0.0, 0.0)]
        e = ends[1] if t > 0.5 else ends[0]
        s = (e[0] - t) / w[0]
        qz, qy = w[2] * s, w[1] * s
        ib2, ic2 = 1.0 / b2, 1.0 / c2
        bq = (qz + qz) * ez * ic2 + (qy + qy) * ey * ib2
        disc = bq * bq - ((qz * qz * ic2 + qy * qy * ib2) - 1.0) * (ez * ez * ic2 + ey * ey * ib2) * 4.0
        if disc > 0.0:                                     # the plane leaves through the end-cap ellipse: tilt it
            corrected = True
            v = safe_normal([(t + w[0] * s) - e[0], qy - e[1], qz - e[2]])
            kk = max(math.sqrt(v[2] * v[2] * ic2 + v[1] * v[1] * ib2), 0.0001)
            v = [v[0] / kk, v[1] / kk, v[2] / kk]
            prim = [v[0] + e[0], v[1] + e[1], v[2] + e[2]]  # point on the end-cap ellipse rim
            d1 = safe_normal([f1[0] - v[0], f1[1] - v[1], f1[2] - v[2]])
            d2 = safe_normal([f2[0] - v[0], f2[1] - v[1], f2[2] - v[2]])
            my = (d2[1] + d1[1]) * -0.5
            mz = (d2[2] + d1[2]) * 0.5
            nn = safe_normal([my * prim[1] - prim[2] * mz, -(my * (prim[0] - t)), mz * (prim[0] - t)])
            g_axis = safe_normal([mz * nn[2] - my * nn[1], my * nn[0], (d2[2] + d1[2]) * -0.5 * nn[0]])
            # decompile: H = (G.z*N.y - G.y*N.z, G.x*N.z - G.z*N.x, G.y*N.x - G.x*N.y) -> N x G
            h_axis = safe_normal([g_axis[2] * nn[1] - g_axis[1] * nn[2], g_axis[0] * nn[2] - g_axis[2] * nn[0],
                                  g_axis[1] * nn[0] - g_axis[0] * nn[1]])
    sgn = -1.0 if nn[0] >= 0.0 else 1.0                    # final normal points to socket -X
    nn = [nn[0] * sgn, nn[1] * sgn, nn[2] * sgn]
    pen = 1.0 - abs(dot(o, n0) - t * n0[0]) * 0.2
    pen = min(max(pen, 0.0), 1.0)
    align = min(abs(dot(nn, n0)), 1.0)
    score = align ** 4 * 0.6666667 + pen * 0.33333334
    frame = [xform_vec(g_axis, u) + [0.0], xform_vec(nn, u) + [0.0], xform_vec(h_axis, u) + [0.0],
             [u[3][0] + t * u[0][0], u[3][1] + t * u[0][1], u[3][2] + t * u[0][2], 1.0]]
    return {"frame": frame, "safe_region": safe_region_matrix(w_scaled, socket.get("branch_mask", 0) > 0),
            "branch_mask": socket.get("branch_mask", 0), "score": score, "t": t, "corrected": corrected}


def decal_frame_from_rotator(loc, pitch, yaw, roll):
    """SplatterDecal 0x140a161a0: frame rows = (R.Y, -R.Z, -R.X, location)."""
    r = rotation_matrix(pitch, yaw, roll)
    x, y, z = unit_axis(r, 1), r[1][:3], safe_normal(r[2][:3])
    yy = cross([-z[0], -z[1], -z[2]], [-x[0], -x[1], -x[2]])
    return [yy + [0.0], [-z[0], -z[1], -z[2], 0.0], [-x[0], -x[1], -x[2], 0.0], list(loc) + [1.0]]


def place_dismember(decal_frame_world, bone_now, ref_bone, sockets, reference_pose=False):
    """0x140a05050. Returns the fields of the second pending decal, or None (no region socket => no edit).
    bone_now = GetBoneMatrix (world) of the hit bone; ref_bone = its composed ref-pose matrix.
    sockets = list for '<bone>_safe_region', '_1', '_2' ... (Dismember) or '<bone>_break_region', ... (BoneBreak)."""
    if not sockets:
        return None
    cur = ref_bone if reference_pose else bone_now
    t_w2r = mmul(inverse(cur), ref_bone)                    # +0x1c0: world -> ref-pose space via the hit bone
    frame_ref = mmul(decal_frame_world, t_w2r)
    best, best_score = None, -1.0
    for s in sockets:
        c = evaluate_candidate(frame_ref, ref_bone, s)
        if best_score < c["score"]:
            best, best_score = c, c["score"]
    n = safe_normal(best["frame"][1][:3])
    by = ref_bone[1][:3]                                    # unnormalised ref bone Y
    z = safe_normal(cross(by, best["frame"][1][:3]))
    x = safe_normal(cross(best["frame"][1][:3], z))
    nrm = best["frame"][1][:3]
    frame = [x + [0.0], list(nrm) + [0.0], z + [0.0], best["frame"][3][:3] + [1.0]]
    bx = unit_axis(ref_bone, 1)
    byn = safe_normal(by)
    if dot(bx, n) < 0.0:
        bx, byn = [-v for v in bx], [-v for v in byn]
    bone_matrix = [byn + [0.0], bx + [0.0], ref_bone[2][:], ref_bone[3][:]]
    return {"frame": frame,                 # +0x80 and +0xC0 (cut frame, ref space, rigid); Y = cut normal
            "decal_matrix": inverse(frame),  # c_DecalMatrix used by GeometryIndicesCS/BreakCS (decal y = distance)
            "bone_matrix": bone_matrix,     # +0x100 (c_BoneMatrix: compiled out of the shipping shaders)
            "bone_now": cur, "ref_bone": ref_bone, "world_to_ref": t_w2r,   # +0x140, +0x180, +0x1C0
            "safe_region": best["safe_region"],                               # +0x280
            "region_branch_mask": best["branch_mask"],                        # +0x2D8
            "reference_pose": True, "score": best["score"], "t": best["t"], "corrected": best["corrected"]}


# ---------------------------------------------------------------------------------------------------------------
# 3. GPU: FSplatterGeometryIndicesCS_FourBone (Global 939) and FSplatterBreakCS (Global 904)
# ---------------------------------------------------------------------------------------------------------------
def _plane_d(p, dm):
    return p[0] * dm[0][1] + p[1] * dm[1][1] + p[2] * dm[2][1] + dm[3][1]


def _in_safe_region(p, sr):
    q = xform_pos(p, sr)
    return abs(q[0]) < 1.0 and abs(q[1]) < 1.0 and abs(q[2]) < 1.0


def classify_triangle(verts, decal_matrix, safe_region, target, topo, binary):
    """'body' (code 3), 'limb' (code 0) or 'drop' (codes 1, 2) for `classify_code`."""
    return {3: "body", 0: "limb"}.get(classify_code(verts, decal_matrix, safe_region, target, topo, binary), "drop")


def classify_code(verts, decal_matrix, safe_region, target, topo, binary):
    """GeometryIndicesCS per triangle. verts: 3 x (bind_pos, bones[4] (section-local), weights[4] (0..1, 8-bit)).
    target = (x: section-local hit bone or -1, y: depth, z: branch mask, w unused). topo[section_local_bone] =
    (depth, branch). Returns 'body' (kept, front of the section's index range), 'limb' (packed at the end) or
    'drop' (straddles the cut inside the safe region / at the target bone)."""
    t1, t2, fill = (0.0, 0.0, 0) if binary else (0.1, 0.24, 255)
    tx, ty, tz, _ = target
    inside_sr = all(_in_safe_region(v[0], safe_region) for v in verts) and tz != 0 and not binary
    in_branch = True
    any_primary_target, any_target = False, False
    deeper = False
    for pos, bones, wts in verts:
        br = [(topo[b][1] if w > t2 else fill) for b, w in zip(bones, wts)]
        hit = [((br_ & tz) != 0) for br_ in br]
        in_branch = in_branch and (any(hit) if binary else all(hit))
        sig = [w > t1 for w in wts]
        tgt = [s and b == tx for s, b in zip(sig, bones)]
        any_primary_target |= tgt[0]
        any_target |= any(tgt)
        dep = [(topo[b][0] if s else 0) for s, b in zip(sig, bones)]
        deeper |= any(ty < d for d in dep)                 # unsigned compare in the shader
    candidate = inside_sr or in_branch
    touch = 0 if ((not candidate and not any_primary_target) or tx == -1) else int(any_target)
    sr_or_target = inside_sr or bool(touch)
    limb_tri = candidate and deeper and not sr_or_target
    if sr_or_target:
        return 0 if binary else sum(1 for v in verts if _plane_d(v[0], decal_matrix) < 0.0)
    return 0 if limb_tri else 3


def break_vertex(pos, bones, wts, decal_matrix, target, topo, binary):
    """BreakCS per vertex (run once per vertex per pass). Returns new (bones, wts) or None (unchanged).
    target = (x: section-local broken bone, y: its depth, z: branch mask, w: section-local break child bone)."""
    t_hit, t_br, fill = (0.0, 0.0, 0) if binary else (0.1, 0.24, 255)
    tx, ty, tz, tw = target
    d = _plane_d(pos, decal_matrix)
    hit = [(((topo[b][1] if w > t_br else fill) & tz) != 0) for b, w in zip(bones, wts)]
    affected = any(hit) if binary else all(hit)
    if not (affected and d >= 0.0):
        return None
    sig = [w > t_hit for w in wts]
    on_target = any(s and b == tx for s, b in zip(sig, bones)) and tx != -1
    dep = [(topo[b][0] if s else 0) for s, b in zip(sig, bones)]
    same_depth = any(dv == ty for dv in dep)
    if not (on_target or same_depth):
        return None
    ramp = min(max(d * 0.1, 0.0), 1.0)                     # 10 cm ramp beyond the break plane
    total = sum(wts)
    red = [ramp * (1.0 if ty >= dep[k] else 0.0) for k in range(3)]
    nw = [wts[0] * (1 - red[0]), wts[1] * (1 - red[1]), wts[2] * (1 - red[2]), ramp]
    s = sum(nw)
    nw = [x * (total / s) for x in nw] if s else nw
    nw = [math.floor(min(x, 1.0) * 255.0) / 255.0 for x in nw]   # ftou(min(w,1)*255)
    return [bones[0], bones[1], bones[2], tw], nw


def radial_decal_matrix(cut_frame, uv_scale):
    """DecalMatrix of the radial stamp: inverse(cut frame with rows 0, 1 scaled by UVScale/2)."""
    m = [r[:] for r in cut_frame]
    for r in (0, 1):
        m[r] = [m[r][0] * uv_scale * 0.5, m[r][1] * uv_scale * 0.5, m[r][2] * uv_scale * 0.5, m[r][3]]
    return inverse(m)


def _sat(x):
    return min(max(x, 0.0), 1.0)


def radial_coords(p, radial_dm, safe_region):
    """FSplatterPS_OneElement_Radial (DeadIsland 1943) / FSplatterDeformMeshCS p82 (Global 926), shared part.
    Returns (w, (u, v)): y = axial (+-1 at +-UVScale/2 cm from the cut), (s.y, s.z) = region cross-section.
    At r == 0 the shaders compute s.z * rsqrt(0) = 0 * inf = NaN and saturate(NaN) = 0, so u = 0 there."""
    y = _plane_d(p, radial_dm)
    s = xform_pos(p, safe_region)
    r2 = s[1] * s[1] + s[2] * s[2]
    r = math.sqrt(r2)
    w = (1.0 if abs(y) < 1.0 else 0.0) * (1.0 - _sat(4.0 * (r - 1.0)))
    u = _sat((s[2] / r) * 0.5 + 0.5) if r > 0.0 else 0.0
    v = _sat(y * 0.5 + 0.5)
    return w, (u, v)


def radial_stamp(p_bind, cut_frame, safe_region, uv_scale):
    """DismemberWithDecal / BoneBreakWithDecal wound stamp geometry: (w, (u, v)) for a bind-pose position."""
    return radial_coords(p_bind, radial_decal_matrix(cut_frame, uv_scale), safe_region)


def radial_texel(p, radial_dm, safe_region, elem, deform_len, sample_dif, sample_disp):
    """FSplatterPS_OneElement_Radial (DeadIsland 1943), one texel whose bind-pose position is p.
    elem: ScaleVec (z < 0 ApplyMin, w < 0 ApplyMax), WoundScale (w > 0: wound R * 3/DEFORM0), FXScale, RangeParams
    (InputMinimum, InputRange). deform_len = |Deform.xyz| of the texel's vertex (VS: DEFORM0 = max(1, len)).
    sample_dif / sample_disp(u, v) -> RGBA (bilinear). Returns (SV_Target0, SV_Target1), or None when w == 0 (the
    PS writes 0 to both: nothing, no coverage)."""
    w, (u, v) = radial_coords(p, radial_dm, safe_region)
    if w == 0.0:
        return None
    sv, ws, fx, rg = elem["ScaleVec"], elem["WoundScale"], elem["FXScale"], elem["RangeParams"]
    t0, t1 = sample_dif(u, v), sample_disp(u, v)
    d = [fx[c] * ((t0[c] - rg[0]) / rg[1]) * w for c in range(4)]
    wd = [ws[c] * ((t1[c] - rg[0]) / rg[1]) * w for c in range(3)]
    if ws[3] > 0.0:
        wd[0] *= 3.0 / max(1.0, deform_len)
    o1 = wd + [1.0]
    o0 = d
    if sv[2] < 0.0:
        o0, o1 = [min(0.0, x) for x in d], [min(0.0, x) for x in o1]
    if sv[3] < 0.0:
        o0, o1 = [max(0.0, x) for x in d], [max(0.0, x) for x in wd + [1.0]]
    return o0, o1


def radial_vertex_depth(p, radial_dm, safe_region, elem, depth, disp_r_point):
    """FSplatterDeformMeshCS p82 (Global 926: RADIAL, REFERENCE_POSE), one vertex: the new Deform.w (before the
    f16 store). disp_r_point(u, v) = DisplacementTexture.R loaded at texel (uint)(uv * size), mip 0. No deform
    normalisation (DeformParams.x is not read)."""
    w, (u, v) = radial_coords(p, radial_dm, safe_region)
    sv, rg, dp = elem["ScaleVec"], elem["RangeParams"], elem["DeformParams"]
    val = ((disp_r_point(u, v) - rg[0]) / rg[1]) * sv[1]
    vw = val * w
    mn = (1.0 - vw) if dp[1] < 0.0 else vw
    val = mn if sv[2] < 0.0 else dp[1] * vw
    s = val * 1.11111116
    if sv[3] < 0.0:
        return _sat(max(s, depth))
    if sv[2] < 0.0:
        return _sat(min(s, depth))
    return _sat(val * 1.11111116 + depth)


# ---------------------------------------------------------------------------------------------------------------
# 3b. Clears (RT: 0x140a12a40 + FSplatterClearPS Global 1877; vertex: FSplatterDeformMeshCS p83 Global 885)
# ---------------------------------------------------------------------------------------------------------------
def f16(x):
    """f32tof16 (round to nearest even) and back."""
    return struct.unpack("<e", struct.pack("<e", x))[0]


def clear_kind(t):
    """'value' (ClearToValue 64), 'zero' (ClearSplatter / ClearAll 80) or None. Literal: bit 0x10 selects 'zero', so
    ApplyMin 16 / MinDecal 17 land here too (no asset uses them)."""
    if not (t & 0x50):
        return None
    return "zero" if t & 0x10 else "value"


def clear_rt_texel(t, clothing_proxy, clear_value, disp, dif):
    """One texel of both splatter RTs after the clear pass (section in WriteSplatterMask). disp / dif = current RGBA
    (0..1). FSplatterClearPS: o = saturate(1 - c_ClearMask), drawn over the whole UV rect."""
    kind = clear_kind(t)
    if kind is None:
        return list(disp), list(dif)
    if clothing_proxy:            # mask (1,1,1,1) -> o = 0; Min(One, One), write mask R|A, DispSplatterRT only
        o = _sat(1.0 - 1.0)
        return [min(disp[0], o), disp[1], disp[2], min(disp[3], o)], list(dif)
    if kind == "zero":            # mask (1,1,1,1), Min(One, One), RGBA
        o = _sat(1.0 - 1.0)
        return [min(c, o) for c in disp], [min(c, o) for c in dif]
    o = _sat(1.0 - (1.0 - clear_value))    # mask = 1 - DisplacementClearValue; Add(One, Zero) = replace
    return [o] * 4, [o] * 4


def clear_vertex_depth(clear_value):
    """p83: Deform.w = f16(c_ClearValueArray[0].x) for every vertex of the section; Deform.z kept."""
    return f16(clear_value)


# ---------------------------------------------------------------------------------------------------------------
# 4. Soft influence (FSplatterDeformMeshCS APPLY_TO_SOFT_BODY, IsSoftUpdate=1) and rupture (UVisceraComponent)
# ---------------------------------------------------------------------------------------------------------------
def soft_influence(pos, s, prims):
    """prims: up to 4 FSplatterSoftPrimitive (Position, Radius, HalfHeight, Axis, FadeRadius, AddInfluenceAmount)
    in ref space. s = current influence (10-bit channel, 0..1). Returns the new influence."""
    for p in prims[:4]:
        d = [pos[i] - p["Position"][i] for i in range(3)]
        t = min(max(dot(d, p["Axis"]), -p["HalfHeight"]), p["HalfHeight"])
        q = [d[i] - t * p["Axis"][i] for i in range(3)]
        dist = max(norm(q) - p["Radius"], 0.0)
        if p["FadeRadius"] >= dist:
            f = max(1.0 - dist * dist / (p["FadeRadius"] * p["FadeRadius"] + 1.0), 0.0)
            s = min(max(p["AddInfluenceAmount"] * f + s, 0.0), 1.0)
            s = math.floor(s * 1023.0) / 1023.0
    return s


def rupture_volume(info):
    """UVisceraComponent::Splatter 0x141256940: (depth, radius) of the rupture slab. NB: both use
    RuptureDepthOffset; RuptureRadiusOffset is never read (literal)."""
    radius = info["RuptureRadiusMultiplier"] * info["UVScale"] + info["RuptureDepthOffset"]
    depth = info["RuptureDepthMultiplier"] * info["DepthScale"] + info["RuptureDepthOffset"]
    return depth, radius


def rupture_damage(info, decal_origin, proxy_center):
    """per hit proxy: distance falloff + damage (0x141256940)."""
    f = 1.0
    if info["RuptureFalloffFactor"] > 0.0001 and info["UVScale"] > 0.0001:
        r2 = sum((decal_origin[i] - proxy_center[i]) ** 2 for i in range(3)) / (info["UVScale"] ** 2)
        if r2 >= 0.0:
            f = 1.0 - min(r2, 1.0)
            if f <= 0.0001:
                return None
    return (info["UVScale"] * 0.01 * f * info["DisplacementScale"] * info["RuptureDamageMultiplier"]
            + info["RuptureDamageOffset"]) * f


def apply_rupture_damage(state, threshold, damage, limit_fraction, hold_final_state):
    """UVisceraComponent vtable+0x408 (0x14124f570). state = [accumulated, cap]. Returns True on rupture."""
    cap = threshold * limit_fraction
    if cap <= state[0]:
        return False
    state[0] = min(state[0] + damage, cap)
    state[1] = cap
    return (not hold_final_state) and threshold <= state[0]


# ---------------------------------------------------------------------------------------------------------------
# self test on the Walker (extracted JSON; skeleton ref pose stands in for the mesh's own ref pose)
# ---------------------------------------------------------------------------------------------------------------
def _load_walker():
    root = r"extracted\json\DeadIsland\Content"
    sk = json.load(open(root + r"\DIShared\Art\Characters\ZombieStandard\SKEL_ZombieStandard.json", encoding="utf-8"))
    rs = [o for o in sk if o["Type"] == "Skeleton"][0]["ReferenceSkeleton"]
    names = [b["Name"] for b in rs["FinalRefBoneInfo"]]
    parents = [b["ParentIndex"] for b in rs["FinalRefBoneInfo"]]
    local = []
    for p in rs["FinalRefBonePose"]:
        r, t, s = p["Rotation"], p["Translation"], p["Scale3D"]
        local.append(transform_matrix((r["X"], r["Y"], r["Z"], r["W"]), (t["X"], t["Y"], t["Z"]), (s["X"], s["Y"], s["Z"])))
    comp = [None] * len(local)
    for i in range(len(local)):
        comp[i] = local[i] if parents[i] < 0 else mmul(local[i], comp[parents[i]])
    mesh = json.load(open(root + r"\DI2\Art\Characters\ZombieMale\Walker\SK_WalkerMaleCas01.json", encoding="utf-8"))
    sockets = {}
    for o in mesh:
        if o["Type"] == "SkeletalMeshSocket":
            p = o["Properties"]
            loc, rot, sc = p.get("RelativeLocation", {}), p.get("RelativeRotation", {}), p.get("RelativeScale", {})
            sockets[p["SocketName"]] = {"bone": p["BoneName"],
                                        "loc": (loc.get("X", 0), loc.get("Y", 0), loc.get("Z", 0)),
                                        "rot": (rot.get("Pitch", 0), rot.get("Yaw", 0), rot.get("Roll", 0)),
                                        "scale": (sc.get("X", 1), sc.get("Y", 1), sc.get("Z", 1)),
                                        "branch_mask": p.get("BoneBranchMask", 0)}
    return names, parents, comp, sockets


def region_sockets(sockets, bone, kind):
    out, base = [], f"{bone}_{kind}_region"
    if base in sockets:
        out.append(sockets[base])
        i = 1
        while f"{base}_{i}" in sockets:
            out.append(sockets[f"{base}_{i}"])
            i += 1
    return out


def selftest():
    names, parents, comp, sockets = _load_walker()
    topo = bone_topology(names, parents)
    for b in ("upperarm_l", "lowerarm_l", "thigh_r", "calf_r", "neck_01", "head", "spine_04"):
        i = names.index(b)
        print(f"topology {b:12s} depth {topo[i]['depth']:2d} branch {topo[i]['branch']:2d} "
              f"break_bone {names[topo[i]['break_bone']] if topo[i]['break_bone'] >= 0 else -1}")
    for bone, kind in (("upperarm_l", "safe"), ("upperarm_l", "break"), ("thigh_r", "safe"), ("spine_04", "safe")):
        bi = names.index(bone)
        ref = comp[bi]
        mid = xform_pos((12.0 if bone != "spine_04" else 0.0, 0, 0), ref)   # a point on the bone
        # a hit whose -Z (decal Y) runs along the bone's X axis: the ideal "perpendicular" cut
        bx = unit_axis(ref, 1)
        yaw = math.degrees(math.atan2(bx[1], bx[0]))
        pitch = math.degrees(math.asin(max(-1, min(1, bx[2])))) - 90.0
        frame = decal_frame_from_rotator(mid, pitch, yaw, 0.0)
        r = place_dismember(frame, ref, ref, region_sockets(sockets, bone, kind))
        n = r["frame"][1][:3]
        print(f"{bone:11s} {kind:5s}: t {r['t']:7.2f} corrected {r['corrected']} score {r['score']:.3f} "
              f"normal.boneX {dot(n, bx):+.3f} origin {[round(v, 1) for v in r['frame'][3][:3]]} mask {r['region_branch_mask']}")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
