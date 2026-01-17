# RouteDNS: Production-Ready DNS over TLS (DoT) Stack

[![Docker](https://img.shields.io/badge/Docker-Ready-blue)](https://www.docker.com/)
[![HAProxy](https://img.shields.io/badge/HAProxy-3.3-green)](https://www.haproxy.org/)
[![License](https://img.shields.io/badge/License-MIT-yellow)](LICENSE)

A production-ready, security-hardened DNS over TLS (DoT) service with multi-tenant validation, DDoS protection, rate limiting, and full observability.

---

## 🚀 Quick Start (5 Minutes)

```bash
# 1. Clone and enter directory
git clone https://github.com/bdtunneldev/routeDNS.git && cd routeDNS

# 2. Configure environment (REQUIRED)
cp .env.example .env
nano .env  # Set strong passwords!

# 3. Deploy SSL certificates (see SSL section below)
sudo ./deploy-certs.sh

# 4. Start all services
docker compose up -d

# 5. Verify deployment
./manage.sh test
```

---

## 📋 Table of Contents

- [Architecture](#-architecture)
- [Features](#-features)
- [Prerequisites](#-prerequisites)
- [Installation](#-installation)
- [SSL/TLS Setup](#-ssltls-setup)
- [Configuration](#-configuration)
- [Security Hardening](#-security-hardening)
- [Monitoring](#-monitoring)
- [Management Commands](#-management-commands)
- [Troubleshooting](#-troubleshooting)
- [API Reference](#-api-reference)

---

## 🏗 Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         INTERNET                                     │
│                            │                                         │
│                       Port 853 (DoT)                                │
│                            ▼                                         │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                      HAProxy 3.3                             │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │   │
│  │  │ TLS Term    │→ │ Rate Limit  │→ │ Lua Tenant Valid    │  │   │
│  │  │ (DoT)       │  │ DDoS Protect│  │ + Device Tracking   │  │   │
│  │  └─────────────┘  └─────────────┘  └─────────────────────┘  │   │
│  └──────────────────────────┬──────────────────────────────────┘   │
│                             │                                        │
│         ┌───────────────────┼───────────────────┐                   │
│         ▼                   ▼                   ▼                   │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────┐           │
│  │   Valkey    │     │  RouteDNS   │     │ Prometheus  │           │
│  │  (Cache)    │     │  (Resolver) │     │  + Grafana  │           │
│  └─────────────┘     └─────────────┘     └─────────────┘           │
│                             │                                        │
│         ┌───────────────────┼───────────────────┐                   │
│         ▼                   ▼                   ▼                   │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────┐           │
│  │ Cloudflare  │     │   Google    │     │ Bangladesh  │           │
│  │    DoT      │     │    DoT      │     │  Resolvers  │           │
│  └─────────────┘     └─────────────┘     └─────────────┘           │
└─────────────────────────────────────────────────────────────────────┘
```

---

## ✨ Features

| Feature | Description |
|---------|-------------|
| **DNS over TLS** | Secure DNS on port 853 with TLS 1.2/1.3 |
| **Multi-Tenant** | Validate tenants via SNI: `{tenant}.dns.routedns.io` |
| **Device Limiting** | 1 device per tenant with auto-blocking |
| **DDoS Protection** | Connection rate limiting, IP banning |
| **Caching** | Valkey (Redis) caching for fast validation |
| **Monitoring** | Prometheus metrics + Grafana dashboards |
| **Security Hardened** | Minimal privileges, read-only containers |

---

## 📦 Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| Docker | 24.0+ | With Compose V2 |
| Domain | - | e.g., `*.dns.routedns.io` |
| SSL Cert | - | Let's Encrypt or other CA |
| RAM | 2GB+ | Recommended for all services |

---

## 🔧 Installation

### Step 1: Clone Repository

```bash
git clone https://github.com/bdtunneldev/routeDNS.git
cd routeDNS
```

### Step 2: Configure Environment

```bash
# Copy template
cp .env.example .env

# Generate strong passwords and edit
openssl rand -base64 24  # Use for each password
nano .env
```

**Required variables in `.env`:**

```env
VALKEY_PASSWORD=<strong-password-here>
GF_SECURITY_ADMIN_PASSWORD=<strong-password-here>
HAPROXY_STATS_USER=admin
HAPROXY_STATS_PASSWORD=<strong-password-here>
```

### Step 3: Deploy SSL Certificates

See [SSL/TLS Setup](#-ssltls-setup) section below.

### Step 4: Start Services

```bash
# Start all services
docker compose up -d

# Watch logs
docker compose logs -f

# Verify health
./manage.sh test
```

---

## 🔐 SSL/TLS Setup

### Option A: Let's Encrypt (Recommended)

```bash
# 1. Install certbot
sudo apt install certbot  # Debian/Ubuntu
# or
brew install certbot      # macOS

# 2. Obtain certificate
sudo certbot certonly --standalone -d dns.routedns.io

# 3. Deploy to HAProxy
sudo ./deploy-certs.sh

# 4. Restart HAProxy
docker compose restart haproxy
```

### Option B: Manual Certificate

```bash
# Place your certificates
cp fullchain.pem haproxy/certs/
cp privkey.pem haproxy/certs/

# Create combined PEM for HAProxy
cat haproxy/certs/fullchain.pem haproxy/certs/privkey.pem > haproxy/certs/dot.pem
chmod 600 haproxy/certs/dot.pem
```

### Auto-Renewal (Let's Encrypt)

Add to crontab (`sudo crontab -e`):

```cron
0 3 * * * certbot renew --quiet && /path/to/routeDNS/deploy-certs.sh && docker compose -f /path/to/routeDNS/docker-compose.yml restart haproxy
```

---

## ⚙️ Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `VALKEY_PASSWORD` | - | Valkey/Redis password (required) |
| `GF_SECURITY_ADMIN_USER` | `admin` | Grafana admin username |
| `GF_SECURITY_ADMIN_PASSWORD` | - | Grafana admin password (required) |
| `HAPROXY_STATS_USER` | `admin` | HAProxy stats username |
| `HAPROXY_STATS_PASSWORD` | - | HAProxy stats password (required) |
| `BACKUP_DIR` | `./backups` | Backup storage directory |

### Tenant Validation API

The Lua script validates tenants against `https://routedns.io/dns/validate.php`:

```
SNI: {tenant_code}.dns.routedns.io
API: GET /dns/validate.php?code={tenant_code}
Response: {"valid": true/false}
```

### Rate Limiting Defaults

| Limit | Value | Location |
|-------|-------|----------|
| Connections/IP/10s | 20 | HAProxy |
| Concurrent conn/IP | 10 | HAProxy |
| Connections/tenant/10s | 100 | HAProxy |
| Auto-ban threshold | 50 conn/10s | HAProxy |
| Ban duration | 30 minutes | HAProxy |
| Device limit/tenant | 1 | Lua script |
| Device block duration | 30 minutes | Lua script |

---

## 🛡 Security Hardening

### Container Security

All containers run with:
- ✅ `no-new-privileges:true`
- ✅ `cap_drop: ALL` (minimal capabilities)
- ✅ Read-only filesystems where possible
- ✅ Resource limits (CPU/Memory)
- ✅ Non-root users

### Network Security

- ✅ Internal networks isolated
- ✅ Admin ports bound to `127.0.0.1` only
- ✅ Only port 853 (DoT) exposed externally

### Exposed Ports

| Port | Binding | Service | Auth Required |
|------|---------|---------|---------------|
| 853 | `0.0.0.0` | DoT (HAProxy) | TLS + Tenant |
| 8404 | `127.0.0.1` | HAProxy Stats | Yes |
| 9090 | `127.0.0.1` | Prometheus | No |
| 3000 | `127.0.0.1` | Grafana | Yes |
| 6379 | `127.0.0.1` | Valkey | Yes |

### Security Checklist

- [ ] Strong passwords in `.env` (min 24 chars)
- [ ] SSL certificates from trusted CA
- [ ] Firewall rules: only port 853 public
- [ ] Regular backups enabled
- [ ] Log monitoring configured
- [ ] Alerts configured in Prometheus

---

## 📊 Monitoring

### Access Dashboards

```bash
# Grafana (default: admin / your-password)
open http://localhost:3000

# Prometheus
open http://localhost:9090

# HAProxy Stats
open http://localhost:8404/stats
```

### Pre-configured Alerts

| Alert | Condition | Severity |
|-------|-----------|----------|
| HAProxyBackendDown | Backend unreachable > 1m | Critical |
| HAProxyDoTDown | DoT frontend down > 1m | Critical |
| ValkeyDown | Valkey unreachable > 1m | Critical |
| HAProxyHighErrorRate | 5xx > 10% for 5m | Critical |
| ValkeyHighMemory | Memory > 90% | Warning |

---

## 🔨 Management Commands

```bash
# Service status
./manage.sh status

# View logs
./manage.sh logs              # All services
./manage.sh logs haproxy      # Specific service

# Restart services
./manage.sh restart           # All services
./manage.sh restart haproxy   # Specific service

# Health checks
./manage.sh test

# Shell access
./manage.sh shell valkey
./manage.sh shell haproxy

# Backups
./backup.sh daily
./backup.sh weekly
./backup.sh manual
```

### Valkey Commands

```bash
# Connect to Valkey
docker exec -it valkey valkey-cli -a $VALKEY_PASSWORD

# Check cached tenants
KEYS v:*

# Unblock a tenant
DEL blocked:tenant_code
DEL dev:tenant_code

# View stats
INFO
```

---

## 🐛 Troubleshooting

### Common Issues

#### Services won't start

```bash
# Check logs
docker compose logs --tail=50

# Verify .env file exists
ls -la .env

# Check certificate permissions
ls -la haproxy/certs/
```

#### Certificate errors

```bash
# Verify certificate
openssl x509 -in haproxy/certs/dot.pem -noout -dates

# Check HAProxy can read it
docker compose exec haproxy cat /usr/local/etc/haproxy/certs/dot.pem | head -5
```

#### Tenant validation fails

```bash
# Check Valkey connection
docker compose exec haproxy nc -zv valkey 6379

# Test API manually
curl "https://routedns.io/dns/validate.php?code=test_tenant"

# Check HAProxy logs
docker compose logs haproxy | grep tenant
```

#### High memory usage

```bash
# Check container stats
docker stats

# Clear Valkey cache
docker exec valkey valkey-cli -a $VALKEY_PASSWORD FLUSHDB
```

### Test DNS Resolution

```bash
# Test DoT connection (requires kdig from knot-dnsutils)
kdig @dns.routedns.io +tls google.com

# Or using openssl
echo -e '\x00\x1c\x00\x00\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x06google\x03com\x00\x00\x01\x00\x01' | \
  openssl s_client -connect dns.routedns.io:853 -servername tenant.dns.routedns.io -quiet
```

---

## 📚 API Reference

### Tenant Validation Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/dns/validate.php?code={code}` | GET | Validate tenant code |
| `/dns/bind-device.php?code={code}&ip={ip}` | GET | Bind device to tenant |

### HAProxy Stats API

```bash
# Prometheus metrics
curl http://localhost:8404/metrics

# Health check
curl http://localhost:8404/health

# Stats page (requires auth)
curl -u admin:password http://localhost:8404/stats
```

---

## 📁 Project Structure

```
routeDNS/
├── docker-compose.yml      # Main stack definition
├── Dockerfile              # HAProxy with Lua
├── .env.example            # Environment template
├── .gitignore              # Git ignore rules
├── manage.sh               # Management script
├── backup.sh               # Backup script
├── deploy-certs.sh         # Certificate deployment
├── haproxy/
│   ├── haproxy.cfg         # HAProxy configuration
│   ├── certs/              # TLS certificates
│   └── lua/
│       └── tenant_validation.lua  # Tenant validation
├── routedns/
│   └── config.toml         # RouteDNS configuration
└── monitoring/
    ├── prometheus/
    │   ├── prometheus.yml  # Prometheus config
    │   └── alerts.yml      # Alert rules
    └── grafana/
        ├── dashboards/     # Pre-built dashboards
        └── provisioning/   # Auto-provisioning
```

---

## 📄 License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

---

## 🤝 Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing`)
5. Open a Pull Request

---

## 📞 Support

- **Issues**: [GitHub Issues](https://github.com/bdtunneldev/routeDNS/issues)
- **Documentation**: This README
- **Email**: support@routedns.io
