#!/usr/bin/env python3
"""Deterministic Silo /api/v2 HTTP double for the Silo provider integration test.

Response shapes follow Silo's native /api/v2 contract (admin users, playback
history, catalog listing, item detail, signed artwork). Every identity, title,
and address is fictional. Collections page with opaque cursors and a small page
size so the renderer's cursor handling is exercised. The first item-detail
request answers 429 with Retry-After to exercise the retry path.
"""

from __future__ import annotations

import argparse
import binascii
import json
import struct
import threading
import zlib
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

MONITOR_KEY = "sa_fictional_monitor_key"
CATALOG_KEY = "sa_fictional_catalog_key"
CATALOG_PROFILE = "c0ffee00-0000-4000-8000-000000000001"
PAGE_SIZE = 2


def png(width: int, height: int, rgba: bool, seed: int) -> bytes:
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            r = (x * 7 + seed * 40) % 256
            g = (y * 5 + seed * 70) % 256
            b = ((x + y) * 3 + seed * 20) % 256
            if rgba:
                alpha = 0 if (x < 6 or y < 6 or x >= width - 6 or y >= height - 6) else 255
                rows.extend((255, 255 - (x % 64), 220, alpha))
            else:
                rows.extend((r, g, b))

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", binascii.crc32(kind + data) & 0xFFFFFFFF)

    color_type = 6 if rgba else 2
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(rows), 6))
        + chunk(b"IEND", b"")
    )


def instant(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + f"{moment.microsecond // 1000:03d}Z"


def parse_instant(value: str) -> datetime:
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc)


NOW = datetime.now(timezone.utc)
RECENT = NOW - timedelta(days=1)
OLD = NOW - timedelta(days=60)

USERS = [
    {"id": "1", "username": "AliceFictional", "email": "alice@example.com", "role": "admin", "enabled": True,
     "library_ids": None, "last_active_at": instant(RECENT)},
    {"id": "2", "username": "BobFictional", "email": "bob@example.com", "role": "user", "enabled": True,
     "library_ids": ["1"], "last_active_at": instant(RECENT)},
    {"id": "3", "username": "CarolDisabled", "email": "carol@example.com", "role": "user", "enabled": False,
     "library_ids": None, "last_active_at": instant(OLD)},
    {"id": "4", "username": "DaveNoEmail", "email": "", "role": "user", "enabled": True,
     "library_ids": None, "last_active_at": instant(OLD)},
]

PROFILES = {
    "1": [
        {"id": "aaaaaaaa-0000-4000-8000-000000000001", "name": "Alice", "is_primary": True, "is_child": False, "has_pin": False},
        {"id": "aaaaaaaa-0000-4000-8000-000000000002", "name": "Alice Kid", "is_primary": False, "is_child": True, "has_pin": False},
    ],
    "2": [{"id": "bbbbbbbb-0000-4000-8000-000000000001", "name": "Bob", "is_primary": True, "is_child": False, "has_pin": False}],
    "3": [],
    "4": [],
}

LIBRARIES = [
    {"id": "1", "name": "Fictional Movies", "type": "movies", "sort_order": 0, "box_sets_enabled": True},
    {"id": "2", "name": "Fictional Series", "type": "series", "sort_order": 1, "box_sets_enabled": True},
]


def catalog_items() -> list[dict[str, object]]:
    def movie(content_id, title, year, added):
        return {"content_id": content_id, "type": "movie", "title": title, "year": year, "tmdb_id": content_id.split("-")[-1],
                "library_ids": ["1"], "added_at": instant(added), "status": "matched", "versions": []}

    def episode(series, season, number, title, added):
        return {"content_id": f"episode-tvdb-{series}-{season}-{number}", "type": "episode", "title": title, "year": 2026,
                "series_id": f"series-tvdb-{series}", "series_title": "Silo Fictional Series", "season_number": season,
                "episode_number": number, "library_ids": ["2"], "added_at": instant(added), "versions": []}

    return [
        movie("movie-tmdb-1001", "Silo Fictional Feature", 2026, RECENT),
        movie("movie-tmdb-1002", "Silo Rotten Fixture", 2025, RECENT - timedelta(hours=3)),
        movie("movie-tmdb-1003", "Bob Private Rewatch", 1999, OLD),
        {"content_id": "series-tvdb-2001", "type": "series", "title": "Silo Fictional Series", "year": 2026,
         "tvdb_id": "2001", "library_ids": ["2"], "added_at": instant(RECENT), "status": "matched", "versions": []},
        episode(2001, 1, 1, "Fictional Pilot", RECENT),
        episode(2001, 1, 2, "Fictional Second Hour", RECENT - timedelta(hours=1)),
    ]


