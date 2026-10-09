"""Tolerant 3D convex hull (incremental, numpy) used to pre-clean collision hulls before Jolt builds them: points
closer than `eps` to the hull built so far are dropped, so near-coplanar point clouds (DI2's cooked ConvexElems carry
points a few mm off their faces) don't trip Jolt's hull builder ("Hull building failed, point N had an error ...").
The hull's shape changes by at most eps."""
import numpy as np


def hull_points(pts, eps=0.002, with_faces=False):
    """Vertices (k, 3) of the convex hull of pts (n, 3), points within eps of it dropped; None when degenerate.
    with_faces: also its triangles (f, 3, 3), outward-facing."""
    pts = np.asarray(pts, float)
    if len(pts) < 4:
        return None
    c = pts.mean(0)
    # initial tetrahedron: the two farthest-apart extremes, the farthest from their line, the farthest from that plane
    i0 = int(np.argmax(np.linalg.norm(pts - c, axis=1)))
    i1 = int(np.argmax(np.linalg.norm(pts - pts[i0], axis=1)))
    d = pts[i1] - pts[i0]
    if np.linalg.norm(d) < eps:
        return None
    t = np.cross(pts - pts[i0], d / np.linalg.norm(d))
    i2 = int(np.argmax(np.linalg.norm(t, axis=1)))
    nrm = np.cross(pts[i1] - pts[i0], pts[i2] - pts[i0])
    if np.linalg.norm(nrm) < eps * eps:
        return None
    nrm /= np.linalg.norm(nrm)
    h = (pts - pts[i0]) @ nrm
    i3 = int(np.argmax(np.abs(h)))
    if abs(h[i3]) < eps:
        return None
    inner = (pts[i0] + pts[i1] + pts[i2] + pts[i3]) / 4.0
    faces = []

    def add(a, b, cc):
        n = np.cross(pts[b] - pts[a], pts[cc] - pts[a])
        ln = np.linalg.norm(n)
        if ln < 1e-12:
            return
        n /= ln
        if (inner - pts[a]) @ n > 0:  # keep normals pointing out
            a, b, n = b, a, -n
        faces.append((a, b, cc, n, n @ pts[a]))

    for f in ((i0, i1, i2), (i0, i1, i3), (i0, i2, i3), (i1, i2, i3)):
        add(*f)
    order = np.argsort(-np.linalg.norm(pts - inner, axis=1))
    for p in order:
        if p in (i0, i1, i2, i3):
            continue
        q = pts[p]
        vis = [f for f in faces if f[3] @ q - f[4] > eps]
        if not vis:
            continue
        edges = {}
        for a, b, cc, _n, _d in vis:
            for e in ((a, b), (b, cc), (cc, a)):
                k = (min(e), max(e))
                edges[k] = None if k in edges else e
        faces = [f for f in faces if not any(f is v for v in vis)]
        for e in edges.values():
            if e is not None:
                add(e[0], e[1], p)
    used = sorted({i for f in faces for i in f[:3]})
    if with_faces:
        return pts[used], pts[np.array([f[:3] for f in faces], int)]
    return pts[used]
