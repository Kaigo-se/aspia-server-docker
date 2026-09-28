# Aspia Server на Synology NAS

Инструкция для DSM 7.2+ с **Container Manager**. Процессор NAS должен быть **x86_64** (Intel/AMD): серверные пакеты Aspia собираются только под эту архитектуру. Модели на ARM (серии `j`, часть `play`) не подойдут.

## 1. Подготовить папку

File Station → `docker` → создайте папку `aspia` со структурой:

```
docker/aspia/
├── compose.yaml
├── .env
└── data/
    ├── config/
    ├── database/
    └── logs/
```

- `compose.yaml` скачайте из репозитория: [compose.yaml](../compose.yaml).
- `.env` сделайте из [.env.example](../.env.example): скачайте и переименуйте в `.env`. Если File Station не даёт создать имя, начинающееся с точки, создайте файл через SSH или в текстовом редакторе DSM.
- Папки `data/config`, `data/database`, `data/logs` создайте пустыми. Synology не создаёт папки для томов автоматически, и без них проект не запустится.

## 2. Настроить `.env`

Откройте `.env` в Text Editor (пакет DSM) и укажите:

```ini
EXTERNAL_IP=<ваш внешний IP>
ASPIA_DIR=/volume1/docker/aspia
TZ=Europe/Moscow
```

**`ASPIA_DIR` должен точно совпадать с реальным путём к папке.** Узнать путь можно в File Station: правой кнопкой по папке → Свойства → «Расположение». Обычно это `/volume1/docker/aspia`.

## 3. Данные Aspia 2.x (если переходите со старого сервера)

1. Остановите старый проект или контейнер Aspia: он занимает те же порты.
2. Скопируйте его данные в новую папку:

| Откуда (старый проект) | Куда |
|---|---|
| `data/config/router.json`, `relay.json`, `router.pub` | `aspia/data/config/` |
| `data/database/router.db3` | `aspia/data/database/` |

Копируйте, а не переносите: оригинал пригодится для отката. Конвертация в формат 3.x произойдёт при первом запуске.

**Важно:** хосты старше 2.6.2 к Aspia 3.x не подключатся, их нужно обновить.

## 3а. Доступ к образам (если они приватные)

Если пакеты на GitHub закрыты:

1. Создайте на GitHub токен: Settings → Developer settings → Personal access tokens (classic), право только `read:packages`.
2. Подключитесь к NAS по SSH и выполните:
   ```bash
   sudo docker login ghcr.io -u <логин GitHub>
   # Password: вставьте токен
   ```

Логин сохранится в `/root/.docker/config.json`, и оттуда его возьмут и Container Manager, и планировщик.

## 4. Создать проект

Container Manager → **Проект** → **Создать**:

1. **Имя проекта:** `aspia` (любое, планировщик определит его сам).
2. **Путь:** `/docker/aspia`.
3. **Источник:** «Использовать существующий docker-compose.yml». Container Manager покажет `compose.yaml`.
4. **Далее**. Настройки Web Station пропустите.
5. **Готово**. Container Manager скачает образы и запустит контейнеры `aspia-server` и `aspia-updater`.

Через SSH:

```bash
cd /volume1/docker/aspia
sudo docker compose up -d
```

## 5. Проверить

Container Manager → **Контейнер**:
- `aspia-server` — «Работает», через минуту статус «Исправен» (healthy);
- `aspia-updater` — «Работает».

Журнал `aspia-server` при переходе с 2.x:

```
Router configuration of 2.x: /etc/aspia/router.json, it will be migrated on start
Relay configuration of 2.x: /etc/aspia/relay.json, it will be migrated on start
```

При новой установке журнал покажет созданного пользователя `admin` / `admin`.

## 6. Порты

Контейнер использует сеть NAS напрямую. Если в DSM включён брандмауэр (Панель управления → Безопасность → Брандмауэр), разрешите в нём порты.

На роутере пробросьте на IP NAS:

| Порт | Для чего |
|---|---|
| 8060/tcp | хосты 2.x |
| 8061/tcp | хосты 3.x |
| 8062/tcp | консоль |
| 8065/udp | STUN |
| 8070/tcp | relay |

## 7. Обновления

Отдельно настраивать ничего не нужно: `aspia-updater` каждую ночь проверяет новые версии и обновляет сервер сам, с бэкапом и откатом. Журнал — `aspia/update.log`.

Проверить сейчас (SSH):

```bash
sudo docker exec aspia-updater update.sh
```

Задача в Планировщике DSM **не нужна**.

## Откат на старый сервер

1. Container Manager → Проект `aspia` → **Остановить**.
2. Запустите старый проект.
