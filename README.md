# 🚀 Doprax Clean IP Hunter

![Python](https://img.shields.io/badge/Python-3.8%2B-blue.svg)
![License](https://img.shields.io/badge/License-MIT-green.svg)
![Platform](https://img.shields.io/badge/Platform-Windows%20%7C%20Linux%20%7C%20macOS-lightgrey.svg)

An automated, **multithreaded Clean IP Hunter** for the **Doprax Cloud Platform** (supporting **Vultr**, **Hetzner**, **ProVM**, and **DigitalOcean** datacenters directly via a single Doprax API key). It spins up virtual machines in parallel, deploys **WatTunnel**, runs real-time bidirectional **TCP & UDP download/upload benchmarks** directly from your Iran server, stores dirty/blocked IPs in a local database to prevent re-testing, and gives you full interactive control over instance termination and billing.

---

## ✨ Key Features

- **⚡ Multithreaded Parallel Engine**: Provisions, configures, and benchmarks entire batches of VMs simultaneously across background worker threads (3x–5x faster than sequential scanners).
- **🌍 Multi-Datacenter Support (via Doprax API v3)**:
  - **Vultr**: Germany (`DE, Frankfurt`), Netherlands (`NL, Amsterdam`), Poland (`PL, Warsaw`), France (`FR, Paris`), UK (`GB, London`), Japan (`JP, Tokyo`), US, and 25+ global locations.
  - **Hetzner**: Germany (`Falkenstein, DE`, `Nuremberg, DE`), Finland (`Helsinki, FI`), US, Singapore.
  - **ProVM & DigitalOcean**: Poland, UK, Frankfurt, Amsterdam, London, New York, etc.
- **🔬 True Bidirectional TCP & UDP Verification**:
  - Verifies SSH reachability from your Iran server to detect immediate GFW IP blocks.
  - Runs a dual-listener socket benchmark on the foreign VM and measures real TCP Download, TCP Upload, and UDP echo packet loss from the Iran node.
- **🚫 Local Dirty IP Database (`dirty_servers.json`)**:
  - Persistently records blocked/dirty IPs on your computer with timestamps and failure diagnostics.
  - **Instant Pre-Flagging**: If a cloud provider assigns a previously flagged dirty IP, the scanner immediately identifies it (`PRE-FLAGGED DIRTY`) without wasting time or bandwidth.
- **🛡️ Controlled Deletion & Billing Protection**:
  - No forced auto-deletion—choose after each scan whether to delete only dirty servers, delete specific instances, keep all, or terminate all.
  - Built-in `SIGINT`/`atexit` emergency cleanup hooks prevent orphaned VMs if the terminal is closed mid-provisioning.
- **🎯 Custom & Existing Server Modes**:
  - Benchmark your existing running Doprax VMs or any external third-party VPS list (`custom_servers.txt`).

---

## 📦 Installation

1. **Clone the repository:**
   ```bash
   git clone https://github.com/AdamBarfii/doprax-clean-ip-hunter.git
   cd doprax-clean-ip-hunter
   ```

2. **Install Python dependencies:**
   ```bash
   pip install -r requirements.txt
   ```

3. **Configure your credentials:**
   Copy [`config.example.json`](config.example.json) to `config.json` (or configure interactively inside the CLI via Option `[6]`):
   ```bash
   cp config.example.json config.json
   ```

4. **Run the tool:**
   - **Windows**: Double-click `start.bat` or run:
     ```powershell
     python doprax_hunter.py
     ```
   - **Linux / macOS**:
     ```bash
     python3 doprax_hunter.py
     ```

---

## 🖥️ Main Menu Overview

```text
Main Menu:
  [1] 🚀 Start Clean IP Hunter (Vultr · Hetzner · ProVM · DO inside Doprax)
  [2] 🧪 Test Existing Running Doprax VMs (Multithreaded benchmark)
  [3] 🎯 Test Custom External Server(s) (Multithreaded benchmark)
  [4] 🚫 View Dirty IPs Database (Inspect locally stored blocked IPs)
  [5] 💳 Check Doprax Balance & Quotas
  [6] ⚙️  Configure API Key & Iran Server SSH
  [7] 📋 List & Manage Doprax VMs
  [8] 📄 View Saved Clean Servers
  [0] ❌ Exit
```

---

## 🔒 Security Note

Your sensitive files (`config.json`, `clean_servers.json`, `clean_servers.txt`, `dirty_servers.json`, `dirty_servers.txt`, `custom_servers.txt`) are automatically excluded via `.gitignore` so your API keys, passwords, and clean IPs are never committed to Git.

---
---

<div dir="rtl">

# 🇮🇷 راهنمای فارسی (شکارچی آی‌پی تمیز دوپراکس)

این نرم‌افزار به صورت کاملاً خودکار سرورهای خارج را در پلتفرم **Doprax** (شامل دیتاسنترهای **Vultr**، **Hetzner**، **ProVM** و **DigitalOcean**) می‌سازد، آن‌ها را به صورت **چندرشته‌ای و هم‌زمان (Multithreaded)** تست می‌کند، اسکریپت **WatTunnel** را روی آن‌ها نصب و راه‌اندازی می‌کند، ارتباط **TCP و UDP** (دانلود و آپلود دوطرفه) را مستقیماً از سرور ایران شما بنچمارک می‌گیرد و آی‌پی‌های کثیف را در دیتابیس محلی ذخیره می‌کند.

### ویژگی‌های کلیدی:
1. **پشتیبانی کامل از دیتاسنترهای آلمان، هلند، لهستان و... (Vultr & Hetzner در دوپراکس):**
   - بدون نیاز به اکانت جداگانه والتر یا هتزنر؛ مستقیماً با API Key دوپراکس تمام لوکیشن‌ها (از جمله `DE, Frankfurt` در صدر لیست) و ارزان‌ترین پلن‌ها قابل انتخاب و جستجو هستند.
2. **اجرای موازی و چندرشته‌ای (Multithreading):**
   - تست هم‌زمان تمام سرورهای یک Batch در تردهای مجزا با سرعت ۳ تا ۵ برابر بیشتر.
3. **تشخیص هوشمند قطعی پورت و پروتکل:**
   - بررسی باز بودن SSH پس از اتمام `cloud-init`، نصب خودکار WatTunnel و تست واقعی ارسال و دریافت پکت‌های TCP و UDP از سمت سرور ایران.
4. **دیتابیس محلی آی‌پی‌های کثیف (`dirty_servers.json`):**
   - ذخیره دائمی آی‌پی‌های مسدود در سیستم شما و پرچم‌گذاری فوری (`Pre-Flagged Dirty`) در صورت اختصاص مجدد آی‌پی تکراری توسط دیتاسنتر.
5. **کنترل کامل روی حذف سرورها:**
   - پس از پایان تست، خودتان انتخاب می‌کنید که فقط سرورهای خراب/مسدود حذف شوند، سرور خاصی حذف شود، یا همه سرورها باقی بمانند.

### نحوه اجرا در ویندوز:
کافیست روی فایل `start.bat` دابل کلیک کنید یا دستور زیر را اجرا نمایید:
```powershell
python doprax_hunter.py
```

</div>
