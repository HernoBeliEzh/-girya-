# ============================================================================
#  Гиря — Whizi.ps1
#  Адаптер (мост) к whizi.io.
#
#  Как устроен whizi (по результатам разбора сетевых запросов):
#   1) Аутентификация — Clerk (clerk.whizi.io). По cookie сессии (главное —
#      cookie __client) запрашивается короткоживущий JWT (~60 сек):
#         POST {clerkBase}/v1/client/sessions/{sessionId}/tokens?__clerk_api_version=..&_clerk_js_version=..
#      Ответ: { "jwt": "<токен>" }.
#   2) Чат — Cloudflare Worker backend.whizibackend.workers.dev:
#         POST {backendBase}/api/add-message?stream=true
#         Заголовок: Authorization: Bearer <JWT>
#         Ответ: text/event-stream (SSE).
#
#  Cookie аккаунта = строка Cookie из запроса к clerk.whizi.io (содержит __client).
#  sessionId (sess_...) берётся из cookie, либо определяется автоматически
#  через Clerk /v1/client, либо задаётся вручную при добавлении аккаунта.
# ============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Accounts.ps1')

# Кэш JWT по имени аккаунта: @{ name = @{ jwt=..; exp=unixtime } }
$script:GiryaTokenCache = @{}

# --- Определение sessionId --------------------------------------------------

# Достать sess_... из строки cookie (clerk_active_context или sid из __session JWT).
function Get-WhiziSessionIdFromCookie {
    param([Parameter(Mandatory)][string] $Cookie)
    if ($Cookie -match '(sess_[A-Za-z0-9]+)') { return $Matches[1] }
    # Попробовать вытащить sid из __session JWT.
    if ($Cookie -match '__session=([^;]+)') {
        $payload = ConvertFrom-GiryaJwt $Matches[1]
        if ($payload -and ($payload.PSObject.Properties.Name -contains 'sid')) {
            return [string]$payload.sid
        }
    }
    return $null
}

# Определить sessionId через Clerk /v1/client (если не нашли в cookie).
function Resolve-WhiziSessionIdViaClerk {
    param([Parameter(Mandatory)][string] $Cookie, [Parameter(Mandatory)] $Config)
    $w = $Config.whizi
    $uri = "$($w.clerkBase)/v1/client?__clerk_api_version=$($w.clerkApiVersion)&_clerk_js_version=$($w.clerkJsVersion)"
    $headers = @{
        'Cookie'  = $Cookie
        'Accept'  = 'application/json'
        'Origin'  = $w.origin
        'Referer' = $w.origin + '/'
        'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
    }
    $resp = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
    $r = $resp.response
    if ($r) {
        if (($r.PSObject.Properties.Name -contains 'last_active_session_id') -and $r.last_active_session_id) {
            return [string]$r.last_active_session_id
        }
        if (($r.PSObject.Properties.Name -contains 'sessions') -and @($r.sessions).Count -gt 0) {
            return [string](@($r.sessions)[0].id)
        }
    }
    throw 'Не удалось определить sessionId Clerk (нет активной сессии в /v1/client).'
}

# Получить sessionId для аккаунта (с кэшированием в конфиге).
function Get-WhiziSessionId {
    param([Parameter(Mandatory)] $Account, [Parameter(Mandatory)] $Config, [Parameter(Mandatory)][string] $Cookie)
    if (($Account.PSObject.Properties.Name -contains 'sessionId') -and $Account.sessionId) {
        return [string]$Account.sessionId
    }
    $sid = Get-WhiziSessionIdFromCookie $Cookie
    if (-not $sid) {
        $sid = Resolve-WhiziSessionIdViaClerk -Cookie $Cookie -Config $Config
    }
    # Сохранить в конфиг, чтобы не определять каждый раз.
    Set-GiryaAccountSessionId -Name $Account.name -SessionId $sid | Out-Null
    return $sid
}

# --- Получение короткоживущего JWT через Clerk -----------------------------

