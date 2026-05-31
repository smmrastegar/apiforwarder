# API Forwarder

یک **HTTP Request Forwarder (Reverse Proxy)** با رابط کاربری (UI) که روی **IIS** و
ویندوز سرور اجرا می‌شود. با آن می‌توانید ریکوست‌ها را از طریق یک پنل مدیریت تعریف
کنید و با یک آدرس جدید (مثلاً `https://api.lto.bz/github`) صدا بزنید، **بدون اینکه
آدرس اصلی مقصد دیده شود**. ضمناً درخواست خروجی همیشه از طرف **IP خود سرور** ارسال
می‌شود (نه IP کلاینت).

ساخته‌شده با **ASP.NET Core 8 + YARP** و دیپلوی خودکار با **GitHub Actions**.

---

## ✨ امکانات

- 🔀 **فوروارد داینامیک**: قوانین مسیر را از UI اضافه/ویرایش/حذف کنید؛ بدون ری‌استارت اعمال می‌شود.
- 🕵️ **مخفی‌سازی مقصد**: کلاینت فقط `api.lto.bz/<prefix>` را می‌بیند؛ آدرس واقعی سمت سرور می‌ماند.
- 🌐 **مخفی‌سازی کلاینت**: هدرهای `X-Forwarded-*` حذف می‌شوند تا مقصد فقط IP سرور را ببیند.
- 🔐 **پنل مدیریت محافظت‌شده** با نام کاربری/رمز عبور (Cookie auth).
- 🧩 امکان حذف Prefix، تنظیم Host مقصد، محدودکردن متدها و افزودن هدرهای دلخواه (مثل توکن).
- 💾 ذخیره‌سازی قوانین در فایل JSON (در دیپلوی‌ها حفظ می‌شود).
- 🚀 **دیپلوی کاملاً خودکار**: هر `git push` روی سرور build و منتشر می‌شود.

---

## 🗺️ معماری

```
کلاینت ──► Cloudflare (api.lto.bz) ──► IIS (ویندوز سرور) ──► ApiForwarder (ASP.NET Core + YARP) ──► مقصد واقعی (مخفی)
```

- مسیر `/admin` → پنل مدیریت
- مسیر `/health` → health check
- بقیه‌ی مسیرها طبق قوانینی که در UI تعریف می‌کنید فوروارد می‌شوند.

---

## ⚡ راه‌اندازی سریع (یک خط — پیشنهادی)

روی سرور با **RDP** وارد شوید، یک **PowerShell با دسترسی Administrator** باز کنید و این را اجرا کنید:

```powershell
irm https://raw.githubusercontent.com/smmrastegar/apiforwarder/claude/http-forwarder-ui-VVsZF/deploy/bootstrap.ps1 | iex
```

این اسکریپت همه‌چیز را خودکار انجام می‌دهد: نصب **.NET 8 Hosting Bundle**، فعال‌سازی **IIS**،
ساخت سایت/App Pool، کلون سورس، اولین **build & deploy** و گرفتن رمز پنل ادمین. در پایان آدرس
پنل را نشان می‌دهد.

برای اینکه **دیپلوی خودکار** (با هر `git push`) هم در همان اجرا نصب شود، اول یک
**registration token** از مسیر `repo → Settings → Actions → Runners → New self-hosted runner → Windows`
بگیرید، بعد:

```powershell
$b = "https://raw.githubusercontent.com/smmrastegar/apiforwarder/claude/http-forwarder-ui-VVsZF/deploy/bootstrap.ps1"
irm $b -OutFile $env:TEMP\bootstrap.ps1
& $env:TEMP\bootstrap.ps1 -RunnerToken "<TOKEN>"
```

> اگر می‌خواهید مرحله‌به‌مرحله و دستی پیش بروید، بخش زیر را دنبال کنید.

---

## 🚀 راه‌اندازی دستی روی سرور (یک‌بار)

> همه‌ی دستورها در **PowerShell با دسترسی Administrator** اجرا شوند.

### ۱) نصب پیش‌نیازها
- **.NET 8 Hosting Bundle** را نصب کنید (ماژول `AspNetCoreModuleV2` را برای IIS فراهم می‌کند):
  https://dotnet.microsoft.com/download/dotnet/8.0 → بخش **Hosting Bundle**
- سپس: `net stop was /y ; net start w3svc` (یا یک ری‌استارت).

### ۲) ساخت IIS Site و App Pool
```powershell
git clone https://github.com/smmrastegar/apiforwarder.git C:\src\apiforwarder
cd C:\src\apiforwarder
.\deploy\setup-iis.ps1 -HostName api.lto.bz
```
این اسکریپت فیچرهای IIS را فعال می‌کند، App Pool (No Managed Code) و سایت را روی
`C:\inetpub\apiforwarder` می‌سازد و دسترسی‌ها را تنظیم می‌کند.

