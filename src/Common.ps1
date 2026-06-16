# ============================================================================
#  Гиря — Common.ps1
#  Общее ядро: пути, конфигурация, генерация API-ключа, шифрование cookie.
# ============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Пути -------------------------------------------------------------------
# Все пользовательские данные (конфиг, аккаунты, ключ) хранятся в %APPDATA%\Girya,
# чтобы не попасть в репозиторий и пережить обновление программы.
$script:GiryaDataDir   = Join-Path $env:APPDATA 'Girya'
$script:GiryaConfigPath = Join-Path $script:GiryaDataDir 'config.json'

function Initialize-GiryaData {
    if (-not (Test-Path -LiteralPath $script:GiryaDataDir)) {
        New-Item -ItemType Directory -Path $script:GiryaDataDir -Force | Out-Null
    }
}

# --- Структура конфигурации по умолчанию -----------------------------------
function New-GiryaDefaultConfig {
    [pscustomobject]@{
        # Единый OpenAI-совместимый ключ, который выдаётся клиентам (OpenCode и др.)
        apiKey   = ''
        # Отладочный лог последнего запроса/ответа в %APPDATA%\Girya\debug.log
        debug    = $false
        # Настройки локального сервера
        server   = [pscustomobject]@{
            host = '127.0.0.1'
            port = 8788
        }
        # Параметры обращения к whizi.io (адаптер).
        whizi    = [pscustomobject]@{
            # Сайт (для заголовков Origin/Referer).
            origin          = 'https://whizi.io'
            # Clerk — провайдер аутентификации whizi. Используется для получения
            # короткоживущего JWT по cookie сессии.
            clerkBase       = 'https://clerk.whizi.io'
            clerkApiVersion = '2025-11-10'
            clerkJsVersion  = '5.125.13'
            # Имя JWT-шаблона Clerk. Пусто = стандартный токен сессии (/tokens).
            # Если бэкенд отвергает токен (401) — впишите сюда имя шаблона.
            clerkTemplate   = ''
            # Бэкенд чата (Cloudflare Worker).
            backendBase     = 'https://backend.whizibackend.workers.dev'
            chatPath        = '/api/add-message?stream=true'
            # Эндпоинт создания чата (нужен chat_id перед отправкой сообщения).
            createChatPath  = '/api/create-chat'
            # Имя модели по умолчанию (формат whizi: "<провайдер> <модель>").
            defaultModel    = 'openai gpt-5.5'
            # Список моделей для /v1/models (имена в формате whizi). Дополняйте по вкусу.
            models          = @(
                'openai gpt-5.5',
                'anthropic claude-sonnet-4.6',
                'google gemini-3.1-pro-preview'
            )
            # Постоянные поля тела запроса.
            userType        = 'user'
            # Веб-поиск включён по умолчанию.
            webSearch       = $true
            # Дополнительные заголовки запроса к бэкенду, при необходимости.
            extraHeaders    = [pscustomobject]@{}
        }
        # Аккаунт: { name, cookie (зашифр.), sessionId, userId, active }
        accounts = @()
    }
}

# --- Загрузка / сохранение конфигурации ------------------------------------
function Get-GiryaConfig {
    Initialize-GiryaData
    if (-not (Test-Path -LiteralPath $script:GiryaConfigPath)) {
        $cfg = New-GiryaDefaultConfig
        $cfg.apiKey = New-GiryaApiKey
        Save-GiryaConfig $cfg
        return $cfg
    }
    $raw = Get-Content -LiteralPath $script:GiryaConfigPath -Raw -Encoding UTF8
    $cfg = $raw | ConvertFrom-Json
    # Гарантируем, что массив аккаунтов — всегда массив (ConvertFrom-Json даёт $null для пустых).
    if ($null -eq $cfg.accounts) {
        $cfg | Add-Member -NotePropertyName accounts -NotePropertyValue @() -Force
    }
    # Авто-миграция: дополнить старый конфиг новыми полями из умолчаний.
    $def = New-GiryaDefaultConfig
    foreach ($top in $def.PSObject.Properties.Name) {
        if ($cfg.PSObject.Properties.Name -notcontains $top) {
            $cfg | Add-Member -NotePropertyName $top -NotePropertyValue $def.$top -Force
        }
    }
    if ($null -ne $cfg.whizi) {
        foreach ($p in $def.whizi.PSObject.Properties.Name) {
            if ($cfg.whizi.PSObject.Properties.Name -notcontains $p) {
                $cfg.whizi | Add-Member -NotePropertyName $p -NotePropertyValue $def.whizi.$p -Force
            }
        }
    }
    return $cfg
}

