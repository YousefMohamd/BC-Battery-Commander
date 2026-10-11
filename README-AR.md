# BattOpt Control Center — دليل عربي

مركز تحكم في البطارية من شريط القوائم على macOS 10.15+.
طبقة أتمتة فوق أداة `battopt`، مدمجة مع SwiftBar، مع 7 طبقات حماية.

---

## ما الذي تفعله الأداة

- **حد الشحن** — إيقاف الشحن عند 80-85% لإطالة عمر البطارية.
- **وضع الإبحار (Sailing)** — تقلب بين الحد الأدنى والأعلى.
- **أوضاع النوم** — Normal / Presentation / Long Tasks / Travel.
- **أوضاع الطاقة** — Fast Sleep / Balanced / Always Awake / Deep Only.
- **التفريغ الذكي** — تفريغ البطارية إلى نسبة محددة.
- **المعايرة** — دورة كاملة دورية لضبط قراءة النسبة.
- **وضع الغطاء المغلق** — التحكم في عمل الجهاز والغطاء مغلق.
- **التنظيف الآلي** — إيقاف Spotlight وPhotos وTime Machine عند الخمول.
- **تنبيهات استباقية** — الحرارة، الصحة، البطارية المنخفضة.
- **تقرير النوم والبطارية** — ملخص يومي لأسباب الاستيقاظ ومعدل الاستهلاك.

---

## المتطلبات

- macOS 10.15 Catalina أو أحدث (مُختبر على MacBookPro9,1).
- SwiftBar 1.4 أو أحدث.
- أداة `battopt` (تُثبّت بشكل منفصل).
- `terminal-notifier` (مُرفق مع المشروع).

### تنصيب battopt

اتّبع التعليمات من: <https://battopt.buddha-path.top>.

الأداة تُثبّت على المسار:

    /Library/Application Support/battopt/battopt

للتحقق:

    sudo battopt status

---

## التنصيب

من ملف DMG:

1. افتح `BattOpt-Installer.dmg`.
2. اسحب `BattOpt.app` إلى `/Applications`.
3. شغّل `install.sh`:

       sudo bash /Volumes/BattOpt/install.sh

---

## الاستخدام

اضغط على أيقونة البطارية في شريط القوائم. القائمة منظّمة كالتالي:

- **الرأس** — النسبة، الوضع، الصحة، الحرارة، أيام التجربة.
- **أفعال سريعة** — قائمة Power Mode وقائمة Sleep Mode.
- **حدود الشحن** — تخصيص الحد الأعلى/الأدنى، تشغيل الإبحار، حجم الفرق.
- **العناية بالبطارية** — المعايرة، Clamshell، الجدولة.
- **موارد النظام** — CPU و RAM لـ SwiftBar والـ daemon.
- **إيقاف** — إغلاق نظيف مع إمكانية الاستعادة.

---

## المعمارية

    SwiftBar (واجهة شريط القوائم)
        │
        ▼
    battopt.30s.sh  ──► dispatch.sh  ──►  30 سكربتاً مساعداً
        │                  │
        │                  └──► battopt binary (SMC مباشرة)
        │
        └──► ملفات الحالة (~/.battopt-swiftbar/)

    powerwatch (ثنائي C، يعمل كـ root)
        └──► سكربتات النوم/الاستيقاظ

    launchd — يشغّل السكربتات المجدولة كل 1-60 دقيقة.

أداة `battopt` **طرف ثالث** تتحكم بمفاتيح SMC مباشرة. المشروع يلتف حولها
ولا يستبدلها.

---

## طبقات الحماية السبع

1. **التحقق من المدخلات والحفظ** — كل إدخال يُحفظ في `.last_inputs`.
2. **الإيقاف الطارئ والتدقيق** — `emergency-stop.sh` + `.audit.log`.
3. **الاسترجاع التلقائي** — `ensure_limit.sh` كل 10 دقائق.
4. **نسخ احتياطية صارمة** — كل تعديل يسبقه نسخة موقّعة زمنياً.
5. **ديمون الاستشفاء الذاتي** — `self_healing.sh` كل 5 دقائق.
6. **نبض Guardian** — `guardian.sh` يسجّل الحالة كل دقيقتين.
7. **مدقّق الإعدادات** — يتحقق من ملفات الحالة ويصلح الأعطال الآمنة.

---

## ملفات الإعداد

كل حالة الأداة في `~/.battopt-swiftbar/`.

| الملف | الوظيفة |
|-------|---------|
| `config` | القيم المعروضة للمستخدم |
| `.sleep_mode` | `default` / `presentation` / `download` / `travel` |
| `.current_power_mode` | `fast` / `balanced` / `awake` / `deep` / `custom` |
| `.last_inputs` | آخر مدخلات الحوارات |
| `.status_cache` | تخزين مؤقت (TTL 10s) |
| `actions.log` | كل أفعال المستخدم |
| `.healing.log` | تدخّلات الاستشفاء الذاتي |
| `.guardian.log` | نبض Guardian |

---

## حل المشكلات

### القائمة تعرض نسبة قديمة

    rm -f ~/.battopt-swiftbar/.status_cache

### "Charge limit is suspended"

    sudo battopt limit 85 80

### اختفت إضافة SwiftBar

    ~/.battopt-swiftbar/launch_swiftbar.sh

أو افتح `BattOpt.app` من `/Applications`.

### powerwatch لا يعمل

    sudo launchctl list | grep powerwatch
    sudo launchctl load -w /Library/LaunchDaemons/com.battopt.powerwatch.plist

---

## إزالة التنصيب

    sudo bash /Applications/BattOpt.app/Contents/Resources/uninstall.sh

أو يدوياً:

    sudo launchctl unload /Library/LaunchDaemons/com.battopt.powerwatch.plist
    sudo launchctl unload /Library/LaunchDaemons/com.buddha-path.BattOpt.daemon.plist
    for p in ~/Library/LaunchAgents/com.battopt.*.plist; do launchctl unload "$p"; done
    rm -rf ~/.battopt-swiftbar
    rm -f ~/SwiftBar/battopt.30s.sh
    sudo rm -f /etc/sudoers.d/battopt-nopasswd
    rm -rf /Applications/BattOpt.app

---

## الترخيص

- **السكربتات والإضافة**: MIT.
- **battopt binary**: طرف ثالث، مملوك، غير موزّع هنا.
- **SwiftBar**: MIT، مشروع منفصل.
- **terminal-notifier**: MIT، مُرفق كتطبيق مستقل.

---

## الإصدار

الحالي: **v1.3.0**
تاريخ الإصدار: 2026-10-11
الجهاز المُختبر: MacBookPro9,1 (MacBook Pro 15-inch mid-2012)
macOS المُختبر: 10.15.8 (Catalina, Build 19H2036)
