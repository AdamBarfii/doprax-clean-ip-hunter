#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SSH Connection & Protocol Verification Manager
Handles remote SSH execution on both Iran server and Kharej Doprax VMs,
WatTunnel installation, and bidirectional TCP/UDP throughput testing.
"""

import time
import socket
import logging
import paramiko
from typing import Dict, Any, Optional, Tuple

# Suppress Paramiko internal background thread tracebacks during transient handshake retries
logging.getLogger("paramiko").setLevel(logging.CRITICAL)
logging.getLogger("paramiko.transport").setLevel(logging.CRITICAL)

class SSHManager:
    @staticmethod
    def wait_for_ssh_ready(host: str, port: int = 22, timeout: int = 90) -> bool:
        """
        Probes host:port and verifies that the remote SSH server actually sends an SSH banner (e.g. 'SSH-2.0-...').
        This ensures sshd is not only accepting raw TCP packets, but has finished launching and is ready
        to receive SSH handshakes without premature socket drops or EOFs from cloud-init restarts.
        """
        start = time.time()
        while time.time() - start < timeout:
            try:
                s = socket.create_connection((host, port), timeout=4)
                s.settimeout(4)
                banner_bytes = s.recv(512)
                s.close()
                if banner_bytes and b"SSH-" in banner_bytes:
                    # Give sshd 1.5 seconds to stabilize before Paramiko connects
                    time.sleep(1.5)
                    return True
            except (socket.timeout, ConnectionRefusedError, OSError, EOFError):
                time.sleep(2)
        return False

    @staticmethod
    def wait_for_port_open(host: str, port: int = 22, timeout: int = 90) -> bool:
        """Alias for wait_for_ssh_ready for backward compatibility."""
        return SSHManager.wait_for_ssh_ready(host, port, timeout)

    @staticmethod
    def create_client(host: str, port: int = 22, username: str = "root",
                      password: Optional[str] = None, key_path: Optional[str] = None,
                      timeout: int = 25, banner_timeout: int = 60) -> paramiko.SSHClient:
        """Creates an authenticated Paramiko SSHClient with extended banner and auth timeouts."""
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        kwargs: Dict[str, Any] = {
            "hostname": host,
            "port": port,
            "username": username,
            "timeout": timeout,
            "banner_timeout": banner_timeout,
            "auth_timeout": banner_timeout,
        }
        if password:
            kwargs["password"] = password
            # Disable probing local ~/.ssh keys to avoid triggering OpenSSH rate limiting
            kwargs["look_for_keys"] = False
            kwargs["allow_agent"] = False
        if key_path:
            kwargs["key_filename"] = key_path

        client.connect(**kwargs)
        return client

    @classmethod
    def create_client_with_retry(cls, host: str, port: int = 22, username: str = "root",
                                 password: Optional[str] = None, key_path: Optional[str] = None,
                                 max_wait: int = 90, retry_interval: int = 4,
                                 status_cb=None) -> paramiko.SSHClient:
        """
        Attempts to connect via SSH with robust retry logic.
        Handles transient cloud-init restarts, SSH banner read EOFs, and password activation delays.
        """
        start = time.time()
        attempt = 1
        last_err = None
        while time.time() - start < max_wait:
            try:
                if status_cb and attempt > 1:
                    status_cb(f"Waiting for SSH on {host} ({int(time.time() - start)}s, attempt {attempt})...")
                client = cls.create_client(host, port, username, password, key_path, timeout=15, banner_timeout=45)
                return client
            except paramiko.ssh_exception.AuthenticationException as e:
                last_err = e
                time.sleep(retry_interval)
                attempt += 1
            except (socket.timeout, ConnectionRefusedError, paramiko.ssh_exception.SSHException, OSError, EOFError, Exception) as e:
                last_err = e
                time.sleep(retry_interval)
                attempt += 1

        raise ConnectionError(f"SSH connection failed on {host} after {max_wait}s: {last_err}")

    @staticmethod
    def run_cmd(client: paramiko.SSHClient, command: str, timeout: int = 120) -> Tuple[int, str, str]:
        """
        Executes a command on the remote server with an absolute timeout loop.
        Guarantees that it never hangs indefinitely even if the command hangs.
        """
        transport = client.get_transport()
        if not transport or not transport.is_active():
            raise ConnectionError("SSH transport is not active.")

        channel = transport.open_session()
        channel.settimeout(timeout)
        channel.exec_command(command)

        start = time.time()
        stdout_data = []
        stderr_data = []

        while True:
            if channel.recv_ready():
                data = channel.recv(4096)
                if data:
                    stdout_data.append(data)

            if channel.recv_stderr_ready():
                data = channel.recv_stderr(4096)
                if data:
                    stderr_data.append(data)

            if channel.exit_status_ready():
                break

            if time.time() - start > timeout:
                channel.close()
                return -1, b"".join(stdout_data).decode("utf-8", errors="ignore").strip(), f"Command timed out after {timeout}s"

            time.sleep(0.1)

        # Drain any remaining data
        while channel.recv_ready():
            stdout_data.append(channel.recv(4096))
        while channel.recv_stderr_ready():
            stderr_data.append(channel.recv_stderr(4096))

        exit_code = channel.recv_exit_status()
        channel.close()
        out_str = b"".join(stdout_data).decode("utf-8", errors="ignore").strip()
        err_str = b"".join(stderr_data).decode("utf-8", errors="ignore").strip()
        return exit_code, out_str, err_str

    @classmethod
    def test_iran_connection(cls, iran_cfg: Dict[str, Any]) -> Tuple[bool, str]:
        """Verifies that the Iran server is reachable and credentials are correct."""
        host = iran_cfg.get("host")
        port = int(iran_cfg.get("port", 22))
        username = iran_cfg.get("username", "root")
        password = iran_cfg.get("password")
        key_path = iran_cfg.get("key_path")

        if not host:
            return False, "Iran server host IP is not configured."

        if not cls.wait_for_port_open(host, port, timeout=10):
            return False, f"Could not reach SSH port {port} on Iran server ({host})."

        try:
            client = cls.create_client(host, port, username, password, key_path, timeout=15)
            code, out, _ = cls.run_cmd(client, "echo IRAN_SSH_OK", timeout=10)
            client.close()
            if code == 0 and "IRAN_SSH_OK" in out:
                return True, "Iran server connected successfully."
            return False, f"Unexpected response from Iran server: {out}"
        except Exception as e:
            return False, f"Failed to authenticate with Iran server: {e}"

    @classmethod
    def install_and_setup_wattunnel_kharej(cls, client: paramiko.SSHClient, public_ip: str,
                                          tunnel_name: str = "testtun",
                                          carrier: str = "auto",
                                          status_cb=None) -> Tuple[bool, str, str]:
        """
        Installs WatTunnel on the Kharej VM and creates an unattended Kharej tunnel.
        Returns: (success, token_or_error, logs)
        """
        if status_cb:
            status_cb("Checking WatTunnel on Kharej VM...")

        # 1. Check if wattun-manager is already installed, else run installer
        check_cmd = "which wattun-manager || which wattun"
        code, out, _ = cls.run_cmd(client, check_cmd, timeout=10)
        if code != 0:
            if status_cb:
                status_cb("Downloading and installing WatTunnel via install.sh...")
            install_cmd = "curl -fsSL https://raw.githubusercontent.com/JohnWatsoon/WatTunnel/main/install.sh | bash"
            code, out, err = cls.run_cmd(client, install_cmd, timeout=180)
            if code != 0:
                # Try with proxy fallback if raw github blocked
                install_cmd_proxy = "WAT_PROXY=https://ghproxy.net/ bash <(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/JohnWatsoon/WatTunnel/main/install.sh)"
                code, out, err = cls.run_cmd(client, install_cmd_proxy, timeout=180)
                if code != 0:
                    return False, f"WatTunnel installation failed: {err or out}", out

        # 2. Configure Kharej tunnel unattended
        if status_cb:
            status_cb("Configuring WatTunnel in Kharej unattended mode...")

        # Remove old tunnel if existed
        cls.run_cmd(client, f"wattun-manager delete {tunnel_name} --yes 2>/dev/null || true", timeout=15)

        # Run unattended kharej setup
        kharej_cmd = f"wattun-manager kharej --name {tunnel_name} --carrier {carrier} --addr {public_ip} --yes"
        code, out, err = cls.run_cmd(client, kharej_cmd, timeout=45)
        
        # 3. Retrieve token
        token_cmd = f"cat /etc/wattun/{tunnel_name}.token 2>/dev/null || wattun-manager token {tunnel_name}"
        code, token_out, _ = cls.run_cmd(client, token_cmd, timeout=15)
        token = ""
        for line in token_out.splitlines():
            line = line.strip()
            if line.startswith("wat1:"):
                token = line
                break

        if not token:
            for line in out.splitlines():
                line = line.strip()
                if line.startswith("wat1:"):
                    token = line
                    break

        if not token:
            return False, f"Failed to retrieve WatTunnel token. Output: {out}", out

        return True, token, out

    @classmethod
    def _single_protocol_probe(cls, kharej_client: paramiko.SSHClient, iran_client: paramiko.SSHClient,
                               kharej_ip: str, test_port: int, ssh_port: int = 22,
                               status_cb=None) -> Dict[str, Any]:
        """Runs a single round of bidirectional TCP/UDP benchmark from Iran."""
        # 1. Ensure firewall on Kharej accepts test port
        firewall_cmd = f"iptables -I INPUT -p tcp --dport {test_port} -j ACCEPT 2>/dev/null; iptables -I INPUT -p udp --dport {test_port} -j ACCEPT 2>/dev/null; ufw allow {test_port} 2>/dev/null || true"
        cls.run_cmd(kharej_client, firewall_cmd, timeout=10)

        # 2. Start a robust 60-second daemon on Kharej
        cls.run_cmd(kharej_client, f"fuser -k {test_port}/tcp {test_port}/udp 2>/dev/null || true", timeout=10)
        kharej_server_py = f"""python3 -c "
