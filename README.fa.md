# Cloud Android 17 — GitHub Actions + Releases

یک Android Emulator مبتنی بر Android 17 QPR1 (API 37.1) با حافظه پایدار بین Runnerها. محیط اجرای اندروید روی GitHub-hosted runner موقت است؛ فایل‌های قابل‌نوشتن کاربر در Snapshot رمزگذاری‌شده AES-256-GCM داخل GitHub Releases نگهداری می‌شوند.

> **وضعیت:** نسخه اولیه قابل نصب و آزمایش است. اولین اجرای واقعی، سازگاری دقیق system image، KVM، اندازه Snapshot و زمان انتقال را روی حساب GitHub شما مشخص می‌کند. این پروژه Live Migration ندارد و وقفه بین دو Runner اجتناب‌ناپذیر است.

## امکانات

- Android 17 QPR1 / API 37.1 با Google Play system image و معماری x86_64.
- VNC تصویری از طریق noVNC در مرورگر.
- ترمینال مرورگری محدود به اجرای دستورهای `adb`؛ برای نمونه `adb devices` و `adb shell`.
- بازیابی `userdata-qemu.img` و `sdcard.img` از آخرین Release معتبر.
- فشرده‌سازی Zstandard، رمزگذاری AES-256-GCM و تقسیم فایل به قطعات ۱۸۰۰ MiB.
- انتشار Snapshot جدید پیش از حذف Releaseهای قدیمی؛ نگهداری دو Snapshot آخر برای امکان rollback.
- زنجیره‌کردن اجرای بعدی با `workflow_dispatch` و جلوگیری از اجرای هم‌زمان با concurrency group.
- دسترسی موقت HTTPS با Cloudflare Quick Tunnel؛ بدون خرید دامنه یا VPS.

## معماری و محدودیت‌ها

```text
GitHub Actions Runner (موقت)
  ├── Android Emulator 17
  ├── userdata-qemu.img  ─┐
  ├── sdcard.img         ─┴─> tar + zstd -> AES-256-GCM -> split
  ├── noVNC + VNC                 |
  ├── ADB-only browser terminal   v
  └── Cloudflare Quick Tunnel   GitHub Releases (عمومی، ولی داده رمزگذاری‌شده)
                                  |
                                  v
                         Runner بعدی: download -> verify -> decrypt -> restore
```

- GitHub-hosted job حداکثر ۶ ساعت عمر دارد. پیش‌فرض اجرای فعال Android برابر ۲۷۰ دقیقه (۴ ساعت و ۳۰ دقیقه) است تا برای نصب، بازیابی و ذخیره زمان باقی بماند. تغییر آن به ۳۰۰ دقیقه ممکن است در صورت کندی دانلود/آپلود باعث timeout و از دست رفتن Snapshot جدید شود.
- `concurrency` جلوی اجرای هم‌زمان دو نمونه از این Workflow را می‌گیرد، اما شروع Runner بعدی بلافاصله تضمین نمی‌شود.
- GitHub Releases برای هر فایل حداکثر کمتر از ۲ GiB مجاز می‌داند؛ قطعات ۱۸۰۰ MiB هستند. تعداد قطعات نباید از ۹۹۹ بیشتر شود.
- رمزگذاری فقط محرمانگی و صحت رمزنگاری Snapshot را تأمین می‌کند؛ اگر کلید را گم کنید، داده قابل بازیابی نیست. کلید را در Password Manager امن نگه دارید و در Repository قرار ندهید.
- دو Release آخر نگه داشته می‌شوند. این رفتار عمداً امن‌تر از حذف نسخه قبلی بلافاصله بعد از ذخیره است.
- این پروژه کل وضعیت سخت‌افزار مجازی، Quick Boot، کلیدهای وابسته به سخت‌افزار یا تضمین سازگاری تمام اپ‌ها را ذخیره نمی‌کند. تمرکز روی userdata و فایل‌های SD است.
- Android Emulator یک دستگاه مجازی x86_64 است؛ One UI سامسونگ نیست. نصب One UI رسمی روی این Emulator پشتیبانی‌شده و قابل اتکا نیست.
- Cloudflare Quick Tunnel یک URL موقت می‌دهد. URL با هر Runner تغییر می‌کند. مسیر دسترسی با Basic Auth محافظت می‌شود؛ رمز عبور قوی و غیرتکراری انتخاب کنید.
- ترمینال وب فقط دستورهایی را می‌پذیرد که با `adb` شروع شوند؛ اما `adb shell` دسترسی مدیریتی داخل Android می‌دهد. هیچ‌گاه URL و رمز دسترسی را عمومی نکنید.

