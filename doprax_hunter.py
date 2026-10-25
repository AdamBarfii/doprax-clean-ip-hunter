#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Doprax Clean IP Hunter (شکارچی آی‌پی تمیز دوپراکس)
Multi-Datacenter (ProVM, Vultr, Hetzner, DigitalOcean inside Doprax)
Multithreaded Parallel Verification, Local Dirty IP Database & Controlled Deletion.
"""

import os
import sys
import json
import time
import signal
import atexit
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Dict, Any, List, Set, Optional

from rich.console import Console
from rich.table import Table
from rich.panel import Panel
from rich.prompt import Prompt, Confirm, IntPrompt
from rich import box

from doprax_client import DopraxClient, DopraxAPIError
from ssh_manager import SSHManager
from dirty_manager import DirtyIPManager

console = Console()

CONFIG_FILE = "config.json"
CLEAN_SERVERS_FILE = "clean_servers.json"
CLEAN_SERVERS_TXT = "clean_servers.txt"

# Track active temporary VMs to guarantee emergency cleanup if process is killed
ACTIVE_TEMP_VMS: List[Dict[str, str]] = []  # [{"id": service_id, "ip": ip, "name": name}]
DOPRAX_CLIENT_INSTANCE: Optional[DopraxClient] = None


def load_config() -> Dict[str, Any]:
    """Loads configuration from config.json or returns defaults."""
    defaults = {
        "doprax_api_key": os.getenv("DOPRAX_API_KEY", ""),
        "iran_server": {
            "host": "",
            "port": 22,
            "username": "root",
            "password": "",
            "key_path": ""
        },
        "defaults": {
            "batch_size": 3,
            "provider": "vultr",
            "plan": "VC2-1C-1GB",
            "location": "DE, Frankfurt",
            "os": "ubuntu_24_04",
            "carrier": "auto"
        },
        "custom_servers": []
    }
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
                defaults.update(data)
        except Exception as e:
            console.print(f"[yellow]Warning: Could not read {CONFIG_FILE} ({e}). Using defaults.[/yellow]")
    return defaults


def save_config(cfg: Dict[str, Any]):
    """Persists config to config.json."""
    with open(CONFIG_FILE, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)


def emergency_cleanup():
    """Emergency hook: deletes any temporary VMs that were not approved if process is terminated."""
    global ACTIVE_TEMP_VMS, DOPRAX_CLIENT_INSTANCE
    if ACTIVE_TEMP_VMS and DOPRAX_CLIENT_INSTANCE:
        console.print("\n[bold red]⚠️  EMERGENCY CLEANUP TRIGGERED![/bold red]")
        console.print(f"[yellow]Cleaning up {len(ACTIVE_TEMP_VMS)} temporary VM(s) from Doprax...[/yellow]")
        for item in list(ACTIVE_TEMP_VMS):
            s_id = item.get("id")
            try:
                DOPRAX_CLIENT_INSTANCE.delete_instance(s_id)
                console.print(f"  [red]✓ Deleted Doprax VM: {s_id}[/red]")
            except Exception as e:
                console.print(f"  [red]✗ Error deleting VM {s_id}: {e}[/red]")
        ACTIVE_TEMP_VMS.clear()


def sigint_handler(sig, frame):
    console.print("\n[bold red]Process interrupted by user (Ctrl+C).[/bold red]")
    emergency_cleanup()
    sys.exit(1)

signal.signal(signal.SIGINT, sigint_handler)
signal.signal(signal.SIGTERM, sigint_handler)
atexit.register(emergency_cleanup)


def display_banner():
    banner = """[bold cyan]
