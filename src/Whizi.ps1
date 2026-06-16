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

# Разобрать строку cookie в упорядоченный словарь.
function ConvertFrom-GiryaCookie {
    param([string] $Cookie)
    $dict = [ordered]@{}
    if ([string]::IsNullOrWhiteSpace($Cookie)) { return $dict }
    foreach ($pair in $Cookie.Split(';')) {
        $p = $pair.Trim()
        if ($p -eq '') { continue }
        $idx = $p.IndexOf('=')
        if ($idx -lt 1) { continue }
        $k = $p.Substring(0, $idx).Trim()
        $v = $p.Substring($idx + 1).Trim()
        $dict[$k] = $v
    }
    return $dict
}

function ConvertTo-GiryaCookie {
    param($Dict)
    return (($Dict.Keys | ForEach-Object { "$_=$($Dict[$_])" }) -join '; ')
}

# Применить Set-Cookie из ответа Clerk к текущему cookie (ротация __client, __cf_bm и т.п.).
# Возвращает новую строку cookie или $null, если изменений нет.
function Merge-GiryaSetCookies {
    param([string] $Cookie, [string[]] $SetCookies)
    if (-not $SetCookies -or $SetCookies.Count -eq 0) { return $null }
    $dict = ConvertFrom-GiryaCookie $Cookie
    $changed = $false
    foreach ($sc in $SetCookies) {
        $first = $sc.Split(';')[0].Trim()
        $idx = $first.IndexOf('=')
        if ($idx -lt 1) { continue }
        $k = $first.Substring(0, $idx).Trim()
        $v = $first.Substring($idx + 1).Trim()
        # Игнорируем удаляющие cookie.
        if ($v -eq '' -and $sc -match 'Max-Age=0') { continue }
        if (-not $dict.Contains($k) -or $dict[$k] -ne $v) {
            $dict[$k] = $v
            $changed = $true
        }
    }
    if (-not $changed) { return $null }
    return (ConvertTo-GiryaCookie $dict)
}

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

    Add-Type -AssemblyName System.Net.Http
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.UseCookies = $false   # cookie ставим вручную, Set-Cookie читаем сами
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(30)

    try {
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $uri)
        [void]$req.Headers.TryAddWithoutValidation('Cookie', $cookie)
        [void]$req.Headers.TryAddWithoutValidation('Accept', 'application/json')
        [void]$req.Headers.TryAddWithoutValidation('Origin', $w.origin)
        [void]$req.Headers.TryAddWithoutValidation('Referer', $w.origin + '/')
        [void]$req.Headers.TryAddWithoutValidation('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36')
        $req.Content = [System.Net.Http.StringContent]::new('', [System.Text.Encoding]::UTF8, 'application/x-www-form-urlencoded')

        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        $bodyText = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()

        if (-not $resp.IsSuccessStatusCode) {
            $code = [int]$resp.StatusCode
            if ($code -eq 401 -or $code -eq 403) {
                throw "Clerk отклонил запрос токена (HTTP $code). Cookie аккаунта '$name' устарел или __client прокручен браузером — обновите cookie (girya cookie) и не используйте whizi в браузере параллельно."
            }
            throw "Clerk вернул HTTP $code для '$name': $bodyText"
        }

        # Сохранить ротацию cookie (новый __client и пр.) из Set-Cookie.
        $setCookies = $null
        if ($resp.Headers.TryGetValues('Set-Cookie', [ref]$setCookies)) {
            $merged = Merge-GiryaSetCookies -Cookie $cookie -SetCookies @($setCookies)
            if ($merged) {
                Set-GiryaAccountCookie -Name $name -Cookie $merged | Out-Null
            }
        }
    }
    finally {
        $client.Dispose()
    }

    $respObj = $null
    try { $respObj = $bodyText | ConvertFrom-Json } catch {}
    $jwt = $null
    if ($respObj) {
        if ($respObj.PSObject.Properties.Name -contains 'jwt') { $jwt = [string]$respObj.jwt }
        elseif ($respObj.PSObject.Properties.Name -contains 'token') { $jwt = [string]$respObj.token }
    }
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

