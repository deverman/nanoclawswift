# Production Readiness Guide

## Issues Encountered & Mitigation Strategies

### 1. Swift Version Compatibility
**Issue:** GitHub Actions `swift-actions/setup-swift` doesn't support Swift 6.2.3  
**Impact:** CI/CD pipeline failure  
**Mitigation:** 
- Use native Swift toolchain on `macos-26` runner instead of forcing setup action installs
- Keep `swift-tools-version:5.10` for broader local compatibility
- **Prevention:** Always check available versions on https://swift.org/download/ before specifying in CI

### 2. SwiftAgents / Swarm API Documentation Gaps
**Issue:** Limited documentation on exact type names (ToolSchema vs ToolDefinition, etc.)  
**Impact:** Build failures due to type name mismatches  
**Mitigation:**
- Had to explore SwiftAgents source code directly to find correct types
- Repository source aligned to renamed upstream (`Swarm.git`) while keeping pinned `0.3.1` API surface (phased migration)
- **Prevention:** Clone and examine dependencies locally before coding; check for breaking changes between versions

### 3. Swift ArgumentParser @main Attribute
**Issue:** LSP errors about 'main' attribute with top-level code  
**Impact:** IDE warnings but builds worked  
**Mitigation:**
- Moved helper functions inside the main struct as static methods
- **Prevention:** Follow ArgumentParser examples exactly; avoid global variables

### 4. Git Remote URL Confusion
**Issue:** Git was pointing to gavrielc/nanoclaw instead of deverman/nanoclawswift  
**Impact:** Push failures with 403 errors  
**Mitigation:**
- Updated remote URL to correct fork location
- **Prevention:** Always verify `git remote -v` after cloning a fork

### 5. Swift Concurrency with Foundation
**Issue:** FileHandle.readDataToEndOfFile() is not async  
**Impact:** Blocking calls in async context  
**Mitigation:**
- Used synchronous read (acceptable for small stdin data)
- **Prevention:** Check Foundation APIs for async variants; consider NIO for large I/O

### 6. File Path vs FilePath
**Issue:** swift-configuration expects FilePath type, not String  
**Impact:** Type conversion errors  
**Mitigation:**
- Removed swift-configuration dependency entirely
- Implemented simple environment + JSON file loading manually
- **Prevention:** Check type signatures carefully; prefer simple solutions

### 7. Container Build Dependencies
**Issue:** Container requires Swift binary to be built before Docker build  
**Impact:** CI/CD race conditions  
**Mitigation:**
- Made container-build job depend on build-and-test job
- **Prevention:** Always specify job dependencies in CI workflows

### 8. Container Image Metadata Drift (Local Host)
**Issue:** `container image ls` can fail if local state references missing content digests  
**Impact:** Image management commands fail despite runtime still working  
**Mitigation:**
- Identify stale digest references in `/Users/deverman/Library/Application Support/com.apple.container/state.json`
- Re-pull stale image tags or clean stale metadata references with a backup
- Verified on 2026-02-06 that after cleanup + service restart, `container image ls` and `container run` both recover normally
- **Prevention:** Keep base images current and avoid interrupted large pulls for multi-GB images

### 9. Tailscale Exit-Node / `utun` Default Route vs Container Egress
**Issue:** With host default route on `utun*` (common with Tailscale exit-node), container VM outbound internet can fail while host internet remains healthy  
**Impact:** LLM provider calls from inside container fail (DNS errors/timeouts), breaking Telegram/WhatsApp agent responses  
**Mitigation:**
- Runtime now detects default route interface and enables host relay automatically in `CONTAINER_LLM_RELAY_MODE=auto` when route is `utun*`
- Relay rewrites container `BASE_URL` to `http://192.168.64.1:18081/relay/{provider}/v1`
- Relay DNS uses explicit resolvers (`CONTAINER_LLM_RELAY_DNS_SERVERS`, default `1.1.1.1,8.8.8.8`)
- Host-level option: if using Tailscale exit node, enable "Allow LAN access" or disable exit node during direct container egress tests
- **Prevention:** Treat `route -n get default` + container egress probe as part of incident triage before blaming provider/API keys

### 10. Missing First-Class Web Tools in Swift Runtime
**Issue:** Swift runtime initially lacked `WebFetch`/`WebSearch` despite architecture docs expecting them  
**Impact:** Agent fell back to shell tooling (`curl`) which was not always available/reliable in runtime images  
**Mitigation:**
- Added host web broker endpoints (`/web/fetch`, `/web/search`, `/web/policy/list`) on the relay server path
- Added Swift tools: `web_fetch`, `web_search`, `web_policy_add_domain`, `web_policy_remove_domain`, `web_policy_list`
- Added two-layer policy model:
  - global baseline `~/.config/nanoclaw/web-policy.global.json` (host-managed)
  - group overlay `groups/{group}/.nanoclaw/web-policy.overlay.json` (container-writable)
