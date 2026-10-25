# Doprax API Reference Manual

> Comprehensive reference guide for the **Doprax Cloud Panel API** (OpenAPI 3.0.3, v1, v2, and v3).
> Built for writing scripts, CLI tools, and automated cloud workflows.

---

## Table of Contents

1. [Architecture & Authentication](#1-architecture--authentication)
   - [Base URL & Headers](#base-url--headers)
   - [API Key Authentication](#api-key-authentication)
   - [Response Envelope Standard](#response-envelope-standard)
   - [HTTP Status Codes](#http-status-codes)
   - [Operation Cooldowns & Rate Limits](#operation-cooldowns--rate-limits)
   - [Idempotency Pattern](#idempotency-pattern)
   - [Currency Units](#currency-units)
2. [API Versioning Comparison (v2 vs v3)](#2-api-versioning-comparison-v2-vs-v3)
3. [v3 Simplified VM Provisioning](#3-v3-simplified-vm-provisioning)
   - [List Plans (v3)](#get-apiv3catalogueplans)
   - [Create VM Service (v3)](#post-apiv3services)
   - [Disambiguation & Validation Errors](#v3-disambiguation--validation-errors)
4. [v1 & v2 Core API Endpoint Reference](#4-v1--v2-core-api-endpoint-reference)
   - [Category 1: Account & Billing](#category-1-account--billing)
   - [Category 2: Catalogue & Pricing](#category-2-catalogue--pricing)
   - [Category 3: Service Instances (VM Management)](#category-3-service-instances-vm-management)
   - [Category 4: VM Credentials & Access](#category-4-vm-credentials--access)
   - [Category 5: Lifecycle Operations & Async Task Polling](#category-5-lifecycle-operations--async-task-polling)
   - [Category 6: VM Resizing & Upgrade Previews](#category-6-vm-resizing--upgrade-previews)
   - [Category 7: Snapshots Management](#category-7-snapshots-management)
   - [Category 8: SSH Key Management](#category-8-ssh-key-management)
5. [End-to-End Automation Workflow Patterns](#5-end-to-end-automation-workflow-patterns)
   - [Pattern A: Safe VM Provisioning with Quota & Balance Check](#pattern-a-safe-vm-provisioning-with-quota--balance-check)
   - [Pattern B: Async Polling Engine](#pattern-b-async-polling-engine)
   - [Pattern C: Python SDK / Automation Client Script](#pattern-c-python-sdk--automation-client-script)
   - [Pattern D: Node.js / TypeScript Automation Script](#pattern-d-nodejs--typescript-automation-script)

---

## 1. Architecture & Authentication

### Base URL & Headers
All requests must be made over HTTPS to the primary API host:
```
https://www.doprax.com
```

Standard request headers:
```http
X-API-Key: <YOUR_DOPRAX_API_KEY>
Content-Type: application/json
Accept: application/json
```

### API Key Authentication
- An account has **one API key** at a time.
- API keys are generated/regenerated under **Account > API Keys** in the Doprax dashboard.
- If you regenerate a key, the previous key is immediately revoked.
- Keys must be kept private and never bundled into client-side code.

### Response Envelope Standard
Most `/api/v1/` and `/api/v2/` endpoints wrap results in a standard envelope:

```json
{
  "success": true,
  "data": { ... },
  "error": null,
  "meta": {
    "pagination": {}
  }
}
```

On failure (`success: false`):
```json
{
  "success": false,
  "data": {},
  "error": {
    "code": "request_failed",
    "message": "Authentication credentials were not provided"
  },
  "meta": {
    "pagination": {}
  }
}
```

*(Note: Modern `/api/v3/` endpoints return raw JSON bodies directly on success and specific structured error objects on failure).*

### HTTP Status Codes

| Status Code | Description | Meaning in Doprax API |
|:---|:---|:---|
| `200 OK` | Success | Request succeeded, response body returned. |
| `201 Created` | Created | Resource successfully created (e.g. SSH keys). |
| `400 Bad Request` | Client Error | Invalid parameters, missing required fields, or validation failures. |
| `403 Forbidden` | Auth Failure | Missing, invalid, or expired `X-API-Key`. |
| `404 Not Found` | Resource Not Found | VM instance, snapshot, or key does not exist on your account. |
| `409 Conflict` | State Conflict | The VM is currently in a state that prevents this action (e.g. operation in progress, frozen). |
| `429 Too Many Requests` | Operation Rate Limit | Firing operations too quickly on the same instance. |
| `500 Internal Error` | Server Error | Doprax backend or upstream hypervisor issue. |

### Operation Cooldowns & Rate Limits
Operations against a single VM instance require physical hypervisor coordination and cannot be dispatched simultaneously. When calling lifecycle operations on an instance, respect the cooldown delays:

| Operation | Required Wait Interval |
|:---|:---|
| **Start** | 60 seconds |
| **Reboot** | 90 seconds |
| **Stop** | 15 seconds |
| **Change IP** | 90 seconds |

> **Rate Limit Behavior (429)**: If an operation is invoked before the previous operation's cooldown expires, the API returns HTTP `429 Too Many Requests` with a `Retry-After: <seconds>` response header indicating how long your script should sleep before retrying.

### Idempotency Pattern
All state-modifying POST requests accept an `idempotency_key` parameter (UUID or random string).
- If a network failure occurs or a timeout interrupts the call, you can safely resend the exact same request with the same `idempotency_key`.
- The Doprax backend guarantees you will not accidentally create duplicate VMs or trigger duplicate billable events.

### Currency Units
- Financial figures in `/api/v2/finance/` (such as `available_balance_cents`, `accrued_cents`, `recurring_cents`, `usage_cents`) are integers denominated in **USD cents** (`100 cents = $1.00 USD`).
- Plans in `/api/v3/catalogue/plans/` report `monthly_price` as a decimal float (e.g. `7.95` USD).

---

## 2. API Versioning Comparison (v2 vs v3)

Doprax provides two complementary paradigms for interacting with resources:

| Feature | v3 API (`/api/v3/`) | v2 API (`/api/v2/`) |
|:---|:---|:---|
| **Primary Use** | High-level, frictionless VM provisioning | Complete lifecycle management, operations, finance, snapshots, SSH keys |
| **Parameters Style** | Human-readable strings (`plan: "P1"`, `location: "Poland"`, `os: "ubuntu_24_04"`) | Explicit UUIDs / IDs (`product_version_id`, `service_id`, `vm_code`) |
| **Response Style** | Direct payload object | Envelope with `success`, `data`, `error`, `meta` |
| **Disambiguation** | Friendly errors listing available choices if ambiguous | Standard validation error messages |
| **Recommendation** | **Use v3 for catalog discovery and initial VM creation** | **Use v2 for polling, status, power controls, resize, snapshots, and deletion** |

---

## 3. v3 Simplified VM Provisioning

### GET `/api/v3/catalogue/plans/`
Query available VM plans, hardware specs, locations, and monthly prices.

- **Query Parameters**:
  - `service_type` (string, default: `vm`)
  - `provider` (string, e.g. `provm` for Doprax native hardware)
- **Example Request**:
```bash
curl -sS "https://www.doprax.com/api/v3/catalogue/plans/?service_type=vm&provider=provm" \
  -H "X-API-Key: $DOPRAX_API_KEY"
```
- **Sample Response**:
```json
{
  "success": true,
  "data": [
    {
      "plan": "P1",
      "product_version_id": "367e0f33-4cf5-498e-9537-cf6d74632e9c",
      "service_type": "vm",
      "provider": "ProVM",
      "provider_code": "provm",
      "cpu": 1.0,
      "ram_gb": 1.0,
      "disk_gb": 20.0,
      "locations": [
        {
          "name": "Poland",
          "code": "provm_019b3cb3-3bc8-73e2-8aba-7edcad26ed0f"
        },
        {
          "name": "UK",
          "code": "provm_019ac0e3-500c-7e67-a7da-e6ac9916ac1b"
        }
      ],
      "monthly_price": 7.95,
      "currency": "USD"
    }
  ]
}
```

---

### POST `/api/v3/services/`
Create a new Virtual Machine using human-friendly names without needing raw UUIDs.

- **Headers**: `Content-Type: application/json`, `X-API-Key: <key>`
- **Request Body Fields**:
  - `service_type` (string, required): typically `"vm"`
  - `plan` (string, required): e.g. `"P1"`, `"P2"`
  - `location` (string, required): e.g. `"Poland"`, `"UK"`
  - `os` (string, optional): e.g. `"ubuntu_24_04"` (defaults to latest Ubuntu)
  - `name` (string, optional): Display name for the instance (e.g. `"worker-node-1"`)
  - `idempotency_key` (string, required): Unique token to prevent duplicate creation
- **Example Request**:
```bash
curl -sS -X POST "https://www.doprax.com/api/v3/services/" \
  -H "X-API-Key: $DOPRAX_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "service_type": "vm",
    "plan": "P1",
    "location": "Poland",
    "os": "ubuntu_24_04",
    "name": "my-worker-node",
    "idempotency_key": "vm-create-001"
  }'
```
- **Sample 200 Response**:
```json
{
  "operation_id": "c725787d-7d98-40f5-b155-40ca5127e660",
  "service_id": "187030b1-dd8d-4a50-95bb-7dd0ca4acf1c",
  "status": "pending",
  "action": "create",
  "task_id": "task-uuid",
  "status_reason": null,
  "created_at": "2026-10-12T05:36:06.703Z",
  "started_at": null,
  "completed_at": null,
  "updated_at": "2026-10-12T05:36:06.703Z",
  "success": true,
  "resolved": {
    "plan": "P1",
    "location": "provm_019b3cb3-3bc8-73e2-8aba-7edcad26ed0f",
    "os": "ubuntu_24_04"
  }
}
```

### v3 Disambiguation & Validation Errors
If any supplied name is ambiguous or missing, the API returns HTTP `400` with the available valid choices:

| Error Code | Meaning | Additional Fields in Response |
|:---|:---|:---|
| `plan_not_found` | No plan matches the given name | `available_plans` |
| `plan_ambiguous` | Multiple plans match the name | `matches` |
| `location_required` | Plan runs in multiple regions; specify which | `available_locations` |
| `location_not_allowed` | Plan does not run in the chosen location | `available_locations` |
| `location_ambiguous` | Ambiguous location name | `matches` |
| `os_not_allowed` | Selected OS not available on this plan | `available_os` |
| `os_ambiguous` | Ambiguous OS specification (e.g. `"ubuntu"`) | `matches` |

---

## 4. v1 & v2 Core API Endpoint Reference

All endpoints below require header: `X-API-Key: <key>`.

### Category 1: Account & Billing

#### 1. `GET /api/v1/account/info/`
- **Description**: Account profile and quota info, including `numVmLimit`. Check this before attempting to create a new VM to avoid exceeding account quotas.
- **Parameters**: None.
- **Response (`200 OK`)**:
```json
{
  "success": true,
  "data": {
    "email": "user@example.com",
    "name": "Jane Doe",
    "numVmLimit": 10,
    "currentVmCount": 2,
    "isVerified": true
  }
}
```

#### 2. `GET /api/v2/finance/available-balance/`
- **Description**: Check available account balance against an optional minimum required amount before creating or starting a VM.
- **Query Parameters**:
  - `action` (string, optional): Lifecycle action being planned (e.g. `create`, `start`)
  - `min_required_cents` (integer, optional): Desired minimum balance in cents
  - `refresh` (boolean, optional): Force real-time balance recount
  - `refresh_alerts` (boolean, optional): Recompute active billing alerts
- **Response (`200 OK`)**:
```json
{
  "success": true,
  "data": {
    "currency": "USD",
    "available_balance_cents": 2500,
    "accrued_cents": 12,
    "recurring_cents": 12,
    "usage_cents": 0,
    "min_required_cents": 300,
    "is_sufficient": true,
    "default_min_required_cents": 300
  },
  "error": null,
  "meta": { "pagination": {} }
}
```

#### 3. `GET /api/v2/finance/summary/`
- **Description**: Comprehensive billing summary, including `runway_days` — an estimate of how many days the current balance will last at the account's burn rate.
- **Query Parameters**:
  - `refresh_alerts` (boolean, optional): Force recount of billing alerts
- **Response (`200 OK`)**:
```json
{
  "success": true,
  "data": {
    "currency": "USD",
    "balance_cents": 2500,
    "burn_rate_cents_per_hour": 5,
    "runway_days": 20,
    "active_services_count": 2
  }
}
```

---

### Category 2: Catalogue & Pricing

#### 4. `GET /api/v2/catalogue/service-catalogue/`
- **Description**: List available VM plans, providers, locations, and operating systems. Used to pick a `product_version_id` and configuration options for `/api/v2/services/instances/`.
- **Query Parameters**:
  - `provider` (string, optional): Filter by provider (e.g. `provm`)
  - `service_type` (string, optional): Filter by service type (e.g. `vm`)
- **Response (`200 OK`)**: Full hierarchy of providers, plans, versions, regions, and pricing components.

---

### Category 3: Service Instances (VM Management)

#### 5. `GET /api/v2/services/instances/list/`
- **Description**: List service instances (VMs). Filter with `service_type=vm` and compare `meta.active_total` against `numVmLimit` to check quota before creating a VM.
- **Query Parameters**:
  - `service_type` (string, optional): e.g. `"vm"`
  - `status` (string, optional): e.g. `"running"`, `"stopped"`, `"provisioning"`
  - `provider` (string, optional): e.g. `"provm"`
  - `region` (string, optional)
  - `search` (string, optional): Search query on instance name/description
  - `sort_by` (string, optional): Field to sort by
  - `sort_dir` (string, optional): `"asc"` or `"desc"`
  - `page` (integer, optional): Page number
  - `page_size` (integer, optional): Results per page
- **Response (`200 OK`)**:
```json
{
  "success": true,
  "data": [
    {
      "service_id": "187030b1-dd8d-4a50-95bb-7dd0ca4acf1c",
      "name": "web-server-01",
      "status": "running",
      "service_type": "vm",
      "created_at": "2026-10-12T05:36:07.545Z"
    }
  ],
  "meta": {
    "pagination": { "count": 1, "page": 1, "page_size": 20 },
    "active_total": 1
  }
}
```

#### 6. `POST /api/v2/services/instances/`
- **Description**: Create a new VM service instance from a plan (`product_version_id`) with either a standard OS install, SSH-key access, or restore-from-snapshot.
- **Request Body Fields**:
  - `product_version_id` (UUID, required): The target hardware plan version ID
  - `idempotency_key` (string, required): Idempotency token
  - `name` (string, optional): Friendly name
  - `description` (string, optional)
  - `metadata` (object, optional): Configuration options (e.g. `ssh_key_code`, `snapshot_code`, root password preferences)
  - `selections` (object, optional): Region and OS selections
- **Response (`200 OK`)**:
```json
{
  "success": true,
  "data": {
    "service_id": "187030b1-dd8d-4a50-95bb-7dd0ca4acf1c",
    "operation_id": "c725787d-7d98-40f5-b155-40ca5127e660",
    "status": "pending"
  }
}
```

#### 7. `GET /api/v2/services/instances/{service_id}/detail/`
- **Description**: Get full service/VM detail: status (`running`, `stopped`, `provisioning`), plan, location, public IPs, access info, and the lifecycle actions currently available.
- **Path Parameters**:
  - `service_id` (UUID, required): The VM's service UUID
- **Response (`200 OK`)**:
```json
{
  "success": true,
  "data": {
    "service": {
      "service_id": "187030b1-dd8d-4a50-95bb-7dd0ca4acf1c",
      "name": "my-vm",
      "status": "running",
      "status_reason": "vm_setup_complete",
      "service_type": "vm",
      "product_version_id": "367e0f33-4cf5-498e-9537-cf6d74632e9c",
      "metadata": {
        "vm_code": "0eb0c974-8aff-46c6-904a-83b1053e72d8"
      },
      "created_at": "2026-10-12T05:36:07.545Z",
      "activated_at": "2026-10-12T05:37:08.142Z"
    },
    "access": {
      "username": "root",
      "public_ipv4": "203.0.113.10",
      "public_ipv6": "2001:db8::10",
      "active_ssh_key": null,
      "authentication_type": "password",
      "web_ui_url": null
    }
  }
}
```

#### 8. `PUT /api/v2/services/instances/{service_id}/detail/`
- **Description**: Update the VM’s name and/or description. At least one field is required.
- **Path Parameters**: `service_id` (UUID, required)
- **Request Body Fields**:
  - `name` (string, optional)
  - `description` (string, optional)

---

### Category 4: VM Credentials & Access

#### 9. `GET /api/v2/vms/{vm_code}/actions/access/`
- **Description**: Provide access details (e.g. temporary root password) for a VM. Returns `null` for the password field when the VM was provisioned with SSH-key access instead.
- **Path Parameters**:
  - `vm_code` (UUID, required): The internal VM identifier found in `service.metadata.vm_code` from the instance detail response.
- **Response (`200 OK`)**:
```json
{
  "success": true,
  "data": {
    "tempPass": "GeneratedPassword123!",
    "vmUsername": "root",
    "accessMethod": "password",
    "userPublicSSHKeyFingerprint": null,
    "userPublicSSHKeyTitle": null
  },
  "error": null,
  "meta": { "pagination": {} }
}
```

---

### Category 5: Lifecycle Operations & Async Task Polling

#### 10. `POST /api/v2/services/instances/{service_id}/operations/`
- **Description**: Run a lifecycle action on the VM as a queued async operation.
- **Path Parameters**: `service_id` (UUID, required)
- **Request Body Fields**:
  - `action` (string, required): One of:
    - `"start"`: Power on a stopped VM
    - `"stop"`: Graceful power off
    - `"reboot"`: Restart VM
    - `"delete"`: Terminate and purge VM (stops hourly billing immediately)
    - `"resize"`: Apply new hardware plan
    - `"snapshot"`: Trigger disk snapshot
    - `"change_ip"`: Request a new public IPv4 address
    - `"rebuild"`: Reinstall base image
    - `"rescue"`: Boot into rescue image
  - `idempotency_key` (string, required): Unique action token
  - `ip_version` (integer, optional): When running `change_ip`, specify `4` or `6`
- **Response (`200 OK`)**:
```json
{
  "success": true,
  "data": {
    "operation_id": "6cc2ca76-3ae7-4fc0-bad8-e44746cb8c65",
    "service_id": "187030b1-dd8d-4a50-95bb-7dd0ca4acf1c",
    "status": "pending",
    "action": "stop",
    "created_at": "2026-10-12T05:37:11.673Z"
  }
}
```

#### 11. `GET /api/v2/services/operations/{operation_id}/`
- **Description**: Get the status of an ongoing or completed operation by its `operation_id`. Use this endpoint to poll operations until completion.
- **Path Parameters**:
  - `operation_id` (UUID, required)
- **Response (`200 OK`)**:
```json
{
  "success": true,
  "idempotent": true,
  "operation_id": "6cc2ca76-3ae7-4fc0-bad8-e44746cb8c65",
  "service_id": "187030b1-dd8d-4a50-95bb-7dd0ca4acf1c",
  "status": "completed",
  "action": "stop",
  "status_reason": null,
  "created_at": "2026-10-12T05:37:11.673Z",
  "completed_at": "2026-10-12T05:37:19.412Z"
}
```
*(Statuses: `"pending"`, `"running"`, `"completed"`, `"failed"`)*

#### 12. `GET /api/v2/services/instances/{service_id}/operations/`
- **Description**: List recent operations (audit log) for this specific VM.
- **Path Parameters**: `service_id` (UUID, required)
- **Query Parameters**:
  - `status` (string, optional): Filter by status (`completed`, `failed`, etc.)
  - `page_size` (integer, optional)

---

### Category 6: VM Resizing & Upgrade Previews

#### 13. `GET /api/v2/services/instances/{service_id}/resize_options/`
- **Description**: List plans this VM can resize to (upgrade/downgrade), along with target specs and pricing for each option.
- **Path Parameters**: `service_id` (UUID, required)

#### 14. `POST /api/v2/services/instances/{service_id}/resize_options/{new_pv_id}/preview/`
- **Description**: Dry-run a resize to a target plan: preview billing delta and warnings before executing it via the resize lifecycle action.
- **Path Parameters**:
  - `service_id` (UUID, required)
  - `new_pv_id` (UUID, required): The target plan's `product_version_id`

---

### Category 7: Snapshots Management

#### 15. `GET /api/v2/services/instances/{service_id}/snapshots/`
- **Description**: List snapshots created for a specific VM instance.
- **Path Parameters**: `service_id` (UUID, required)

#### 16. `POST /api/v2/services/instances/{service_id}/snapshots/`
- **Description**: Create a new snapshot of this VM (service-scoped).
- **Path Parameters**: `service_id` (UUID, required)
- **Request Body Fields**:
  - `description` (string, required): Human-readable snapshot name/memo
  - `idempotency_key` (string, optional)

#### 17. `DELETE /api/v2/services/instances/{service_id}/snapshots/{snapshot_code}/`
- **Description**: Delete a snapshot belonging to this VM's service instance.
- **Path Parameters**:
  - `service_id` (UUID, required)
  - `snapshot_code` (UUID, required)

#### 18. `POST /api/v2/services/instances/{service_id}/snapshots/{snapshot_code}/actions/restore/`
- **Description**: Restore/overwrite the VM's disk from a snapshot. **Destructive to the current disk state.** The snapshot must be in ready state.
- **Path Parameters**:
  - `service_id` (UUID, required)
  - `snapshot_code` (UUID, required)

#### 19. `GET /api/v2/snapshots/` & `GET /api/v2/services/snapshots/`
- **Description**: List snapshots across all of your account's VMs.
- **Query Parameters**: `vm_code` (UUID, optional)

#### 20. `POST /api/v2/snapshots/`
- **Description**: Create a new VM snapshot via the account-wide endpoint.
- **Request Body Fields**:
  - `vm_code` (UUID, required)
  - `description` (string, required)

#### 21. `GET /api/v2/snapshots/{snapshot_code}/`
- **Description**: Get single snapshot details by its code.

#### 22. `DELETE /api/v2/snapshots/{snapshot_code}/`
- **Description**: Delete snapshot by code.

---

### Category 8: SSH Key Management

#### 23. `GET /api/v2/ssh-keys/`
- **Description**: List all registered SSH public keys on your Doprax account.
- **Response (`200 OK`)**:
```json
{
  "success": true,
  "data": [
    {
      "code": "ssh_019a...",
      "title": "my-macbook-pro",
      "fingerprint": "SHA256:...",
      "created_at": "2026-09-01T10:00:00Z"
    }
  ]
}
```

#### 24. `POST /api/v2/ssh-keys/`
- **Description**: Register a new SSH public key for key-based VM access.
- **Request Body Fields**:
  - `title` (string, required): Key label (e.g. `"work-laptop"`)
  - `public_key` (string, required): OpenSSH public key string (e.g. `"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5..."`)
- **Response (`201 Created`)**:
```json
{
  "success": true,
  "data": {
    "code": "ssh_019b...",
    "title": "work-laptop",
    "fingerprint": "SHA256:..."
  }
}
```

#### 25. `DELETE /api/v2/ssh-keys/{ssh_key_code}/`
- **Description**: Delete a registered SSH public key from your account.
- **Path Parameters**:
  - `ssh_key_code` (string, required): The SSH key identifier code

---

## 5. End-to-End Automation Workflow Patterns

### Pattern A: Safe VM Provisioning with Quota & Balance Check
Before firing a VM creation request in your script:
1. Call `GET /api/v1/account/info/` and check that `currentVmCount < numVmLimit`.
2. Call `GET /api/v2/finance/available-balance/?min_required_cents=300` and ensure `data.is_sufficient === true`.
3. Call `POST /api/v3/services/` with plan, location, name, and an idempotency key.

### Pattern B: Async Polling Engine
After creating a VM or running an operation:
```python
import time, requests

def wait_for_vm_running(base_url, api_key, service_id, timeout_sec=300):
    headers = {"X-API-Key": api_key}
    url = f"{base_url}/api/v2/services/instances/{service_id}/detail/"
    start = time.time()
    while time.time() - start < timeout_sec:
        res = requests.get(url, headers=headers).json()
        status = res.get("data", {}).get("service", {}).get("status")
        print(f"VM Status: {status}")
        if status == "running":
            access = res["data"]["access"]
            vm_code = res["data"]["service"]["metadata"]["vm_code"]
            return access["public_ipv4"], vm_code
        elif status in ["failed", "error"]:
            raise RuntimeError(f"VM provisioning failed: {res}")
        time.sleep(10)
    raise TimeoutError("VM timed out before reaching running state.")
```

### Pattern C: Python SDK / Automation Client Script

```python
#!/usr/bin/env python3
"""
Doprax Cloud API Python Automation Client
Requires: pip install requests
"""

import os
import time
import uuid
import requests

class DopraxClient:
    def __init__(self, api_key: str = None, base_url: str = "https://www.doprax.com"):
        self.api_key = api_key or os.getenv("DOPRAX_API_KEY")
        if not self.api_key:
            raise ValueError("DOPRAX_API_KEY must be provided or set in environment")
        self.base_url = base_url.rstrip("/")
        self.session = requests.Session()
        self.session.headers.update({
            "X-API-Key": self.api_key,
            "Content-Type": "application/json",
            "Accept": "application/json"
        })

    def get_balance(self):
        """Check available balance in cents and USD."""
        r = self.session.get(f"{self.base_url}/api/v2/finance/available-balance/")
        r.raise_for_status()
        return r.json().get("data", {})

    def list_plans(self, provider="provm"):
        """List hardware plans under provider."""
        r = self.session.get(f"{self.base_url}/api/v3/catalogue/plans/?service_type=vm&provider={provider}")
        r.raise_for_status()
        return r.json().get("data", [])

    def create_vm(self, plan: str, location: str, name: str, os_name: str = "ubuntu_24_04"):
        """Create a VM via v3 API."""
        payload = {
            "service_type": "vm",
            "plan": plan,
            "location": location,
            "os": os_name,
            "name": name,
            "idempotency_key": str(uuid.uuid4())
        }
        r = self.session.post(f"{self.base_url}/api/v3/services/", json=payload)
        r.raise_for_status()
        return r.json()

    def get_instance_detail(self, service_id: str):
        """Fetch instance detail, status, and IP."""
        r = self.session.get(f"{self.base_url}/api/v2/services/instances/{service_id}/detail/")
        r.raise_for_status()
        return r.json().get("data", {})

    def get_vm_credentials(self, vm_code: str):
        """Fetch temporary root password or SSH access method."""
        r = self.session.get(f"{self.base_url}/api/v2/vms/{vm_code}/actions/access/")
        r.raise_for_status()
        return r.json().get("data", {})

    def perform_action(self, service_id: str, action: str):
        """Execute lifecycle action (start, stop, reboot, delete, change_ip)."""
        payload = {
            "action": action,
            "idempotency_key": str(uuid.uuid4())
        }
        r = self.session.post(f"{self.base_url}/api/v2/services/instances/{service_id}/operations/", json=payload)
        r.raise_for_status()
        return r.json()

    def wait_for_status(self, service_id: str, target_status: str = "running", timeout: int = 300, poll_interval: int = 10):
        """Poll until service reaches target status."""
        start = time.time()
        while time.time() - start < timeout:
            data = self.get_instance_detail(service_id)
            current_status = data.get("service", {}).get("status")
            print(f"[Wait] Current status: {current_status}")
            if current_status == target_status:
                return data
            time.sleep(poll_interval)
        raise TimeoutError(f"Service {service_id} did not reach {target_status} within {timeout}s")

if __name__ == "__main__":
    # Example flow
    client = DopraxClient()
    balance = client.get_balance()
    print(f"Available Balance: {balance.get('available_balance_cents', 0) / 100:.2f} USD")
```

### Pattern D: Node.js / TypeScript Automation Script

```javascript
const https = require('https');

class DopraxAPI {
    constructor(apiKey, baseUrl = 'https://www.doprax.com') {
        this.apiKey = apiKey || process.env.DOPRAX_API_KEY;
        this.baseUrl = baseUrl;
    }

    async request(path, options = {}) {
        const url = new URL(path, this.baseUrl);
        return new Promise((resolve, reject) => {
            const req = https.request(url, {
                method: options.method || 'GET',
                headers: {
                    'X-API-Key': this.apiKey,
                    'Content-Type': 'application/json',
                    'Accept': 'application/json',
                    ...options.headers
                }
            }, (res) => {
                let data = '';
                res.on('data', chunk => data += chunk);
                res.on('end', () => {
                    try {
                        const parsed = JSON.parse(data);
                        if (res.statusCode >= 400) return reject({ status: res.statusCode, body: parsed });
                        resolve(parsed);
                    } catch (e) {
                        resolve(data);
                    }
                });
            });
            req.on('error', reject);
            if (options.body) req.write(JSON.stringify(options.body));
            req.end();
        });
    }

    getBalance() {
        return this.request('/api/v2/finance/available-balance/');
    }

    listInstances() {
        return this.request('/api/v2/services/instances/list/?service_type=vm');
    }

    createVM(config) {
        return this.request('/api/v3/services/', {
            method: 'POST',
            body: {
                service_type: 'vm',
                plan: config.plan,
                location: config.location,
                os: config.os || 'ubuntu_24_04',
                name: config.name,
                idempotency_key: config.idempotencyKey || Date.now().toString()
            }
        });
    }

    lifecycleAction(serviceId, action) {
        return this.request(`/api/v2/services/instances/${serviceId}/operations/`, {
            method: 'POST',
            body: {
                action,
                idempotency_key: Date.now().toString() + '-' + action
            }
        });
    }
}

module.exports = DopraxAPI;
```

---

## 6. Summary of Endpoints Matrix

| HTTP Method | Route | Description |
|:---|:---|:---|
| `GET` | `/api/v3/catalogue/plans/` | List hardware plans by provider & service type (v3) |
| `POST` | `/api/v3/services/` | Create VM with friendly names (plan, location, os) (v3) |
| `GET` | `/api/v1/account/info/` | Account profile & quota info (numVmLimit) |
| `GET` | `/api/v2/finance/available-balance/` | Check available credit in cents |
| `GET` | `/api/v2/finance/summary/` | Billing summary & runway days estimate |
| `GET` | `/api/v2/catalogue/service-catalogue/` | Comprehensive service catalogue & plan version UUIDs |
| `GET` | `/api/v2/services/instances/list/` | List all service instances / VMs with filters |
| `POST` | `/api/v2/services/instances/` | Advanced instance creation using `product_version_id` |
| `GET` | `/api/v2/services/instances/{service_id}/detail/` | Get VM details, status, IP addresses, vm_code |
| `PUT` | `/api/v2/services/instances/{service_id}/detail/` | Update VM name or description |
| `GET` | `/api/v2/vms/{vm_code}/actions/access/` | Retrieve root password or SSH authentication details |
| `POST` | `/api/v2/services/instances/{service_id}/operations/` | Trigger lifecycle operation (start/stop/reboot/delete/etc) |
| `GET` | `/api/v2/services/instances/{service_id}/operations/` | View operation history for a VM |
| `GET` | `/api/v2/services/operations/{operation_id}/` | Check status of single operation |
| `GET` | `/api/v2/services/instances/{service_id}/resize_options/` | Available upgrade/downgrade target plans |
| `POST` | `/api/v2/services/instances/{service_id}/resize_options/{new_pv_id}/preview/` | Dry-run preview of resize operation |
| `GET` | `/api/v2/services/instances/{service_id}/snapshots/` | List snapshots for specific VM instance |
| `POST` | `/api/v2/services/instances/{service_id}/snapshots/` | Take a new snapshot of VM |
| `DELETE` | `/api/v2/services/instances/{service_id}/snapshots/{snapshot_code}/` | Delete VM snapshot |
| `POST` | `/api/v2/services/instances/{service_id}/snapshots/{snapshot_code}/actions/restore/` | Restore VM disk from snapshot |
| `GET` | `/api/v2/snapshots/` | Account-wide snapshot list |
| `POST` | `/api/v2/snapshots/` | Account-wide snapshot creation |
| `GET` | `/api/v2/snapshots/{snapshot_code}/` | Account-wide snapshot details |
| `DELETE` | `/api/v2/snapshots/{snapshot_code}/` | Account-wide snapshot deletion |
| `GET` | `/api/v2/services/snapshots/` | List snapshots across all account services |
| `GET` | `/api/v2/ssh-keys/` | List registered SSH public keys |
| `POST` | `/api/v2/ssh-keys/` | Register new SSH public key |
| `DELETE` | `/api/v2/ssh-keys/{ssh_key_code}/` | Delete registered SSH public key |