function Get-WhiziToken {
    param([Parameter(Mandatory)] $Account, [Parameter(Mandatory)] $Config)

    $name = [string]$Account.name
    $now  = Get-GiryaUnixNow

    # Используем кэш, если до истечения JWT ещё больше 15 секунд.
    if ($script:GiryaTokenCache.ContainsKey($name)) {
        $cached = $script:GiryaTokenCache[$name]
        if (($cached.exp - $now) -gt 15) { return $cached.jwt }
    }

    $cookie = Unprotect-GiryaSecret $Account.cookie
    $w = $Config.whizi
    $sid = Get-WhiziSessionId -Account $Account -Config $Config -Cookie $cookie

    $path = "/v1/client/sessions/$sid/tokens"
    if ($w.clerkTemplate) { $path += "/$($w.clerkTemplate)" }
    $uri = "$($w.clerkBase)$path`?__clerk_api_version=$($w.clerkApiVersion)&_clerk_js_version=$($w.clerkJsVersion)"

    $headers = @{
        'Cookie'       = $cookie
        'Accept'       = 'application/json'
        'Content-Type' = 'application/x-www-form-urlencoded'
        'Origin'       = $w.origin
        'Referer'      = $w.origin + '/'
        'User-Agent'   = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
    }

    try {
        $resp = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body '' -ErrorAction Stop
    }
    catch {
        $status = $null
        if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
            try { $status = [int]$_.Exception.Response.StatusCode } catch {}
        }
        if ($status -eq 401 -or $status -eq 403) {
            throw "Clerk отклонил запрос токена (HTTP $status). Cookie аккаунта '$name' устарел — обновите его."
        }
        throw "Ошибка получения токена Clerk для '$name': $($_.Exception.Message)"
    }

    $jwt = $null
    if ($resp.PSObject.Properties.Name -contains 'jwt') { $jwt = [string]$resp.jwt }
    elseif ($resp.PSObject.Properties.Name -contains 'token') { $jwt = [string]$resp.token }
    if ([string]::IsNullOrWhiteSpace($jwt)) {
        throw "Clerk вернул ответ без поля jwt для '$name'."
    }

    # Срок действия — из claim exp; если нет, считаем 50 секунд.
    $exp = $now + 50
    $payload = ConvertFrom-GiryaJwt $jwt
    if ($payload -and ($payload.PSObject.Properties.Name -contains 'exp')) {
        $exp = [int]$payload.exp
    }
    $script:GiryaTokenCache[$name] = @{ jwt = $jwt; exp = $exp }
    return $jwt
}

# Привести content (строка или массив частей OpenAI) к строке.
function Get-GiryaMessageText {
    param($Content)
    if ($null -eq $Content) { return '' }
    if ($Content -is [string]) { return $Content }
    if ($Content -is [System.Array]) {
        $parts = foreach ($p in $Content) {
            if ($p -is [string]) { $p }
            elseif ($p.PSObject.Properties.Name -contains 'text') { [string]$p.text }
        }
        return ($parts -join "`n")
    }
    return [string]$Content
}

# Свернуть историю диалога (OpenAI messages) в одно текстовое поле content.
# whizi хранит историю на своей стороне по chat_id, но мы создаём новый чат на
# каждый запрос, поэтому передаём весь контекст одним сообщением.
function Convert-GiryaMessagesToContent {
    param([Parameter(Mandatory)][array] $Messages)
    $arr = @($Messages)
    if ($arr.Count -eq 1) {
        return (Get-GiryaMessageText $arr[0].content)
    }
    $sb = [System.Text.StringBuilder]::new()
    foreach ($m in $arr) {
        $role = switch ([string]$m.role) {
            'system'    { 'System' }
            'assistant' { 'Assistant' }
            'user'      { 'User' }
            'tool'      { 'Tool' }
            default     { [string]$m.role }
        }
        [void]$sb.AppendLine("${role}: $(Get-GiryaMessageText $m.content)")
        [void]$sb.AppendLine()
    }
    return $sb.ToString().TrimEnd()
}