# Обрезать текст до N символов с пометкой (whizi режет длинный content по началу).
function Get-GiryaTrimmed {
    param([string] $Text, [int] $Max)
    if ($null -eq $Text) { return '' }
    if ($Max -le 0 -or $Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max) + "`n...[обрезано $($Text.Length - $Max) симв.]"
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

# Свернуть историю диалога (OpenAI messages) в один текст, включая вызовы
# инструментов (tool_calls у assistant) и их результаты (role=tool).
function Convert-GiryaMessagesToContent {
    param([Parameter(Mandatory)][array] $Messages, [bool] $HasTools = $false, [int] $MaxPerMessage = 0)
    $arr = @($Messages)
    if ($arr.Count -eq 1 -and -not $HasTools) {
        $only = $arr[0]
        $hasTC = ($only.PSObject.Properties.Name -contains 'tool_calls') -and $only.tool_calls
        if (-not $hasTC -and [string]$only.role -ne 'tool') {
            return (Get-GiryaMessageText $only.content)
        }
    }
    $sb = [System.Text.StringBuilder]::new()
    foreach ($m in $arr) {
        $roleRaw = [string]$m.role
        $hasTC = ($m.PSObject.Properties.Name -contains 'tool_calls') -and $m.tool_calls
        if ($roleRaw -eq 'tool') {
            $tid = ''
            if ($m.PSObject.Properties.Name -contains 'tool_call_id') { $tid = [string]$m.tool_call_id }
            [void]$sb.AppendLine("РЕЗУЛЬТАТ ИНСТРУМЕНТА (tool_call_id=$tid):")
            [void]$sb.AppendLine((Get-GiryaTrimmed (Get-GiryaMessageText $m.content) $MaxPerMessage))
            [void]$sb.AppendLine()
            continue
        }
        $role = switch ($roleRaw) {
            'system'    { 'System' }
            'assistant' { 'Assistant' }
            'user'      { 'User' }
            default     { $roleRaw }
        }
        $txt = Get-GiryaTrimmed (Get-GiryaMessageText $m.content) $MaxPerMessage
        if ($hasTC) {
            $calls = foreach ($tc in @($m.tool_calls)) {
                $fn = $tc.function
                $a = if ($fn.PSObject.Properties.Name -contains 'arguments') { [string]$fn.arguments } else { '{}' }
                "<tool_call>{""name"":""$($fn.name)"",""arguments"":$a}</tool_call>"
            }
            [void]$sb.AppendLine("${role}:")
            if ($txt) { [void]$sb.AppendLine($txt) }
            [void]$sb.AppendLine(($calls -join "`n"))
        } else {
            [void]$sb.AppendLine("${role}: $txt")
        }
        [void]$sb.AppendLine()
    }
    return $sb.ToString().TrimEnd()
}

# Сформировать инструкцию для модели по работе с инструментами (эмуляция tool-calling).
function Build-GiryaToolsPrompt {
    param([Parameter(Mandatory)][array] $Tools)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('# Режим агента OpenCode — вызов инструментов')
    [void]$sb.AppendLine('Ты решаешь задачу, вызывая инструменты. Чтобы вызвать инструмент, выведи СТРОГО один или несколько блоков:')
    [void]$sb.AppendLine('<tool_call>{"name":"ИМЯ_ИНСТРУМЕНТА","arguments":{...}}</tool_call>')
    [void]$sb.AppendLine('Правила:')
    [void]$sb.AppendLine('- Внутри блока — только валидный JSON. "arguments" — объект строго по схеме инструмента.')
    [void]$sb.AppendLine('- ИСПОЛЬЗУЙ ТОЧНЫЕ имена параметров из схемы (если в схеме "command" — пиши "command", а не "cmd"). Не добавляй параметры, которых нет в схеме.')
    [void]$sb.AppendLine('- "name" должен ТОЧНО совпадать с именем инструмента из списка ниже.')
    [void]$sb.AppendLine('- Если вызываешь инструменты — НЕ пиши никакого другого текста, только блоки <tool_call>.')
    [void]$sb.AppendLine('- Можно вызвать несколько инструментов сразу (несколько блоков подряд).')
    [void]$sb.AppendLine('- НЕ придумывай результаты — дождись ответа инструмента (он придёт как "РЕЗУЛЬТАТ ИНСТРУМЕНТА").')
    [void]$sb.AppendLine('- Когда инструменты больше не нужны и можно ответить пользователю — пиши обычный текст БЕЗ блоков.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Доступные инструменты:')
    foreach ($t in $Tools) {
        $fn = $t.function
        if (-not $fn) { continue }
        [void]$sb.AppendLine("## $($fn.name)")
        if ($fn.PSObject.Properties.Name -contains 'description' -and $fn.description) {
            # Описание режем (whizi ограничивает длину content).
            [void]$sb.AppendLine((Get-GiryaTrimmed ([string]$fn.description) 220))
        }
        if ($fn.PSObject.Properties.Name -contains 'parameters' -and $fn.parameters) {
            $schema = $fn.parameters | ConvertTo-Json -Depth 20 -Compress
            [void]$sb.AppendLine("Параметры (JSON Schema): $schema")
        }
        [void]$sb.AppendLine('')
    }
    return $sb.ToString().TrimEnd()
}

# Разобрать ответ модели на вызовы инструментов. Возвращает массив
# @{ id; name; arguments(строка JSON) } либо пустой массив, если вызовов нет.
function Get-GiryaToolCalls {
    param([Parameter(Mandatory)][string] $Text)
    $calls = @()
    $rx = [regex]'(?s)<tool_call>\s*(\{.*?\})\s*</tool_call>'
    $matches = $rx.Matches($Text)
    $i = 0
    foreach ($mm in $matches) {
        $json = $mm.Groups[1].Value
        $obj = $null
        try { $obj = $json | ConvertFrom-Json } catch { continue }
        if (-not ($obj.PSObject.Properties.Name -contains 'name')) { continue }
        $argStr = '{}'
        if ($obj.PSObject.Properties.Name -contains 'arguments' -and $null -ne $obj.arguments) {
            if ($obj.arguments -is [string]) { $argStr = $obj.arguments }
            else { $argStr = $obj.arguments | ConvertTo-Json -Depth 20 -Compress }
        }
        $calls += @{
            id        = "call_$([guid]::NewGuid().ToString('N').Substring(0,24))"
            name      = [string]$obj.name
            arguments = $argStr
        }
        $i++
    }
    return $calls
}

# Создать новый чат в whizi и вернуть его chat_id.
# whizi не принимает произвольный chat_id — его нужно сначала создать здесь.
function New-WhiziChat {
    param(
        [Parameter(Mandatory)][string] $Jwt,
        [Parameter(Mandatory)][string] $Model,
        [Parameter(Mandatory)][string] $UserId,
        [Parameter(Mandatory)] $Config
    )
    $w = $Config.whizi
    $uri = $w.backendBase.TrimEnd('/') + $w.createChatPath
    $body = @{ user_id = $UserId; model = $Model; title = 'Girya' } | ConvertTo-Json -Depth 6

    Add-Type -AssemblyName System.Net.Http
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    try {
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $uri)
        [void]$req.Headers.TryAddWithoutValidation('Authorization', "Bearer $Jwt")
        [void]$req.Headers.TryAddWithoutValidation('Origin', $w.origin)
        [void]$req.Headers.TryAddWithoutValidation('Referer', $w.origin + '/')
        [void]$req.Headers.TryAddWithoutValidation('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36')
        $req.Content = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, 'application/json')
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        $txt = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $resp.IsSuccessStatusCode) {
            throw "Не удалось создать чат whizi (HTTP $([int]$resp.StatusCode)): $txt"
        }
        $obj = $txt | ConvertFrom-Json
        $id = $null
        foreach ($p in 'chat_id','id','chatId') {
            if ($obj.PSObject.Properties.Name -contains $p -and $obj.$p) { $id = [string]$obj.$p; break }
        }
        if ([string]::IsNullOrWhiteSpace($id)) { throw "Создание чата: в ответе нет chat_id: $txt" }
        return $id
    }
    finally {
        $client.Dispose()
    }
}