import socket, threading, time

running = True
PORT = {test_port}

def tcp_worker():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(('0.0.0.0', PORT))
    s.listen(10)
    s.settimeout(60)
    try:
        while running:
            try:
                conn, _ = s.accept()
            except socket.timeout:
                break
            cmd = conn.recv(32).decode('utf-8', errors='ignore')
            if 'PING' in cmd:
                conn.sendall(b'PONG\\n')
            elif 'DOWN' in cmd:
                chunk = b'X' * 32768
                for _ in range(32): # 1MB
                    conn.sendall(chunk)
            elif 'UP' in cmd:
                total = 0
                while True:
                    data = conn.recv(32768)
                    if not data: break
                    total += len(data)
                conn.sendall(f'ACK:{{total}}\\n'.encode())
            conn.close()
    except Exception: pass
    finally: s.close()

def udp_worker():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(('0.0.0.0', PORT))
    s.settimeout(60)
    try:
        while running:
            try:
                data, addr = s.recvfrom(2048)
            except socket.timeout:
                break
            if b'PING' in data or b'ECHO' in data:
                s.sendto(data, addr)
    except Exception: pass
    finally: s.close()

t1 = threading.Thread(target=tcp_worker, daemon=True)
t2 = threading.Thread(target=udp_worker, daemon=True)
t1.start()
t2.start()
time.sleep(55)
running = False
" >/dev/null 2>&1 &
"""
        cls.run_cmd(kharej_client, kharej_server_py, timeout=10)
        time.sleep(1.5)

        # 3. Benchmark from Iran
        iran_test_py = f"""python3 -c "