# --- Построение тела запроса к бэкенду чата (схема whizi /api/add-message) --
function Build-WhiziRequestBody {
    param(
        [Parameter(Mandatory)][array] $Messages,
        [Parameter(Mandatory)][string] $Model,
        [Parameter(Mandatory)][string] $UserId,
        [Parameter(Mandatory)] $Config
    )
    return @{
        chat_id            = [guid]::NewGuid().ToString()
        user_id            = $UserId
        content            = (Convert-GiryaMessagesToContent -Messages $Messages)
        files              = @()
        image_url          = $null
        model              = $Model
        user_type          = $Config.whizi.userType
        web_search_enabled = [bool]$Config.whizi.webSearch
    }
}

# Универсальный (фолбэк) разбор для не-whizi форматов (OpenAI-подобных).
function Get-WhiziDeltaGeneric {
    param([Parameter(Mandatory)] $Obj)
    if ($Obj.PSObject.Properties.Name -contains 'choices') {
        $c = @($Obj.choices)[0]
        if ($c) {
            if (($c.PSObject.Properties.Name -contains 'delta') -and $c.delta -and ($c.delta.PSObject.Properties.Name -contains 'content')) {
                return [string]$c.delta.content
            }
            if ($c.PSObject.Properties.Name -contains 'text') { return [string]$c.text }
        }
    }
    foreach ($p in 'content','text','token','chunk','response') {
        if ($Obj.PSObject.Properties.Name -contains $p) {
            $v = $Obj.$p
            if ($v -is [string]) { return $v }
            if ($v -and ($v.PSObject.Properties.Name -contains 'content')) { return [string]$v.content }
        }
    }
    return ''
}

# Разбор одного события потока whizi.
# Возвращает хэш: @{ stream = <дельта> } | @{ final = <полный текст> } | $null.
# Протокол whizi:
#   {"type":"aiStream","data":"кусок"}            -> текст ответа (по кускам)
#   {"type":"finalMessage","data":{"message":..}} -> полный финальный текст
#   {"type":"aiReasoning",...}                     -> размышления (игнорируем)
#   originalMessage|aiMessage|title|trial_prompt_count -> служебное (игнор)
function Get-WhiziEvent {
    param([Parameter(Mandatory)][string] $Json)
    $obj = $null
    try { $obj = $Json | ConvertFrom-Json } catch { return $null }
    if ($null -eq $obj) { return $null }

    if ($obj.PSObject.Properties.Name -contains 'type') {
        switch ([string]$obj.type) {
            'aiStream' {
                if ($obj.PSObject.Properties.Name -contains 'data') { return @{ stream = [string]$obj.data } }
                return $null
            }
            'finalMessage' {
                if ($obj.data -and ($obj.data.PSObject.Properties.Name -contains 'message')) {
                    return @{ final = [string]$obj.data.message }
                }
                return $null
            }
            default { return $null }
        }
    }

    # Иной формат — пробуем универсальный разбор.
    $d = Get-WhiziDeltaGeneric $obj
    if ($d) { return @{ stream = $d } }
    return $null
}

