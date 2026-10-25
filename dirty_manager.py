#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Dirty IP Database Manager
Maintains a thread-safe local persistent registry of blocked/dirty IPs so previously flagged IPs
can be detected immediately upon provisioning.
"""

import os
import json
import time
import ipaddress
import threading
from typing import Dict, Any, List, Optional

DIRTY_SERVERS_JSON = "dirty_servers.json"
DIRTY_SERVERS_TXT = "dirty_servers.txt"

_DB_LOCK = threading.RLock()


def _is_valid_ip(ip: str) -> bool:
    """Returns True if string is a valid IPv4 or IPv6 address."""
    if not ip or not isinstance(ip, str):
        return False
    try:
        ipaddress.ip_address(ip.strip())
        return True
    except ValueError:
        return False


class DirtyIPManager:
    @staticmethod
    def load_dirty_ips() -> Dict[str, Dict[str, Any]]:
        """Loads all recorded dirty IPs as a dict keyed by IP (thread-safe)."""
        with _DB_LOCK:
            if not os.path.exists(DIRTY_SERVERS_JSON):
                return {}
            try:
                with open(DIRTY_SERVERS_JSON, "r", encoding="utf-8") as f:
                    data = json.load(f)
                    if isinstance(data, list):
                        return {
                            item.get("ip"): item
                            for item in data
                            if isinstance(item, dict) and _is_valid_ip(item.get("ip", ""))
                        }
                    elif isinstance(data, dict):
                        return {k: v for k, v in data.items() if _is_valid_ip(k)}
            except Exception:
                return {}
            return {}

    @classmethod
    def is_dirty(cls, ip: str) -> Optional[Dict[str, Any]]:
        """Returns dirty record if IP was previously flagged, else None."""
        if not _is_valid_ip(ip):
            return None
        db = cls.load_dirty_ips()
        return db.get(ip.strip())

    @classmethod
    def record_dirty_ip(cls, ip: str, provider: str = "Doprax", reason: str = "Blocked",
                        diag: Optional[List[str]] = None, details: Optional[Dict[str, Any]] = None):
        """Records a new dirty IP into JSON and TXT database atomically and thread-safely."""
        if not _is_valid_ip(ip):
            return
        ip = ip.strip()

        with _DB_LOCK:
            db = cls.load_dirty_ips()
            prev_hits = db.get(ip, {}).get("hit_count", 0)
            record = {
                "ip": ip,
                "provider": provider,
                "reason": reason,
                "diag": diag or [],
                "details": details or {},
                "hit_count": prev_hits + 1,
                "flagged_at": time.strftime("%Y-%m-%d %H:%M:%S")
            }
            db[ip] = record

            # Atomic JSON write
            tmp_file = f"{DIRTY_SERVERS_JSON}.tmp"
            try:
                with open(tmp_file, "w", encoding="utf-8") as f:
                    json.dump(list(db.values()), f, indent=2, ensure_ascii=False)
                os.replace(tmp_file, DIRTY_SERVERS_JSON)
            except Exception:
                if os.path.exists(tmp_file):
                    try:
                        os.remove(tmp_file)
                    except OSError:
                        pass

            # Append TXT audit log
            try:
                with open(DIRTY_SERVERS_TXT, "a", encoding="utf-8") as f:
                    f.write(
                        f"[{record['flagged_at']}] IP: {ip} | Provider: {provider} | "
                        f"Reason: {reason} | Hits: {record['hit_count']} | Diag: {'; '.join(diag or [])}\n"
                    )
            except Exception:
                pass

    @classmethod
    def remove_dirty_ip(cls, ip: str) -> bool:
        """Removes an IP from the dirty database (e.g. if unflagged by user)."""
        if not ip:
            return False
        ip = ip.strip()
        with _DB_LOCK:
            db = cls.load_dirty_ips()
            if ip not in db:
                return False
            del db[ip]
            tmp_file = f"{DIRTY_SERVERS_JSON}.tmp"
            try:
                with open(tmp_file, "w", encoding="utf-8") as f:
                    json.dump(list(db.values()), f, indent=2, ensure_ascii=False)
                os.replace(tmp_file, DIRTY_SERVERS_JSON)
                return True
            except Exception:
                return False

    @classmethod
    def list_all(cls) -> List[Dict[str, Any]]:
        """Returns all recorded dirty IPs as a list."""
        db = cls.load_dirty_ips()
        return list(db.values())