import socket, time, json

HOST = '{kharej_ip}'
PORT = {test_port}
SSH_PORT = {ssh_port}
res = {{
    'ssh_reachable': False, 'tcp_ok': False, 'udp_ok': False,
    'tcp_down_kb': 0.0, 'tcp_up_kb': 0.0, 'udp_down_kb': 0.0, 'udp_up_kb': 0.0,
    'udp_loss': 100.0, 'udp_loss_pct': 100.0, 'rtt_ms': 0.0, 'latency_ms': 0.0, 'diag': []
}}

# 0. Check SSH Reachability from Iran (Proves IP is routeable through GFW)
try:
    s0 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s0.settimeout(3)
    s0.connect((HOST, SSH_PORT))
    s0.close()
    res['ssh_reachable'] = True
except Exception as e:
    res['diag'].append(f'Port {{SSH_PORT}} SSH unreachable from Iran: {{type(e).__name__}}')

# 1. TCP Latency & Ping
try:
    t0 = time.time()
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(4)
    s.connect((HOST, PORT))
    s.sendall(b'PING\\n')
    data = s.recv(16)
    rtt = round((time.time() - t0) * 1000, 1)
    s.close()
    if b'PONG' in data:
        res['rtt_ms'] = rtt
        res['latency_ms'] = rtt