# --- Построение тела запроса к бэкенду чата (схема whizi /api/add-message) --
function Build-WhiziRequestBody {
    param(
        [Parameter(Mandatory)][array] $Messages,
        [Parameter(Mandatory)][string] $Model,
        [Parameter(Mandatory)][string] $UserId,
        [Parameter(Mandatory)][string] $ChatId,
        [Parameter(Mandatory)] $Config,
        [array] $Tools
    )
    $hasTools = ($Tools -and @($Tools).Count -gt 0)
    $webSearch = [bool]$Config.whizi.webSearch
    $arr = @($Messages)

    # whizi обрезает длинный content, СОХРАНЯЯ НАЧАЛО. Поэтому важное (инструкции +
    # текущая задача/диалог) ставим в начало, а громоздкий системный промпт OpenCode —
    # обрезанным в конец как фоновый контекст.
    $sysMsgs   = @($arr | Where-Object { [string]$_.role -eq 'system' })
    $convoMsgs = @($arr | Where-Object { [string]$_.role -ne 'system' })

    if ($hasTools) {
        $webSearch = $false   # в режиме агента веб-поиск мешает формату вызовов
        $convo = Convert-GiryaMessagesToContent -Messages $convoMsgs -HasTools $true -MaxPerMessage 3000
        $parts = @()
        $parts += (Build-GiryaToolsPrompt -Tools $Tools)
        $parts += "===== ДИАЛОГ (выполни последний запрос пользователя, вызывая инструменты) =====`n$convo"
        $sysText = ($sysMsgs | ForEach-Object { Get-GiryaMessageText $_.content }) -join "`n"
        if ($sysText) { $parts += "===== ФОНОВЫЙ КОНТЕКСТ OpenCode (справочно) =====`n$(Get-GiryaTrimmed $sysText 1500)" }
        $content = $parts -join "`n`n"
    }
    elseif ($arr.Count -eq 1) {
        $content = Get-GiryaMessageText $arr[0].content
    }
    else {
        $convo = Convert-GiryaMessagesToContent -Messages $convoMsgs -MaxPerMessage 6000
        $sysText = ($sysMsgs | ForEach-Object { Get-GiryaMessageText $_.content }) -join "`n"
        if ($sysText) {
            $content = "===== ДИАЛОГ =====`n$convo`n`n===== ФОНОВЫЙ КОНТЕКСТ (справочно) =====`n$(Get-GiryaTrimmed $sysText 2000)"
        } else {
            $content = $convo
        }
    }
    return @{
        chat_id            = $ChatId
        user_id            = $UserId
        content            = $content
        files              = @()
        image_url          = $null
        model              = $Model
        user_type          = $Config.whizi.userType
        web_search_enabled = $webSearch
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

# --- Основной вызов чата ----------------------------------------------------
# Возвращает хэш: @{ content = <строка|null>; toolCalls = @(...) }.
function Invoke-WhiziChat {
    param(
        [Parameter(Mandatory)][array] $Messages,
        [string] $Model,
        [array] $Tools
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

    # whizi требует существующий chat_id — создаём новый чат на каждый запрос.
    $chatId = New-WhiziChat -Jwt $jwt -Model $Model -UserId $userId -Config $cfg

    $bodyObj  = Build-WhiziRequestBody -Messages $Messages -Model $Model -UserId $userId -ChatId $chatId -Config $cfg -Tools $Tools
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

        # Если были инструменты — пытаемся распознать вызовы в ответе модели.
        if ($Tools -and @($Tools).Count -gt 0) {
            $toolCalls = @(Get-GiryaToolCalls -Text $result)
            if ($toolCalls.Count -gt 0) {
                return @{ content = $null; toolCalls = $toolCalls }
            }
        }
        return @{ content = $result; toolCalls = @() }
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