# --- Основной вызов чата: возвращает полный текст ответа ассистента ---------
function Invoke-WhiziChat {
    param(
        [Parameter(Mandatory)][array] $Messages,
        [string] $Model
    )
    $cfg = Get-GiryaConfig
    $account = Get-GiryaActiveAccount
    if ($null -eq $account) {
        throw 'Нет активного аккаунта whizi. Добавьте аккаунт с cookie через меню Гири.'
    }
    if ([string]::IsNullOrWhiteSpace($Model)) { $Model = $cfg.whizi.defaultModel }

    $userId = ''
    if ($account.PSObject.Properties.Name -contains 'userId') { $userId = [string]$account.userId }
    if ([string]::IsNullOrWhiteSpace($userId)) {
        throw "У аккаунта '$($account.name)' не задан userId (UUID whizi). Добавьте его: girya add ... -UserId <uuid>, либо обновите аккаунт. Где взять — см. README."
    }

    $jwt = Get-WhiziToken -Account $account -Config $cfg
    $w = $cfg.whizi
    $uri = ($w.backendBase.TrimEnd('/')) + $w.chatPath

    $bodyObj  = Build-WhiziRequestBody -Messages $Messages -Model $Model -UserId $userId -Config $cfg
    $bodyJson = $bodyObj | ConvertTo-Json -Depth 12

    Add-Type -AssemblyName System.Net.Http

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromMinutes(5)

    try {
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $uri)
        [void]$req.Headers.TryAddWithoutValidation('Authorization', "Bearer $jwt")
        [void]$req.Headers.TryAddWithoutValidation('Accept', 'text/event-stream')
        [void]$req.Headers.TryAddWithoutValidation('Origin', $w.origin)
        [void]$req.Headers.TryAddWithoutValidation('Referer', $w.origin + '/')
        [void]$req.Headers.TryAddWithoutValidation('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36')
        if ($w.extraHeaders) {
            foreach ($p in $w.extraHeaders.PSObject.Properties) {
                [void]$req.Headers.TryAddWithoutValidation($p.Name, [string]$p.Value)
            }
        }
        $req.Content = [System.Net.Http.StringContent]::new($bodyJson, [System.Text.Encoding]::UTF8, 'application/json')

        $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $resp.IsSuccessStatusCode) {
            $errText = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $code = [int]$resp.StatusCode
            if ($code -eq 401 -or $code -eq 403) {
                # Токен мог протухнуть — сбросим кэш, чтобы следующий запрос обновил.
                $script:GiryaTokenCache.Remove([string]$account.name) | Out-Null
            }
            throw "Бэкенд whizi вернул HTTP $code`: $errText"
        }

        $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
        $sb = [System.Text.StringBuilder]::new()   # накопление кусков aiStream
        $final = $null                              # текст из finalMessage (приоритетный)
        try {
            while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine()
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                # Снять необязательный префикс SSE 'data:' и служебные строки.
                if ($line.StartsWith(':')) { continue }
                if ($line.StartsWith('event:') -or $line.StartsWith('id:') -or $line.StartsWith('retry:')) { continue }
                if ($line.StartsWith('data:')) { $line = $line.Substring(5).Trim() }
                if ($line -eq '[DONE]' -or [string]::IsNullOrWhiteSpace($line)) { continue }

                $ev = Get-WhiziEvent -Json $line
                if ($null -eq $ev) { continue }
                if ($ev.ContainsKey('final') -and $ev.final) { $final = [string]$ev.final }
                elseif ($ev.ContainsKey('stream') -and $ev.stream) { [void]$sb.Append([string]$ev.stream) }
            }
        } finally {
            $reader.Dispose()
        }
        # finalMessage надёжнее (полный текст); иначе — склейка кусков aiStream.
        $result = if (-not [string]::IsNullOrEmpty($final)) { $final } else { $sb.ToString() }
        if ([string]::IsNullOrEmpty($result)) {
            throw 'Бэкенд whizi вернул пустой ответ (формат SSE мог измениться — проверьте Get-WhiziEvent в Whizi.ps1).'
        }
        return $result
    }
    finally {
        $client.Dispose()
    }
}

# Список моделей, отдаваемый через /v1/models (берётся из конфига whizi.models).
function Get-WhiziModels {
    $cfg = Get-GiryaConfig
    $models = @()
    if (($cfg.whizi.PSObject.Properties.Name -contains 'models') -and $cfg.whizi.models) {
        $models = @($cfg.whizi.models)
    }
    if ($models.Count -eq 0) { $models = @($cfg.whizi.defaultModel) }
    if ($models -notcontains $cfg.whizi.defaultModel) {
        $models = @($cfg.whizi.defaultModel) + $models
    }
    return $models
}