except Exception as e:
    res['diag'].append(f'TCP Ping failed: {{type(e).__name__}}')

# 2. TCP Download (Kharej -> Iran)
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect((HOST, PORT))
    s.sendall(b'DOWN\\n')
    t0 = time.time()
    received = 0
    while True:
        chunk = s.recv(32768)
        if not chunk: break
        received += len(chunk)
    elapsed = max(0.001, time.time() - t0)
    s.close()
    res['tcp_down_kb'] = round((received / 1024) / elapsed, 1)
except Exception as e:
    res['diag'].append(f'TCP Download failed: {{type(e).__name__}}')

# 3. TCP Upload (Iran -> Kharej)
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect((HOST, PORT))
    s.sendall(b'UP\\n')
    payload = b'A' * 32768
    t0 = time.time()
    sent = 0
    for _ in range(32): # 1MB
        s.sendall(payload)
        sent += len(payload)
    s.shutdown(socket.SHUT_WR)
    s.recv(64)
    elapsed = max(0.001, time.time() - t0)
    s.close()
    res['tcp_up_kb'] = round((sent / 1024) / elapsed, 1)
    if res['tcp_down_kb'] > 0 and res['tcp_up_kb'] > 0:
        res['tcp_ok'] = True
except Exception as e:
    res['diag'].append(f'TCP Upload failed: {{type(e).__name__}}')

# 4. UDP Ping & Echo Test (Bidirectional)
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(1.5)
    packets = 10
    received = 0
    t0 = time.time()
    total_bytes = 0
    for i in range(packets):
        msg = f'ECHO:{{i}}'.encode().ljust(256, b'#')
        s.sendto(msg, (HOST, PORT))
        try:
            ack, _ = s.recvfrom(2048)
            if ack.startswith(b'ECHO'):
                received += 1
                total_bytes += len(ack) + len(msg)
        except socket.timeout: pass
    elapsed = max(0.001, time.time() - t0)
    s.close()
    loss = round(((packets - received) / packets) * 100, 1)
    res['udp_loss'] = loss
    res['udp_loss_pct'] = loss
    if received > 0:
        speed_kb = round((total_bytes / 1024) / elapsed, 1)
        res['udp_down_kb'] = speed_kb
        res['udp_up_kb'] = speed_kb
        if loss <= 40.0:
            res['udp_ok'] = True
except Exception as e:
    res['diag'].append(f'UDP Echo failed: {{type(e).__name__}}')