- **Prevention:** Keep docs and runtime tool registry aligned as part of release checklist

### 11. Network-Constrained Builder Pull Blocks Final Runtime Image Refresh
**Issue:** Final runtime image validation requires rebuilding `nanoclawswift-agent:slim`, but the builder base image `docker.io/library/swift:6.2.3` is ~2.2GB and may be unavailable/too slow on constrained links.  
**Impact:** Source changes are ready and tested locally, but container E2E can still run older agent binary until image rebuild completes.  
**Mitigation:**
- Keep non-image validation moving: `npm run typecheck`, `npm run build`, `swift test`, `npm run container:smoke`, `npm run container:netcheck`.
- Rebuild immediately when network stabilizes:
  - `container image pull docker.io/library/swift:6.2.3`
  - `container build -f container/Dockerfile.slim -t nanoclawswift-agent:slim .`
- Verify freshness via `container image inspect nanoclawswift-agent:slim` and rerun Telegram E2E.
- **Prevention:** Maintain a pre-pulled local cache of large builder images before travel/limited-connectivity windows.

### 12. Kimi Temperature Constraint (HTTP 400)
**Issue:** Some Kimi models reject non-`1` temperature with `invalid temperature: only 1 is allowed for this model`  
**Impact:** Agent returns upstream 400 instead of response  
**Mitigation:**
- `OpenAICompatibleProvider` now normalizes Kimi/Moonshot requests to `temperature=1.0`
- Rebuild and redeploy container image after this change
- **Prevention:** Keep provider-specific request normalization tests and verify model-compat constraints on upgrade

### 13. Relay Port Conflict (`EADDRINUSE` on `:18081`)
**Issue:** Stale local `npm run dev` process can keep relay port `18081` bound  
**Impact:** Relay startup fails; container falls back to direct egress and may hit DNS/network errors  
**Mitigation:**
- Detect via logs: `Failed to start LLM relay ... EADDRINUSE`
- Identify stale listener (`lsof -nP -iTCP:18081 -sTCP:LISTEN`) and stop it
- Restart app cleanly
- **Prevention:** Ensure old dev sessions are terminated before restart

---

## Monitoring CI/CD via GitHub CLI

### View Recent Runs
```bash
# List last 5 runs
gh run list --repo deverman/nanoclawswift --limit 5

# View specific run details
gh run view <run-id> --repo deverman/nanoclawswift

# View failed logs
gh run view <run-id> --log-failed --repo deverman/nanoclawswift
```

### Watch Live Builds
```bash
# Trigger and watch a build
gh workflow run CI --repo deverman/nanoclawswift
gh run watch --repo deverman/nanoclawswift
```

---

## API Key Configuration for Kimi

### Where to Put API Keys

**Option 1: Environment Variables (Recommended for CI/CD)**
```bash
# Set in your shell or CI environment
export MOONSHOT_API_KEY="your-api-key-here"
export MODEL_PROVIDER="kimi"
export MODEL_NAME="kimi-k2.5"
```

**Option 2: Config File (Recommended for Local Development)**
Create `/workspace/config.json`:
```json
{
  "api_key": "your-api-key-here",
  "model_provider": "kimi",
  "model_name": "kimi-k2.5",
  "timeout": 60
}
```

**Option 3: Container Environment**
In `container/Dockerfile.slim`:
```dockerfile
ENV MOONSHOT_API_KEY="${MOONSHOT_API_KEY}"
```

**Security Best Practices:**
- Never commit API keys to git
- Use GitHub Secrets for CI/CD: `Settings > Secrets and variables > Actions`
- Rotate keys every 90 days
- Use different keys for dev/staging/prod
- Never log API keys (redact in logs)

### Getting a Kimi API Key
1. Visit https://platform.moonshot.ai/
2. Create an account
3. Generate API key in the console
4. Copy key (starts with `sk-`)

---

## Integration Testing Steps

### 1. Local Binary Test
```bash
cd /Users/deverman/Documents/Code/nanoclawswift
swift build -c release
echo '{"prompt":"What is 2+2?","groupFolder":"test","chatJid":"test@g.us","isMain":false}' | ./.build/release/nanoclaw-agent --config /dev/null --group-folder test --chat-jid test@g.us
```