DETAILS = {
    "movie-tmdb-1001": {"overview": "A fictional feature about a server that finally sends its own newsletter.",
                        "genres": ["Drama", "Science Fiction"], "ratings": [
                            {"source": "imdb", "name": "IMDb", "score": 78, "display": "7.8"},
                            {"source": "tmdb", "name": "TMDB", "score": 74.2, "display": "7.4"},
                            {"source": "rt_critic", "name": "RT", "score": 91, "display": "91%"},
                            {"source": "rt_audience", "name": "RT Audience", "score": 88, "display": "88%"}],
                        "logo": True},
    "movie-tmdb-1002": {"overview": "A fictional fixture that critics did not enjoy.", "genres": ["Comedy"], "ratings": [
                            {"source": "rt_critic", "name": "RT", "score": 42, "display": "42%"}],
                        "rating_rt_audience": 51},
    "movie-tmdb-1003": {"overview": "Bob's fictional private rewatch.", "genres": ["Thriller"], "ratings": [
                            {"source": "imdb", "name": "IMDb", "score": 66, "display": "6.6"}]},
    "series-tvdb-2001": {"overview": "A fictional series used only by the TautWeekly test suite.", "genres": ["Mystery"],
                         "ratings": [{"source": "imdb", "name": "IMDb", "score": 83, "display": "8.3"},
                                     {"source": "tmdb", "name": "TMDB", "score": 80, "display": "8.0"}]},
    "episode-tvdb-2001-1-1": {"overview": "The fictional first hour.", "genres": [],
                              "ratings": [{"source": "imdb", "name": "IMDb", "score": 81, "display": "8.1"}]},
    "episode-tvdb-2001-1-2": {"overview": "The fictional second hour.", "genres": [], "ratings": []},
}


def history_rows() -> list[dict[str, object]]:
    def play(session, user, profile, content_id, media_type, title, played, duration, completed, ended, platform, client,
             series_title="", season=None, number=None, measured=True):
        start = ended - timedelta(seconds=played + 120)
        return {
            "session_id": session, "user_id": user, "username": next(u["username"] for u in USERS if u["id"] == user),
            "profile_id": profile, "profile_name": "", "media_item_id": content_id, "media_file_id": "f" + session,
            "media_title": title, "media_type": media_type, "play_method": "direct", "started_at": instant(start),
            "ended_at": instant(ended), "watched_seconds": float(played), "duration_seconds": duration,
            "completed": completed, "played_seconds": played if measured else None, "series_title": series_title,
            "season_number": season, "episode_number": number, "measured": measured,
            "start_position_seconds": 0 if measured else None, "paused_seconds": 12.5 if measured else None,
            "measured_since": instant(start) if measured else None, "measured_until": instant(ended) if measured else None,
            "client_ip": "192.0.2.10", "device_id": "dev-" + session, "device_platform": platform,
            "client_name": client, "client_version": "1.0.0", "video_decision": "direct", "audio_decision": "direct",
            "end_reason": "stopped", "lifecycle_seq": 1,
        }

    alice = PROFILES["1"][0]["id"]
    alice_kid = PROFILES["1"][1]["id"]
    bob = PROFILES["2"][0]["id"]
    return sorted([
        play("s1", "1", alice, "movie-tmdb-1001", "movie", "Silo Fictional Feature", 6000, 6200, True, RECENT, "iOS", "Silo iPhone"),
        play("s2", "1", alice, "episode-tvdb-2001-1-1", "episode", "Fictional Pilot", 2700, 2760, True,
             RECENT - timedelta(hours=2), None, "Silo Web", "Silo Fictional Series", 1, 1),
        play("s3", "1", alice, "episode-tvdb-2001-1-2", "episode", "Fictional Second Hour", 2600, 2700, False,
             RECENT - timedelta(hours=1), None, "Silo Web", "Silo Fictional Series", 1, 2, measured=False),
        play("s4", "1", alice_kid, "movie-tmdb-1002", "movie", "Silo Rotten Fixture", 5000, 5100, True,
             RECENT - timedelta(hours=4), "Android", "Silo Android"),
        play("s5", "2", bob, "movie-tmdb-1003", "movie", "Bob Private Rewatch", 7000, 7100, True,
             RECENT - timedelta(hours=5), "Android", "Silo Android"),
        play("s6", "2", bob, "", "", "", 10, 0, False, RECENT - timedelta(hours=6), None, None),
    ], key=lambda row: (row["ended_at"], row["session_id"]), reverse=True)


