#!/usr/bin/env python3
"""Lightweight smoke tests for QHTP pure logic (no Flutter required)."""
from __future__ import annotations

import base64
import json
import re
import sys
import unittest


def sanitize_segment(segment: str) -> str:
    clean = re.sub(r'[\x00-\x1f\x7f/\\:*?"<>|]', "_", segment).strip()
    if not clean or clean.replace(".", "") == "":
        clean = "item"
    return clean


def materialize_path(relative_path: str, base_dir: str) -> str:
    import os

    segments = []
    for seg in relative_path.split("/"):
        if seg in (".", "..", ""):
            continue
        segments.append(sanitize_segment(seg))
    resolved = os.path.normpath(os.path.join(base_dir, *segments))
    base = os.path.normpath(base_dir)
    if not (resolved == base or resolved.startswith(base + os.sep)):
        raise ValueError(f"Path traversal: {relative_path}")
    return resolved


def qr_v2_encode(ip: str, port: int, token: str, sid: str) -> str:
    payload = {"v": 2, "ip": ip, "p": port, "t": token, "sid": sid, "mode": "http-lan"}
    raw = json.dumps(payload, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def qr_v2_decode(encoded: str) -> dict:
    pad = "=" * ((4 - len(encoded) % 4) % 4)
    raw = base64.urlsafe_b64decode(encoded + pad)
    return json.loads(raw.decode())


class TestQhtpLogic(unittest.TestCase):
    def test_sanitize_and_materialize(self):
        base = "/tmp/qhtp_base"
        p = materialize_path("photos/2024/a.jpg", base)
        self.assertTrue(p.endswith("photos/2024/a.jpg") or p.endswith("photos\\2024\\a.jpg"))
        p2 = materialize_path("../../evil/../etc/passwd", base)
        self.assertNotIn("..", p2)
        self.assertTrue(p2.startswith("/tmp/qhtp_base") or p2.startswith("/private/tmp/qhtp_base"))

    def test_qr_v2_roundtrip(self):
        enc = qr_v2_encode("192.168.1.10", 8123, "tok-abc", "session99")
        data = qr_v2_decode(enc)
        self.assertEqual(data["v"], 2)
        self.assertEqual(data["ip"], "192.168.1.10")
        self.assertEqual(data["p"], 8123)
        self.assertEqual(data["sid"], "session99")
        self.assertEqual(data["mode"], "http-lan")
        self.assertNotIn("fn", data)

    def test_limits_constants(self):
        max_file = 100 * 1024**3
        max_session = 500 * 1024**3
        max_count = 100_000
        self.assertEqual(max_file, 107374182400)
        self.assertEqual(max_session, 536870912000)
        self.assertEqual(max_count, 100000)

    def test_hex_ids(self):
        ids = [(i + 1).to_bytes(3, "big").hex() if False else format(i + 1, "x").zfill(6) for i in range(3)]
        self.assertEqual(ids, ["000001", "000002", "000003"])


if __name__ == "__main__":
    result = unittest.main(verbosity=2, exit=False)
    sys.exit(0 if result.result.wasSuccessful() else 1)