## راه‌اندازی

### ۱) ساخت Repository عمومی

یک Repository عمومی جدید در GitHub بسازید، ZIP پروژه را Extract کنید و تمام محتویات فولدر را در ریشه Repository قرار دهید. سپس Commit و Push کنید. مسیر Workflow باید دقیقاً این باشد:

```text
.github/workflows/android.yml
```

در Repository به مسیر **Settings → Actions → General → Workflow permissions** بروید. فایل Workflow مجوزهای `contents: write` و `actions: write` را درخواست می‌کند؛ اگر سیاست سازمانی اجازه ندهد، اجرای زنجیره‌ای یا انتشار Release شکست می‌خورد.

### ۲) ساخت کلید رمزگذاری

روی Linux/macOS یا Git Bash اجرا کنید:

```bash
bash scripts/generate-key.sh
```

خروجی یک کلید ۶۴ کاراکتری Hex است. آن را در مکانی امن ذخیره کنید.

### ۳) تعریف Repository Secrets

از مسیر **Settings → Secrets and variables → Actions → New repository secret** سه Secret زیر را اضافه کنید:

| نام Secret | مقدار |
|---|---|
| `STATE_ENCRYPTION_KEY` | خروجی `generate-key.sh`، دقیقاً ۶۴ کاراکتر Hex |
| `WEB_ACCESS_USER` | نام کاربری دلخواه، مثلاً `cloudandroid` |
| `WEB_ACCESS_PASSWORD` | رمز تصادفی قوی با حداقل ۱۶ کاراکتر |

از کلید رمزگذاری در جای دیگری استفاده نکنید و آن را در فایل یا Commit قرار ندهید.

### ۴) اجرای اولیه

به **Actions → Cloud Android 17 → Run workflow** بروید و `continuous` را روی `true` بگذارید. اولین اجرا حافظه خالی می‌سازد؛ اجراهای بعدی Snapshot آخر را بازیابی می‌کنند.

پس از Boot، لینک Quick Tunnel در **Summary** همان Job و در Log مرحله دسترسی نمایش داده می‌شود. آن را در مرورگر باز کنید و با `WEB_ACCESS_USER` و `WEB_ACCESS_PASSWORD` وارد شوید.

- صفحه اصلی: محیط تصویری noVNC.
- مسیر `/terminal/`: ترمینال ADB. مثال‌ها:

```text
adb devices
adb shell
adb install /sdcard/Download/app.apk
adb logcat
```

برای نصب APK می‌توانید آن را از داخل مرورگر Android دانلود کنید و سپس از مسیر درست فایل در `adb install` استفاده کنید. ترمینال میزبان فایل دلخواه را مستقیماً آپلود نمی‌کند.

### ۵) توقف زنجیره

برای توقف اجرای خودکار بعدی، در اجرای دستی بعدی `continuous` را `false` انتخاب کنید. اجرای در حال انجام به‌طور خودکار قطع نمی‌شود؛ در صورت نیاز از Actions آن را Cancel کنید. Cancel اجباری ممکن است فرصت ذخیره Snapshot را از بین ببرد.

## بازیابی و امنیت