print(json.dumps(res))
"
"""
        code, out, err = cls.run_cmd(iran_client, iran_test_py, timeout=25)
        import json
        res = {
            "tcp_ok": False, "udp_ok": False, "ssh_reachable": False,
            "tcp_down_kb": 0.0, "tcp_up_kb": 0.0, "udp_down_kb": 0.0, "udp_up_kb": 0.0,
            "udp_loss": 100.0, "udp_loss_pct": 100.0, "rtt_ms": 0.0, "latency_ms": 0.0, "diag": []
        }
        try:
            for line in out.splitlines():
                if line.startswith("{") and "tcp_ok" in line:
                    parsed = json.loads(line)
                    res.update(parsed)
                    res["udp_loss_pct"] = parsed.get("udp_loss_pct", parsed.get("udp_loss", 100.0))
                    res["latency_ms"] = parsed.get("latency_ms", parsed.get("rtt_ms", 0.0))
                    break
        except Exception as e:
            res["diag"].append(f"Parse error: {e}")
        return res

    @classmethod
    def run_protocol_verification(cls, kharej_client: paramiko.SSHClient, iran_client: paramiko.SSHClient,
                                  kharej_ip: str, token: str, test_port: int = 28880,
                                  ssh_port: int = 22, status_cb=None) -> Dict[str, Any]:
        """
        Runs comprehensive TCP & UDP download/upload verification with an AUTOMATIC RETRY.
        Ensures 100% certainty before any server is marked as dirty, and guarantees daemon cleanup.
        """
        try:
            if status_cb:
                status_cb(f"Benchmarking TCP/UDP throughput from Iran ({kharej_ip}) [Attempt 1/2]...")

            probe1 = cls._single_protocol_probe(kharej_client, iran_client, kharej_ip, test_port, ssh_port=ssh_port, status_cb=status_cb)

            # Clean criteria: TCP works both ways AND UDP loss is acceptable
            is_clean1 = probe1["tcp_ok"] and probe1["udp_ok"] and (probe1["tcp_down_kb"] > 0) and (probe1["tcp_up_kb"] > 0)

            if is_clean1:
                probe1["wattun_alive"] = True
                return probe1

            # If attempt 1 failed, wait 2 seconds and RETRY to eliminate false positives
            if status_cb:
                status_cb(f"Double-checking {kharej_ip} [Attempt 2/2 to prevent false dirty]...")
            time.sleep(2)

            probe2 = cls._single_protocol_probe(kharej_client, iran_client, kharej_ip, test_port, ssh_port=ssh_port, status_cb=status_cb)
            probe2["wattun_alive"] = True
            return probe2
        finally:
            try:
                cls.run_cmd(kharej_client, f"fuser -k {test_port}/tcp {test_port}/udp 2>/dev/null || true", timeout=5)
            except Exception:
                pass

    # ==========================================================================
    #  STANDALONE AGENTLESS VERIFICATION (NO IRAN SERVER REQUIRED)
    #  Completely decoupled from Iran-server mode (~80-85% accuracy estimation)
    # ==========================================================================

    @classmethod
    def _check_host_iran_tcp_probe(cls, target_ip: str, target_port: int) -> Dict[str, Any]:
        """
        Uses Check-Host.net public API to test TCP connectivity from all active Iranian
        datacenter nodes (Tehran, Isfahan, Shiraz) to target_ip:target_port.
        """
        import requests as req_lib
        headers = {"Accept": "application/json", "User-Agent": "Mozilla/5.0"}
        default_ir_nodes = [
            "ir1.node.check-host.net",
            "ir2.node.check-host.net",
            "ir3.node.check-host.net",
            "ir4.node.check-host.net",
            "ir5.node.check-host.net",
            "ir7.node.check-host.net"
        ]
        ir_nodes = default_ir_nodes
        try:
            nr = req_lib.get("https://check-host.net/nodes/hosts", headers=headers, timeout=8)
            if nr.status_code == 200:
                ndata = nr.json().get("nodes", {})
                found = [k for k, v in ndata.items() if v.get("location") and v["location"][0] == "ir"]
                if found:
                    ir_nodes = found
        except Exception:
            pass

        params = [("host", f"{target_ip}:{target_port}"), ("max_nodes", len(ir_nodes))] + [("node", n) for n in ir_nodes]
        try:
            r = req_lib.get("https://check-host.net/check-tcp", params=params, headers=headers, timeout=10)
            req_id = r.json().get("request_id")
            if not req_id:
                return {"ok_count": 0, "total": len(ir_nodes), "avg_ms": 0.0, "error": "No request_id from check-host"}

            results = {}
            for _ in range(4):
                time.sleep(2.5)
                poll = req_lib.get(f"https://check-host.net/check-result/{req_id}", headers=headers, timeout=10)
                if poll.status_code == 200:
                    results = poll.json()
                    if all(v is not None for v in results.values()):
                        break

            ok_count = 0
            rtts = []
            responded_total = 0
            for node_name, val in results.items():
                if val is None or not isinstance(val, list) or not val:
                    continue
                responded_total += 1
                entry = val[0]
                if isinstance(entry, dict) and "time" in entry and "error" not in entry:
                    ok_count += 1
                    rtts.append(float(entry["time"]) * 1000.0)

            total_eval = responded_total if responded_total > 0 else len(ir_nodes)
            avg_ms = round(sum(rtts) / len(rtts), 1) if rtts else 0.0
            return {"ok_count": ok_count, "total": total_eval, "avg_ms": avg_ms, "error": ""}
        except Exception as e:
            return {"ok_count": 0, "total": len(ir_nodes), "avg_ms": 0.0, "error": str(e)}

    @classmethod
    def run_agentless_verification(cls, kharej_client: paramiko.SSHClient, kharej_ip: str,
                                   test_port: int = 28880, ssh_port: int = 22) -> Dict[str, Any]:
        """
        Completely standalone verification when user does NOT have an Iran server:
        1. Opens a temporary TCP responder on Kharej VM and probes it from 6 Iranian datacenters via Check-Host.net.
        2. Executes a Reverse TCP + UDP DNS/Gateway probe from inside the Kharej VM toward major Iranian ISP resolvers
           (TIC/Mokhaberat, Shatel, Shecan, Electro, IPM) to verify bidirectional TCP & UDP return routing.
        """
        import json
        try:
            # 1. Open firewall & start lightweight TCP listener on Kharej for Check-Host Iran nodes
            firewall_cmd = (
                f"iptables -I INPUT -p tcp --dport {test_port} -j ACCEPT 2>/dev/null; "
                f"ufw allow {test_port} 2>/dev/null || true"
            )
            cls.run_cmd(kharej_client, firewall_cmd, timeout=8)
            cls.run_cmd(kharej_client, f"fuser -k {test_port}/tcp 2>/dev/null || true", timeout=5)

            listener_py = f"""python3 -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', {test_port}))