### 2. Container Test
```bash
cd container
./build-swift.sh slim
container run --rm nanoclawswift-agent:slim echo "Container works"
```

### 2b. Container Runtime Smoke
```bash
cd /Users/deverman/Documents/Code/nanoclawswift
npm run container:smoke
```

### 2c. Container Network Diagnostics (VPN/Tailscale Hosts)
```bash
cd /Users/deverman/Documents/Code/nanoclawswift
npm run container:netcheck
```

### 3. Full Integration Test
```bash
# Start the Node.js orchestration
npm run dev

# Send a test message via WhatsApp or manually trigger
# Check logs for agent execution
```

---

## Production Readiness Checklist

### Code Quality
- [x] Swift 6.2.3 runtime validated on macOS 26 CI host
- [x] All compiler warnings resolved
- [x] Swift test suite passing (13 tests: CLI, config, tools, session, tool-call integration, pseudo-tool rejection, schedule/cancel IPC persistence, web policy tool coverage)
- [ ] Comprehensive test suite (>80% coverage)
- [ ] Integration tests with mock LLM
- [ ] Error handling audit (all throws documented)
- [ ] Memory leak testing (instruments)

### Security
- [x] No hardcoded secrets
- [x] File permissions set correctly (600/700)
- [x] Non-root container user
- [x] API keys via environment variables
- [ ] Secrets scanning in CI (git-secrets)
- [ ] Dependency vulnerability scanning
- [ ] Security headers in HTTP requests

### Performance
- [x] Async/await for I/O operations
- [x] Relay-side connection reuse via keep-alive agents in `src/container-runner.ts`
- [ ] Provider-side connection pooling/circuit breaking policy hardening
- [ ] Response caching for repeated prompts
- [ ] Timeout handling (60s default)
- [ ] Circuit breaker for LLM failures
- [ ] Rate limiting compliance

### Observability
- [ ] Structured logging (not just print)
- [ ] Metrics collection (Prometheus)
- [ ] Distributed tracing (OpenTelemetry)
- [ ] Health check endpoint
- [ ] Alerting for failures

### Reliability
- [x] Session persistence (JSON files)
- [x] Conversation archiving
- [x] Retry logic with exponential backoff (429 handling)
- [ ] Graceful degradation (fallback models)
- [ ] Data backup strategy
- [ ] Disaster recovery plan

### Documentation
- [ ] API documentation (OpenAPI/Swagger)
- [ ] Architecture diagrams
- [ ] Troubleshooting guide
- [ ] Runbook for common issues
- [ ] Changelog maintenance

### CI/CD
- [x] GitHub Actions workflow
- [x] Swift build + test on PR
- [x] Automated testing on PR
- [x] Local container smoke gate (`npm run container:smoke`)
- [x] CI container runtime smoke gate (`.github/workflows/ci.yml` -> `scripts/container-smoke.sh`)
- [ ] Container image publishing
- [ ] Automated security scanning
- [ ] Performance benchmarking
- [x] Confirm runtime image is rebuilt from current source commit and validated in Telegram E2E

---

## Remaining Work for Production

### High Priority
1. **Comprehensive Testing**
   - Unit tests for each tool
   - Integration tests with real LLM
   - Mock provider for CI

2. **Error Handling**
   - Audit all error cases
   - Add user-friendly error messages
   - Expand retry policy coverage beyond HTTP 429 and add retry telemetry
   - Add guarded preflight remediation playbook for local container metadata drift

3. **Observability**
   - Replace print statements with structured logging
   - Add metrics collection
   - Create monitoring dashboard

4. **Configuration Management**
   - Support for multiple environments
   - Configuration validation
   - Hot-reloading config

### Medium Priority
5. **Performance Optimization**
   - HTTP connection pooling
   - Response caching
   - Binary size optimization

6. **Security Hardening**
   - Secrets scanning in CI
   - Vulnerability scanning
   - Penetration testing

7. **Documentation**
   - API reference
   - Troubleshooting guide
   - Contribution guidelines

### Low Priority
8. **Features**
   - Expand search provider support beyond DuckDuckGo API
   - Rich HTML extraction and readability transforms for web fetch
   - Image generation support
   - Multi-modal inputs

---

## Migration from Old NanoClaw

See migration notes in this repository for detailed migration guidance from Node.js/Claude SDK to Swift/SwiftAgents (Swarm source).

## Next Steps

1. Run Mac mini bring-up checklist from `README.md`
2. Add comprehensive test suite coverage
3. Set up API key in GitHub Secrets
4. Run integration tests
5. Create monitoring/alerting
6. Performance testing
7. Security audit
8. Documentation updates
