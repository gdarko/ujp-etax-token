# Безбедност и лиценцирање

[← README](../README.md)

## Ризици

Ова поставување користи застарен прелистувач. Ограничете ја неговата употреба на страницата на УЈП.

- Firefox 52 нема безбедносни закрпи од 2018 година. Не отворајте други страници во него и не поставувајте го како стандарден прелистувач.
- Современите прелистувачи не можат да го вчитаат Java-приклучокот. За е-Даноци користете го само Firefox во `C:\FF52`.
- Промената во `java.security` овозможува прифаќање стари SHA-1 потписи во таа JRE. Таа Java-инсталација користете ја само за овој аплет.
- Java policy дозволата му дава `AllPermission` на кодот од `https://etax-fl.ujp.gov.mk/`. Ако страницата биде компромитирана, нејзиниот код би можел да се извршува без ограничувањата што вообичаено ги наметнува Java sandbox-от.
- Не отворајте `.jar` или `.jnlp` датотеки од други извори, бидејќи Java Web Start може да ги изврши.
- Watchdog-от работи како SYSTEM. Неговата папка `C:\ProgramData\EDanoci` е заштитена, па обичен корисник не може да ја измени скриптата што се извршува.
- За поголема изолација, поставете ја целата околина во Hyper-V виртуелна машина со Windows и пренасочете ја смарт-картичката преку Enhanced Session.

## Лиценцирање

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

Задржете го SAC, бидејќи токенот може да се користи и за други услуги на KIBSTrust. Измените на токенот од `Fix-TokenIds.ps1` не пречат на другите услуги. Ако е потребно, вратете ги со `.\Fix-TokenIds.ps1 undo`.

## Извори

[KIBSTrust — софтвер и драјвери](https://www.kibstrust.mk/mk-MK/softver-drajveri), [рачно преземање Java](https://www.java.com/en/download/manual.jsp), [архива на изданија на Mozilla](https://ftp.mozilla.org/pub/firefox/releases/52.9.0esr/).
