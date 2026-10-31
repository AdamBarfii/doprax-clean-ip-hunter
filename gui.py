#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AetherProbe Observability Bridge
High-concurrency background job manager with non-blocking event-streaming to PyWebView UI,
atomic cancellation semantics (threading.Event), live telemetry, and resilient lifecycle control.
"""

import os
import sys
import json
import time
import socket
import logging
import threading
import ipaddress
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Dict, Any, List, Optional, Callable

import webview

from doprax_client import DopraxClient, DopraxAPIError
from ssh_manager import SSHManager
from dirty_manager import DirtyIPManager
from doprax_hunter import (
    load_config,
    save_config,
    save_clean_records,
    CONFIG_FILE,
    CLEAN_SERVERS_FILE,
    ACTIVE_TEMP_VMS
)

# Suppress noisy transport logs in console
logging.getLogger("paramiko").setLevel(logging.CRITICAL)


class JobCancelledException(Exception):
    """Raised when an active scan job is aborted by the user."""
    pass


class ObservabilityAPI:
    """
    API exposed to Javascript via window.pywebview.api.
    Runs jobs asynchronously in daemon threads and dispatches live events
    to the frontend via window.evaluate_js().
    """

    def __init__(self):
        self._cfg = load_config()
        self._doprax: Optional[DopraxClient] = None
        self._active_cancel_event = threading.Event()
        self._is_scan_running = False
        self._window: Optional[webview.Window] = None
        self._init_doprax()

    def set_window(self, win: webview.Window):
        self._window = win

    def _init_doprax(self):
        key = self._cfg.get("doprax_api_key", "").strip()
        if key:
            self._doprax = DopraxClient(key)

    # --------------------------------------------------------------------------
    #  Event Dispatcher (Python -> JavaScript)
    # --------------------------------------------------------------------------
    def dispatch_event(self, event_type: str, payload: Dict[str, Any]):
        """Dispatches an asynchronous event packet directly into the UI state store."""
        if not self._window:
            return
        try:
            packet = json.dumps({"type": event_type, "payload": payload, "ts": time.time()})
            # Escape for JS string literal
            escaped = packet.replace("\\", "\\\\").replace("'", "\\'")
            js_code = f"if (window.AppState && window.AppState.handleBackendEvent) {{ window.AppState.handleBackendEvent('{escaped}'); }}"
            self._window.evaluate_js(js_code)
        except Exception as e:
            pass

    def emit_log(self, level: str, message: str, source: str = "CORE"):
        """Pushes a timestamped log line to the live UI console."""
        self.dispatch_event("LOG_STREAM", {
            "level": level.upper(),
            "message": message,
            "source": source,
            "time": time.strftime("%H:%M:%S")
        })

    # --------------------------------------------------------------------------
    #  Config & Telemetry Endpoints
    # --------------------------------------------------------------------------
    def get_config(self) -> Dict[str, Any]:
        return self._cfg

    def save_config(self, new_data: Dict[str, Any]) -> Dict[str, Any]:
        self._cfg.update(new_data)
        save_config(self._cfg)
        self._init_doprax()
        self.emit_log("INFO", "Configuration updated and saved to config.json", "CONFIG")
        return {"ok": True}

    def get_balance(self) -> Dict[str, Any]:
        if not self._doprax:
            return {"available_balance_cents": 0, "error": "No Doprax API key"}
        try:
            return self._doprax.get_available_balance(min_required_cents=50)
        except Exception as e:
            return {"error": str(e)}

    def list_plans(self, provider: str = "vultr") -> List[Dict[str, Any]]:
        if not self._doprax:
            return []
        try:
            return self._doprax.list_plans(provider=provider)
        except Exception as e:
            self.emit_log("ERROR", f"Error querying {provider} catalogue: {e}", "DOPRAX")
            return []

    def test_iran_connection(self, iran_info: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        info = iran_info or self._cfg.get("iran_server", {})
        self.emit_log("INFO", f"Probing Iran server SSH ({info.get('host')}:{info.get('port', 22)})...", "IRAN_SSH")
        ok, msg = SSHManager.test_iran_connection(info)
        level = "SUCCESS" if ok else "ERROR"
        self.emit_log(level, f"Iran Server result: {msg}", "IRAN_SSH")
        return {"ok": ok, "msg": msg}

    def list_clean_servers(self) -> List[Dict[str, Any]]:
        if not os.path.exists(CLEAN_SERVERS_FILE):
            return []
        try:
            with open(CLEAN_SERVERS_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return []

    def list_dirty_ips(self) -> List[Dict[str, Any]]:
        return DirtyIPManager.list_all()

    def unflag_ip(self, ip: str) -> bool:
        res = DirtyIPManager.remove_dirty_ip(ip)
        if res:
            self.emit_log("WARN", f"Unflagged IP: {ip} removed from dirty database", "VAULT")
        return res

    def delete_instance(self, service_id: str) -> Dict[str, Any]:
        if not self._doprax or not service_id:
            return {"ok": False}
        try:
            self.emit_log("INFO", f"Sending delete operation for VM {service_id}...", "LIFECYCLE")
            res = self._doprax.delete_instance(service_id)
            ACTIVE_TEMP_VMS[:] = [t for t in ACTIVE_TEMP_VMS if t.get("id") != service_id]
            self.emit_log("SUCCESS", f"Deleted VM {service_id}. Billing halted.", "LIFECYCLE")
            return {"ok": True}
        except Exception as e:
            self.emit_log("ERROR", f"Failed deleting VM {service_id}: {e}", "LIFECYCLE")
            return {"ok": False, "error": str(e)}

    def list_existing_vms(self) -> List[Dict[str, Any]]:
        if not self._doprax:
            return []
        try:
            instances = self._doprax.list_instances(service_type="vm")
            out = []
            for inst in instances:
                s_id = inst.get("service_id")
                detail = self._doprax.get_instance_detail(s_id)
                access = detail.get("access", {})
                out.append({
                    "service_id": s_id,
                    "name": inst.get("name", "unnamed"),
                    "status": inst.get("status", "unknown"),
                    "ip": access.get("public_ipv4") or "Pending"
                })
            return out
        except Exception as e:
            self.emit_log("ERROR", f"Error listing Doprax instances: {e}", "DOPRAX")
            return []

    def list_custom_servers(self) -> List[Dict[str, Any]]:
        return self._cfg.get("custom_servers", [])

    def add_custom_server(self, srv: Dict[str, Any]) -> bool:
        srv_list = self._cfg.setdefault("custom_servers", [])
        srv_list.append(srv)
        save_config(self._cfg)
        self.emit_log("SUCCESS", f"Custom server added: {srv.get('host')}", "CUSTOM")
        return True

    # --------------------------------------------------------------------------
    #  Atomic Cancellation
    # --------------------------------------------------------------------------
    def abort_active_scan(self) -> Dict[str, Any]:
        """Sets the atomic cancellation event to interrupt in-flight threads."""
        if not self._is_scan_running:
            return {"ok": False, "msg": "No active scan running"}
        self._active_cancel_event.set()
        self.emit_log("WARN", "ABORT SIGNAL RECEIVED: Halting all worker threads...", "CORE")
        self.dispatch_event("SCAN_STATUS", {"status": "ABORTING", "message": "Halting workers..."})
        return {"ok": True}

    # --------------------------------------------------------------------------
    #  Asynchronous Job Engine (Launch & Stream)
    # --------------------------------------------------------------------------
    def start_hunt_job(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """Entry point called from UI. Kicks off job in a dedicated daemon thread."""
        if self._is_scan_running:
            return {"ok": False, "msg": "A scan job is already in progress."}

        self._active_cancel_event.clear()
        self._is_scan_running = True

        thread = threading.Thread(target=self._execute_hunt_pipeline, args=(params,), daemon=True)
        thread.start()
        return {"ok": True, "msg": "Hunt job launched successfully"}

    def _execute_hunt_pipeline(self, params: Dict[str, Any]):
        """Executes the full provision, boot-wait, deploy, and benchmark stages asynchronously."""
        try:
            provider = params.get("provider", "vultr")
            location = params.get("location", "DE, Frankfurt")
            plan = params.get("plan", "VC2-1C-1GB")
            batch_size = int(params.get("batch_size", 3))
            mode = params.get("mode", "iran")
            carrier = self._cfg.get("defaults", {}).get("carrier", "auto")

            self.emit_log("INFO", f"=== STARTING BATCH HUNT: {batch_size} VM(s) | {provider.upper()} | {location} ===", "PIPELINE")
            self.dispatch_event("SCAN_STATUS", {
                "status": "PROVISIONING",
                "batch_size": batch_size,
                "provider": provider,
                "location": location,
                "step": 1,
                "total_steps": 3,
                "message": f"Provisioning {batch_size} VM(s) on Doprax API..."
            })

            # Check pre-flight
            iran_cfg = self._cfg.get("iran_server", {})
            if mode == "iran":
                self.emit_log("INFO", "Pre-flight: Checking Iran relay node connectivity...", "PREFLIGHT")
                ok, msg = SSHManager.test_iran_connection(iran_cfg)
                if not ok:
                    raise ValueError(f"Iran SSH connection failed: {msg}")

            if self._active_cancel_event.is_set():
                raise JobCancelledException()

            # Step 1: Provision
            prefix = provider[:3]
            batch_records = []
            for i in range(1, batch_size + 1):
                if self._active_cancel_event.is_set():
                    raise JobCancelledException()
                vm_name = f"{prefix}-{int(time.time()) % 10000}-{i}"
                self.emit_log("INFO", f"Requesting VM #{i}: {vm_name} ({plan} @ {location})...", "DOPRAX")
                try:
                    res = self._doprax.create_vm_v3(plan=plan, location=location, name=vm_name)
                    s_id = res.get("service_id")
                    if s_id:
                        ACTIVE_TEMP_VMS.append({"id": s_id, "ip": "", "name": vm_name})
                        record = {
                            "idx": i,
                            "name": vm_name,
                            "id": s_id,
                            "datacenter": f"Doprax/{provider.upper()}",
                            "ip": "booting...",
                            "password": "",
                            "stage": "BOOTING",
                            "clean": False
                        }
                        batch_records.append(record)
                        self.dispatch_event("VM_STAGE_UPDATE", record)
                        self.emit_log("SUCCESS", f"✓ VM #{i} created with Service ID: {s_id}", "DOPRAX")
                except Exception as e:
                    self.emit_log("ERROR", f"✗ Failed creating VM #{i}: {e}", "DOPRAX")
                    record = {
                        "idx": i,
                        "name": vm_name,
                        "id": "",
                        "datacenter": f"Doprax/{provider.upper()}",
                        "ip": "Failed",
                        "stage": "FAILED",
                        "tcp_result": f"Create Error: {e}",
                        "clean": False
                    }
                    batch_records.append(record)
                    self.dispatch_event("VM_STAGE_UPDATE", record)

            valid_records = [b for b in batch_records if b.get("id")]
            if not valid_records:
                raise ValueError("No VMs were provisioned on Doprax.")

            if self._active_cancel_event.is_set():
                raise JobCancelledException()

            # Step 2: Poll Until Ready
            self.dispatch_event("SCAN_STATUS", {
                "status": "BOOTING",
                "step": 2,
                "total_steps": 3,
                "message": f"Waiting for {len(valid_records)} VM(s) to acquire public IPs and activate password..."
            })
            self.emit_log("INFO", f"Polling {len(valid_records)} VM(s) in parallel until ready...", "LIFECYCLE")

            def poll_worker(item):
                s_id = item["id"]
                start = time.time()
                while time.time() - start < 300:
                    if self._active_cancel_event.is_set():
                        raise JobCancelledException()
                    try:
                        detail = self._doprax.get_instance_detail(s_id)
                        svc = detail.get("service", {})
                        status = svc.get("status", "unknown")
                        reason = svc.get("status_reason", "")
                        access = detail.get("access", {})
                        ip = access.get("public_ipv4")
                        vm_code = svc.get("metadata", {}).get("vm_code")

                        if ip:
                            item["ip"] = ip
                            self.dispatch_event("VM_STAGE_UPDATE", {
                                "idx": item["idx"], "id": s_id, "ip": ip,
                                "stage": f"BOOTING ({status}/{reason or 'init'})"
                            })

                        if status == "running" and ip and vm_code:
                            if reason == "vm_setup_complete" or (time.time() - start > 75):
                                time.sleep(2.5)
                                cred = self._doprax.get_vm_access(vm_code)
                                item["password"] = cred.get("tempPass") or ""
                                item["stage"] = "SSH_STABILIZING"
                                for t in ACTIVE_TEMP_VMS:
                                    if t["id"] == s_id:
                                        t["ip"] = ip
                                self.dispatch_event("VM_STAGE_UPDATE", {
                                    "idx": item["idx"], "id": s_id, "ip": ip,
                                    "stage": "SSH_STABILIZING"
                                })
                                return item
                    except JobCancelledException:
                        raise
                    except Exception:
                        pass
                    time.sleep(5)
                raise TimeoutError(f"VM {s_id} failed to boot within 300s")

            with ThreadPoolExecutor(max_workers=len(valid_records)) as ex:
                futs = [ex.submit(poll_worker, item) for item in valid_records]
                for f in as_completed(futs):
                    if self._active_cancel_event.is_set():
                        raise JobCancelledException()
                    try:
                        item_res = f.result()
                        self.emit_log("SUCCESS", f"✓ VM #{item_res['idx']} is ready with IPv4: {item_res['ip']}", "LIFECYCLE")
                    except Exception as e:
                        self.emit_log("ERROR", f"Boot error: {e}", "LIFECYCLE")

            if self._active_cancel_event.is_set():
                raise JobCancelledException()

            # Step 3: Parallel Benchmarks with Live Telemetry
            self.dispatch_event("SCAN_STATUS", {
                "status": "BENCHMARKING",
                "step": 3,
                "total_steps": 3,
                "message": f"Running parallel WatTunnel & protocol benchmarks ({mode.upper()})..."
            })
            self.emit_log("INFO", f"Initiating high-concurrency verification ({mode.upper()} mode)...", "BENCHMARK")

            final_results = []
            with ThreadPoolExecutor(max_workers=len(valid_records)) as executor:
                if mode == "agentless":
                    futures = [
                        executor.submit(self._worker_agentless_stream, item, carrier)
                        for item in valid_records
                    ]
                else:
                    futures = [
                        executor.submit(self._worker_iran_stream, item, iran_cfg, carrier)
                        for item in valid_records
                    ]

                for fut in as_completed(futures):
                    if self._active_cancel_event.is_set():
                        raise JobCancelledException()
                    try:
                        res = fut.result()
                        final_results.append(res)
                    except Exception as e:
                        self.emit_log("ERROR", f"Benchmark worker error: {e}", "BENCHMARK")

            final_results.sort(key=lambda x: x.get("idx", 1))

            # Auto-save clean servers
            clean_servers = [r for r in final_results if r.get("clean")]
            if clean_servers:
                save_clean_records(clean_servers)
                self.emit_log("SUCCESS", f"🎉 SAVED {len(clean_servers)} CLEAN SERVER(S) TO VAULT!", "DATABASE")
                for cs in clean_servers:
                    ACTIVE_TEMP_VMS[:] = [t for t in ACTIVE_TEMP_VMS if t["id"] != cs["id"]]

            self.dispatch_event("SCAN_COMPLETE", {
                "results": final_results,
                "clean_count": len(clean_servers),
                "dirty_count": len(final_results) - len(clean_servers)
            })
            self.emit_log("SUCCESS", f"=== BATCH COMPLETE: {len(clean_servers)} Clean / {len(final_results) - len(clean_servers)} Dirty ===", "PIPELINE")

        except JobCancelledException:
            self.emit_log("WARN", "Job execution stopped: User cancelled scan.", "CORE")
            self.dispatch_event("SCAN_STATUS", {"status": "CANCELLED", "message": "Scan aborted by user."})
        except Exception as err:
            self.emit_log("ERROR", f"Fatal scan pipeline error: {err}", "CORE")
            self.dispatch_event("SCAN_STATUS", {"status": "ERROR", "message": str(err)})
        finally:
            self._is_scan_running = False
            self._active_cancel_event.clear()

    # --------------------------------------------------------------------------
    #  Streaming Workers
    # --------------------------------------------------------------------------
    def _worker_iran_stream(self, target: Dict[str, Any], iran_cfg: Dict[str, Any], carrier: str) -> Dict[str, Any]:
        idx = target.get("idx", 1)
        ip = (target.get("ip") or "").strip()
        pwd = target.get("password")
        s_id = target.get("id")
        datacenter = target.get("datacenter", "Doprax")
        name = target.get("name", ip)

        result = {
            "idx": idx, "name": name, "id": s_id, "ip": ip, "datacenter": datacenter,
            "stage": "CHECKING_DIRTY_DB", "tcp_result": "Pending", "udp_result": "Pending",
            "clean": False, "pre_flagged": False, "details": {}
        }
        self.dispatch_event("VM_STAGE_UPDATE", result)

        # 1. Pre-check
        dirty_rec = DirtyIPManager.is_dirty(ip)
        if dirty_rec:
            result["pre_flagged"] = True
            result["tcp_result"] = "Pre-Flagged Dirty"
            result["udp_result"] = f"Seen {dirty_rec.get('flagged_at', '')[:10]}"
            result["stage"] = "FLAGGED_DIRTY"
            self.emit_log("WARN", f"[{ip}] PRE-FLAGGED DIRTY! Skipping benchmark.", "FILTER")
            self.dispatch_event("VM_STAGE_UPDATE", result)
            return result

        # 2. Wait for SSH banner
        result["stage"] = "WAITING_SSH_BANNER"
        self.dispatch_event("VM_STAGE_UPDATE", result)
        self.emit_log("INFO", f"[{ip}] Verifying OpenSSH daemon readiness & protocol banner...", "SSH")
        if not SSHManager.wait_for_ssh_ready(ip, 22, timeout=90):
            result["stage"] = "SSH_TIMEOUT"
            result["tcp_result"] = "SSH Timeout"
            result["udp_result"] = "Skipped"
            DirtyIPManager.record_dirty_ip(ip, provider=datacenter, reason="SSH Port 22 Unreachable or No Banner")
            self.emit_log("ERROR", f"[{ip}] Port 22 Unreachable. Flagged as dirty.", "SSH")
            self.dispatch_event("VM_STAGE_UPDATE", result)
            return result

        # 3. Setup WatTunnel
        result["stage"] = "WATTUNNEL_SETUP"
        self.dispatch_event("VM_STAGE_UPDATE", result)
        self.emit_log("INFO", f"[{ip}] Deploying WatTunnel unattended server...", "WATTUNNEL")
        kharej_client = None
        token = ""
        try:
            kharej_client = SSHManager.create_client_with_retry(
                host=ip, port=22, username="root", password=pwd, max_wait=90, retry_interval=4
            )
            ok, token_res, _ = SSHManager.install_and_setup_wattunnel_kharej(
                kharej_client, public_ip=ip, tunnel_name=f"tun{idx}", carrier=carrier
            )
            if ok:
                token = token_res
                result["token"] = token
                self.emit_log("SUCCESS", f"[{ip}] WatTunnel token acquired: {token[:25]}...", "WATTUNNEL")
        except Exception as e:
            result["stage"] = "WATTUNNEL_FAIL"
            result["tcp_result"] = "SSH/WatTun Error"
            result["udp_result"] = "Error"
            DirtyIPManager.record_dirty_ip(ip, provider=datacenter, reason=f"SSH/WatTunnel setup failure: {e}")
            self.emit_log("ERROR", f"[{ip}] WatTunnel setup failed: {e}", "WATTUNNEL")
            self.dispatch_event("VM_STAGE_UPDATE", result)
            return result

        # 4. Benchmark from Iran
        result["stage"] = "BENCHMARKING_IRAN"
        self.dispatch_event("VM_STAGE_UPDATE", result)
        self.emit_log("INFO", f"[{ip}] Benchmarking bidirectional TCP/UDP traffic from Iran relay...", "BENCHMARK")

        iran_client = None
        test_port = 28880 + (idx % 50)
        try:
            time.sleep((idx % 4) * 0.35)
            iran_client = SSHManager.create_client_with_retry(
                host=iran_cfg["host"],
                port=int(iran_cfg.get("port", 22)),
                username=iran_cfg.get("username", "root"),
                password=iran_cfg.get("password"),
                key_path=iran_cfg.get("key_path"),
                max_wait=45,
                retry_interval=3
            )
            bench = SSHManager.run_protocol_verification(
                kharej_client=kharej_client,
                iran_client=iran_client,
                kharej_ip=ip,
                token=token,
                test_port=test_port,
                ssh_port=22
            )

            tcp_ok = bench.get("tcp_ok", False)
            udp_ok = bench.get("udp_ok", False)
            t_down = bench.get("tcp_down_kb", 0.0)
            t_up = bench.get("tcp_up_kb", 0.0)
            u_loss = bench.get("udp_loss_pct", 100.0)
            latency = bench.get("latency_ms", 0.0)
            ssh_reach = bench.get("ssh_reachable", False)
            diag = bench.get("diag", [])

            result["tcp_result"] = f"{'✓' if tcp_ok else '✗'} ↓{t_down}K ↑{t_up}K"
            result["udp_result"] = f"{'✓' if udp_ok else '✗'} Loss: {u_loss}%"
            result["details"] = bench

            is_clean = tcp_ok and udp_ok and (t_down > 0) and (t_up > 0)
            result["clean"] = is_clean
            result["stage"] = "CLEAN" if is_clean else "DIRTY"

            if is_clean:
                self.emit_log("SUCCESS", f"🎉 [{ip}] CLEAN CONFIRMED: ↓{t_down}K ↑{t_up}K | UDP Loss: {u_loss}% | {latency}ms", "BENCHMARK")
            else:
                reason = "GFW Blocked" if not ssh_reach else "TCP/UDP Packet Loss"
                DirtyIPManager.record_dirty_ip(ip, provider=datacenter, reason=reason, diag=diag, details=bench)
                self.emit_log("WARN", f"🚫 [{ip}] BLOCKED/DIRTY: TCP ok:{tcp_ok} | UDP ok:{udp_ok} | Loss:{u_loss}%", "BENCHMARK")

        except Exception as e:
            result["stage"] = "ERROR"
            result["tcp_result"] = "Error"
            result["udp_result"] = "Error"
            DirtyIPManager.record_dirty_ip(ip, provider=datacenter, reason=f"Benchmark error: {e}")
            self.emit_log("ERROR", f"[{ip}] Benchmark exception: {e}", "BENCHMARK")
        finally:
            if kharej_client:
                kharej_client.close()
            if iran_client:
                iran_client.close()

        self.dispatch_event("VM_STAGE_UPDATE", result)
        return result

    def _worker_agentless_stream(self, target: Dict[str, Any], carrier: str) -> Dict[str, Any]:
        idx = target.get("idx", 1)
        ip = (target.get("ip") or "").strip()
        pwd = target.get("password")
        s_id = target.get("id")
        datacenter = target.get("datacenter", "Doprax")
        name = target.get("name", ip)

        result = {
            "idx": idx, "name": name, "id": s_id, "ip": ip, "datacenter": datacenter,
            "stage": "CHECKING_DIRTY_DB", "tcp_result": "Pending", "udp_result": "Pending",
            "clean": False, "pre_flagged": False, "details": {}
        }
        self.dispatch_event("VM_STAGE_UPDATE", result)

        dirty_rec = DirtyIPManager.is_dirty(ip)
        if dirty_rec:
            result["pre_flagged"] = True
            result["tcp_result"] = "Pre-Flagged Dirty"
            result["udp_result"] = f"Seen {dirty_rec.get('flagged_at', '')[:10]}"
            result["stage"] = "FLAGGED_DIRTY"
            self.emit_log("WARN", f"[{ip}] PRE-FLAGGED DIRTY! Skipping.", "FILTER")
            self.dispatch_event("VM_STAGE_UPDATE", result)
            return result

        result["stage"] = "WAITING_SSH_BANNER"
        self.dispatch_event("VM_STAGE_UPDATE", result)
        self.emit_log("INFO", f"[{ip}] Checking OpenSSH banner readiness...", "SSH")
        if not SSHManager.wait_for_ssh_ready(ip, 22, timeout=90):
            result["stage"] = "SSH_TIMEOUT"
            result["tcp_result"] = "SSH Timeout"
            result["udp_result"] = "Skipped"
            DirtyIPManager.record_dirty_ip(ip, provider=datacenter, reason="SSH Port 22 Unreachable or No Banner")
            self.emit_log("ERROR", f"[{ip}] SSH Timeout. Flagged dirty.", "SSH")
            self.dispatch_event("VM_STAGE_UPDATE", result)
            return result

        result["stage"] = "WATTUNNEL_SETUP"
        self.dispatch_event("VM_STAGE_UPDATE", result)
        kharej_client = None
        try:
            kharej_client = SSHManager.create_client_with_retry(
                host=ip, port=22, username="root", password=pwd, max_wait=90, retry_interval=4
            )
            ok, token_res, _ = SSHManager.install_and_setup_wattunnel_kharej(
                kharej_client, public_ip=ip, tunnel_name=f"tun{idx}", carrier=carrier
            )
            if ok:
                result["token"] = token_res
        except Exception as e:
            result["stage"] = "WATTUNNEL_FAIL"
            result["tcp_result"] = "WatTun Error"
            result["udp_result"] = "Error"
            DirtyIPManager.record_dirty_ip(ip, provider=datacenter, reason=f"Setup failure: {e}")
            self.dispatch_event("VM_STAGE_UPDATE", result)
            return result

        result["stage"] = "PROBING_AGENTLESS"
        self.dispatch_event("VM_STAGE_UPDATE", result)
        self.emit_log("INFO", f"[{ip}] Probing 6 Check-Host nodes + Iranian ISP DNS resolvers...", "AGENTLESS")

        test_port = 28880 + (idx % 50)
        try:
            bench = SSHManager.run_agentless_verification(
                kharej_client=kharej_client, kharej_ip=ip, test_port=test_port, ssh_port=22
            )
            tcp_ok = bench.get("tcp_ok", False)
            udp_ok = bench.get("udp_ok", False)
            ch_ok = bench.get("ch_ok", 0)
            ch_total = bench.get("ch_total", 6)
            rev_udp = bench.get("rev_udp_ok", 0)
            rev_total = bench.get("rev_total", 6)
            latency = bench.get("latency_ms", 0.0)

            result["tcp_result"] = f"{'✓' if tcp_ok else '✗'} IR: {ch_ok}/{ch_total}"
            result["udp_result"] = f"{'✓' if udp_ok else '✗'} DNS: {rev_udp}/{rev_total}"
            result["details"] = bench

            is_clean = tcp_ok and udp_ok
            result["clean"] = is_clean
            result["stage"] = "CLEAN" if is_clean else "DIRTY"

            if is_clean:
                self.emit_log("SUCCESS", f"🎉 [{ip}] AGENTLESS CLEAN (~85%): IR {ch_ok}/{ch_total} | DNS {rev_udp}/{rev_total} | {latency}ms", "AGENTLESS")
            else:
                DirtyIPManager.record_dirty_ip(ip, provider=datacenter, reason="Agentless Probe Failed", diag=bench.get("diag", []))
                self.emit_log("WARN", f"🚫 [{ip}] AGENTLESS BLOCKED: IR {ch_ok}/{ch_total} | DNS {rev_udp}/{rev_total}", "AGENTLESS")
        except Exception as e:
            result["stage"] = "ERROR"
            result["tcp_result"] = "Error"
            result["udp_result"] = "Error"
            DirtyIPManager.record_dirty_ip(ip, provider=datacenter, reason=f"Agentless error: {e}")
            self.emit_log("ERROR", f"[{ip}] Agentless exception: {e}", "AGENTLESS")
        finally:
            if kharej_client:
                kharej_client.close()

        self.dispatch_event("VM_STAGE_UPDATE", result)
        return result


def get_resource_path(relative_path: str) -> str:
    """Get absolute path to resource, works for dev and for PyInstaller bundle."""
    if hasattr(sys, '_MEIPASS'):
        return os.path.join(sys._MEIPASS, relative_path)
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), relative_path)


def main():
    # If running from a bundled executable, switch working directory to executable folder
    # so config.json and server databases stay adjacent to the .exe
    if getattr(sys, 'frozen', False):
        os.chdir(os.path.dirname(sys.executable))

    api = ObservabilityAPI()
    html_path = get_resource_path("dashboard.html")

    window = webview.create_window(
        title="AetherProbe Industrial Observability Suite",
        url=f"file:///{html_path.replace(os.sep, '/')}",
        js_api=api,
        width=1320,
        height=860,
        min_size=(1040, 720),
        background_color="#080c14"
    )

    api.set_window(window)
    webview.start(debug=False)


if __name__ == "__main__":
    main()
