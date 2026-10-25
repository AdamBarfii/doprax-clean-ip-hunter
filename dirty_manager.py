#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Dirty IP Database Manager
Maintains a local persistent registry of blocked/dirty IPs so previously flagged IPs
can be detected immediately upon provisioning.
"""

import os
import json
import time
from typing import Dict, Any, List, Optional

DIRTY_SERVERS_JSON = "dirty_servers.json"
DIRTY_SERVERS_TXT = "dirty_servers.txt"

class DirtyIPManager:
    @staticmethod
    def load_dirty_ips() -> Dict[str, Dict[str, Any]]:
        """Loads all recorded dirty IPs as a dict keyed by IP."""
        if not os.path.exists(DIRTY_SERVERS_JSON):
            return {}
        try:
            with open(DIRTY_SERVERS_JSON, "r", encoding="utf-8") as f:
                data = json.load(f)
                if isinstance(data, list):
                    return {item.get("ip"): item for item in data if "ip" in item}
                elif isinstance(data, dict):
                    return data
        except Exception:
            return {}
        return {}

    @classmethod
    def is_dirty(cls, ip: str) -> Optional[Dict[str, Any]]:
        """Returns dirty record if IP was previously flagged, else None."""
        if not ip:
            return None
        db = cls.load_dirty_ips()
        return db.get(ip)

    @classmethod
    def record_dirty_ip(cls, ip: str, provider: str = "Doprax", reason: str = "Blocked",
                        diag: Optional[List[str]] = None, details: Optional[Dict[str, Any]] = None):
        """Records a new dirty IP into JSON and TXT database."""
        if not ip or ip in ["provisioning...", "Waiting..."]:
            return

        db = cls.load_dirty_ips()
        record = {
            "ip": ip,
            "provider": provider,
            "reason": reason,
            "diag": diag or [],
            "details": details or {},
            "flagged_at": time.strftime("%Y-%m-%d %H:%M:%S")
        }
        db[ip] = record

        # Save JSON
        try:
            with open(DIRTY_SERVERS_JSON, "w", encoding="utf-8") as f:
                json.dump(list(db.values()), f, indent=2, ensure_ascii=False)
        except Exception:
            pass

        # Save TXT audit log
        try:
            with open(DIRTY_SERVERS_TXT, "a", encoding="utf-8") as f:
                f.write(f"[{record['flagged_at']}] IP: {ip} | Provider: {provider} | Reason: {reason} | Diag: {'; '.join(diag or [])}\n")
        except Exception:
            pass

    @classmethod
    def list_all(cls) -> List[Dict[str, Any]]:
        """Returns all recorded dirty IPs as a list."""
        db = cls.load_dirty_ips()
        return list(db.values())