██████╗  ██████╗ ██████╗ ██████╗  █████╗ ██╗  ██╗
██╔══██╗██╔═══██╗██╔══██╗██╔══██╗██╔══██╗╚██╗██╔╝
██║  ██║██║   ██║██████╔╝██████╔╝███████║ ╚███╔╝ 
██║  ██║██║   ██║██╔═══╝ ██╔══██╗██╔══██║ ██╔██╗ 
██████╔╝╚██████╔╝██║     ██║  ██║██║  ██║██╔╝ ██╗
╚═════╝  ╚═════╝ ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝
[bold yellow]   🚀 Doprax Clean IP Hunter (Vultr · ProVM · Hetzner · DO) 🚀[/bold yellow]
[dim]     Multithreaded Parallel Benchmarking | Local Dirty IP Storage[/dim]
[/bold cyan]"""
    console.print(banner)


def get_doprax_client(cfg: Dict[str, Any]) -> DopraxClient:
    global DOPRAX_CLIENT_INSTANCE
    key = cfg.get("doprax_api_key", "").strip()
    if not key:
        console.print("[yellow]No Doprax API Key found.[/yellow]")
        key = Prompt.ask("[bold green]Enter your Doprax API Key[/bold green]").strip()
        cfg["doprax_api_key"] = key
        save_config(cfg)
    client = DopraxClient(key)
    DOPRAX_CLIENT_INSTANCE = client
    return client


def configure_credentials_and_iran(cfg: Dict[str, Any]):
    console.print("\n[bold cyan]─── Configure Doprax API Key & Iran Server ───[/bold cyan]")
    cfg["doprax_api_key"] = Prompt.ask("Doprax API Key", default=cfg.get("doprax_api_key", ""))

    iran = cfg.setdefault("iran_server", {})
    console.print("\n[bold cyan]Iran Server SSH Settings:[/bold cyan]")
    iran["host"] = Prompt.ask("Iran Server IP", default=iran.get("host", ""))
    iran["port"] = IntPrompt.ask("Iran Server SSH Port", default=int(iran.get("port", 22)))
    iran["username"] = Prompt.ask("Iran Server Username", default=iran.get("username", "root"))
    
    use_pass = Confirm.ask("Authenticate Iran server with Password?", default=bool(iran.get("password") or not iran.get("key_path")))
    if use_pass:
        iran["password"] = Prompt.ask("Iran Server Password", default=iran.get("password", ""), password=True)
        iran["key_path"] = ""
    else:
        iran["key_path"] = Prompt.ask("Path to Private Key", default=iran.get("key_path", ""))
        iran["password"] = ""

    save_config(cfg)
    console.print("[green]Testing Iran server connection...[/green]")
    ok, msg = SSHManager.test_iran_connection(iran)
    if ok:
        console.print(f"[bold green]✓ {msg}[/bold green]")
    else:
        console.print(f"[bold red]✗ {msg}[/bold red]")


def show_doprax_balance(doprax: DopraxClient):
    with console.status("[cyan]Fetching account and financial info from Doprax...[/cyan]"):
        try:
            acc = doprax.get_account_info()
            bal = doprax.get_available_balance(min_required_cents=100)
        except Exception as e:
            console.print(f"[red]Error fetching Doprax status: {e}[/red]")
            return

    table = Table(title="Doprax Account & Balance Status", box=box.ROUNDED)
    table.add_column("Property", style="bold cyan")
    table.add_column("Value", style="green")

    table.add_row("Account Name", str(acc.get("name", "N/A")))
    table.add_row("Email", str(acc.get("email", "N/A")))
    table.add_row("Active VMs", f"{acc.get('currentVmCount', 0)} / {acc.get('numVmLimit', 0)} max")
    
    cents = bal.get("available_balance_cents", 0)
    table.add_row("Available Balance", f"${cents/100:.2f} USD ({cents} cents)")
    table.add_row("Sufficient Balance", "[bold green]YES[/bold green]" if bal.get("is_sufficient") else "[bold red]LOW BALANCE[/bold red]")
    console.print(table)


# ==============================================================================
#  Parallel Worker Test Routine
# ==============================================================================

def worker_test_single_vm(target: Dict[str, Any], iran_cfg: Dict[str, Any], carrier: str) -> Dict[str, Any]:
    """
    Executes in a dedicated background worker thread:
    1. Checks if IP was previously flagged in local Dirty Database.
    2. Waits for SSH & cloud-init password activation.
    3. Deploys WatTunnel on Kharej VM.
    4. Runs bidirectional TCP/UDP benchmark against Iran server.
    """
    ip = target.get("ip")
    s_id = target.get("id")
    pwd = target.get("password")
    name = target.get("name", ip)
    datacenter = target.get("datacenter", "Doprax")

    result = {
        "idx": target.get("idx", 1),
        "name": name,
        "id": s_id,
        "ip": ip,
        "datacenter": datacenter,
        "password": pwd,
        "token": "",
        "tcp_result": "Pending",
        "udp_result": "Pending",
        "clean": False,
        "pre_flagged": False,
        "details": {}
    }

    # Pre-check: Is this IP already in our local Dirty Database?
    dirty_rec = DirtyIPManager.is_dirty(ip)
    if dirty_rec:
        result["pre_flagged"] = True
        result["tcp_result"] = "Pre-Flagged Dirty"
        result["udp_result"] = f"Seen {dirty_rec.get('flagged_at', '')[:10]}"
        result["clean"] = False
        console.print(f"[bold red]⚠️  [{name} - {ip}] PRE-FLAGGED DIRTY! (Found in local dirty IP database: {dirty_rec.get('reason')})[/bold red]")
        return result

    # 1. Wait for SSH server to be fully ready and sending protocol banners
    if not SSHManager.wait_for_ssh_ready(ip, 22, timeout=90):
        result["tcp_result"] = "SSH Timeout"
        result["udp_result"] = "Skipped"
        result["clean"] = False
        DirtyIPManager.record_dirty_ip(ip, provider=datacenter, reason="SSH Port 22 Unreachable or No Banner")
        return result

    # 2. SSH Connection with cloud-init retry loop
    kharej_client = None
    token = ""
    try:
        kharej_client = SSHManager.create_client_with_retry(
            host=ip, port=22, username="root", password=pwd, max_wait=90, retry_interval=4
        )
        ok, token_res, _ = SSHManager.install_and_setup_wattunnel_kharej(
            kharej_client, public_ip=ip, tunnel_name=f"tun{result['idx']}", carrier=carrier
        )
        if ok:
            token = token_res
            result["token"] = token
    except Exception as e:
        result["tcp_result"] = "SSH/WatTun Error"
        result["udp_result"] = "Error"
        result["clean"] = False
        DirtyIPManager.record_dirty_ip(ip, provider=datacenter, reason=f"SSH/WatTunnel setup failure: {e}")
        return result

    # 3. Benchmark from Iran
    iran_client = None
    try:
        # Small stagger to prevent threads from hammering Iran sshd simultaneously
        time.sleep((result.get("idx", 1) % 4) * 0.4)
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
            test_port=28880
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

        if is_clean:
            console.print(f"[bold green]🎉 [{name} - {ip}] CLEAN IP CONFIRMED! TCP: ↓{t_down}K ↑{t_up}K | UDP Loss: {u_loss}% | {latency}ms[/bold green]")
        else:
            reason = "GFW Blocked" if not ssh_reach else "TCP/UDP Packet Loss"
            DirtyIPManager.record_dirty_ip(ip, provider=datacenter, reason=reason, diag=diag, details=bench)
            console.print(f"[bold red]🚫 [{name} - {ip}] DIRTY/BLOCKED IP: TCP ok: {tcp_ok} | UDP ok: {udp_ok} | Loss: {u_loss}%[/bold red]")
            if not ssh_reach:
                console.print(f"    [bold yellow]↳ GFW Blocked: Port 22 unreachable from Iran[/bold yellow]")
            elif diag:
                console.print(f"    [dim]↳ Diag: {'; '.join(diag)}[/dim]")

    except Exception as e:
        result["tcp_result"] = "Benchmark Error"
        result["udp_result"] = "Error"
        result["clean"] = False
        DirtyIPManager.record_dirty_ip(ip, provider=datacenter, reason=f"Benchmark error: {e}")
    finally:
        if kharej_client:
            kharej_client.close()
        if iran_client:
            iran_client.close()

    return result


def prompt_deletion_options(records: List[Dict[str, Any]], doprax: DopraxClient):
    """
    Presents controlled deletion choices to the user:
    1. Delete only dirty servers in this batch
    2. Choose specific servers to delete
    3. Keep all servers (do not delete anything)
    """
    dirty_records = [r for r in records if not r.get("clean", False)]
    clean_records = [r for r in records if r.get("clean", False)]

    console.print(Panel(
        f"[bold cyan]Post-Scan Management ({len(records)} Servers Tested)[/bold cyan]\n"
        f"• Clean Servers: [bold green]{len(clean_records)}[/bold green]\n"
        f"• Dirty/Blocked Servers: [bold red]{len(dirty_records)}[/bold red]",
        title="Action Options",
        box=box.ROUNDED
    ))

    console.print("[bold yellow]Choose deletion action:[/bold yellow]")
    console.print("  [1] [bold red]🗑️  Delete ALL Dirty/Blocked servers in this batch[/bold red] (Stops billing for bad IPs)")
    console.print("  [2] [bold yellow]🎯 Select specific servers to delete[/bold yellow]")
    console.print("  [3] [bold green]💾 Keep all servers[/bold green] (Do not delete anything)")

    act = Prompt.ask("Choose action", choices=["1", "2", "3"], default="1" if dirty_records else "3")

    to_delete = []
    if act == "1":
        to_delete = dirty_records
    elif act == "2":
        console.print("\nServers in this batch:")
        for r in records:
            status_lbl = "[green]CLEAN[/green]" if r.get("clean") else "[red]DIRTY[/red]"
            console.print(f"  #{r['idx']} {r['ip']} ({r.get('datacenter', 'Doprax')}) - {status_lbl}")
        idxs = Prompt.ask("Enter numbers to delete (e.g. 1, 3)").split(",")
        for idx_str in idxs:
            try:
                num = int(idx_str.strip())
                for r in records:
                    if r["idx"] == num:
                        to_delete.append(r)
            except ValueError:
                pass
    elif act == "3":
        console.print("[green]Keeping all servers running as requested.[/green]")
        return

    if to_delete:
        for r in to_delete:
            s_id = r.get("id")
            ip = r.get("ip")
            try:
                doprax.delete_instance(s_id)
                console.print(f"  [red]✓ Deleted Doprax VM {s_id} ({ip}). Billing halted.[/red]")
                r["action_taken"] = "DELETED"
            except Exception as e:
                console.print(f"  [red]✗ Error deleting VM {s_id}: {e}[/red]")


# ==============================================================================
#  Unified Doprax Datacenter Hunter (Vultr, ProVM, Hetzner, etc.)
# ==============================================================================

def select_datacenter_location_and_plan(plans: List[Dict[str, Any]], provider_code: str) -> Tuple[str, str]:
    """
    Intelligently displays all available locations for the selected provider (Vultr, Hetzner, ProVM, DO, etc.).
    Places high-demand locations like Germany (Frankfurt), Netherlands (Amsterdam), Poland (Warsaw) at the top.
    Supports direct number selection, typing 'germany'/'fra'/'de' keyword filter, or resetting with 'all'.
    Then displays all plans available in that location sorted by price (cheapest first).
    Returns (plan_name, location_name).
    """
    if not plans:
        plan_name = Prompt.ask("Plan Name", default="VC2-1C-1GB" if provider_code == "vultr" else "P1")
        location_name = Prompt.ask("Location", default="DE, Frankfurt" if provider_code == "vultr" else "Poland")
        return plan_name, location_name

    # 1. Aggregate unique locations and map their plans
    loc_map: Dict[str, Dict[str, Any]] = {}
    for p in plans:
        p_name = p.get("plan", "")
        ram = p.get("ram_gb", 0)
        cpu = p.get("cpu", 0)
        disk = p.get("disk_gb") or p.get("disk", 0)
        price = p.get("monthly_price", 0)
        for loc in p.get("locations", []):
            name = loc.get("name", "").strip()
            code = loc.get("code", "").strip()
            if not name:
                continue
            if name not in loc_map:
                loc_map[name] = {
                    "name": name,
                    "code": code,
                    "plans": []
                }
            loc_map[name]["plans"].append({
                "plan": p_name,
                "ram": ram,
                "cpu": cpu,
                "disk": disk,
                "price": price
            })

    # Sort plans within each location by price ascending (cheapest first)
    for l_data in loc_map.values():
        l_data["plans"].sort(key=lambda x: (x["price"], x["ram"]))

    # Sort locations with priority: Germany & Western Europe first, then Europe, Asia, Americas, Oceania
    def get_sort_weight(loc_name: str) -> Tuple[int, str]:
        n = loc_name.upper()
        # Germany / Frankfurt
        if any(k in n for k in ["DE,", "FRANKFURT", "GERMANY", "FALKENSTEIN", "NUREMBERG"]):
            return (0, loc_name)
        # Netherlands / Poland / France / UK
        elif any(k in n for k in ["NL,", "AMSTERDAM", "PL,", "WARSAW", "POLAND", "FR,", "PARIS", "GB,", "LONDON"]):
            return (1, loc_name)
        # Rest of Europe
        elif any(k in n for k in ["MANCHESTER", "UNITED KINGDOM", "SE,", "STOCKHOLM", "ES,", "MADRID", "FI,", "HELSINKI"]):
            return (2, loc_name)
        # Asia / Middle East
        elif any(k in n for k in ["JP,", "TOKYO", "OSAKA", "SG,", "SINGAPORE", "KR,", "SEOUL", "IL,", "TEL AVIV", "IN,", "MUMBAI", "BANGALORE", "DELHI"]):
            return (3, loc_name)
        # Americas
        elif any(k in n for k in ["US,", "NEW JERSEY", "ATLANTA", "CHICAGO", "DALLAS", "LOS ANGELES", "MIAMI", "SEATTLE", "SILICON VALLEY", "NEW YORK", "SAN FRANCISCO", "CA,", "TORONTO", "BR,", "CL,", "MX,"]):
            return (4, loc_name)
        else:
            return (5, loc_name)

    all_locs = sorted(loc_map.values(), key=lambda x: get_sort_weight(x["name"]))

    # Interactive Location Selection Loop with Search/Filter support
    current_list = all_locs
    selected_loc_name = ""
    selected_loc_code = ""

    while True:
        loc_table = Table(title=f"All Available Locations for {provider_code.upper()} ({len(current_list)} total)", box=box.ROUNDED)
        loc_table.add_column("#", style="dim", justify="right")
        loc_table.add_column("Location Name", style="bold green")
        loc_table.add_column("Datacenter Code", style="cyan")
        loc_table.add_column("Plans", justify="center")
        loc_table.add_column("Starting Price", style="yellow")
        loc_table.add_column("Cheapest Plan", style="dim")

        for idx, l in enumerate(current_list, start=1):
            cheapest = l["plans"][0] if l["plans"] else {}
            c_price = f"${cheapest.get('price', 0)}/mo" if cheapest else "N/A"
            c_plan = cheapest.get("plan", "")
            loc_table.add_row(str(idx), l["name"], l["code"], str(len(l["plans"])), c_price, c_plan)

        console.print(loc_table)
        console.print("[dim]💡 Tip: Enter # to select, or type search text (e.g. 'germany', 'fra', 'de', 'ams', 'warsaw', or 'all' to reset).[/dim]")

        # Default suggestion: #1 (which is Germany / Frankfurt for Vultr/Hetzner)
        def_choice = "1"
        user_input = Prompt.ask(f"Select location # [1-{len(current_list)}] or search", default=def_choice).strip()

        if user_input.lower() == "all":
            current_list = all_locs
            continue

        if user_input.isdigit():
            val = int(user_input)
            if 1 <= val <= len(current_list):
                selected = current_list[val - 1]
                selected_loc_name = selected["name"]
                selected_loc_code = selected["code"]
                break
            else:
                console.print(f"[red]Please enter a number between 1 and {len(current_list)}[/red]")
                continue

        # Treat as search query
        query = user_input.lower()
        matches = [
            l for l in all_locs
            if query in l["name"].lower() or query in l["code"].lower()
            or ("germany" in query and any(g in l["name"].lower() for g in ["de,", "frankfurt", "falkenstein", "nuremberg"]))
            or (query in "germany" and any(g in l["name"].lower() for g in ["de,", "frankfurt", "falkenstein", "nuremberg"]))
            or (query in "netherlands" and any(n in l["name"].lower() for n in ["nl,", "amsterdam"]))
            or (query in "poland" and any(p in l["name"].lower() for p in ["pl,", "warsaw", "poland"]))
        ]

        if not matches:
            console.print(f"[yellow]No locations found matching '{user_input}'. Showing all locations.[/yellow]")
            current_list = all_locs
        elif len(matches) == 1:
            selected = matches[0]
            console.print(f"[bold green]✓ Auto-selected matching location: {selected['name']} ({selected['code']})[/bold green]")
            selected_loc_name = selected["name"]
            selected_loc_code = selected["code"]
            break
        else:
            console.print(f"[cyan]Found {len(matches)} matching locations for '{user_input}':[/cyan]")
            current_list = matches

    console.print(f"\n[bold green]✓ Chosen Location: {selected_loc_name} ({selected_loc_code})[/bold green]")

    # 2. Plan Selection for this Location
    available_plans = loc_map[selected_loc_name]["plans"]
    plan_table = Table(title=f"Available Plans in {selected_loc_name} (Cheapest First)", box=box.ROUNDED)
    plan_table.add_column("#", style="dim", justify="right")
    plan_table.add_column("Plan Name", style="bold cyan")
    plan_table.add_column("RAM / CPU", style="green")
    plan_table.add_column("Disk", style="dim")
    plan_table.add_column("Monthly Price", style="bold yellow")
    plan_table.add_column("Recommendation", style="bold")

    for p_idx, p in enumerate(available_plans, start=1):
        note = "[bold green]★ Recommended (Cheapest)[/bold green]" if p_idx == 1 else ""
        plan_table.add_row(
            str(p_idx),
            p["plan"],
            f"{p['ram']} GB / {p['cpu']} CPU",
            f"{p['disk']} GB",
            f"${p['price']}/mo",
            note
        )
    console.print(plan_table)

    chosen_p_idx = IntPrompt.ask(f"Select plan # [1-{len(available_plans)}]", default=1)
    selected_plan_info = available_plans[min(max(1, chosen_p_idx) - 1, len(available_plans) - 1)]
    plan_name = selected_plan_info["plan"]

    console.print(f"[bold green]✓ Selected Plan: {plan_name} (${selected_plan_info['price']}/mo) in {selected_loc_name}[/bold green]\n")
    return plan_name, selected_loc_name


def run_doprax_datacenter_hunter(doprax: DopraxClient, cfg: Dict[str, Any]):
    global ACTIVE_TEMP_VMS
    console.print(Panel("[bold yellow]⚡ Doprax Multi-Datacenter Hunter (Vultr · ProVM · Hetzner) ⚡[/bold yellow]\n"
                        "Choose your preferred datacenter inside Doprax (e.g. Vultr, ProVM, Hetzner, DigitalOcean).\n"
                        "Spins up VMs in parallel, checks local dirty IP records, benchmarks from Iran, and gives controlled deletion.",
                        box=box.ROUNDED))

    # Pre-flight: Check Iran server
    iran_cfg = cfg.get("iran_server", {})
    if not iran_cfg.get("host"):
        configure_credentials_and_iran(cfg)
        iran_cfg = cfg.get("iran_server", {})

    with console.status("[cyan]Verifying Iran server SSH connection...[/cyan]"):
        ok, msg = SSHManager.test_iran_connection(iran_cfg)
        if not ok:
            console.print(f"[bold red]❌ Cannot proceed: {msg}[/bold red]")
            return

    # Check Doprax balance
    with console.status("[cyan]Checking Doprax available balance...[/cyan]"):
        bal = doprax.get_available_balance(min_required_cents=100)
        cents = bal.get("available_balance_cents", 0)
        if cents < 100:
            console.print(f"[bold red]⚠️ Low Balance: ${cents/100:.2f} USD.[/bold red]")
            if not Confirm.ask("Balance is low. Continue anyway?", default=False):
                return

    # Datacenter Provider Selection inside Doprax
    console.print("\n[bold cyan]Select Datacenter Provider inside Doprax:[/bold cyan]")
    console.print("  [1] [bold green]Vultr (via Doprax)[/bold green] - Frankfurt (Germany), Amsterdam, Paris, London, Tokyo, Warsaw, etc.")
    console.print("  [2] [bold magenta]Hetzner (via Doprax)[/bold magenta] - Germany (Falkenstein, Nuremberg), Finland, US")
    console.print("  [3] [bold blue]ProVM (Doprax Native)[/bold blue] - Poland, UK")
    console.print("  [4] [bold yellow]DigitalOcean (via Doprax)[/bold yellow] - Frankfurt, Amsterdam, London, NY, etc.")
    console.print("  [5] Custom Provider Code (e.g. gcore, ovh, scaleway)")

    prov_choice = Prompt.ask("Choose provider", choices=["1", "2", "3", "4", "5"], default="1")
    prov_map = {
        "1": "vultr",
        "2": "hetzner",
        "3": "provm",
        "4": "digitalocean"
    }
    provider_code = prov_map.get(prov_choice)
    if prov_choice == "5":
        provider_code = Prompt.ask("Enter provider code", default="vultr").strip().lower()

    # Query available plans and locations for this provider from Doprax
    plans = []
    with console.status(f"[cyan]Fetching {provider_code.upper()} plans and locations from Doprax...[/cyan]"):
        try:
            plans = doprax.list_plans(provider=provider_code)
        except Exception as e:
            console.print(f"[red]Error listing plans for {provider_code}: {e}[/red]")

    plan_name, location_name = select_datacenter_location_and_plan(plans, provider_code)

    defaults = cfg.get("defaults", {})
    batch_size = IntPrompt.ask("Batch size (number of servers to create & test in parallel)", default=int(defaults.get("batch_size", 3)))
    os_image = defaults.get("os", "ubuntu_24_04")
    carrier = defaults.get("carrier", "auto")

    console.print(f"\n[cyan]Starting hunt: {batch_size} VM(s) | Provider: {provider_code.upper()} | Plan: {plan_name} | Location: {location_name}[/cyan]")
    if not Confirm.ask("[bold green]Start provisioning now?[/bold green]", default=True):
        return

    # Step 1: Create VMs on Doprax
    console.print(f"\n[bold cyan]Step 1/3: Provisioning {batch_size} VM(s) on Doprax ({provider_code.upper()})...[/bold cyan]")
    batch_records = []
    prefix = provider_code[:3]
    for i in range(1, batch_size + 1):
        vm_name = f"{prefix}-{int(time.time())%10000}-{i}"
        try:
            res = doprax.create_vm_v3(plan=plan_name, location=location_name, name=vm_name, os_name=os_image)
            s_id = res.get("service_id")
            if s_id:
                ACTIVE_TEMP_VMS.append({"id": s_id, "ip": "", "name": vm_name})
                batch_records.append({
                    "idx": i, "name": vm_name, "id": s_id, "datacenter": f"Doprax/{provider_code.upper()}",
                    "ip": "booting...", "password": "", "clean": False
                })
                console.print(f"  [green]✓ Created {provider_code.upper()} VM #{i}: {vm_name} (ID: {s_id})[/green]")
        except Exception as e:
            console.print(f"  [red]✗ Failed to create VM #{i}: {e}[/red]")

    if not batch_records:
        console.print("[red]No VMs were created. Aborting.[/red]")
        return

    # Step 2: Poll in parallel until running & cloud-init ready
    console.print("\n[bold cyan]Step 2/3: Waiting for VMs to boot and activate root password...[/bold cyan]")
    def doprax_poll_worker(item):
        s_id = item["id"]
        ip, vm_code, pwd = doprax.poll_until_ready(s_id, max_wait_sec=300)
        item["ip"] = ip
        item["password"] = pwd
        for t in ACTIVE_TEMP_VMS:
            if t["id"] == s_id:
                t["ip"] = ip
        return item

    with console.status("[cyan]Waiting for all VMs to reach running status...[/cyan]"):
        with ThreadPoolExecutor(max_workers=len(batch_records)) as ex:
            futs = [ex.submit(doprax_poll_worker, item) for item in batch_records]
            for f in as_completed(futs):
                try:
                    res_item = f.result()
                    console.print(f"  [green]✓ VM #{res_item['idx']} ({res_item['name']}) is ready: {res_item['ip']}[/green]")
                except Exception as e:
                    console.print(f"  [red]✗ Error waiting for VM: {e}[/red]")

    # Step 3: Run Multithreaded Parallel Testing!
    console.print("\n[bold cyan]Step 3/3: Running parallel WatTunnel & Protocol Benchmarks...[/bold cyan]")
    results = []
    with console.status(f"[cyan]Testing {len(batch_records)} servers simultaneously in parallel threads...[/cyan]"):
        with ThreadPoolExecutor(max_workers=len(batch_records)) as executor:
            futures = [executor.submit(worker_test_single_vm, item, iran_cfg, carrier) for item in batch_records]
            for fut in as_completed(futures):
                try:
                    res = fut.result()
                    results.append(res)
                except Exception as e:
                    console.print(f"[red]Thread test exception: {e}[/red]")

    results.sort(key=lambda x: x["idx"])

    # Summary Table
    console.print("\n")
    report_table = Table(title=f"Doprax ({provider_code.upper()}) Multithreaded Scan Results", box=box.HEAVY_EDGE)
    report_table.add_column("#", style="dim")
    report_table.add_column("Public IP", style="bold")
    report_table.add_column("Datacenter", style="cyan")
    report_table.add_column("TCP Test", style="green")
    report_table.add_column("UDP Test", style="magenta")
    report_table.add_column("Result", style="bold")

    for r in results:
        res_style = "[bold green]CLEAN (تمیز)[/bold green]" if r["clean"] else ("[yellow]FLAGGED DIRTY[/yellow]" if r.get("pre_flagged") else "[bold red]DIRTY (مسدود)[/bold red]")
        report_table.add_row(str(r["idx"]), r["ip"], r.get("datacenter", "Doprax"), r["tcp_result"], r["udp_result"], res_style)
    console.print(report_table)

    # Save clean servers
    clean_servers = [r for r in results if r["clean"]]
    if clean_servers:
        save_clean_records(clean_servers)
        for cs in clean_servers:
            ACTIVE_TEMP_VMS[:] = [t for t in ACTIVE_TEMP_VMS if t["id"] != cs["id"]]

    # Controlled Deletion Prompt
    prompt_deletion_options(results, doprax=doprax)


# ==============================================================================
#  Test Existing Doprax VMs (Multithreaded)
# ==============================================================================

def test_existing_doprax_vms(doprax: DopraxClient, cfg: Dict[str, Any]):
    """Tests existing VMs already in Doprax account using parallel worker threads."""
    console.print(Panel("[bold yellow]🧪 Test Existing Doprax VMs (Multithreaded) 🧪[/bold yellow]\n"
                        "Parallel benchmark for currently active Doprax VMs with controlled deletion.",
                        box=box.ROUNDED))

    iran_cfg = cfg.get("iran_server", {})
    if not iran_cfg.get("host"):
        configure_credentials_and_iran(cfg)
        iran_cfg = cfg.get("iran_server", {})

    with console.status("[cyan]Verifying Iran server SSH connection...[/cyan]"):
        ok, msg = SSHManager.test_iran_connection(iran_cfg)
        if not ok:
            console.print(f"[bold red]❌ Cannot proceed: {msg}[/bold red]")
            return

    with console.status("[cyan]Retrieving active instances from Doprax...[/cyan]"):
        try:
            instances = doprax.list_instances(service_type="vm")
        except Exception as e:
            console.print(f"[red]Error listing instances: {e}[/red]")
            return

    if not instances:
        console.print("[yellow]No active VMs found on your Doprax account.[/yellow]")
        return

    table = Table(title=f"Existing Doprax VMs ({len(instances)})", box=box.ROUNDED)
    table.add_column("#", style="dim")
    table.add_column("Service ID", style="cyan")
    table.add_column("Name", style="bold")
    table.add_column("Status", style="green")

    for i, inst in enumerate(instances, start=1):
        table.add_row(str(i), inst.get("service_id", ""), inst.get("name", "unnamed"), inst.get("status", "unknown"))
    console.print(table)

    test_all = Confirm.ask(f"Test all {len(instances)} existing VM(s)?", default=True)
    selected = instances if test_all else []
    if not test_all:
        idxs = Prompt.ask("Enter VM numbers to test (e.g. 1, 2)", default="1").split(",")
        for idx_str in idxs:
            try:
                num = int(idx_str.strip())
                if 1 <= num <= len(instances):
                    selected.append(instances[num - 1])
            except ValueError:
                pass

    if not selected:
        console.print("[yellow]No VMs selected.[/yellow]")
        return

    carrier = cfg.get("defaults", {}).get("carrier", "auto")

    targets = []
    for i, inst in enumerate(selected, start=1):
        s_id = inst.get("service_id")
        name = inst.get("name", f"vm-{i}")
        detail = doprax.get_instance_detail(s_id)
        access = detail.get("access", {})
        ip = access.get("public_ipv4")
        vm_code = detail.get("service", {}).get("metadata", {}).get("vm_code")
        pwd = ""
        if vm_code:
            cred_info = doprax.get_vm_access(vm_code)
            pwd = cred_info.get("tempPass") or ""
        targets.append({
            "idx": i, "name": name, "id": s_id, "ip": ip, "password": pwd,
            "datacenter": "Doprax", "clean": False
        })

    console.print(f"\n[cyan]Starting parallel test of {len(targets)} server(s)...[/cyan]")
    results = []
    with console.status(f"[cyan]Testing {len(targets)} server(s) concurrently in parallel...[/cyan]"):
        with ThreadPoolExecutor(max_workers=len(targets)) as executor:
            futures = [executor.submit(worker_test_single_vm, item, iran_cfg, carrier) for item in targets]
            for fut in as_completed(futures):
                try:
                    res = fut.result()
                    results.append(res)
                except Exception as e:
                    console.print(f"[red]Thread error: {e}[/red]")

    results.sort(key=lambda x: x["idx"])

    # Table
    console.print("\n")
    report_table = Table(title="Existing Doprax VMs Parallel Test Results", box=box.HEAVY_EDGE)
    report_table.add_column("#", style="dim")
    report_table.add_column("Public IP", style="bold")
    report_table.add_column("TCP Test", style="cyan")
    report_table.add_column("UDP Test", style="magenta")
    report_table.add_column("Result", style="bold")

    for r in results:
        res_style = "[bold green]CLEAN (تمیز)[/bold green]" if r["clean"] else ("[yellow]FLAGGED DIRTY[/yellow]" if r.get("pre_flagged") else "[bold red]DIRTY (مسدود)[/bold red]")
        report_table.add_row(str(r["idx"]), r["ip"], r["tcp_result"], r["udp_result"], res_style)
    console.print(report_table)

    clean_servers = [r for r in results if r["clean"]]
    if clean_servers:
        save_clean_records(clean_servers)

    prompt_deletion_options(results, doprax=doprax)


# ==============================================================================
#  Custom Servers Testing (Multithreaded)
# ==============================================================================

def test_custom_servers(cfg: Dict[str, Any]):
    """Tests custom external servers using parallel worker threads."""
    console.print(Panel("[bold cyan]🎯 Test Custom Servers (Multithreaded) 🎯[/bold cyan]\n"
                        "Benchmarks your custom foreign VPS servers simultaneously against your Iran server.",
                        box=box.ROUNDED))

    iran_cfg = cfg.get("iran_server", {})
    if not iran_cfg.get("host"):
        configure_credentials_and_iran(cfg)
        iran_cfg = cfg.get("iran_server", {})

    with console.status("[cyan]Verifying Iran server SSH connection...[/cyan]"):
        ok, msg = SSHManager.test_iran_connection(iran_cfg)
        if not ok:
            console.print(f"[bold red]❌ Cannot proceed: {msg}[/bold red]")
            return

    custom_servers = cfg.setdefault("custom_servers", [])

    console.print("\n[bold yellow]Custom Server Options:[/bold yellow]")
    console.print("  [1] Test a new custom server now")
    console.print(f"  [2] Test all saved custom servers ({len(custom_servers)} saved)")
    console.print("  [3] Load custom servers from a text file (custom_servers.txt)")
    console.print("  [4] Add/Save a custom server to list")
    console.print("  [0] Back to main menu")

    sub_choice = Prompt.ask("Choose option", choices=["1", "2", "3", "4", "0"], default="1")
    targets_to_test = []

    if sub_choice == "0":
        return
    elif sub_choice == "1":
        ip = Prompt.ask("Custom Server IP").strip()
        port = IntPrompt.ask("SSH Port", default=22)
        username = Prompt.ask("SSH Username", default="root").strip()
        use_pass = Confirm.ask("Authenticate with Password?", default=True)
        pwd = Prompt.ask("SSH Password", password=True) if use_pass else ""
        key_path = "" if use_pass else Prompt.ask("Private Key Path")
        srv_entry = {"host": ip, "port": port, "username": username, "password": pwd, "key_path": key_path, "name": f"custom-{ip}"}
        if Confirm.ask("Save this server to config for future scans?", default=True):
            custom_servers.append(srv_entry)
            save_config(cfg)
        targets_to_test.append(srv_entry)
    elif sub_choice == "2":
        if not custom_servers:
            console.print("[yellow]No custom servers saved yet.[/yellow]")
            return
        targets_to_test = list(custom_servers)
    elif sub_choice == "3":
        fname = Prompt.ask("Text file path", default="custom_servers.txt")
        if not os.path.exists(fname):
            console.print(f"[yellow]File {fname} not found.[/yellow]")
            return
        with open(fname, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split(":")
                if len(parts) >= 4:
                    targets_to_test.append({
                        "host": parts[0].strip(), "port": int(parts[1].strip()),
                        "username": parts[2].strip(), "password": ":".join(parts[3:]).strip(),
                        "key_path": "", "name": f"custom-{parts[0]}"
                    })
                elif len(parts) == 2:
                    targets_to_test.append({
                        "host": parts[0].strip(), "port": 22, "username": "root",
                        "password": parts[1].strip(), "key_path": "", "name": f"custom-{parts[0]}"
                    })
    elif sub_choice == "4":
        ip = Prompt.ask("Custom Server IP").strip()
        port = IntPrompt.ask("SSH Port", default=22)
        username = Prompt.ask("SSH Username", default="root").strip()
        use_pass = Confirm.ask("Authenticate with Password?", default=True)
        pwd = Prompt.ask("SSH Password", password=True) if use_pass else ""
        key_path = "" if use_pass else Prompt.ask("Private Key Path")
        name = Prompt.ask("Server Name", default=f"custom-{ip}")
        custom_servers.append({"host": ip, "port": port, "username": username, "password": pwd, "key_path": key_path, "name": name})
        save_config(cfg)
        console.print("[bold green]✓ Custom server saved successfully![/bold green]")
        return

    if not targets_to_test:
        console.print("[yellow]No custom servers to test.[/yellow]")
        return

    carrier = cfg.get("defaults", {}).get("carrier", "auto")
    targets = [{
        "idx": i, "name": srv.get("name", srv["host"]), "id": f"cust-{i}",
        "ip": srv["host"], "password": srv.get("password", ""), "datacenter": "Custom",
        "clean": False
    } for i, srv in enumerate(targets_to_test, start=1)]

    console.print(f"\n[cyan]Benchmarking {len(targets)} custom server(s) in parallel threads...[/cyan]")
    results = []
    with console.status(f"[cyan]Testing {len(targets)} custom server(s) concurrently...[/cyan]"):
        with ThreadPoolExecutor(max_workers=len(targets)) as executor:
            futures = [executor.submit(worker_test_single_vm, item, iran_cfg, carrier) for item in targets]
            for fut in as_completed(futures):
                try:
                    res = fut.result()
                    results.append(res)
                except Exception as e:
                    console.print(f"[red]Thread error: {e}[/red]")

    results.sort(key=lambda x: x["idx"])

    # Table
    console.print("\n")
    report_table = Table(title="Custom Servers Parallel Test Results", box=box.HEAVY_EDGE)
    report_table.add_column("#", style="dim")
    report_table.add_column("Public IP", style="bold")
    report_table.add_column("TCP Test", style="cyan")
    report_table.add_column("UDP Test", style="magenta")
    report_table.add_column("Result", style="bold")

    for r in results:
        res_style = "[bold green]CLEAN (تمیز)[/bold green]" if r["clean"] else ("[yellow]FLAGGED DIRTY[/yellow]" if r.get("pre_flagged") else "[bold red]DIRTY (مسدود)[/bold red]")
        report_table.add_row(str(r["idx"]), r["ip"], r["tcp_result"], r["udp_result"], res_style)
    console.print(report_table)

    clean_servers = [r for r in results if r["clean"]]
    if clean_servers:
        if Confirm.ask("Save clean custom servers to clean_servers.txt?", default=True):
            save_clean_records(clean_servers)


# ==============================================================================
#  View Storage Databases
# ==============================================================================

def save_clean_records(servers: List[Dict[str, Any]]):
    """Saves verified clean servers to JSON and TXT logs."""
    existing = []
    if os.path.exists(CLEAN_SERVERS_FILE):
        try:
            with open(CLEAN_SERVERS_FILE, "r", encoding="utf-8") as f:
                existing = json.load(f)
        except Exception:
            pass
    for s in servers:
        existing.append({
            "service_id": s.get("id"),
            "ip": s.get("ip"),
            "datacenter": s.get("datacenter", "Doprax"),
            "password": s.get("password"),
            "ssh_cmd": f"ssh root@{s.get('ip')}",
            "token": s.get("token", ""),
            "tcp_down_kb": s.get("details", {}).get("tcp_down_kb", 0),
            "tcp_up_kb": s.get("details", {}).get("tcp_up_kb", 0),
            "udp_loss_pct": s.get("details", {}).get("udp_loss_pct", 0),
            "latency_ms": s.get("details", {}).get("latency_ms", 0),
            "saved_at": time.strftime("%Y-%m-%d %H:%M:%S")
        })
    with open(CLEAN_SERVERS_FILE, "w", encoding="utf-8") as f:
        json.dump(existing, f, indent=2, ensure_ascii=False)

    with open(CLEAN_SERVERS_TXT, "a", encoding="utf-8") as f:
        for s in servers:
            f.write(f"=== Clean Server ({s.get('datacenter')}): {s['ip']} ===\n")
            f.write(f"ID: {s.get('id')}\n")
            f.write(f"Root Password: {s.get('password')}\n")
            f.write(f"SSH Command: ssh root@{s['ip']}\n")
            f.write(f"WatTunnel Token: {s.get('token')}\n\n")


def view_clean_servers():
    if not os.path.exists(CLEAN_SERVERS_FILE):
        console.print("[yellow]No clean servers recorded yet.[/yellow]")
        return
    try:
        with open(CLEAN_SERVERS_FILE, "r", encoding="utf-8") as f:
            servers = json.load(f)
    except Exception:
        servers = []

    if not servers:
        console.print("[yellow]No clean servers recorded yet.[/yellow]")
        return

    table = Table(title=f"Saved Clean Servers ({len(servers)})", box=box.ROUNDED)
    table.add_column("#", style="dim")
    table.add_column("IP", style="bold green")
    table.add_column("Datacenter", style="cyan")
    table.add_column("Root Password", style="yellow")
    table.add_column("Speed / Latency", style="magenta")
    table.add_column("Saved At", style="dim")

    for i, s in enumerate(servers, start=1):
        speed_str = f"{s.get('latency_ms', 0)}ms | ↓{s.get('tcp_down_kb', 0)}K"
        table.add_row(str(i), s.get("ip", ""), s.get("datacenter", "Doprax"), s.get("password", ""), speed_str, str(s.get("saved_at", ""))[:16])
    console.print(table)


def view_dirty_ips():
    """Displays all local dirty/blocked IPs stored on PC."""
    records = DirtyIPManager.list_all()
    if not records:
        console.print("[yellow]No dirty IPs recorded in the local database yet.[/yellow]")
        return

    table = Table(title=f"Local Dirty/Blocked IPs Database ({len(records)} IPs)", box=box.ROUNDED)
    table.add_column("#", style="dim")
    table.add_column("Blocked IP", style="bold red")
    table.add_column("Provider / Datacenter", style="cyan")
    table.add_column("Reason", style="yellow")
    table.add_column("Diagnosis / Error", style="dim")
    table.add_column("Flagged Date", style="dim")

    for i, r in enumerate(records, start=1):
        diag_str = "; ".join(r.get("diag", [])) if r.get("diag") else r.get("reason", "")
        table.add_row(str(i), r.get("ip", ""), r.get("provider", "Doprax"), r.get("reason", ""), diag_str[:40], str(r.get("flagged_at", ""))[:16])
    console.print(table)


def list_and_manage_all_vms(doprax: DopraxClient):
    """Lists current instances on Doprax account with deletion options."""
    try:
        instances = doprax.list_instances(service_type="vm")
    except Exception as e:
        console.print(f"[red]Error fetching Doprax instances: {e}[/red]")
        return

    if not instances:
        console.print("[yellow]No active VMs found on your Doprax account.[/yellow]")
        return

    table = Table(title=f"Doprax Cloud Instances ({len(instances)})", box=box.ROUNDED)
    table.add_column("#", style="dim")
    table.add_column("Service ID", style="cyan")
    table.add_column("Name", style="bold")
    table.add_column("Status", style="green")

    for i, inst in enumerate(instances, start=1):
        table.add_row(str(i), inst.get("service_id", ""), inst.get("name", "unnamed"), inst.get("status", "unknown"))
    console.print(table)

    if Confirm.ask("\nDelete any instance from this list?", default=False):
        num = IntPrompt.ask("Enter # of instance to delete")
        if 1 <= num <= len(instances):
            target = instances[num - 1]
            s_id = target.get("service_id")
            if Confirm.ask(f"[bold red]Permanently terminate Doprax VM {s_id} ({target.get('name')})?[/bold red]"):
                doprax.delete_instance(s_id)
                console.print(f"[green]✓ Deleted Doprax VM {s_id}. Billing halted.[/green]")


# ==============================================================================
#  Main Menu
# ==============================================================================

def main():
    display_banner()
    cfg = load_config()
    doprax = get_doprax_client(cfg)

    while True:
        console.print("\n[bold cyan]Main Menu:[/bold cyan]")
        console.print("  [1] [bold green]🚀 Start Clean IP Hunter (Vultr · ProVM · Hetzner inside Doprax)[/bold green]")
        console.print("  [2] [bold yellow]🧪 Test Existing Running Doprax VMs[/bold yellow] (Multithreaded benchmark)")
        console.print("  [3] [bold blue]🎯 Test Custom External Server(s)[/bold blue] (Multithreaded benchmark)")
        console.print("  [4] [bold red]🚫 View Dirty IPs Database[/bold red] (Inspect locally stored blocked IPs)")
        console.print("  [5] [bold magenta]💳 Check Doprax Balance & Quotas[/bold magenta]")
        console.print("  [6] [bold white]⚙️  Configure API Key & Iran Server SSH[/bold white]")
        console.print("  [7] [bold yellow]📋 List & Manage Doprax VMs[/bold yellow]")
        console.print("  [8] [bold green]📄 View Saved Clean Servers[/bold green]")
        console.print("  [0] [dim]❌ Exit[/dim]")

        choice = Prompt.ask("\nChoose an option", choices=["1", "2", "3", "4", "5", "6", "7", "8", "0"], default="1")

        if choice == "1":
            run_doprax_datacenter_hunter(doprax, cfg)
        elif choice == "2":
            test_existing_doprax_vms(doprax, cfg)
        elif choice == "3":
            test_custom_servers(cfg)
        elif choice == "4":
            view_dirty_ips()
        elif choice == "5":
            show_doprax_balance(doprax)
        elif choice == "6":
            configure_credentials_and_iran(cfg)
        elif choice == "7":
            list_and_manage_all_vms(doprax)
        elif choice == "8":
            view_clean_servers()
        elif choice == "0":
            console.print("[green]Goodbye![/green]")
            break

if __name__ == "__main__":
    main()
