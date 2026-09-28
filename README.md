# Aspia Server в Docker

[![Publish images](https://github.com/SinitsaDA/aspia-server-docker/actions/workflows/publish.yml/badge.svg)](https://github.com/SinitsaDA/aspia-server-docker/actions/workflows/publish.yml)
[![Image](https://img.shields.io/badge/ghcr.io-aspia--server-blue?logo=docker)](https://github.com/SinitsaDA/aspia-server-docker/pkgs/container/aspia-server)

**Русский** | [English](README.en.md)

[Aspia](https://aspia.org) — система удалённого доступа с открытым исходным кодом. Этот проект запускает её серверную часть, **Router** и **Relay**, в одном Docker-контейнере и **сам держит её в актуальной версии**.

> Это неофициальный проект. Aspia разрабатывает [Дмитрий Чапышев](https://github.com/dchapyshev/aspia). Здесь только упаковка в Docker.

## Возможности

- **Router + Relay в одном контейнере.** Готовые образы для каждой версии Aspia лежат в `ghcr.io/sinitsada/aspia-server`.
- **Автообновление.** Контейнер `aspia-updater` каждую ночь проверяет релизы Aspia. Найдя новую версию, он:
  1. скачивает образ;
  2. делает бэкап данных;
  3. запускает новую версию;
  4. если она не заработала, **откатывается** на прежнюю.
- **Проверка здоровья.** Docker знает, что Router принимает подключения, а Relay подключён к Router: статус `healthy` или `unhealthy`.
- **Миграция с Aspia 2.x.** Конфигурация и база 2.x переносятся автоматически при первом запуске, в том числе с образа [`paprikkafox/aspia-server`](https://hub.docker.com/r/paprikkafox/aspia-server).
- **Проверенные образы.** GitHub Actions собирает образ в течение 6 часов после релиза Aspia. Перед публикацией каждый образ проверяется запуском. Раз в неделю образ пересобирается с обновлениями безопасности Debian.
- **Локальная сборка** — для тех, кто не хочет пользоваться готовыми образами.

## Содержание

- [Быстрый старт](#быстрый-старт)
- [Порты](#порты)
- [Настройки](#настройки)
- [Первый вход и ключ для хостов](#первый-вход-и-ключ-для-хостов)
- [Обновления](#обновления)
- [Переход с Aspia 2.x](#переход-с-aspia-2x)
- [Synology NAS](docs/synology.md)
- [Проброс портов на MikroTik](docs/mikrotik.md)
- [Бэкапы и восстановление](#бэкапы-и-восстановление)
- [Локальная сборка](#локальная-сборка)
- [Устранение неполадок](#устранение-неполадок)
- [Как это устроено](#как-это-устроено)

## Быстрый старт

Требования:
- Linux на **x86_64** (Aspia выпускает серверные пакеты только под эту архитектуру);
- Docker 24+ с плагином Compose;
- внешний IP-адрес или проброс портов на этот сервер.

```bash
sudo mkdir -p /opt/aspia && cd /opt/aspia
sudo curl -fsSLO https://raw.githubusercontent.com/SinitsaDA/aspia-server-docker/main/compose.yaml
sudo curl -fsSL -o .env https://raw.githubusercontent.com/SinitsaDA/aspia-server-docker/main/.env.example
sudo nano .env          # укажите EXTERNAL_IP, ASPIA_DIR и TZ
sudo docker compose up -d
```

Проверка:

```bash
sudo docker compose ps          # aspia-server должен стать (healthy) примерно через минуту
sudo docker logs aspia-server
```

### Если образы приватные

Если репозиторий или пакеты на GitHub закрыты, серверу нужен доступ к registry. Сделайте это один раз:

1. На GitHub: Settings → Developer settings → **Personal access tokens (classic)** → Generate new token, право только **`read:packages`**.
2. На сервере выполните:
   ```bash
   sudo docker login ghcr.io -u <логин GitHub>
   # Password: вставьте токен
   ```

Логин сохраняется в `/root/.docker/config.json`. Планировщик берёт его оттуда автоматически, путь можно поменять параметром `DOCKER_CONFIG_DIR` в `.env`.

Если у вас уже есть данные Aspia 2.x, положите их в `data/` **до** первого запуска, см. [Переход с Aspia 2.x](#переход-с-aspia-2x).

## Порты

Контейнер работает в сети хоста (`network_mode: host`), порты открываются прямо на сервере.

| Порт | Сервис | Для чего | Открыть наружу |
|---|---|---|---|
| 8060/tcp | Router | хосты Aspia 2.x (2.6.2 и новее) | если есть хосты 2.x |
| 8061/tcp | Router | хосты Aspia 3.x | да |
| 8062/tcp | Router | консоли (клиенты) | да |
| 8063/tcp | Router | подключение Relay к Router | нет |
| 8065/udp | Router | встроенный STUN-сервер | да |
| 8070/tcp | Relay | соединения между консолью и хостом | да |

Сервер за роутером MikroTik — готовый скрипт проброса портов в [docs/mikrotik.md](docs/mikrotik.md).

## Настройки

Все настройки в файле `.env`. Образец — [.env.example](.env.example).

| Параметр | По умолчанию | Описание |
|---|---|---|
| `ASPIA_VERSION` | — | версия Aspia; **меняется автоматически** планировщиком |
| `EXTERNAL_IP` | — | внешний IP или DNS-имя сервера, его Relay сообщает клиентам |
| `ASPIA_DIR` | — | **абсолютный путь** к папке проекта на хосте, например `/opt/aspia`. Должен совпадать с реальным: планировщик монтирует папку по тому же пути |
| `COMPOSE_PROJECT_NAME` | `aspia` | имя проекта Compose |
| `TZ` | `UTC` | часовой пояс контейнеров (логи, время проверки обновлений) |
| `UPDATE_TIME` | `04:00` | время ежедневной проверки обновлений |
| `MIN_AGE_DAYS` | `2` | ставить релиз, только когда ему исполнится столько дней (`0` — сразу) |
| `KEEP_BACKUPS` | `10` | сколько бэкапов хранить в `backups/` |
| `LOG_RETENTION_DAYS` | `30` | через сколько дней удалять логи Aspia |
| `SELF_UPDATE` | `1` | обновлять и сам планировщик |
| `ASPIA_IMAGE`, `UPDATER_IMAGE` | `ghcr.io/sinitsada/...` | откуда брать образы |
| `COMPOSE_FILE` | — | `compose.yaml:compose.build.yaml` — собирать образы локально |
| `DOCKER_CONFIG_DIR` | `/root/.docker` | где лежат данные `docker login` хоста (для приватных образов) |

После изменения `.env` выполните `docker compose up -d`.

## Первый вход и ключ для хостов

При первом запуске без данных создаётся новая конфигурация и пользователь **admin** с паролем **admin**:

```bash
docker logs aspia-server | grep -A2 "User name"
```

1. Установите консоль Aspia 3.x ([релизы](https://github.com/dchapyshev/aspia/releases)).
2. Подключитесь к Router: адрес сервера, порт **8062**.
3. Смените пароль. В Aspia 3.x для пользователей Router обязательна двухфакторная аутентификация (TOTP): консоль предложит настроить её при первом входе.

Сбросить TOTP пользователю:

```bash
docker exec aspia-server aspia_router --reset-otp admin
```

Публичный ключ Router, который нужно указать в настройках хостов:

```bash
cat data/config/host.pub
```

Хосты 3.x подключаются к порту **8061**, хосты 2.x — к **8060**.

## Обновления

Контейнер `aspia-updater` проверяет обновления при запуске и каждый день в `UPDATE_TIME`. Порядок такой:

1. Находит последний релиз на [GitHub Aspia](https://github.com/dchapyshev/aspia/releases). Релиз берётся в работу, когда ему исполнится `MIN_AGE_DAYS` дней: сразу после выхода нередко выходит исправление.
2. Скачивает образ этой версии, пока текущая продолжает работать. Пересобранный образ той же версии, например с обновлениями безопасности, тоже считается обновлением.
3. Останавливает сервер и сохраняет `data/config` и `data/database` в `backups/`.
4. Запускает новую версию и ждёт статуса `healthy` до 3 минут.
5. **Если сервер не стал `healthy`, восстанавливает бэкап и прежний образ.**
6. Удаляет старые образы, лишние бэкапы и старые логи, затем обновляет сам планировщик.

Простой при обновлении — 10–40 секунд. Журнал пишется в `update.log` и в `docker logs aspia-updater`.

Ручное управление:

```bash
docker exec aspia-updater update.sh                                  # проверить сейчас
docker exec -e MIN_AGE_DAYS=0 aspia-updater update.sh                # поставить свежий релиз сразу
docker exec -e DRY_RUN=1 -e MIN_AGE_DAYS=0 aspia-updater update.sh   # только показать, что будет сделано
docker exec -e FORCE_VERSION=3.0.18 aspia-updater update.sh          # перейти на конкретную версию
```

Чтобы отключить автообновление, выполните `docker compose stop updater`. Версия останется той, что указана в `.env`.

> Встроенный механизм обновления Aspia (`--install-update`, обновление из консоли) в контейнере не используется. Он рассчитан на systemd, а изменения пропали бы при пересоздании контейнера.

## Переход с Aspia 2.x

Сервер 3.x сам конвертирует данные 2.x при запуске:
- `router.json` → `router.conf`, `relay.json` → `relay.conf`, старые файлы сохраняются как `*.json.bak`;
- база `router.db3` обновляется, хосты и пользователи сохраняются;
- ключ шифрования остаётся прежним: `host.pub` = старый `router.pub`, на хостах ничего менять не нужно.

**Новая установка с данными 2.x.** До первого `docker compose up` положите файлы так:

```
data/config/router.json
data/config/relay.json
data/config/router.pub
data/database/router.db3
```

**С образа `paprikkafox/aspia-server`.** Его папки `./data/config` и `./data/database` имеют ту же структуру. Остановите старый контейнер, он занимает те же порты. Затем скопируйте папки в `data/` нового проекта и запустите.

**В уже работающую установку.** Положите архив (`.zip` или `.tar.gz`) с этими четырьмя файлами в папку проекта и выполните:

```bash
docker exec aspia-updater import-2x.sh import/aspia.zip
```

Перед импортом текущие данные сохраняются в `backups/`.

**Что учесть:**

- **Хосты старше 2.6.2 к Router 3.x не подключатся.** В логе Router это выглядит как `Invalid peer architecture (size: 0)`. Их нужно обновить.
- **Консоль** нужна версии 3.x, порт **8062**.
- **Порты 8061, 8062 и 8065/udp** нужно открыть или пробросить дополнительно.

## Бэкапы и восстановление

Перед каждым обновлением и импортом создаётся архив `backups/data_<версия>_<дата>.tar.gz` (или `before-import_<дата>.tar.gz`) с папками `data/config` и `data/database`.

Восстановление:

```bash
cd /opt/aspia
docker compose stop server
rm -rf data/config data/database
tar -xzf backups/<архив>.tar.gz
docker compose up -d server
```

Если бэкап сделан на другой версии, переключитесь на неё: `docker exec -e FORCE_VERSION=<версия> aspia-updater update.sh`.

## Локальная сборка

Чтобы не пользоваться готовыми образами:

```bash
git clone https://github.com/SinitsaDA/aspia-server-docker.git /opt/aspia
cd /opt/aspia
cp .env.example .env
# в .env: EXTERNAL_IP, ASPIA_DIR=/opt/aspia и раскомментировать
#   COMPOSE_FILE=compose.yaml:compose.build.yaml
docker compose up -d --build
```

Планировщик в этом режиме сам собирает каждую новую версию на этой машине.

Собрать только образ сервера:

```bash
docker build --build-arg ASPIA_VERSION=3.0.18 -t aspia-server:3.0.18 server
```

## Устранение неполадок

| Симптом | Что делать |
|---|---|
| `aspia-server` в статусе `unhealthy` | `docker inspect --format '{{json .State.Health}}' aspia-server` покажет причину; подробные логи в `data/logs/router` и `data/logs/relay` |
| Хосты 2.x не подключаются, в логе `Invalid peer architecture` | хост старше 2.6.2, обновите его |
| `ERROR: .../.env not found` в логе планировщика | `ASPIA_DIR` в `.env` не совпадает с реальным путём к проекту |
| `address already in use` | порты заняты: остановите старый сервер Aspia |
| Консоль не подключается | консоль должна быть 3.x и подключаться к порту 8062 |

Строки `sd_login_monitor_new failed` и `Unable to install signal handler for SIGKILL/SIGSTOP` в логах безобидны: в контейнере нет systemd.

## Как это устроено

```
├── compose.yaml            сервер + планировщик (готовые образы)
├── compose.build.yaml      дополнение для локальной сборки
├── docs/                   Synology, MikroTik
├── .env.example            образец настроек
├── server/                 образ ghcr.io/sinitsada/aspia-server
│   ├── Dockerfile          Debian slim + официальные .deb пакеты Aspia
│   ├── aspia_start         подготовка конфигурации, миграция 2.x, запуск Router и Relay
│   └── aspia_health        healthcheck (читает /proc/net/tcp, не создаёт подключений)
├── updater/                образ ghcr.io/sinitsada/aspia-server-updater
│   ├── entrypoint.sh       ежедневный запуск
│   ├── update.sh           обновление с бэкапом и откатом
│   └── import-2x.sh        импорт данных Aspia 2.x
└── .github/workflows/
    └── publish.yml         сборка, проверка и публикация образов
```

Теги образа сервера: `3.0.18` (точная версия), `3.0`, `3` и `latest`.

## Лицензия

[GPL-3.0](LICENSE), как и у самой Aspia.

Благодарности:
- [Дмитрий Чапышев](https://github.com/dchapyshev) — автор Aspia;
- [Dmitry Fox (paprikkafox)](https://github.com/paprikkafox/aspia-server-docker) — автор первого Docker-образа Aspia Server, на идеях которого основан этот проект.
