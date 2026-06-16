# ============================================================================
#  Гиря — Server.ps1
#  Локальный OpenAI-совместимый HTTP-сервер. Принимает запросы от OpenCode и
#  любых OpenAI-клиентов, проксирует их в whizi.io через адаптер.
#
#  Поддержка:
#    GET  /v1/models
#    POST /v1/chat/completions   (stream: true|false)
#    GET  /            (страница статуса)
#  Авторизация: заголовок  Authorization: Bearer <единый ключ Гири>.
# ============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Accounts.ps1')
. (Join-Path $PSScriptRoot 'Whizi.ps1')

function Send-GiryaJson {
    param($Context, [int]$Status, $Object)
    $json  = $Object | ConvertTo-Json -Depth 20 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $resp  = $Context.Response
    $resp.StatusCode  = $Status
    $resp.ContentType = 'application/json; charset=utf-8'
    $resp.ContentLength64 = $bytes.Length
    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
    $resp.OutputStream.Close()
}

function Send-GiryaText {
    param($Context, [int]$Status, [string]$Text, [string]$ContentType = 'text/plain; charset=utf-8')
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $resp  = $Context.Response
    $resp.StatusCode  = $Status
    $resp.ContentType = $ContentType
    $resp.ContentLength64 = $bytes.Length
    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
    $resp.OutputStream.Close()
}

# Проверка Bearer-токена против единого ключа Гири.
function Test-GiryaAuth {
    param($Context, [string]$ApiKey)
    $auth = $Context.Request.Headers['Authorization']
    if ([string]::IsNullOrWhiteSpace($auth)) { return $false }
    if ($auth -notmatch '^Bearer\s+(.+)$') { return $false }
    return ($Matches[1].Trim() -eq $ApiKey)
}

# Сформировать объект модели в формате OpenAI.
function New-GiryaModelObject {
    param([string]$Id)
    [pscustomobject]@{
        id       = $Id
        object   = 'model'
        created  = 1700000000
        owned_by = 'girya'
    }
}

# Построить JSON-массив tool_calls (ВСЕГДА в квадратных скобках, даже для 1 элемента —
# ConvertTo-Json в PS схлопывает массив из одного элемента в объект, а OpenCode ждёт массив).
function Get-GiryaToolCallsJson {
    param($ToolCalls)
    $i = 0
    $items = foreach ($t in @($ToolCalls)) {
        $obj = [pscustomobject]@{
            index    = $i
            id       = $t.id
            type     = 'function'
            function = [pscustomobject]@{ name = $t.name; arguments = $t.arguments }
        }
        $i++
        $obj | ConvertTo-Json -Depth 20 -Compress
    }
    return '[' + (@($items) -join ',') + ']'
}

# Стриминг ответа в формате OpenAI SSE (text/event-stream).
function Send-GiryaStream {
    param($Context, [string]$Model, [string]$Content, $ToolCalls = @())

    $resp = $Context.Response
    $resp.StatusCode  = 200
    $resp.ContentType = 'text/event-stream; charset=utf-8'
    $resp.Headers.Add('Cache-Control', 'no-cache')
    $resp.SendChunked = $true
    $stream = $resp.OutputStream

    $id = "chatcmpl-girya-$([guid]::NewGuid().ToString('N').Substring(0,12))"

    function Write-Chunk([string]$data) {
        $line  = "data: $data`n`n"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($line)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    }

    # Первый чанк с ролью.
    $first = @{
        id = $id; object = 'chat.completion.chunk'; created = 1700000000; model = $Model
        choices = @(@{ index = 0; delta = @{ role = 'assistant' }; finish_reason = $null })
    } | ConvertTo-Json -Depth 10 -Compress
    Write-Chunk $first

    $tc = @($ToolCalls)
    if ($tc.Count -gt 0) {
        # Вызовы инструментов: один чанк с delta.tool_calls (массив гарантируем подстановкой).
        $callsJson = Get-GiryaToolCallsJson -ToolCalls $tc
        $obj = @{
            id = $id; object = 'chat.completion.chunk'; created = 1700000000; model = $Model
            choices = @(@{ index = 0; delta = @{ tool_calls = '__TOOLCALLS__' }; finish_reason = $null })
        } | ConvertTo-Json -Depth 20 -Compress
        $obj = $obj.Replace('"__TOOLCALLS__"', $callsJson)
        Write-Chunk $obj
        $finish = 'tool_calls'
    } else {
        # Контент разбиваем на небольшие части, чтобы клиент видел «печать».
        $chunkSize = 24
        for ($i = 0; $i -lt $Content.Length; $i += $chunkSize) {
            $piece = $Content.Substring($i, [Math]::Min($chunkSize, $Content.Length - $i))
            $obj = @{
                id = $id; object = 'chat.completion.chunk'; created = 1700000000; model = $Model
                choices = @(@{ index = 0; delta = @{ content = $piece }; finish_reason = $null })
            } | ConvertTo-Json -Depth 10 -Compress
            Write-Chunk $obj
        }
        $finish = 'stop'
    }

    $last = @{
        id = $id; object = 'chat.completion.chunk'; created = 1700000000; model = $Model
        choices = @(@{ index = 0; delta = @{}; finish_reason = $finish })
    } | ConvertTo-Json -Depth 10 -Compress
    Write-Chunk $last

    Write-Chunk '[DONE]'
    $stream.Close()
}

