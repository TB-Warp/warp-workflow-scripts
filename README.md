# Warp Workflow Scripts

Collection of powerful Warp terminal workflow scripts for development automation with LXC containers, Tailscale networking, and GitHub integration.

## 🚀 Scripts

### saga-dev-workflow.sh
**Complete development environment setup with ephemeral LXC containers**

**Usage:**
```bash
GH_PROJECT="repo_cmd" CONTAINER="container_name" [PROJECT="project_name"] ./saga-dev-workflow.sh
```

**Examples:**
```bash
# Using GitHub CLI with specific project
GH_PROJECT="gh repo clone SagasWeave/forfatter-pwa" CONTAINER="saga-dev" PROJECT="weave" ./saga-dev-workflow.sh

# Using default project (PROJECT not set)
GH_PROJECT="gh repo clone SagasWeave/my-repo" CONTAINER="my-container" ./saga-dev-workflow.sh

# Using HTTPS URL
GH_PROJECT="https://github.com/SagasWeave/my-repo" CONTAINER="my-container" PROJECT="my-project" ./saga-dev-workflow.sh
```

**Features:**
- ✅ **Clean Slate Development**: Ephemeral LXC containers for fresh starts
- ✅ **Stable Tailscale Hostnames**: No more saga-dev-1, saga-dev-2 suffixes
- ✅ **Automatic SSH Cleanup**: Clears old host keys before setup
- ✅ **Multi-language Support**: Auto-detects Node.js, Python, Ruby projects
- ✅ **GitHub Integration**: Supports private repos with GitHub CLI
- ✅ **Complete Project Cleanup**: Removes ALL containers in specified project

**Requirements:**
- LXC/LXD with remote server access
- Tailscale CLI
- GitHub CLI (`gh`) for private repos
- Environment variable: `GITHUB_TOKEN`

### fix-ssh-dynamic-containers.sh
**SSH troubleshooting for ephemeral containers**

**Usage:**
```bash
./fix-ssh-dynamic-containers.sh [COMMAND] [CONTAINER] [USER]
```

**Commands:**
- `clean` - Clean SSH known_hosts aggressively
- `test` - Test SSH connection
- `connect` - Connect via SSH with optimal settings
- `status` - Show Tailscale status
- `config` - Create SSH config entry
- `fix` - Full cleanup + config + test (default)

**Examples:**
```bash
# Quick fix for saga-dev
./fix-ssh-dynamic-containers.sh

# Clean all Tailscale IPs from known_hosts
./fix-ssh-dynamic-containers.sh clean saga-dev

# Test connection
./fix-ssh-dynamic-containers.sh test saga-dev ubuntu
```

**Ephemeral Mode Features:**
- 🧹 **Aggressive Cleanup**: Removes ALL Tailscale IPs (100.x.x.x and fd7a:)
- ⚡ **Optimized SSH Config**: Keepalive and compression for temporary connections
- 🔄 **Enhanced Error Handling**: Works with containers that may disappear

## 🎯 Warp Drive Workflows

### SAGA-DEV Workflow
```yaml
name: SAGA-DEV
command: |
  cd /Users/lpm/Documents/Warp
  ./saga-dev-workflow.sh -r {{repo}} -c {{lxc_container}} -p {{lxc_project}}
arguments:
  - repo: "gh repo clone SagasWeave/forfatter-pwa"
  - lxc_container: "saga-dev"  
  - lxc_project: "weaver"  # Optional - omit to use default project
environment_variables:
  GITHUB_TOKEN: "your_token_here"
```

### Clean SSH Workflow
```yaml
name: Clean SSH
command: |
  cd ~/Documents/Warp
  ./fix-ssh-dynamic-containers.sh
```

## 🛠 Architecture

**Clean-Slate Development Philosophy:**
1. **Ephemeral LXC Containers** - Auto-delete on stop
2. **Ephemeral Tailscale Nodes** - Auto-cleanup on disconnect
3. **Forced Hostname Consistency** - Always same name (no suffixes)
4. **Complete Project Cleanup** - Fresh start every time

**Network Setup:**
- Tailscale mesh networking for secure access
- SSH over Tailscale with optimized settings
- Automatic host key management

**Development Stack:**
- Ubuntu 25.04/24.04 LTS base images
- Node.js LTS (for PWA/web development)
- Python 3 + pip (auto-detected)
- Ruby + bundler (auto-detected)
- Git + build tools included

## 📋 Prerequisites

1. **LXC/LXD Setup:**
   ```bash
   lxc remote list  # Verify remote access
   lxc profile list # Verify 'shared-client' profile exists
   ```

2. **Tailscale:**
   ```bash
   tailscale status  # Verify connection
   ```

3. **GitHub CLI:**
   ```bash
   gh auth status   # Verify authentication
   ```

4. **Environment Variables:**
   ```bash
   export GITHUB_TOKEN="ghp_your_token_here"
   ```

## 🎨 Use Cases

### Web Development (PWA/React/Next.js)
Perfect for developing Progressive Web Apps with clean environments:
- Fresh Node.js + npm setup every time
- Private GitHub repo access
- SSH-based development workflow
- No dependency conflicts between projects

### Microservice Development
Ideal for developing multiple services:
- Isolated containers per service
- Consistent networking via Tailscale
- Easy switching between projects
- Clean slate testing environment

### Learning & Experimentation
Great for trying new technologies:
- No fear of "polluting" main system
- Easy to destroy and recreate
- Consistent starting point
- Real production-like environment

## 🏷 Rules Applied

Based on user preferences and organizational standards:
- 🇩🇰 **Danish Communication** (AI ↔ Human)
- 🇬🇧 **English Documentation** (Code & Docs)
- 📦 **LXC Containers** (Not Docker)
- 🔗 **Tailscale Networking** (All devices)
- 🐙 **GitHub CLI Integration** (Private repos)
- 🍺 **Homebrew on macOS** (Package management)
- ♻️ **Clean Slate Development** (Fresh environments)

## 🤝 Contributing

These scripts are part of the TB-Warp organization's development workflow automation. They follow our sprint process:

0. Init project → 1. Init git → 2. Install gh + auth → 3. Make repo + push → 4. Make project → 5. Make issues → 6. Install dependencies → 7. Develop → 8. Test → 9. Clean up

---

**Happy clean-slate development!** 🚀
