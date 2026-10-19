# Што менуваат скриптите

[← README](../README.md)

Во табелата се наведени измените што ги прават `Install-EDanoci.ps1` и `Repair-EDanoci.ps1`, по редослед на инсталација, и причината за секоја од нив. Направете ги рачно само ако скриптите не може да се извршат.

| Компонента | Локација | Причина |
| --- | --- | --- |
| SafeNet Authentication Client 10.9-R1 x64 ([KIBSTrust](https://www.kibstrust.mk/mk-MK/softver-drajveri)) | `Program Files\SafeNet` | Го инсталира драјверот за токенот. Пакетот ги содржи 32-битните библиотеки `eTPKCS11.dll` и `SAC\x32\IDPrimePKCS11.dll`. |
| IDGo 800 PKCS#11 библиотека | `Program Files (x86)\Gemalto\IDGo 800 PKCS#11` | Го обезбедува 32-битниот `IDPrimePKCS11.dll` што му е потребен на аплетот. |
| Oracle Java 8, 32-битна, најнова верзија | `Program Files (x86)\Java\jre1.8.0_xxx` | Ја обезбедува последната Java верзија со приклучок за прелистувач. Автоматското ажурирање е исклучено, бидејќи секое ажурирање инсталира нова JRE со неприлагодена `java.security`. |
| Java Update политика | `HKLM\SOFTWARE\WOW6432Node\JavaSoft\Java Update\Policy` | `EnableJavaUpdate=0` и отстранет `jusched.exe` од автоматското стартување. |
| Firefox 52.9.0 ESR, 32-битен | `C:\FF52` | Ја обезбедува последната верзија на Firefox со NPAPI-поддршка. `updater.exe` и maintenance service се отстранети. |
| `autoconfig.js` + `mozilla.cfg` | `C:\FF52\defaults\pref`, `C:\FF52` | Ги блокира ажурирањата за сите профили, ја исклучува blocklist-листата на Mozilla за да не може далечински да го блокира Java-приклучокот, го држи Java-приклучокот секогаш вклучен (`plugin.state.java=2`), му дозволува на Firefox да им верува на Windows CA-сертификатите и ја исклучува телеметријата. |
| `java.security` | `lib\security` во секоја JRE | Ги поставува `jdk.jar.disabledAlgorithms=MD2` и `jdk.certpath.disabledAlgorithms=MD2, RSA keySize < 1024, DSA keySize < 1024`. Оригиналната датотека се зачувува како `java.security.orig`. |
| `gclib.dll` | `C:\Program Files\Gemalto\Classic Client\BIN` | Ја копира 32-битната `IDPrimePKCS11.dll` на патеката што ја очекува `Signer.jar`. Претходната датотека се зачувува како `gclib.dll.bak-<timestamp>`. |
| Java deployment поставки | `%USERPROFILE%\AppData\LocalLow\Sun\Java\Deployment` | Го поставува безбедносното ниво на HIGH, го исклучува предупредувањето за застарена Java, го додава URL-то на е-Даноци во `exception.sites` и го чисти Java кешот по секоја поправка. |
| Java policy дозвола | `%USERPROFILE%\.java.policy` и `Deployment\security\java.policy` | Дава `AllPermission` само за `https://etax-fl.ujp.gov.mk/-`. Дозволата се додава ако ја нема, а постоечките дозволи во датотеката се задржуваат. |
| Услуга Smart Card (`SCardSvr`) | Services | Ја поставува услугата на Automatic и ја стартува. |
| Firefox профил `edanoci` и кратенка | `%APPDATA%\Mozilla\Firefox`, Desktop | Создава посебен профил што се отвора со `-no-remote`. |
| Watchdog: закажана задача `e-Danoci watchdog` | Task Scheduler, `C:\ProgramData\EDanoci` | Ја извршува `Repair-EDanoci.ps1` како SYSTEM при секое стартување и секој ден во 07:30. Само SYSTEM и администраторите можат да ја менуваат скриптата во таа папка. |

`Fix-TokenIds.ps1` не го менува системот, туку токенот: на CA-сертификатите им дава посебна ознака и ID. Видете [Токен: „Потписот не е ваш“](troubleshooting.md#токен-потписот-не-е-ваш).