class Handler(BaseHTTPRequestHandler):
    server_version = "FakeSilo/1.0"

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002
        return

    def record(self, status: int) -> None:
        parsed = urlparse(self.path)
        entry = {
            "method": self.command,
            "path": parsed.path,
            "query": sorted(parse_qs(parsed.query).keys()),
            "auth": self.headers.get("Authorization", "").replace("Bearer ", "")[:12] if self.headers.get("Authorization") else "",
            "profile": self.headers.get("X-Profile-Id", ""),
            "status": status,
        }
        with self.server.log_lock:  # type: ignore[attr-defined]
            with self.server.call_log.open("a", encoding="utf-8") as handle:  # type: ignore[attr-defined]
                handle.write(json.dumps(entry) + "\n")

    def send_json(self, status: int, payload: object, headers: dict[str, str] | None = None) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.record(status)
        self.send_response(status)
        content_type = "application/problem+json" if status >= 400 else "application/json"
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def problem(self, status: int, title: str) -> None:
        self.send_json(status, {"type": "about:blank", "title": title, "status": status})

    def paged(self, rows: list[dict[str, object]], query: dict[str, list[str]]) -> None:
        start = int(query.get("cursor", ["0"])[0].replace("c", "") or 0)
        page = rows[start:start + PAGE_SIZE]
        more = start + PAGE_SIZE < len(rows)
        payload = {"items": page, "page": {"has_more": more}}
        if more:
            payload["page"]["next_cursor"] = f"c{start + PAGE_SIZE}"
        self.send_json(200, payload)

    def bearer(self) -> str:
        header = self.headers.get("Authorization", "")
        return header[7:] if header.startswith("Bearer ") else ""

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)
        base = self.server.base_url  # type: ignore[attr-defined]

        if path.startswith("/artwork/"):
            if self.headers.get("Authorization"):
                return self.problem(400, "Artwork URLs carry their own signature")
            if query.get("sig", [""])[0] != "fictional":
                return self.problem(403, "Bad signature")
            name = path.rsplit("/", 1)[-1]
            seed = sum(name.encode()) % 7
            if name.startswith("logo"):
                body = png(320, 96, True, seed)
            elif name.startswith("backdrop"):
                body = png(640, 360, False, seed)
            else:
                body = png(300, 450, False, seed)
            self.record(200)
            self.send_response(200)
            # Silo serves WebP; the double serves PNG bytes at the same URL
            # shape so every converter can decode them by content.
            self.send_header("Content-Type", "image/webp")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if not path.startswith("/api/v2/"):
            return self.problem(404, "Only the native /api/v2 contract is served")

        key = self.bearer()
        catalog_route = path in ("/api/v2/profiles", "/api/v2/user/libraries") or path.startswith("/api/v2/catalog/")
        expected = CATALOG_KEY if catalog_route else MONITOR_KEY
        if key != expected:
            return self.problem(401 if not key else 403, "Wrong credential for this route")

        if path == "/api/v2/profiles":
            return self.send_json(200, {"items": [{"id": CATALOG_PROFILE, "name": "Newsletter", "is_primary": True, "is_child": False}]})
        if path == "/api/v2/user/libraries":
            if self.headers.get("X-Profile-Id") != CATALOG_PROFILE:
                return self.problem(422, "The X-Profile-Id header is required.")
            return self.send_json(200, {"items": LIBRARIES})
        if path.startswith("/api/v2/catalog/items/"):
            if self.headers.get("X-Profile-Id") != CATALOG_PROFILE:
                return self.problem(422, "The X-Profile-Id header is required.")
            if query.get("image_size", [""])[0] not in ("", "small", "medium", "large", "original"):
                return self.problem(422, "Validation failed")
            with self.server.log_lock:  # type: ignore[attr-defined]
                first = not self.server.rate_limited_once  # type: ignore[attr-defined]
                self.server.rate_limited_once = True  # type: ignore[attr-defined]
            if first:
                self.record(429)
                self.send_response(429)
                self.send_header("Retry-After", "1")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            content_id = path.rsplit("/", 1)[-1]
            item = next((row for row in catalog_items() if row["content_id"] == content_id), None)
            if item is None or content_id not in DETAILS:
                return self.problem(404, "Not found")
            info = DETAILS[content_id]
            detail = dict(item)
            detail.pop("library_ids", None)
            detail.update({"overview": info["overview"], "genres": info["genres"], "ratings": info["ratings"],
                           "runtime": 103, "tagline": "", "studios": ["Fictional Studio"], "content_rating": "PG-13",
                           "release_date": "2026-01-01", "user_state": {"played": False}})
            if "rating_rt_audience" in info:
                detail["rating_rt_audience"] = info["rating_rt_audience"]
            art = f"/artwork/{content_id}"
            if item["type"] == "episode":
                detail["poster_url"] = f"{art}/still.webp?sig=fictional"
                detail["series_poster_url"] = f"/artwork/{item['series_id']}/poster.webp?sig=fictional"
                detail["air_date"] = "2026-01-02"
            else:
                detail["poster_url"] = f"{art}/poster.webp?sig=fictional"
                # Absolute signed URLs are valid too; exercise both forms.
                detail["backdrop_url"] = f"{base}{art}/backdrop.webp?sig=fictional"
                if info.get("logo"):
                    detail["logo_url"] = f"{art}/logo.webp?sig=fictional"
            return self.send_json(200, detail)

        if path in ("/api/v2/admin/users/capabilities", "/api/v2/admin/playback-history/capabilities",
                    "/api/v2/admin/catalog/capabilities"):
            return self.send_json(200, {"allowed": True, "available": True, "state": "ready", "revision": "1"})
        if path == "/api/v2/admin/users":
            return self.paged(USERS, query)
        if path.startswith("/api/v2/admin/users/"):
            parts = path.split("/")
            user = next((row for row in USERS if row["id"] == parts[5]), None)
            if user is None:
                return self.problem(404, "Not found")
            if len(parts) == 6:
                return self.send_json(200, user)
            if len(parts) == 7 and parts[6] == "profiles":
                return self.send_json(200, {"items": PROFILES[user["id"]], "page": {"has_more": False}})
            return self.problem(404, "Not found")
        if path == "/api/v2/admin/playback-history":
            if "offset" in query:
                return self.problem(422, "offset is refused")
            rows = history_rows()
            if "user_id" in query:
                rows = [row for row in rows if row["user_id"] == query["user_id"][0]]
            if "ended_after" in query:
                after = parse_instant(query["ended_after"][0])
                rows = [row for row in rows if parse_instant(str(row["ended_at"])) >= after]
            if "ended_before" in query:
                before = parse_instant(query["ended_before"][0])
                rows = [row for row in rows if parse_instant(str(row["ended_at"])) < before]
            return self.paged(rows, query)
        if path == "/api/v2/admin/catalog/items":
            rows = catalog_items()
            if "content_ids" in query:
                wanted = set(query["content_ids"])
                rows = [row for row in rows if row["content_id"] in wanted]
            if "type" in query:
                rows = [row for row in rows if row["type"] == query["type"][0]]
            if "added_after" in query:
                after = parse_instant(query["added_after"][0])
                rows = [row for row in rows if parse_instant(str(row["added_at"])) >= after]
            rows = sorted(rows, key=lambda row: str(row["content_id"]).encode())
            return self.paged(rows, query)
        return self.problem(404, "No operation is registered at this path.")

    def do_POST(self) -> None:  # noqa: N802
        self.problem(405, "The newsletter provider must only read")

    do_PUT = do_POST
    do_DELETE = do_POST
    do_PATCH = do_POST


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--call-log", type=Path, required=True)
    parser.add_argument("--ready-file", type=Path, required=True)
    args = parser.parse_args()

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.call_log = args.call_log  # type: ignore[attr-defined]
    server.log_lock = threading.Lock()  # type: ignore[attr-defined]
    server.rate_limited_once = False  # type: ignore[attr-defined]
    server.base_url = f"http://127.0.0.1:{args.port}"  # type: ignore[attr-defined]
    args.call_log.write_text("", encoding="utf-8")
    args.ready_file.write_text(server.base_url, encoding="utf-8")
    server.serve_forever()


if __name__ == "__main__":
    main()