- Releaseها در Repository عمومی قابل مشاهده و دانلود هستند، اما محتوای Snapshot با AES-256-GCM رمزگذاری شده است.
- نام فایل‌ها و `manifest.json` اطلاعات غیرمحرمانه‌اند؛ هیچ داده خام کاربر نباید خارج از فایل رمزگذاری‌شده قرار گیرد.
- اگر کلید اشتباه باشد یا فایل دستکاری شده باشد، احراز اصالت GCM شکست می‌خورد و Restore متوقف می‌شود.
- Workflow فقط پس از ذخیره و بررسی تعداد Assetهای Release جدید، Releaseهای قدیمی‌تر از دو نسخه آخر را حذف می‌کند.
- اگر اجرای Job قبل از مرحله ذخیره به‌صورت اجباری قطع شود، Snapshot آخرین Release سالم باقی می‌ماند؛ تغییرات پس از آن از دست می‌روند.

## عیب‌یابی اولیه

1. **`yes: standard output: Broken pipe` هنگام پذیرش لایسنس‌ها:** این خطا از بسته‌شدن زودهنگام stdin توسط `sdkmanager` می‌آید؛ نسخه اصلاح‌شده Workflow خروجی مرحله دوم Pipeline را جداگانه بررسی می‌کند و SIGPIPE دستور `yes` را شکست Job حساب نمی‌کند. هشدار deprecated بودن `sdkmanager` به‌تنهایی خطا نیست.
2. **`userdata-qemu.img is missing or empty`:** معمولاً یعنی Emulator هنوز با موفقیت Boot نشده است. نسخه اصلاح‌شده فقط پس از مشاهده `sys.boot_completed=1` فایل marker می‌سازد و اگر Boot انجام نشده باشد، مرحله Save را بدون انتشار Snapshot رد می‌کند؛ در نتیجه خطای ذخیره‌سازی دیگر خطای اصلی را پنهان نمی‌کند.
3. **`/dev/kvm` unavailable:** شتاب‌دهی سخت‌افزاری در Runner در دسترس نیست؛ اجرای Emulator ممکن است بسیار کند یا ناموفق باشد.
4. **System image not found:** بررسی کن `system-images;android-37.1;google_apis_playstore_ps16k;x86_64` در SDK Manager موجود باشد. در صورت تغییر نام بسته، مقدار `SYSTEM_IMAGE` در Workflow و `create-avd.sh` را هماهنگ تغییر بده.
5. **Release upload failed:** مجوز `contents: write`، فضای دیسک Runner و تعداد/اندازه قطعات را بررسی کن.
6. **Next run not queued:** مجوز `actions: write` و وضعیت concurrency را بررسی کن.
7. **Quick Tunnel URL not printed:** Log فایل `/tmp/cloud-android-cloudflared.log` را در همان Job بررسی کن.
8. **Snapshot restore failed:** Release قبلی را حذف نکن؛ کلید، `manifest.json` و SHA-256 را بررسی کن.

## مجوز

MIT. Android، GitHub و Cloudflare علائم تجاری متعلق به صاحبان مربوطه هستند. این پروژه رسمی یا مورد تأیید آن‌ها نیست.

### خطای `Unknown AVD name` یا نبودن `cloud-android.ini`

این خطا یعنی Emulator فایل metadata مربوط به AVD را در مسیر `ANDROID_AVD_HOME` پیدا نکرده است. نسخه v4 مسیر `ANDROID_AVD_HOME` را در ساخت، بازیابی، اجرا و ذخیره‌سازی یکسان می‌کند؛ بعد از ساخت نیز وجود فایل `.ini` و شناسایی نام AVD را قبل از اجرای Emulator بررسی می‌کند. اگر metadata ساخته نشود، Job همان مرحله با گزارش فهرست AVDها متوقف می‌شود و دیگر ۱۸۰ ثانیه منتظر ADB نمی‌ماند.
