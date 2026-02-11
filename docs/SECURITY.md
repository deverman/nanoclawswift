# NanoClaw Security Model

## Trust Model

| Entity | Trust Level | Rationale |
|--------|-------------|-----------|
| Main group | Trusted | Private self-chat, admin control |
| Non-main groups | Untrusted | Other users may be malicious |
| Container agents | Sandboxed | Isolated execution environment |
| WhatsApp messages | User input | Potential prompt injection |

## Security Boundaries

### 1. Container Isolation (Primary Boundary)

Agents execute in Apple Container (lightweight Linux VMs), providing:
- **Process isolation** - Container processes cannot affect the host
- **Filesystem isolation** - Only explicitly mounted directories are visible
- **Non-root execution** - Runs as unprivileged `node` user (uid 1000)
- **Ephemeral containers** - Fresh environment per invocation (`--rm`)

This is the primary security boundary. Rather than relying on application-level permission checks, the attack surface is limited by what's mounted.

### 2. Mount Security

**External Allowlist** - Mount permissions stored at `~/.config/nanoclaw/mount-allowlist.json`, which is:
- Outside project root
- Never mounted into containers
- Cannot be modified by agents

**Default Blocked Patterns:**
```
.ssh, .gnupg, .aws, .azure, .gcloud, .kube, .docker,
credentials, .env, .netrc, .npmrc, id_rsa, id_ed25519,
private_key, .secret
```

**Protections:**
- Symlink resolution before validation (prevents traversal attacks)
- Container path validation (rejects `..` and absolute paths)
- `nonMainReadOnly` option forces read-only for non-main groups

### 3. Session Isolation

Each group has isolated Claude sessions at `data/sessions/{group}/.claude/`:
- Groups cannot see other groups' conversation history
- Session data includes full message history and file contents read
- Prevents cross-group information disclosure

### 4. IPC Authorization

Messages and task operations are verified against group identity:

| Operation | Main Group | Non-Main Group |
|-----------|------------|----------------|
| Send message to own chat | ✓ | ✓ |
| Send message to other chats | ✓ | ✗ |
| Schedule task for self | ✓ | ✓ |
| Schedule task for others | ✓ | ✗ |
| View all tasks | ✓ | Own only |
| Manage other groups | ✓ | ✗ |

### 5. Credential Handling

**Runtime Credentials:**
- Model/provider credentials are passed via a generated `--env-file` at launch time.
- Optional Claude auth token can be included when present.

**NOT Mounted:**
- WhatsApp session (`store/auth/`) - host only
- Mount allowlist - external, never mounted
- Any credentials matching blocked patterns

**Credential Filtering:**
Only an allowlisted set of environment variables is exposed to containers:
```typescript
const allowedVars = [
  'MODEL_PROVIDER', 'MODEL_NAME',
  'OPENAI_API_KEY', 'MOONSHOT_API_KEY', 'ANTHROPIC_API_KEY',
  'BASE_URL', 'TIMEOUT', 'MAX_TOKENS', 'ASSISTANT_NAME',
  'CLAUDE_CODE_OAUTH_TOKEN',
  'NANOCLAW_WEB_BROKER_URL', 'NANOCLAW_GROUP_FOLDER'
];
```

> **Note:** Any credentials passed to the container are available to processes inside the container. Keep the allowlist minimal and do not pass unrelated host secrets.

### 6. Web Access Policy Model

Web tools (`web_fetch`, `web_search`) execute through a host-side broker that enforces domain policy before outbound requests.

- **Global baseline policy**: `~/.config/nanoclaw/web-policy.global.json`
  - Host-managed and not mounted into containers.
- **Group overlay policy**: `groups/{group}/.nanoclaw/web-policy.overlay.json`
  - Mounted in the group folder and directly writable by container tools.
  - Scope is limited to the current group only.

Effective policy = `global allow + group allow`, with deny rules and hard-deny host checks applied first.

Tradeoff: Bash remains unrestricted by design, so policy is best-effort for web tools rather than a strict network egress control.

### 7. Structured Tool-Call Enforcement

Agent execution uses Swarm's native structured tool-calling flow (`ToolCallingAgent`).

- Tools execute only when returned in structured `tool_calls`.
- Raw pseudo-tool markdown/code blocks (for example ````tool ...````) are treated as invalid output.
- Invalid tool-block output is blocked by output guardrails and converted into a safe retry message.

This reduces prompt-based tool spoofing risk compared to text-parsed tool execution.

## Privilege Comparison

| Capability | Main Group | Non-Main Group |
|------------|------------|----------------|
| Project root access | `/workspace/project` (rw) | None |
| Group folder | `/workspace/group` (rw) | `/workspace/group` (rw) |
| Global memory | Implicit via project | `/workspace/global` (ro) |
| Additional mounts | Configurable | Read-only unless allowed |
| Network access | Unrestricted | Unrestricted |
| MCP tools | All | All |
| Web policy overlay writes | Own group | Own group |

## Security Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────┐
│                        UNTRUSTED ZONE                             │
│  WhatsApp Messages (potentially malicious)                        │
└────────────────────────────────┬─────────────────────────────────┘
                                 │
                                 ▼ Trigger check, input escaping
┌──────────────────────────────────────────────────────────────────┐
│                     HOST PROCESS (TRUSTED)                        │
│  • Message routing                                                │
│  • IPC authorization                                              │
│  • Mount validation (external allowlist)                          │
│  • Container lifecycle                                            │
│  • Credential filtering                                           │
└────────────────────────────────┬─────────────────────────────────┘
                                 │
                                 ▼ Explicit mounts only
┌──────────────────────────────────────────────────────────────────┐
│                CONTAINER (ISOLATED/SANDBOXED)                     │
│  • Agent execution                                                │
│  • Bash commands (sandboxed)                                      │
│  • File operations (limited to mounts)                            │
│  • Network access (unrestricted)                                  │
│  • Cannot modify security config                                  │
└──────────────────────────────────────────────────────────────────┘
```
