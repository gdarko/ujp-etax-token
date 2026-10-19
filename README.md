# УЈП е-Даноци: поставување на околината за потпишување

15 октомври 2026 · @Darko

## Преглед

Стариот систем е-Даноци на УЈП ([etax-fl.ujp.gov.mk](https://etax-fl.ujp.gov.mk)) ги потпишува пријавите со Java аплет. За да може да се поднесуваат пријави од Windows 11, потребна е посебна, застарена софтверска околина. Скриптата `Install-EDanoci.ps1` ја поставува целата околина, а `Repair-EDanoci.ps1` ја проверува и поправа секој ден. Во ова упатство се објаснети инсталацијата, нејзините измени и решавањето проблеми.

За потпишувањето да работи, потребни се сите овие компоненти:

1. **Firefox 52.9.0 ESR, 32-битна верзија.** Ова е последната верзија на Firefox што го поддржува NPAPI-приклучокот за Java. Поновите верзии не се компатибилни со него, па автоматските ажурирања се отстранети и блокирани.
2. **Java 8, 32-битна верзија.** Java 9 и поновите верзии немаат приклучок за прелистувач. Освен тоа, 32-битниот Firefox не може да користи 64-битна Java.
3. **УЈП `Signer.jar`.** Датотеката е потпишана со SHA-1 сертификатски синџир што води до стар root-сертификат на thawte. Тековните изданија на Java 8 го одбиваат потписот, а sandbox-от го блокира пристапот до токенот (`accessClassInPackage.sun.security.pkcs11`). Скриптата ги приспособува поставките `jdk.jar.disabledAlgorithms` и `jdk.certpath.disabledAlgorithms` за аплетот да може да се изврши.
4. **PKCS#11 библиотека на очекуваната патека.** Аплетот секогаш ја вчитува `C:\Program Files\Gemalto\Classic Client\BIN\gclib.dll`. Таму мора да има **32-битна** библиотека што препознава **IDPrime** токени. Затоа, 32-битната `IDPrimePKCS11.dll` од Gemalto IDGo 800 се копира на таа патека и се преименува во `gclib.dll`.
5. **KIBSTrust IDPrime токен.** За него се користат SafeNet Authentication Client 10.9-R1 и услугата Smart Card.

## Барања

- 64-битен Windows 10 или Windows 11 и администраторски права.
- KIBSTrust сертификат на Gemalto/Thales **IDPrime** токен. Во SAC, во Token Info треба да се прикажува верзија на аплетот 4.x и „ID Prime“. Постарите SafeNet 5110 eToken токени би требало да работат преку SAC, но поставувањето е проверено со IDPrime.
- Интернет-пристап до kibstrust.mk, java.com, javadl.oracle.com и ftp.mozilla.org.
- Околу 400 MB слободен простор и 10 минути.
- Најавете се како Windows-корисникот што ќе поднесува пријави. Поставките за Java и Firefox се зачувуваат во профилот на корисникот што ја извршува скриптата.

## Автоматска инсталација

Извршете ја `Install-EDanoci.ps1` еднаш со администраторски права за да ги инсталирате и конфигурирате потребните компоненти. Скриптата може безбедно да се изврши повторно: ги прескокнува веќе инсталираните компоненти и повторно ја применува конфигурацијата, па може да послужи и за поправка.

1. Зачувајте ги датотеките од репозиториумот (`Install-EDanoci.ps1`, `Repair-EDanoci.ps1`, `Fix-TokenIds.ps1`, `Fix-TokenIds.js`) во иста папка на компјутерот, на пример во `C:\Tools`. Со Git: `git clone https://github.com/gdarko/ujp-etax-token.git C:\Tools`.
2. Кликнете со десното копче на Start и отворете **Terminal (Admin)** или **Windows PowerShell (Admin)**.
3. Извршете ги командите:

```powershell
cd C:\Tools
Set-ExecutionPolicy -Scope Process Bypass -Force
Unblock-File .\Install-EDanoci.ps1, .\Repair-EDanoci.ps1, .\Fix-TokenIds.ps1
.\Install-EDanoci.ps1
```

4. На крајот проверете ја табелата **Verification**. Секој ред треба да има статус `OK`.
5. Ако скриптата побара рестартирање, рестартирајте го компјутерот пред првото поднесување.

Опционални параметри:

| Параметар | Што прави |
| --- | --- |
| `-EnableJavaDebug` | Ги вклучува следењето и логирањето на Java, како и Java конзолата. Користете го при проблеми со потпишувањето. |
| `-Force` | Повторно ги инсталира компонентите, вклучително и Firefox 52 во `C:\FF52`. |
| `-InstallDir` | Ја задава папката за Firefox. Стандардно е `C:\FF52`. |

Преземените датотеки и логовите се зачувуваат во `%TEMP%\edanoci-setup`. Таму се наоѓа `install.log`, како и посебна `.msi.log` датотека за секој MSI-инсталатор.

## Секојдневна употреба

Е-Даноци секогаш отворајте го преку кратенката **e-Danoci (Firefox 52)** на работната површина. Таа ја извршува командата `C:\FF52\firefox.exe -no-remote -P edanoci https://etax-fl.ujp.gov.mk` и отвора посебен профил. Тој профил може да работи истовремено со вашиот вообичаен прелистувач.

1. Приклучете го токенот пред да ја отворите кратенката.
2. Најавете се, отворете го образецот и изберете ја опцијата за потпишување.
3. При првото потпишување, Java ќе праша дали да го изврши аплетот на УЈП и може да прикаже предупредување за стар или истечен сертификат. Означете го полето за прифаќање и кликнете **Run**. Firefox не прашува за Java-приклучокот, бидејќи е секогаш вклучен.
4. Во прозорецот за потпишување изберете го вашиот сертификат, внесете го PIN-кодот на токенот и потпишете.

Користете го овој прелистувач само за е-Даноци. Другите услуги на УЈП, како е-УЈП на [e-ujp.ujp.gov.mk](https://e-ujp.ujp.gov.mk), работат во современ прелистувач.

## Што менува скриптата

Во табелата се наведени измените што ги прави скриптата, по редослед на инсталација, и причината за секоја од нив. Направете ги рачно само ако скриптата не може да се изврши.

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

## Одржување

Закажаната задача `e-Danoci watchdog` ја извршува `Repair-EDanoci.ps1` при секое стартување и секој ден. Таа ги проверува `gclib.dll`, `java.security` во секоја 32-битна JRE, заклучувањето на Firefox, исклученото ажурирање на Java, услугата Smart Card и Java-поставките на корисникот, и го поправа она што е изменето. Секое извршување се запишува во `C:\ProgramData\EDanoci\repair.log`.

Состојбата може да се провери или поправи и рачно, од административен PowerShell:

```powershell
& 'C:\ProgramData\EDanoci\Repair-EDanoci.ps1' -CheckOnly   # само проверка
& 'C:\ProgramData\EDanoci\Repair-EDanoci.ps1'              # проверка и поправка
Get-Content C:\ProgramData\EDanoci\repair.log -Tail 20
```

Во Task Scheduler, резултатот `0x1` значи дека нешто е поправено, а `0x2` дека проверката не успеала и е потребна интервенција.

| Настан | Што се менува | Решение |
| --- | --- | --- |
| Рачно ажурирање на Java 8 | Се создава нова папка `jre1.8.0_xxx` со неприлагодена датотека `java.security`. Потпишувањето може да откаже поради SHA-1 или sandbox-грешка. | Watchdog-от ја приспособува новата JRE при следното стартување. Веднаш: извршете ја `Repair-EDanoci.ps1`. |
| Повторна инсталација или поправка на SAC, Gemalto или Classic Client | `gclib.dll` може да биде заменета со 64-битна или стара библиотека од Classic Client 9. | Watchdog-от ја враќа 32-битната IDPrime-библиотека. Веднаш: извршете ја `Repair-EDanoci.ps1`. |
| Нов Windows-корисник | Поставките за Java и Firefox се зачувуваат по корисник. Watchdog-от ги одржува поставките само на корисникот што последен ја извршил инсталацијата. | Најавете се како тој корисник и извршете ја `Install-EDanoci.ps1`. |
| Firefox прикажува верзија различна од 52.9.0 | Папката `C:\FF52` е заменета или изменета. Watchdog-от ова го пријавува, но не може да го поправи. | Извршете ја `Install-EDanoci.ps1 -Force`. |
| Обновување на сертификатот или нов KIBSTrust токен | KIBSTrust може повторно да ги запише CA-сертификатите со истиот ID како клучот. Watchdog-от не го проверува токенот. | Приклучете го токенот и извршете `.\Fix-TokenIds.ps1 check`. Видете [Токен: „Потписот не е ваш“](#токен-потписот-не-е-ваш). |

Пред секој период за поднесување, отворете **Help > About** во Firefox за е-Даноци. Верзијата треба да биде **52.9.0**, а Firefox треба да прикажува дека ажурирањата се исклучени од администраторот.

Предупредувањето за истекување на Java (20 ноември 2026 за 8u503) е исклучено. Java не се ажурира автоматски.

## Решавање проблеми

При дијагностицирање, прво извршете `Repair-EDanoci.ps1 -CheckOnly` и прегледајте го `C:\ProgramData\EDanoci\repair.log`. Потоа соберете логови: извршете ја `Install-EDanoci.ps1` со `-EnableJavaDebug`, повторете го проблемот, па отворете ја најновата `.trace` или `.log` датотека во `%USERPROFILE%\AppData\LocalLow\Sun\Java\Deployment\log`. Во неа побарајте `Caused by`, `findTokens` или `gclib`.

Во табелата се наведени проблеми што се појавиле при поставувањето, по редоследот по кој биле забележани.

| Симптом или запис во логот | Причина | Решение |
| --- | --- | --- |
| Firefox се ажурирал при првото отворање | Ажурирањата биле исклучени само за еден профил или Firefox бил отворен пред да се заклучат поставките. | Скриптата го отстранува `updater.exe` и ги заклучува поставките пред првото отворање. Извршете ја повторно со `-Force`. |
| Нема Java-приклучок во `about:addons` | Инсталирана е 64-битна Java или верзијата на Firefox е понова од 52. | Инсталирајте 32-битна Java (`...-windows-i586.exe`). Проверете ја верзијата преку **Help > About**. |
| `Your browser is not Java enabled`, а Java е инсталирана | Деинсталирањето на друга Java 8 го избришало клучот `HKLM\SOFTWARE\WOW6432Node\MozillaPlugins\@java.com/JavaPlugin`, иако датотеките на JRE останале. Поправката преку MSI не успева (Error 1723). Редот `Java plugin registered` покажува `FAILED`. | Деинсталирајте ја и повторно инсталирајте ја истата 32-битна Java, па извршете ја `Repair-EDanoci.ps1`. Не деинсталирајте стари Java-верзии додека е-Даноци се користи. |
| `Error. Click for details` во прозорецот за потпишување, а конзолата прикажува само помош | Аплетот паднал пред да започне логирањето. | Извршете ја скриптата со `-EnableJavaDebug` и прегледајте ја лог-датотеката. |
| `The jar file isnt signed` + `access denied ... accessClassInPackage.sun.security.pkcs11` | Java го одбива алгоритмот со кој е потпишана датотеката и го ограничува аплетот во sandbox. | Повторно извршете ја скриптата за да ја примени поставката `jdk.jar.disabledAlgorithms`. |
| `denyAfter constraint check failed: SHA1 ... thawte Primary Root CA` | Сертификатскиот синџир за потпис користи SHA-1. | Повторно извршете ја скриптата за да ја примени поставката `jdk.certpath.disabledAlgorithms`. |
| `%1 is not a valid Win32 application` + `...Classic Client\BIN\gclib.dll` | 32-битната Java се обидува да вчита 64-битен `gclib.dll`. Најчесто по поправка или повторна инсталација на SAC. | Извршете ја `Repair-EDanoci.ps1`. Проверете дали редот `gclib.dll is 32-bit IDPrime` покажува `OK`. |
| Нема грешка, но сертификатот не се појавува во прозорецот за потпишување | `gclib.dll` е старата библиотека Classic Client 9.0, која не препознава IDPrime. | Користете ја 32-битната `IDPrimePKCS11.dll` како `gclib.dll`. Ако копијата од IDGo 800 не работи, обидете се со `C:\Program Files\SafeNet\Authentication\SAC\x32\IDPrimePKCS11.dll`. |
| Сертификатот се појавува и потпишувањето поминува, но УЈП одговара `Потписот не е ваш` | На токенот, CA-сертификатите на KIBSTrust имаат ист `CKA_LABEL`/`CKA_ID` како приватниот клуч, па аплетот прикачува CA-сертификат наместо вашиот. Во Java-логот, `x509Content` покажува `KIBSTrust Issuing Qsig CA G3`. | Извршете ја `Fix-TokenIds.ps1`. Видете [Токен: „Потписот не е ваш“](#токен-потписот-не-е-ваш). |
| `certutil -scinfo`: не може да најде читач на смарт-картички | Услугата Smart Card е запрена. | Извршете `Start-Service SCardSvr`, па извадете го и повторно приклучете го токенот. |
| 32-битниот SAC MSI одбива да се инсталира | Тоа е очекувано на 64-битен Windows. x64 SAC веќе ги содржи 32-битните библиотеки. | Користете ја само x64 верзијата на MSI. |
| Изгледа дека измените не се примениле | Стариот процес `jp2launcher.exe` сè уште работи. | Извршете `Stop-Process -Name jp2launcher, firefox -Force`, па повторно отворете го Firefox. |

Проверка на библиотеката што се користи:

```powershell
(Get-Item 'C:\Program Files\Gemalto\Classic Client\BIN\gclib.dll').VersionInfo | Format-List ProductName, FileVersion
```

`ProductName` треба да содржи IDPrime. Ако прикажува `PKCS#11 v2.01 - Multiplexer for Cryptoki API`, верзија 9.0, повторно е поставена старата библиотека Classic Client.

### Токен: „Потписот не е ваш“

Новите токени на KIBSTrust ги содржат и CA-сертификатите (Root CA G2, Issuing Qseal CA G3, Issuing Qsig CA G3), запишани со истата ознака и ID како приватниот клуч (на пример `342118`). Аплетот го поврзува клучот со сертификат преку ID, па зема CA-сертификат наместо личниот. УЈП го одбива потписот со пораката „Потписот не е ваш“. Windows и современите апликации проверуваат дали јавниот клуч се совпаѓа, па кај нив проблемот не се појавува.

`Fix-TokenIds.ps1` на CA-сертификатите им дава посебна ознака и ID (на пример `CA-18826C23`). Ништо не се брише, а личниот сертификат и клучот не се менуваат. Пред секоја измена се зачувува резервна копија во `%USERPROFILE%\Documents\KIBSTrust-token-fix\backup`: `backup.json` со оригиналните вредности и `.cer` копија од секој изменет сертификат.

Извршете ја во обичен PowerShell-прозорец, без администраторски права. Затворете го Firefox 52 и приклучете го само токенот на KIBSTrust.

```powershell
.\Fix-TokenIds.ps1 check   # приказ на токенот и планираната измена, без PIN
.\Fix-TokenIds.ps1 apply   # резервна копија, па измена (бара YES и PIN)
.\Fix-TokenIds.ps1 undo    # враќање на оригиналните вредности (бара YES и PIN)
```

PIN-кодот се внесува во прозорецот и не се прикажува. Погрешен PIN се брои во ограничувањето за заклучување на токенот, а скриптата предупредува ако остануваат малку обиди. По `apply`, извадете го и повторно приклучете го токенот, па потпишете повторно.

SafeNet Authentication Client што го дистрибуира KIBSTrust е End User изданието, без Advanced View, па сертификатите не може да се менуваат или бришат од SAC Tools.

## Безбедност и лиценцирање

Ова поставување користи застарен прелистувач. Ограничете ја неговата употреба на страницата на УЈП.

- Firefox 52 нема безбедносни закрпи од 2018 година. Не отворајте други страници во него и не поставувајте го како стандарден прелистувач.
- Современите прелистувачи не можат да го вчитаат Java-приклучокот. За е-Даноци користете го само Firefox во `C:\FF52`.
- Промената во `java.security` овозможува прифаќање стари SHA-1 потписи во таа JRE. Таа Java-инсталација користете ја само за овој аплет.
- Java policy дозволата му дава `AllPermission` на кодот од `https://etax-fl.ujp.gov.mk/`. Ако страницата биде компромитирана, нејзиниот код би можел да се извршува без ограничувањата што вообичаено ги наметнува Java sandbox-от.
- Не отворајте `.jar` или `.jnlp` датотеки од други извори, бидејќи Java Web Start може да ги изврши.
- За поголема изолација, поставете ја целата околина во Hyper-V виртуелна машина со Windows и пренасочете ја смарт-картичката преку Enhanced Session.

Java 8 изданијата понови од 8u202 се опфатени со [лиценцата Oracle Technology Network](https://www.java.com/otnlicense/), која дозволува бесплатна лична употреба. Поднесувањето пријави за фирма е деловна употреба и бара претплата за Java SE. Изданието 8u202 од архивата на Oracle е бесплатно, но не е ажурирано со безбедносни закрпи веќе неколку години.

## Отстранување на околината

Кога УЈП ќе го укине аплетот, отстранете ја оваа околина во административен PowerShell. Потоа, во **Settings > Apps**, деинсталирајте ја Java 8 ако не ја користи друга апликација.

```powershell
Unregister-ScheduledTask -TaskName 'e-Danoci watchdog' -Confirm:$false
Remove-Item C:\ProgramData\EDanoci -Recurse -Force
Stop-Process -Name jp2launcher, firefox -Force -ErrorAction SilentlyContinue
Remove-Item C:\FF52 -Recurse -Force
Remove-Item "$env:USERPROFILE\Desktop\e-Danoci (Firefox 52).lnk", "$env:USERPROFILE\.java.policy" -ErrorAction SilentlyContinue
Get-ChildItem 'C:\Program Files (x86)\Java' -Recurse -Filter java.security.orig |
  ForEach-Object { Copy-Item $_.FullName ($_.FullName -replace '\.orig$','') -Force }
$bin = 'C:\Program Files\Gemalto\Classic Client\BIN'
$bak = Get-ChildItem $bin -Filter 'gclib.dll.bak-*' | Sort-Object Name | Select-Object -First 1
if ($bak) { Copy-Item $bak.FullName "$bin\gclib.dll" -Force } else { Remove-Item "$bin\gclib.dll" }
```

Задржете го SAC, бидејќи токенот може да се користи и за други услуги на KIBSTrust.

Извори: [KIBSTrust — софтвер и драјвери](https://www.kibstrust.mk/mk-MK/softver-drajveri), [рачно преземање Java](https://www.java.com/en/download/manual.jsp), [архива на изданија на Mozilla](https://ftp.mozilla.org/pub/firefox/releases/52.9.0esr/).
