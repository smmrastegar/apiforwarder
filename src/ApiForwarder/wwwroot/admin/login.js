const form = document.getElementById("loginForm");
const errorEl = document.getElementById("error");

// If already signed in, skip the login screen.
fetch("/admin/api/session")
  .then((r) => r.json())
  .then((s) => { if (s.authenticated) location.href = "index.html"; })
  .catch(() => {});

form.addEventListener("submit", async (e) => {
  e.preventDefault();
  errorEl.textContent = "";
  const username = document.getElementById("username").value;
  const password = document.getElementById("password").value;

  try {
    const res = await fetch("/admin/api/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ username, password }),
    });
    if (res.ok) {
      location.href = "index.html";
    } else {
      const body = await res.json().catch(() => ({}));
      errorEl.textContent = body.error || "ورود ناموفق بود";
    }
  } catch {
    errorEl.textContent = "خطا در ارتباط با سرور";
  }
});