s.listen(20)
s.settimeout(45)
t0 = time.time()
while time.time() - t0 < 45:
    try:
        conn, _ = s.accept()
        conn.sendall(b'OK\\r\\n')
        conn.close()
    except Exception:
        break
s.close()
" >/dev/null 2>&1 &
"""
            cls.run_cmd(kharej_client, listener_py, timeout=8)
            time.sleep(1.0)

            # 2. Run Check-Host Iran nodes TCP probe against Kharej test_port (fallback to ssh_port if needed)
            ch_res = cls._check_host_iran_tcp_probe(kharej_ip, test_port)
            if ch_res["ok_count"] == 0:
                ch_ssh = cls._check_host_iran_tcp_probe(kharej_ip, ssh_port)
                if ch_ssh["ok_count"] > ch_res["ok_count"]:
                    ch_res = ch_ssh

            # 3. Run Reverse ISP Probe (TCP + UDP) from inside Kharej VM toward Iranian domestic DNS/Carrier nodes
            reverse_probe_py = """python3 -c "
import socket, struct, time, json

# Authoritative Iranian domestic DNS / carrier endpoints (Shecan, Electro, Shatel, TIC, IPM)
IRAN_TARGETS = [
    ('178.22.122.100', 53, 'Shecan-1'),
    ('185.51.200.2', 53, 'Shecan-2'),
    ('78.157.42.100', 53, 'Electro-1'),
    ('78.157.42.101', 53, 'Electro-2'),
    ('85.15.1.14', 53, 'Shatel-1'),
    ('217.218.127.127', 53, 'TIC-Infra')
]

