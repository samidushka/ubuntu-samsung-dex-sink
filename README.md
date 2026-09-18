# Linux Samsung DeX sink (Miracast)

Turn a Linux laptop into a **wireless Samsung DeX / Smart View receiver**, the same way a phone connects to a TV. The laptop is a **Miracast sink**, not a screen sender.

Русский текст ниже. English: this repo is wrappers + a small [miraclecast](https://github.com/albfan/miraclecast) patch so a Galaxy phone can pick the laptop in DeX → “TV or monitor”.

---

## Что это

Samsung беспроводной DeX на телевизор идёт по **Miracast (Wi‑Fi Direct)**. Ноутбук должен быть **приёмником** (`miracle-sinkctl`), а не «отправителем экрана» (GNOME Network Displays для этой задачи не подходит).

После запуска ноут появляется в списке ТВ на телефоне. На экране ноутбука открывается окно **DeX (Miracast)** — картинка с телефона. Мышь и клавиатура работают **внутри этого окна** (UIBC; запасной путь — USB-отладка / `adb`).

## Проверено на

- **Ноутбук:** Ubuntu 26.04, Intel Wi‑Fi с поддержкой P2P (`P2P-device` / `P2P-GO`). Ethernet и Wi‑Fi могут быть включены вместе: кабель оставляет интернет, Wi‑Fi уходит в P2P.
- **Телефон:** Samsung Galaxy S25 Ultra (SM-S938B), One UI / Android 16. Режимы Smart View и Samsung DeX «на ТВ или мониторе».

Другие чипы и прошивки могут отличаться. Карта Wi‑Fi **без P2P** этот сценарий не поднимет.

## Установка

На ноутбуке, в **локальном** терминале (нужен интерактивный `sudo`):

```bash
git clone https://github.com/samidushka/linux-samsung-dex-sink.git
cd linux-samsung-dex-sink
chmod +x scripts/*.sh scripts/*.py
./scripts/dex-tv-like-install.sh
```

Скрипт:

1. Ставит зависимости (GStreamer, GTK, wpa_supplicant, cmake…).
2. Собирает [miraclecast](https://github.com/albfan/miraclecast) в `~/src/miraclecast` (CMake ≥ 3.16 — нужно на Ubuntu 26.04 / CMake 4).
3. Накладывает патч `patches/miraclecast-samsung-invitation.patch` (Samsung шлёт `P2P-INVITATION`, апстрим это игнорирует; плюс bind пира на `AP-STA-CONNECTED`).
4. Кладёт ярлыки в меню приложений и ссылки в `~/.local/bin`.

## Запуск после перезагрузки

Это **сессионный** сценарий, не systemd. После reboot:

1. Разблокируйте сеанс. Ethernet можно не выдёргивать. Wi‑Fi должен быть **включён** (радио); к точке доступа подключаться не обязательно.
2. Меню приложений → **«DeX как ТВ (приёмник)»**, либо `~/.local/bin/dex-sink-run-now`.
3. В выводе должно быть `Managed=true`, `P2PScanning=true` и имя вроде `hostname-DeX`.
4. На телефоне: DeX → **«на ТВ или мониторе»** (не дублирование экрана, если нужен стол DeX) → выбрать ноут → **Начать**.
5. Стоп: Ctrl+C в терминале или ярлык **«DeX стоп»** / `dex-tv-like-stop`.

Имя в эфире: `DEX_FRIENDLY_NAME=MyLaptop-DeX`.

`--lazy-managed`: сначала `set-managed <N> yes`, потом `run <N>` — иначе `run` молча ничего не делает. `dex-sink-run-now` делает это сам.

## Мышь и клавиатура в окне

Кликайте и печатайте **в окне «DeX (Miracast)»**, не в служебном 1×1.

- ЛКМ — тап / свайп
- Средняя кнопка — «домой»
- ПКМ — «назад»

Приёмник стартует как `miracle-sinkctl --uibc`. Если телефон открыл порт UIBC, события идут через `miracle-uibcctl`. Если нет — плеер может продублировать ввод через `adb input` (нужна USB-отладка; серийник не зашит, берётся `DEX_ADB_SERIAL` или первый `adb devices`).

Плеер: GTK `gtksink` (`scripts/dex-gst-player.py`), не scrcpy. Картинка — RTP MPEG-TS на **UDP 7236**.

## Важные детали

| Тема | Зачем |
|---|---|
| `miracle-wifid --go-intent 0` | Телефон — GO. Высокий intent на ноуте ломает DHCP/RTSP. |
| `dex-p2p-join-on-invite.sh` | Samsung шлёт invitation; helper делает `p2p_connect … pbc join`. |
| Патч invitation | То же в `miracle-wifid`, плюс bind на `AP-STA-CONNECTED` без ifname. |
| UFW | Разрешить **UDP 7236** и типичную P2P-подсеть **192.168.49.0/24** (это Wi‑Fi Direct, не ваша LAN). Иначе PLAYING без кадров. |
| Ethernet | NetworkManager для кабеля **не** останавливаем. Unmanaged только Wi‑Fi. |
| X11 auth | Плеер берёт `XAUTHORITY` сеанса (Mutter/XWayland), иначе окно не мапится. |
| Одна LAN с телефоном | Нужна для обычного интернета/ADB. **Сам DeX «как к ТВ» по Ethernet не ходит** — только Wi‑Fi Direct. |

## Ограничения

- Нужен Wi‑Fi с P2P. Не все USB-свистки умеют.
- После reboot sink сам не поднимается.
- Качество/задержка — как у Miracast, не как у кабеля.
- UIBC зависит от телефона; без него нужен ADB.
- Это не официальный Samsung DeX for PC (на новых One UI беспроводной путь к ТВ — Miracast).

## Состав репозитория

```
scripts/     установка, старт/стоп, P2P join, GTK-плеер, GUI
patches/     miraclecast-samsung-invitation.patch
applications/  ярлыки GNOME (пути подставляет install)
```

Апстрим miraclecast **не** копируется. Лицензия скриптов — MIT; патч — как у miraclecast (LGPL-2.1+), см. `NOTICE`.

## English (short)

Linux laptop as a Samsung wireless DeX / Smart View **Miracast sink** (like a TV). Requires P2P Wi‑Fi. Ethernet may stay connected. Install with `./scripts/dex-tv-like-install.sh`, then `dex-sink-run-now` after each reboot. On the phone: DeX → TV or monitor → this laptop. Click inside the **DeX (Miracast)** window for mouse/keyboard (UIBC; optional ADB fallback). Tested on Ubuntu 26.04 + Galaxy S25 Ultra (SM-S938B, One UI / Android 16).
