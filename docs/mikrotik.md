# Проброс портов на MikroTik (RouterOS)

Инструкция для случая, когда сервер Aspia стоит в локальной сети за роутером MikroTik. Подходит для RouterOS 6 и 7.

После настройки:
- консоли и хосты из интернета подключаются к серверу по внешнему IP роутера;
- устройства **внутри** сети тоже могут подключаться по внешнему IP (hairpin NAT). Одни и те же настройки консоли и хостов работают и дома, и снаружи;
- внешний IP может быть как статическим, так и динамическим (PPPoE, DHCP от провайдера).

> Нужен «белый» внешний IP. Если провайдер выдаёт серый адрес (CGNAT: адрес на WAN вида `10.x`, `100.64–100.127.x`, `172.16–31.x`, `192.168.x`), пробросить порты невозможно. Закажите у провайдера белый IP.

## Какие порты нужны

| Порт | Для чего |
|---|---|
| 8060/tcp | хосты Aspia 2.x |
| 8061/tcp | хосты Aspia 3.x |
| 8062/tcp | консоли |
| 8065/udp | STUN |
| 8070/tcp | relay |

Порт 8063 наружу не нужен.

## 1. Подставьте свои данные

| Переменная | Что указать | Где посмотреть |
|---|---|---|
| `server` | локальный IP сервера Aspia (NAS, ВМ) | на самом сервере или в `/ip dhcp-server lease print` |
| `lan` | локальная подсеть | `/ip address print`: адрес роутера `192.168.88.1/24` значит подсеть `192.168.88.0/24` |

У сервера должен быть **постоянный** локальный IP. Задайте его статически на сервере или закрепите в DHCP: `/ip dhcp-server lease make-static [find address=<IP сервера>]`.

## 2. Выполните скрипт

WinBox → **New Terminal** (или SSH на роутер). Поменяйте значения в первых двух строках и вставьте блок целиком, вместе с фигурными скобками:

```
{
:local server "192.168.88.10"
:local lan "192.168.88.0/24"

/ip firewall nat
add chain=dstnat dst-address-type=local protocol=tcp dst-port=8060-8062,8070 action=dst-nat to-addresses=$server comment="Aspia Server TCP"
add chain=dstnat dst-address-type=local protocol=udp dst-port=8065 action=dst-nat to-addresses=$server comment="Aspia Server STUN"
add chain=srcnat src-address=$lan dst-address=$server protocol=tcp dst-port=8060-8062,8070 action=masquerade comment="Aspia Server hairpin TCP"
add chain=srcnat src-address=$lan dst-address=$server protocol=udp dst-port=8065 action=masquerade comment="Aspia Server hairpin STUN"
}
```

Что делают правила:
- **`dstnat` с `dst-address-type=local`** перенаправляют на сервер подключения к любому адресу самого роутера на портах Aspia: снаружи на внешний IP и изнутри на тот же внешний IP. Внешний IP в правилах не указан, поэтому при его смене ничего не ломается.
- **`srcnat masquerade`** нужен для подключений изнутри сети по внешнему IP. Без него сервер ответит устройству напрямую, мимо роутера, и соединение не установится.

## 3. Брандмауэр

В **стандартной** конфигурации MikroTik (правила с комментариями `defconf`) ничего добавлять не нужно. Правило `defconf: drop all from WAN not DSTNATed` пропускает трафик, прошедший `dst-nat`.

Если брандмауэр настроен вручную и в цепочке `forward` в конце стоит общий `drop`, разрешите проброшенные соединения:

```
/ip firewall filter
add chain=forward connection-nat-state=dstnat action=accept comment="Allow port forwarding" place-before=0
```

## 4. Проверка

Когда подключаются консоли и хосты, счётчики пакетов (`Packets`, `Bytes`) растут:

```
/ip firewall nat print stats where comment~"Aspia Server"
```

Снаружи сети, например с телефона без Wi-Fi через мобильный интернет, можно проверить доступность порта консоли. Команда для Windows PowerShell на компьютере вне вашей сети:

```powershell
Test-NetConnection <внешний IP> -Port 8062
```

`TcpTestSucceeded : True` значит, что порт открыт.

## Изменение и удаление

Сервер переехал на другой IP:

```
{
:local server "192.168.88.20"
/ip firewall nat set [find where comment~"^Aspia Server" and chain=dstnat] to-addresses=$server
/ip firewall nat set [find where comment~"^Aspia Server" and chain=srcnat] dst-address=$server
}
```

Удалить все правила Aspia:

```
/ip firewall nat remove [find where comment~"^Aspia Server"]
```

## Если что-то не работает

| Симптом | Причина и решение |
|---|---|
| Счётчики правил `dstnat` не растут | Подключения не доходят до роутера: серый IP у провайдера, или выше стоит ещё один роутер (например, модем провайдера в режиме роутера). На нём тоже нужно пробросить порты или перевести его в режим моста |
| Снаружи работает, изнутри по внешнему IP — нет | Нет правил `srcnat` (hairpin) или в `lan` указана не та подсеть |
| Изнутри работает, снаружи — нет | Правило в `filter` блокирует `forward`, см. шаг 3 |
| Правило есть, но трафик уходит не туда | Выше в списке NAT стоит другое правило на те же порты: `/ip firewall nat print`. Поднимите правила Aspia выше, в WinBox перетаскиванием или командой `move` |
| Роутер сам использует один из этих портов | Проверьте `/ip service print`. Порты 8060–8070 по умолчанию роутером не заняты |

## Вариант с явным интерфейсом и статическим IP

Если вы предпочитаете классическую схему, где указаны WAN-интерфейс и внешний IP, она тоже работает, но только при статическом внешнем IP:

```
{
:local server "192.168.88.10"
:local lan "192.168.88.0/24"
:local wan "ether1"
:local publicip "203.0.113.10"

/ip firewall nat
add chain=dstnat in-interface=$wan protocol=tcp dst-port=8060-8062,8070 action=dst-nat to-addresses=$server comment="Aspia Server TCP"
add chain=dstnat in-interface=$wan protocol=udp dst-port=8065 action=dst-nat to-addresses=$server comment="Aspia Server STUN"
add chain=dstnat src-address=$lan dst-address=$publicip protocol=tcp dst-port=8060-8062,8070 action=dst-nat to-addresses=$server comment="Aspia Server hairpin TCP"
add chain=dstnat src-address=$lan dst-address=$publicip protocol=udp dst-port=8065 action=dst-nat to-addresses=$server comment="Aspia Server hairpin STUN"
add chain=srcnat src-address=$lan dst-address=$server protocol=tcp dst-port=8060-8062,8070 action=masquerade comment="Aspia Server hairpin TCP"
add chain=srcnat src-address=$lan dst-address=$server protocol=udp dst-port=8065 action=masquerade comment="Aspia Server hairpin STUN"
}
```

При PPPoE укажите в `wan` имя PPPoE-интерфейса, например `pppoe-out1`, а не физический порт.