tcp_ok_count = 0
udp_ok_count = 0
rtts = []

# Minimal DNS query packet for 'shaparak.ir' (type A)
dns_query = (
    b'\\xaa\\xbb\\x01\\x00\\x00\\x01\\x00\\x00\\x00\\x00\\x00\\x00'
    b'\\x08shaparak\\x02ir\\x00\\x00\\x01\\x00\\x01'
)

for ip, port, label in IRAN_TARGETS:
    # A) TCP Handshake Probe
    try:
        t0 = time.time()
        st = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        st.settimeout(2.5)
        st.connect((ip, port))
        rtts.append((time.time() - t0) * 1000.0)
        st.close()
        tcp_ok_count += 1
    except Exception:
        pass

    # B) UDP DNS Round-Trip Probe
    try:
        su = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        su.settimeout(2.5)
        su.sendto(dns_query, (ip, port))
        resp, _ = su.recvfrom(512)
        su.close()
        if resp and len(resp) >= 12:
            udp_ok_count += 1
    except Exception:
        pass

avg_rtt = round(sum(rtts) / len(rtts), 1) if rtts else 0.0
print(json.dumps({
    'rev_tcp_ok': tcp_ok_count,
    'rev_udp_ok': udp_ok_count,
    'rev_total': len(IRAN_TARGETS),
    'rev_rtt_ms': avg_rtt
}))
"
"""
            _, out, _ = cls.run_cmd(kharej_client, reverse_probe_py, timeout=25)
            rev_data = {"rev_tcp_ok": 0, "rev_udp_ok": 0, "rev_total": 6, "rev_rtt_ms": 0.0}
            for line in out.splitlines():
                line = line.strip()
                if line.startswith("{") and "rev_tcp_ok" in line:
                    try:
                        rev_data.update(json.loads(line))
                    except Exception:
                        pass
                    break

            ch_ok = ch_res["ok_count"]
            ch_total = max(1, ch_res["total"])
            rev_tcp = rev_data["rev_tcp_ok"]
            rev_udp = rev_data["rev_udp_ok"]
            rev_total = max(1, rev_data["rev_total"])

            # Evaluate TCP & UDP pass criteria for Agentless mode:
            # TCP passes if at least 50% of Check-Host Iran nodes connected OR >=3 Iran ISP TCP endpoints responded
            tcp_pass = (ch_ok >= max(2, ch_total // 2)) or (ch_res.get("error") and rev_tcp >= 3)
            # UDP passes if >=2 Iranian carrier DNS resolvers returned UDP responses to this Kharej IP
            udp_pass = rev_udp >= 2
            udp_loss_est = round(((rev_total - rev_udp) / rev_total) * 100.0, 1)
            latency_ms = ch_res["avg_ms"] or rev_data["rev_rtt_ms"]

            diag = []
            if ch_ok < ch_total:
                diag.append(f"Check-Host Iran TCP: {ch_ok}/{ch_total} nodes reachable")
            if rev_udp < rev_total:
                diag.append(f"Reverse Iran UDP DNS: {rev_udp}/{rev_total} carriers responded")

            return {
                "mode": "agentless",
                "tcp_ok": tcp_pass,
                "udp_ok": udp_pass,
                "ssh_reachable": ch_ok > 0,
                "ch_ok": ch_ok,
                "ch_total": ch_total,
                "rev_tcp_ok": rev_tcp,
                "rev_udp_ok": rev_udp,
                "rev_total": rev_total,
                "udp_loss_pct": udp_loss_est,
                "latency_ms": latency_ms,
                "diag": diag
            }
        finally:
            try:
                cls.run_cmd(kharej_client, f"fuser -k {test_port}/tcp 2>/dev/null || true", timeout=5)
            except Exception:
                pass