# Полный (нестриминговый) ответ в формате OpenAI.
function Send-GiryaCompletion {
    param($Context, [string]$Model, [string]$Content, $ToolCalls = @())
    $tc = @($ToolCalls)
    $completionTokens = [int]([Math]::Ceiling((([string]$Content).Length + 1) / 4.0))
    if ($tc.Count -gt 0) {
        $callsJson = Get-GiryaToolCallsJson -ToolCalls $tc
        $obj = [pscustomobject]@{
            id      = "chatcmpl-girya-$([guid]::NewGuid().ToString('N').Substring(0,12))"
            object  = 'chat.completion'; created = 1700000000; model = $Model
            choices = @([pscustomobject]@{
                index = 0
                message = [pscustomobject][ordered]@{ role = 'assistant'; content = $null; tool_calls = '__TOOLCALLS__' }
                finish_reason = 'tool_calls'
            })
            usage = [pscustomobject]@{ prompt_tokens = 0; completion_tokens = $completionTokens; total_tokens = $completionTokens }
        }
        $json = ($obj | ConvertTo-Json -Depth 20 -Compress).Replace('"__TOOLCALLS__"', $callsJson)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $r = $Context.Response
        $r.StatusCode = 200; $r.ContentType = 'application/json; charset=utf-8'; $r.ContentLength64 = $bytes.Length
        $r.OutputStream.Write($bytes, 0, $bytes.Length); $r.OutputStream.Close()
        return
    }
    $obj = [pscustomobject]@{
        id      = "chatcmpl-girya-$([guid]::NewGuid().ToString('N').Substring(0,12))"
        object  = 'chat.completion'
        created = 1700000000
        model   = $Model
        choices = @(
            [pscustomobject]@{
                index         = 0
                message       = [pscustomobject]@{ role = 'assistant'; content = $Content }
                finish_reason = 'stop'
            }
        )
        usage   = [pscustomobject]@{
            prompt_tokens     = 0
            completion_tokens = $completionTokens
            total_tokens      = $completionTokens
        }
    }
    Send-GiryaJson -Context $Context -Status 200 -Object $obj
}

