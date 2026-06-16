# Гиря 🏋️

> Репозиторий: https://github.com/HernoBeliEzh/-girya-

**Гиря** — мост между сайтом [whizi.io](https://whizi.io) и любым OpenAI-совместимым клиентом (в первую очередь [OpenCode](https://opencode.ai)). Это программа на PowerShell: она поднимает локальный сервер, который выдаёт **единый API-ключ в формате OpenAI**, принимает запросы OpenCode и проксирует их в whizi.io под вашим аккаунтом (через cookie).

> Иными словами: вы платите за один аккаунт whizi.io (GPT, Claude, Gemini, Llama и др. в одном месте) и пользуетесь всеми моделями прямо из OpenCode, как будто это обычный OpenAI API.

---

## ⚠️ Важно понимать про whizi.io

У whizi.io **нет официального публичного API** — это веб-сервис для людей. «Мост» работает так же, как браузер: берёт ваш **cookie сессии** и повторяет тот же HTTP-запрос чата, что делает сайт.

Точный внутренний путь и формат запроса whizi нигде не опубликованы и могут меняться. Поэтому они вынесены в настройки, и при первом запуске их **нужно один раз уточнить** (займёт 2 минуты, см. раздел [«Настройка моста»](#-настройка-моста)). Всё остальное работает «из коробки».

---

## Возможности

- 🔑 **Единый OpenAI-ключ** формата `sk-girya-...` для всех клиентов.
- 🌐 **Локальный сервер** с эндпоинтами `/v1/models` и `/v1/chat/completions` (включая стриминг SSE).
- 👤 **Управление аккаунтами whizi через cookie**: добавить, удалить, сменить активный, показать список.
- 🔒 **Cookie шифруется** (Windows DPAPI, привязка к вашему пользователю) — на диск в открытом виде не попадает.
- 🤖 **Готовая интеграция с OpenCode** — отправляйте сообщения как в обычном OpenCode.
- 🖥️ **Меню в PowerShell** + полноценный CLI.
- 📦 Готов к публикации на GitHub.

---

## Требования

- Windows 10/11
- PowerShell 5.1+ (встроен) или PowerShell 7+
- Аккаунт на [whizi.io](https://whizi.io)

---

## Установка

### Быстрая установка (одной строкой)

```powershell
irm https://raw.githubusercontent.com/HernoBeliEzh/-girya-/main/bootstrap.ps1 | iex
```

Скрипт клонирует репозиторий в `%LOCALAPPDATA%\Programs\Girya` и запустит установку. Нужен установленный [git](https://git-scm.com/download/win).

### Обычная установка

```powershell
# 1. Клонируйте репозиторий
git clone https://github.com/HernoBeliEzh/-girya-.git
cd -girya-

# 2. Запустите установку (создаст конфиг, ключ, добавит команду 'girya')
powershell -ExecutionPolicy Bypass -File Install.ps1
```

После установки доступна команда `girya` (перезапустите терминал) либо двойной клик по **`Гиря.cmd`**.

---

## Быстрый старт

```powershell
# Открыть меню
girya

# Или по шагам через CLI:
girya add  -Name "main" -Cookie "вставьте_сюда_cookie"   # добавить аккаунт
girya list                                               # показать аккаунты
girya key                                                # показать API-ключ и Base URL
girya serve                                              # поднять локальный сервер
```

После `girya serve` вы увидите:

```
[Гиря] Сервер Гиря запущен: http://127.0.0.1:8788/
[Гиря] OpenAI Base URL : http://127.0.0.1:8788/v1
[Гиря] API-ключ        : sk-girya-XXXXXXXX...
[Гиря] Активный аккаунт: main
```

---

## Меню программы

```
 1) Показать аккаунты
 2) Добавить аккаунт (cookie)
 3) Удалить аккаунт
 4) Сменить активный аккаунт
 5) Сменить модель
 6) Веб-поиск (вкл/выкл)
 7) Показать API-ключ / Base URL
 8) Перегенерировать API-ключ
 9) Настройка OpenCode
 c) Показать конфигурацию
 s) Запустить локальный сервер
 0) Выход
```

---

## Где взять cookie whizi.io

whizi использует для входа сервис **Clerk** (`clerk.whizi.io`). Гире нужен cookie,
который браузер шлёт именно на `clerk.whizi.io` — в нём есть главный долгоживущий
токен **`__client`**.

1. Откройте [whizi.io](https://whizi.io), войдите в аккаунт, перейдите в чат.
2. Нажмите **F12** → вкладка **Network (Сеть)**.
3. Отправьте любое сообщение. В списке запросов найдите запрос к
   **`clerk.whizi.io`** с путём вида `.../tokens?...` (или `.../touch?...`).
4. Откройте его → **Request Headers** → заголовок **`Cookie`** → скопируйте **целиком**.
5. Вставьте в Гирю при добавлении аккаунта.

`sessionId` (`sess_...`) Гиря определит сама — из cookie или через Clerk. При желании
его можно увидеть в URL того же запроса (`/sessions/sess_XXXX/tokens`) и задать вручную.

### User ID (обязательно)

whizi требует ваш внутренний UUID пользователя. Возьмите его один раз:

1. F12 → **Network**, отправьте сообщение в чате whizi.
2. Найдите запрос **`add-message`** → вкладка **«Полезная нагрузка» (Payload)**.
3. Скопируйте значение поля **`user_id`** (UUID вида `cef6f4c5-28f6-41c9-8cb6-9dfdf568077b`).
4. Укажите его при добавлении аккаунта (параметр `-UserId` или в меню).

> Cookie — это ваш ключ доступа. Не публикуйте его. Гиря хранит его в зашифрованном виде (DPAPI).
> Токен Clerk живёт ~60 секунд — Гиря обновляет его автоматически перед каждым запросом.

---

## Интеграция с OpenCode

1. Запустите сервер: `girya serve`.
2. Команда `girya opencode` покажет готовый блок конфигурации. Поместите его в
   `~/.config/opencode/opencode.json` (пример — в [`examples/opencode.json`](examples/opencode.json)):

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "girya": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Гиря (whizi)",
      "options": { "baseURL": "http://127.0.0.1:8788/v1" },
      "models": {
        "gpt-4o": { "name": "GPT-4o (whizi)" },
        "claude-3-5-sonnet": { "name": "Claude 3.5 Sonnet (whizi)" }
      }
    }
  }
}
```

3. В OpenCode выберите провайдера **Гиря** и в качестве API-ключа укажите ключ из `girya key`.
4. Пишите сообщения как обычно — они уходят в whizi.io через ваш аккаунт.

Проверить вручную:

```powershell
curl http://127.0.0.1:8788/v1/chat/completions `
  -H "Authorization: Bearer sk-girya-ВАШ_КЛЮЧ" `
  -H "Content-Type: application/json" `
  -d '{ "model": "gpt-4o", "messages": [ { "role": "user", "content": "Привет!" } ] }'
```

---

## 🔧 Настройка моста

Аутентификация (Clerk) и адрес бэкенда уже настроены в Гире:

```json
"whizi": {
  "origin": "https://whizi.io",
  "clerkBase": "https://clerk.whizi.io",
  "clerkApiVersion": "2025-11-10",
  "clerkJsVersion": "5.125.13",
  "clerkTemplate": "",
  "backendBase": "https://backend.whizibackend.workers.dev",
  "chatPath": "/api/add-message?stream=true",
  "defaultModel": "gpt-4o",
  "extraHeaders": { }
}
```

Файл конфигурации: `girya config` покажет путь (обычно `%APPDATA%\Girya\config.json`).

**Что Гиря делает сама:**
- получает короткоживущий JWT через Clerk `/v1/client/sessions/<sess>/tokens` по вашему cookie и кэширует его;
- определяет `sessionId`;
- шлёт `POST /api/add-message?stream=true` с `Authorization: Bearer <JWT>`;
- читает SSE-поток ответа и отдаёт его как обычный OpenAI-ответ.

**Формат тела запроса `add-message`** (схема whizi) уже реализован в
`Build-WhiziRequestBody` ([`src/Whizi.ps1`](src/Whizi.ps1)):
`chat_id` (новый UUID на запрос), `user_id`, `content` (история диалога, свёрнутая
в один текст), `files`, `image_url`, `model`, `user_type`, `web_search_enabled`.

**Разбор SSE-потока** реализован в `Get-WhiziEvent`: события `aiStream` склеиваются,
`finalMessage` берётся как итоговый текст; `aiReasoning` и служебные события игнорируются.

Если бэкенд возвращает `401` на валидный cookie — впишите имя JWT-шаблона Clerk
в `clerkTemplate` (его видно в пути запроса `tokens/<шаблон>`, если он используется).

### Модели

Список моделей задаётся в `whizi.models` (формат whizi: `"провайдер модель"`):

```
openai gpt-5.5
anthropic claude-sonnet-4.6
google gemini-3.1-pro-preview
```

Сменить модель по умолчанию: `girya model -Model "anthropic claude-sonnet-4.6"`
(или пункт меню «Сменить модель»). В OpenCode модель выбирается из выпадающего списка
провайдера «Гиря».

### Веб-поиск

Включён по умолчанию. Управление: `girya websearch -State on|off` или пункт меню
«Веб-поиск».

---

## CLI-команды

| Команда | Описание |
|---|---|
| `girya` / `girya menu` | Интерактивное меню |
| `girya add -Name <имя> -Cookie <cookie> -UserId <uuid> [-SessionId sess_...]` | Добавить аккаунт |
| `girya remove -Name <имя>` | Удалить аккаунт |
| `girya use -Name <имя>` | Сделать аккаунт активным |
| `girya list` | Показать аккаунты |
| `girya model [-Model "<имя>"]` | Показать / сменить модель |
| `girya websearch [-State on\|off]` | Показать / переключить веб-поиск |
| `girya serve [-ListenHost <addr>] [-Port <n>]` | Запустить сервер |
| `girya key [-Regenerate]` | Показать / пересоздать API-ключ |
| `girya config` | Показать конфигурацию |
| `girya opencode` | Показать настройку OpenCode |

---

## Структура проекта

```
Гиря/
├─ Install.ps1            # установка и первичная настройка
├─ Гиря.cmd               # запуск меню двойным кликом
├─ README.md
├─ LICENSE
├─ .gitignore
├─ examples/
│  └─ opencode.json       # пример конфигурации OpenCode
└─ src/
   ├─ Common.ps1          # конфиг, пути, генерация ключа, шифрование cookie
   ├─ Accounts.ps1        # управление аккаунтами
   ├─ Whizi.ps1           # адаптер (мост) к whizi.io
   ├─ Server.ps1          # OpenAI-совместимый локальный сервер
   └─ Girya.ps1           # меню и CLI
```

---

## Эндпоинты сервера

| Метод | Путь | Назначение |
|---|---|---|
| `GET` | `/` | Страница статуса |
| `GET` | `/v1/models` | Список моделей (формат OpenAI) |
| `POST` | `/v1/chat/completions` | Чат (поддержка `stream: true`) |

Авторизация — заголовок `Authorization: Bearer <ключ Гири>`.

---

## Безопасность и ограничения

- Cookie шифруется через **DPAPI** и расшифровывается только под вашей учётной записью Windows.
- Сервер по умолчанию слушает только `127.0.0.1` (локально). Открывать наружу не рекомендуется.
- Это **неофициальный** инструмент. Он использует ваш личный доступ к whizi.io. Соблюдайте условия использования whizi.io; автоматизация может им противоречить — ответственность на пользователе.
- whizi.io может в любой момент изменить внутренний формат запросов — тогда поправьте раздел [«Настройка моста»](#-настройка-моста).

---

## Лицензия

[MIT](LICENSE)