function Save-GiryaConfig {
    param([Parameter(Mandatory)] $Config)
    Initialize-GiryaData
    $json = $Config | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath $script:GiryaConfigPath -Value $json -Encoding UTF8
}

# --- Генерация OpenAI-формата ключа ----------------------------------------
# Формат как у OpenAI: "sk-" + 48 символов [A-Za-z0-9].
function New-GiryaApiKey {
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    $bytes = New-Object 'System.Byte[]' 48
    $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $sb = [System.Text.StringBuilder]::new()
    foreach ($b in $bytes) {
        [void]$sb.Append($alphabet[$b % $alphabet.Length])
    }
    return "sk-girya-$($sb.ToString())"
}

# --- Шифрование cookie через DPAPI (привязка к текущему пользователю Windows) ---
# Cookie никогда не хранится в открытом виде на диске.
function Protect-GiryaSecret {
    param([Parameter(Mandatory)][string] $PlainText)
    Add-Type -AssemblyName System.Security
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
    $enc = [System.Security.Cryptography.ProtectedData]::Protect(
        $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Convert]::ToBase64String($enc)
}

function Unprotect-GiryaSecret {
    param([Parameter(Mandatory)][string] $Cipher)
    Add-Type -AssemblyName System.Security
    $bytes = [Convert]::FromBase64String($Cipher)
    $dec = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [System.Text.Encoding]::UTF8.GetString($dec)
}

# --- Настройки модели и веб-поиска -----------------------------------------
function Set-GiryaDefaultModel {
    param([Parameter(Mandatory)][string] $Model)
    $cfg = Get-GiryaConfig
    $cfg.whizi.defaultModel = $Model
    # Добавим в список доступных, если ещё нет.
    $models = @($cfg.whizi.models)
    if ($models -notcontains $Model) { $cfg.whizi.models = @($models + $Model) }
    Save-GiryaConfig $cfg
}

function Set-GiryaWebSearch {
    param([Parameter(Mandatory)][bool] $Enabled)
    $cfg = Get-GiryaConfig
    $cfg.whizi.webSearch = $Enabled
    Save-GiryaConfig $cfg
}

# --- Работа с JWT (Clerk-токены) -------------------------------------------
# Декодирование base64url (без выравнивания '=').
function ConvertFrom-GiryaBase64Url {
    param([Parameter(Mandatory)][string] $Text)
    $s = $Text.Replace('-', '+').Replace('_', '/')
    switch ($s.Length % 4) {
        2 { $s += '==' }
        3 { $s += '=' }
        1 { $s += '===' }
    }
    return [Convert]::FromBase64String($s)
}

# Разобрать payload JWT в объект. Возвращает $null при ошибке.
function ConvertFrom-GiryaJwt {
    param([Parameter(Mandatory)][string] $Jwt)
    try {
        $parts = $Jwt.Split('.')
        if ($parts.Count -lt 2) { return $null }
        $bytes = ConvertFrom-GiryaBase64Url $parts[1]
        $json  = [System.Text.Encoding]::UTF8.GetString($bytes)
        return $json | ConvertFrom-Json
    } catch { return $null }
}

# Текущее время в формате unix (без Get-Date, совместимо со StrictMode).
function Get-GiryaUnixNow {
    return [int][double]::Parse(([DateTimeOffset]::UtcNow).ToUnixTimeSeconds().ToString())
}

# --- Вспомогательный вывод --------------------------------------------------
function Write-GiryaInfo  { param([string]$m) Write-Host "[Гиря] $m" -ForegroundColor Cyan }
function Write-GiryaOk    { param([string]$m) Write-Host "[Гиря] $m" -ForegroundColor Green }
function Write-GiryaWarn  { param([string]$m) Write-Host "[Гиря] $m" -ForegroundColor Yellow }
function Write-GiryaError { param([string]$m) Write-Host "[Гиря] $m" -ForegroundColor Red }