# Основной цикл сервера.
function Start-GiryaServer {
    param(
        [string]$ListenHost,
        [int]$Port
    )
    $cfg = Get-GiryaConfig
    if (-not $ListenHost) { $ListenHost = $cfg.server.host }
    if (-not $Port)       { $Port = [int]$cfg.server.port }
    $apiKey = $cfg.apiKey

    $prefix = "http://$ListenHost`:$Port/"
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($prefix)

    try {
        $listener.Start()
    }
    catch {
        Write-GiryaError "Не удалось запустить сервер на $prefix"
        Write-GiryaError $_.Exception.Message
        Write-GiryaWarn  "Если занят порт — поменяйте его в настройках. Для адреса, отличного от 127.0.0.1, запустите PowerShell от администратора."
        return
    }

    Write-GiryaOk   "Сервер Гиря запущен: $prefix"
    Write-GiryaInfo "OpenAI Base URL : http://$ListenHost`:$Port/v1"
    Write-GiryaInfo "API-ключ        : $apiKey"
    $active = Get-GiryaActiveAccount
    if ($active) { Write-GiryaInfo "Активный аккаунт: $($active.name)" }
    else { Write-GiryaWarn "Активный аккаунт whizi не задан — запросы будут отклонены." }
    Write-GiryaInfo 'Остановить: Ctrl+C'
    Write-Host ''

    while ($listener.IsListening) {
        $context = $listener.GetContext()
        try {
            $req  = $context.Request
            $path = $req.Url.AbsolutePath.TrimEnd('/')
            if ([string]::IsNullOrEmpty($path)) { $path = '/' }
            $method = $req.HttpMethod

            Write-GiryaInfo "$method $($req.Url.AbsolutePath)"

            # Страница статуса (без авторизации).
            if ($path -eq '/' -and $method -eq 'GET') {
                Send-GiryaText -Context $context -Status 200 -Text "Гиря — мост к whizi.io работает. OpenAI API: /v1"
                continue
            }

            # --- /v1/models ---
            if ($path -eq '/v1/models' -and $method -eq 'GET') {
                if (-not (Test-GiryaAuth -Context $context -ApiKey $apiKey)) {
                    Send-GiryaJson -Context $context -Status 401 -Object @{ error = @{ message = 'Неверный API-ключ'; type = 'invalid_request_error' } }
                    continue
                }
                $data = @(Get-WhiziModels | ForEach-Object { New-GiryaModelObject -Id $_ })
                Send-GiryaJson -Context $context -Status 200 -Object @{ object = 'list'; data = $data }
                continue
            }

            # --- /v1/chat/completions ---
            if ($path -eq '/v1/chat/completions' -and $method -eq 'POST') {
                if (-not (Test-GiryaAuth -Context $context -ApiKey $apiKey)) {
                    Send-GiryaJson -Context $context -Status 401 -Object @{ error = @{ message = 'Неверный API-ключ'; type = 'invalid_request_error' } }
                    continue
                }

                $reader = [System.IO.StreamReader]::new($req.InputStream, [System.Text.Encoding]::UTF8)
                $bodyRaw = $reader.ReadToEnd()
                $reader.Close()

                try { $body = $bodyRaw | ConvertFrom-Json }
                catch {
                    Send-GiryaJson -Context $context -Status 400 -Object @{ error = @{ message = 'Некорректный JSON'; type = 'invalid_request_error' } }
                    continue
                }

                $messages = @($body.messages)
                $model    = if ($body.PSObject.Properties.Name -contains 'model' -and $body.model) { [string]$body.model } else { '' }
                $stream   = ($body.PSObject.Properties.Name -contains 'stream') -and ([bool]$body.stream)
                $tools    = @()
                if ($body.PSObject.Properties.Name -contains 'tools' -and $body.tools) { $tools = @($body.tools) }

                # Отладочный лог: сохраняем последний запрос (включая tools) для диагностики.
                if ($cfg.PSObject.Properties.Name -contains 'debug' -and $cfg.debug) {
                    try {
                        $dbg = Join-Path $script:GiryaDataDir 'debug.log'
                        $toolNames = @($tools | ForEach-Object { $_.function.name }) -join ', '
                        $line = "REQUEST stream=$stream tools=$(@($tools).Count) [$toolNames]`n$bodyRaw`n"
                        Set-Content -LiteralPath $dbg -Value $line -Encoding UTF8
                    } catch {}
                }

                try {
                    $res = Invoke-WhiziChat -Messages $messages -Model $model -Tools $tools
                }
                catch {
                    Send-GiryaJson -Context $context -Status 502 -Object @{ error = @{ message = $_.Exception.Message; type = 'upstream_error' } }
                    continue
                }

                if ($cfg.PSObject.Properties.Name -contains 'debug' -and $cfg.debug) {
                    try {
                        $dbg = Join-Path $script:GiryaDataDir 'debug.log'
                        $add = "`n---RESULT--- toolCalls=$(@($res.toolCalls).Count)`ncontent: $([string]$res.content)`ntoolCalls: $((@($res.toolCalls) | ForEach-Object { $_.name + ' ' + $_.arguments }) -join ' | ')`n"
                        Add-Content -LiteralPath $dbg -Value $add -Encoding UTF8
                    } catch {}
                }

                $replyModel = if ($model) { $model } else { (Get-GiryaConfig).whizi.defaultModel }
                $toolCalls  = @($res.toolCalls)
                if ($stream) {
                    Send-GiryaStream     -Context $context -Model $replyModel -Content ([string]$res.content) -ToolCalls $toolCalls
                } else {
                    Send-GiryaCompletion -Context $context -Model $replyModel -Content ([string]$res.content) -ToolCalls $toolCalls
                }
                continue
            }

            # Неизвестный маршрут.
            Send-GiryaJson -Context $context -Status 404 -Object @{ error = @{ message = "Не найдено: $path"; type = 'invalid_request_error' } }
        }
        catch {
            Write-GiryaError "Ошибка обработки запроса: $($_.Exception.Message)"
            try { Send-GiryaJson -Context $context -Status 500 -Object @{ error = @{ message = $_.Exception.Message; type = 'server_error' } } } catch {}
        }
    }
}
