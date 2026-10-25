#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Doprax Cloud Panel API Client
Robust, production-ready client for VM provisioning, polling, and lifecycle operations.
"""

import time
import uuid
import requests
from typing import Dict, Any, List, Optional, Tuple

class DopraxAPIError(Exception):
    def __init__(self, message: str, status_code: Optional[int] = None, response_body: Any = None):
        super().__init__(message)
        self.status_code = status_code
        self.response_body = response_body

class DopraxClient:
    def __init__(self, api_key: str, base_url: str = "https://www.doprax.com"):
        self.api_key = api_key.strip()
        self.base_url = base_url.rstrip("/")
        self.session = requests.Session()
        self.session.headers.update({
            "X-API-Key": self.api_key,
            "Content-Type": "application/json",
            "Accept": "application/json"
        })

    def _request(self, method: str, path: str, **kwargs) -> Any:
        url = f"{self.base_url}{path}"
        try:
            resp = self.session.request(method, url, timeout=kwargs.pop("timeout", 30), **kwargs)
        except requests.RequestException as e:
            raise DopraxAPIError(f"Network error connecting to Doprax API: {e}")

        try:
            data = resp.json()
        except Exception:
            data = resp.text

        if resp.status_code >= 400:
            error_msg = f"HTTP {resp.status_code}"
            if isinstance(data, dict):
                err = data.get("error")
                if isinstance(err, dict):
                    error_msg = err.get("message") or err.get("code") or error_msg
                elif isinstance(err, str):
                    error_msg = err
            raise DopraxAPIError(error_msg, status_code=resp.status_code, response_body=data)

        return data

    def get_account_info(self) -> Dict[str, Any]:
        """Fetch account info including numVmLimit and currentVmCount."""
        res = self._request("GET", "/api/v1/account/info/")
        return res.get("data", {}) if isinstance(res, dict) else {}

    def get_available_balance(self, min_required_cents: int = 100) -> Dict[str, Any]:
        """Check available balance in cents and whether it is sufficient."""
        res = self._request("GET", f"/api/v2/finance/available-balance/?min_required_cents={min_required_cents}")
        return res.get("data", {}) if isinstance(res, dict) else {}

    def list_plans(self, provider: str = "provm", service_type: str = "vm") -> List[Dict[str, Any]]:
        """List available VM plans and locations via v3 API."""
        res = self._request("GET", f"/api/v3/catalogue/plans/?service_type={service_type}&provider={provider}")
        if isinstance(res, dict) and "data" in res:
            return res["data"]
        return []

    def create_vm_v3(self, plan: str, location: str, name: str, os_name: str = "ubuntu_24_04", idempotency_key: Optional[str] = None) -> Dict[str, Any]:
        """Create a VM via v3 API using friendly names."""
        payload = {
            "service_type": "vm",
            "plan": plan,
            "location": location,
            "os": os_name,
            "name": name,
            "idempotency_key": idempotency_key or f"hunter-{int(time.time())}-{uuid.uuid4().hex[:8]}"
        }
        return self._request("POST", "/api/v3/services/", json=payload)

    def get_instance_detail(self, service_id: str) -> Dict[str, Any]:
        """Fetch real-time details of a VM instance (status, IPs, vm_code)."""
        res = self._request("GET", f"/api/v2/services/instances/{service_id}/detail/")
        return res.get("data", {}) if isinstance(res, dict) else {}

    def get_vm_access(self, vm_code: str) -> Dict[str, Any]:
        """Fetch access info such as temporary root password."""
        res = self._request("GET", f"/api/v2/vms/{vm_code}/actions/access/")
        return res.get("data", {}) if isinstance(res, dict) else {}

    def list_instances(self, service_type: str = "vm") -> List[Dict[str, Any]]:
        """List all current service instances on the account."""
        res = self._request("GET", f"/api/v2/services/instances/list/?service_type={service_type}")
        return res.get("data", []) if isinstance(res, dict) else []

    def delete_instance(self, service_id: str, idempotency_key: Optional[str] = None) -> Dict[str, Any]:
        """
        Immediately terminate and delete a VM instance.
        Stops billing immediately.
        """
        payload = {
            "action": "delete",
            "idempotency_key": idempotency_key or f"del-{int(time.time())}-{uuid.uuid4().hex[:6]}"
        }
        try:
            return self._request("POST", f"/api/v2/services/instances/{service_id}/operations/", json=payload)
        except DopraxAPIError as e:
            # If already 404 or in deletion, consider handled
            if e.status_code == 404:
                return {"success": True, "already_deleted": True}
            raise

    def poll_until_ready(self, service_id: str, max_wait_sec: int = 300, poll_interval: int = 6, status_callback=None) -> Tuple[str, str, str]:
        """
        Polls until the VM reaches status 'running', status_reason 'vm_setup_complete', and has a public IP.
        Returns: (public_ipv4, vm_code, root_password)
        """
        start = time.time()
        while time.time() - start < max_wait_sec:
            detail = self.get_instance_detail(service_id)
            service = detail.get("service", {})
            status = service.get("status", "unknown")
            status_reason = service.get("status_reason")
            access = detail.get("access", {})
            public_ipv4 = access.get("public_ipv4")
            vm_code = service.get("metadata", {}).get("vm_code")

            status_display = f"{status} [{status_reason or 'booting'}]" if status_reason else status
            if status_callback:
                status_callback(status=status_display, ip=public_ipv4 or "Waiting...", elapsed=int(time.time() - start))

            if status == "running" and public_ipv4 and vm_code:
                # Ensure cloud-init has finished setting the root password
                if status_reason == "vm_setup_complete" or (time.time() - start > 90):
                    time.sleep(3)
                    cred_info = self.get_vm_access(vm_code)
                    temp_pass = cred_info.get("tempPass") or ""
                    return public_ipv4, vm_code, temp_pass

            if status in ["error", "failed"]:
                reason = service.get("status_reason", "unknown error")
                raise DopraxAPIError(f"VM provisioning failed with status: {status} ({reason})")

            time.sleep(poll_interval)

        raise TimeoutError(f"VM {service_id} did not become ready within {max_wait_sec} seconds.")