### ۳) نصب GitHub Actions Runner (برای دیپلوی خودکار)
از مسیر زیر یک **registration token** بگیرید:
GitHub repo → **Settings → Actions → Runners → New self-hosted runner → Windows**

سپس:
```powershell
.\deploy\install-runner.ps1 -RepoUrl https://github.com/smmrastegar/apiforwarder -Token <TOKEN>
```
> Runner به‌صورت سرویس ویندوزی نصب می‌شود. حساب سرویس باید اجازه‌ی مدیریت IIS و
> نوشتن در پوشه‌ی سایت را داشته باشد؛ ساده‌ترین راه این است که سرویس را با همان
> یوزر ادمین ویندوز اجرا کنید (`services.msc` → سرویس Runner → Log On → This account).

### ۴) تنظیم رمز پنل مدیریت
در سرور، فایل `C:\inetpub\apiforwarder\appsettings.json` را بعد از اولین دیپلوی
ویرایش کنید و رمز را عوض کنید، یا بهتر: از **Environment Variable** استفاده کنید
(امن‌تر و در دیپلوی‌ها پاک نمی‌شود):
```powershell
[Environment]::SetEnvironmentVariable("Admin__Username", "myadmin", "Machine")
[Environment]::SetEnvironmentVariable("Admin__Password", "یک-رمز-قوی", "Machine")
# سپس App Pool را ری‌سایکل کنید:
Import-Module WebAdministration; Restart-WebAppPool apiforwarder
```

### ۵) Cloudflare
- رکورد `api.lto.bz` (به‌صورت Proxied / ابر نارنجی) را به IP عمومی سرور وصل کنید.
- برای TLS، یک **Cloudflare Origin Certificate** بسازید، روی IIS یک binding روی
  پورت `443` با آن گواهی اضافه کنید و حالت SSL/TLS را روی **Full (strict)** بگذارید.
  (تا قبل از آن می‌توانید با پورت 80 تست کنید.)

---

## 🔁 جریان دیپلوی خودکار

با هر `push` روی برنچ `claude/http-forwarder-ui-VVsZF` (یا `main`):
1. Runon روی سرور build و `dotnet publish` انجام می‌دهد.
2. اسکریپت `deploy/deploy.ps1` با تکنیک `app_offline.htm` فایل‌ها را جابه‌جا می‌کند.
3. `App_Data\routes.json` (قوانین شما) و `logs` حفظ می‌شوند.

می‌توانید دیپلوی را از تب **Actions** در گیت‌هاب ببینید، یا دستی با
`workflow_dispatch` اجرا کنید.

اگر نمی‌خواهید Runner نصب کنید، می‌توانید همان `deploy/deploy.ps1` را دستی اجرا کنید
(بعد از `dotnet publish`).

---

## 🧪 استفاده از پنل

1. به `https://api.lto.bz/admin/` بروید.
2. با نام‌کاربری/رمزی که تنظیم کردید وارد شوید.
3. روی **«افزودن قانون»** بزنید و مقدارها را پر کنید:
   - **مسیر عمومی**: مثلاً `/github`
   - **مقصد واقعی**: مثلاً `https://api.github.com`
4. حالا فراخوانی `https://api.lto.bz/github/users/octocat` به‌صورت شفاف به
   `https://api.github.com/users/octocat` فوروارد می‌شود و مقصد فقط IP سرور را می‌بیند.

دکمه‌ی **«اطلاعات سرور»** هم IP خروجی سرور (همان IP که مقصدها می‌بینند) را نشان می‌دهد.

---

## 🛠️ توسعه‌ی محلی

```bash
cd src/ApiForwarder
dotnet run
# پنل: http://localhost:5000/admin/
```

---

## 📁 ساختار پروژه

```
src/ApiForwarder/
  Program.cs                 # bootstrap، auth، admin API، اتصال YARP
  Models/RouteRule.cs        # مدل قانون فوروارد
  Services/RouteStore.cs     # ذخیره/خواندن قوانین (JSON) + اعمال داینامیک
  Services/ProxyConfigProvider.cs  # تبدیل قوانین به کانفیگ زنده‌ی YARP
  wwwroot/admin/             # رابط کاربری (HTML/CSS/JS، فارسی/RTL)
  web.config                 # میزبانی IIS
deploy/
  bootstrap.ps1              # راه‌اندازی کامل و یک‌خطی روی سرور (پیشنهادی)
  setup-iis.ps1              # ساخت سایت و App Pool روی IIS
  install-runner.ps1         # نصب GitHub Actions runner
  deploy.ps1                 # انتشار build روی سایت (با حفظ داده)
.github/workflows/deploy.yml # دیپلوی خودکار
```
