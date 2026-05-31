// ---- session guard -------------------------------------------------------
async function requireAuth() {
  const s = await fetch("/admin/api/session").then((r) => r.json()).catch(() => ({}));
  if (!s.authenticated) {
    location.href = "login.html";
    return null;
  }
  document.getElementById("whoami").textContent = "👤 " + (s.username || "");
  return s;
}

// ---- helpers -------------------------------------------------------------
const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

function publicBase() {
  return location.origin; // shown as-is; in production this is https://api.lto.bz
}

// ---- list ----------------------------------------------------------------
async function loadRules() {
  const body = $("rulesBody");
  try {
    const rules = await fetch("/admin/api/routes").then((r) => r.json());
    if (!Array.isArray(rules) || rules.length === 0) {
      body.innerHTML = `<tr><td colspan="6" class="muted">هنوز قانونی تعریف نشده است.</td></tr>`;
      return;
    }
    body.innerHTML = rules.map((r) => {
      const opts = [];
      if (r.stripPrefix) opts.push("Strip");
      if (r.hideOrigin) opts.push("HideIP");
      if (r.methods && r.methods.length) opts.push(r.methods.join("/"));
      return `
        <tr>
          <td><span class="badge ${r.enabled ? "on" : "off"}">${r.enabled ? "فعال" : "غیرفعال"}</span></td>
          <td>${esc(r.name)}</td>
          <td><code>${esc(r.pathPrefix)}</code></td>
          <td><code>${esc(r.destination)}</code></td>
          <td class="muted">${esc(opts.join(" · "))}</td>
          <td style="white-space:nowrap;">
            <button class="btn small secondary" data-edit="${r.id}">ویرایش</button>
            <button class="btn small danger" data-del="${r.id}">حذف</button>
          </td>
        </tr>`;
    }).join("");

    body.querySelectorAll("[data-edit]").forEach((b) =>
      b.addEventListener("click", () => openModal(rules.find((x) => x.id === b.dataset.edit))));
    body.querySelectorAll("[data-del]").forEach((b) =>
      b.addEventListener("click", () => deleteRule(b.dataset.del)));
  } catch {
    body.innerHTML = `<tr><td colspan="6" class="error">خطا در بارگذاری قوانین</td></tr>`;
  }
}

// ---- modal ---------------------------------------------------------------
function openModal(rule) {
  $("modalError").textContent = "";
  $("modalTitle").textContent = rule ? "ویرایش قانون" : "افزودن قانون";
  $("ruleId").value = rule?.id || "";
  $("name").value = rule?.name || "";
  $("pathPrefix").value = rule?.pathPrefix || "/";
  $("destination").value = rule?.destination || "";
  $("enabled").checked = rule ? !!rule.enabled : true;
  $("stripPrefix").checked = rule ? !!rule.stripPrefix : true;
  $("hideOrigin").checked = rule ? !!rule.hideOrigin : true;
  $("useDestHost").checked = rule ? !!rule.useDestinationHostHeader : true;
  $("methods").value = (rule?.methods || []).join(", ");
  $("headers").value = Object.entries(rule?.addRequestHeaders || {}).map(([k, v]) => `${k}: ${v}`).join("\n");
  updatePrefixPreview();
  $("modal").classList.add("show");
}

function closeModal() { $("modal").classList.remove("show"); }

function updatePrefixPreview() {
  $("prefixPreview").textContent = $("pathPrefix").value || "/";
}

function parseHeaders(text) {
  const result = {};
  text.split("\n").forEach((line) => {
    const idx = line.indexOf(":");
    if (idx > 0) {
      const k = line.slice(0, idx).trim();
      const v = line.slice(idx + 1).trim();
      if (k) result[k] = v;
    }
  });
  return result;
}

async function saveRule() {
  $("modalError").textContent = "";
  const id = $("ruleId").value;
  const payload = {
    name: $("name").value.trim(),
    pathPrefix: $("pathPrefix").value.trim() || "/",
    destination: $("destination").value.trim(),
    enabled: $("enabled").checked,
    stripPrefix: $("stripPrefix").checked,
    hideOrigin: $("hideOrigin").checked,
    useDestinationHostHeader: $("useDestHost").checked,
    methods: $("methods").value.split(",").map((s) => s.trim()).filter(Boolean),
    addRequestHeaders: parseHeaders($("headers").value),
  };

  const url = id ? `/admin/api/routes/${id}` : "/admin/api/routes";
  const method = id ? "PUT" : "POST";
  try {
    const res = await fetch(url, {
      method,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    if (res.ok) {
      closeModal();
      loadRules();
    } else {
      const b = await res.json().catch(() => ({}));
      $("modalError").textContent = b.error || "ذخیره ناموفق بود";
    }
  } catch {
    $("modalError").textContent = "خطا در ارتباط با سرور";
  }
}

async function deleteRule(id) {
  if (!confirm("این قانون حذف شود؟")) return;
  await fetch(`/admin/api/routes/${id}`, { method: "DELETE" });
  loadRules();
}

// ---- server info ---------------------------------------------------------
async function showServerInfo() {
  const el = $("serverInfo");
  el.textContent = "در حال دریافت اطلاعات سرور…";
  try {
    const info = await fetch("/admin/api/server-info").then((r) => r.json());
    const parts = [];
    if (info.outboundIp) parts.push(`IP خروجی سرور (که API ها می‌بینند): <code>${esc(info.outboundIp)}</code>`);
    if (info.localIps && info.localIps.length) parts.push(`IP محلی: <code>${esc(info.localIps.join(", "))}</code>`);
    if (info.machineName) parts.push(`سرور: <code>${esc(info.machineName)}</code>`);
    el.innerHTML = parts.join(" &nbsp;|&nbsp; ");
  } catch {
    el.textContent = "دریافت اطلاعات سرور ناموفق بود";
  }
}

// ---- wire up -------------------------------------------------------------
(async function init() {
  if (!(await requireAuth())) return;

  $("addBtn").addEventListener("click", () => openModal(null));
  $("cancelBtn").addEventListener("click", closeModal);
  $("saveBtn").addEventListener("click", saveRule);
  $("pathPrefix").addEventListener("input", updatePrefixPreview);
  $("infoBtn").addEventListener("click", showServerInfo);
  $("logoutBtn").addEventListener("click", async () => {
    await fetch("/admin/api/logout", { method: "POST" });
    location.href = "login.html";
  });
  $("modal").addEventListener("click", (e) => { if (e.target.id === "modal") closeModal(); });

  loadRules();
  showServerInfo();
})();
