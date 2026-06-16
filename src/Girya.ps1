# ============================================================================
#  Гиря — Girya.ps1
#  Главная программа. Интерактивное меню + CLI-команды.
#  Мост между whizi.io и OpenAI-совместимыми клиентами (OpenCode и др.).
#
#  Запуск меню:           powershell -ExecutionPolicy Bypass -File Girya.ps1
#  CLI-примеры:
#     .\Girya.ps1 add     -Name "main" -Cookie "session=..."
#     .\Girya.ps1 remove  -Name "main"
#     .\Girya.ps1 use     -Name "main"
#     .\Girya.ps1 list
#     .\Girya.ps1 serve
#     .\Girya.ps1 key     [-Regenerate]
#     .\Girya.ps1 config
# ============================================================================

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu','add','remove','use','list','serve','key','config','opencode','model','websearch')]
    [string] $Command = 'menu',

    [string] $Name,
    [string] $Cookie,
    [string] $SessionId,
    [string] $UserId,
    [string] $Model,
    [ValidateSet('on','off','')]
    [string] $State = '',
    [string] $ListenHost,
    [int]    $Port,
    [switch] $Regenerate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Accounts.ps1')
. (Join-Path $PSScriptRoot 'Whizi.ps1')
. (Join-Path $PSScriptRoot 'Server.ps1')

# --- Вспомогательные действия ----------------------------------------------

function Show-GiryaBanner {
    Write-Host ''
    Write-Host '   ____ _                 ' -ForegroundColor DarkYellow
    Write-Host '  / ___(_)_ __ _   _  __ _ ' -ForegroundColor DarkYellow
    Write-Host ' | |  _| | __ | | | |/ _` |' -ForegroundColor Yellow
    Write-Host ' | |_| | | |  | |_| | (_| |' -ForegroundColor Yellow
    Write-Host '  \____|_|_|   \__, |\__,_|' -ForegroundColor Yellow
    Write-Host '              |___/        ' -ForegroundColor Yellow
    Write-Host '  Мост whizi.io <-> OpenAI API' -ForegroundColor Gray
    Write-Host ''
}

function Show-GiryaKey {
    param([switch]$Regenerate)
    $cfg = Get-GiryaConfig
    if ($Regenerate) {
        $cfg.apiKey = New-GiryaApiKey
        Save-GiryaConfig $cfg
        Write-GiryaOk 'Сгенерирован новый API-ключ.'
    }
    Write-Host ''
    Write-Host 'Единый OpenAI-совместимый API-ключ:' -ForegroundColor Cyan
    Write-Host "  $($cfg.apiKey)" -ForegroundColor White
    Write-Host ''
    Write-Host "Base URL:  http://$($cfg.server.host):$($cfg.server.port)/v1" -ForegroundColor Cyan
    Write-Host ''
}

function Show-GiryaConfigInfo {
    $cfg = Get-GiryaConfig
    Write-Host ''
    Write-Host 'Текущая конфигурация Гири:' -ForegroundColor Cyan
    Write-Host "  Файл конфигурации : $script:GiryaConfigPath"
    Write-Host "  Base URL          : http://$($cfg.server.host):$($cfg.server.port)/v1"
    Write-Host "  API-ключ          : $($cfg.apiKey)"
    Write-Host "  Бэкенд            : $($cfg.whizi.backendBase)$($cfg.whizi.chatPath)"
    Write-Host "  Clerk             : $($cfg.whizi.clerkBase)"
    Write-Host "  Модель по умолч.  : $($cfg.whizi.defaultModel)"
    Write-Host "  Веб-поиск         : $(if($cfg.whizi.webSearch){'включён'}else{'выключен'})"
    Write-Host "  Аккаунтов         : $(@($cfg.accounts).Count)"
    Write-Host ''
}

# Показать / сменить модель по умолчанию.
function Show-GiryaModel {
    param([string]$Model)
    $cfg = Get-GiryaConfig
    if ($Model) {
        Set-GiryaDefaultModel -Model $Model
        Write-GiryaOk "Модель по умолчанию: '$Model'."
        return
    }
    Write-Host ''
    Write-Host "Текущая модель: $($cfg.whizi.defaultModel)" -ForegroundColor Cyan
    Write-Host 'Доступные модели:' -ForegroundColor Cyan
    $i = 1
    foreach ($m in @($cfg.whizi.models)) {
        $mark = if ($m -eq $cfg.whizi.defaultModel) { ' *' } else { '  ' }
        Write-Host ("  $i)$mark $m")
        $i++
    }
    Write-Host ''
}

# Интерактивная смена модели (меню).
function Invoke-MenuModel {
    $cfg = Get-GiryaConfig
    Show-GiryaModel
    Write-Host 'Введите номер модели из списка или впишите своё имя (формат "провайдер модель").' -ForegroundColor Cyan
    $ans = Read-Host 'Модель'
    if ([string]::IsNullOrWhiteSpace($ans)) { Write-GiryaWarn 'Отменено.'; return }
    $models = @($cfg.whizi.models)
    $num = 0
    if ([int]::TryParse($ans, [ref]$num) -and $num -ge 1 -and $num -le $models.Count) {
        $ans = $models[$num - 1]
    }
    Set-GiryaDefaultModel -Model $ans
    Write-GiryaOk "Модель по умолчанию: '$ans'."
}

# Показать / переключить веб-поиск.
function Show-GiryaWebSearch {
    param([string]$State)
    $cfg = Get-GiryaConfig
    if ($State -eq 'on')  { Set-GiryaWebSearch -Enabled $true;  Write-GiryaOk 'Веб-поиск включён.';  return }
    if ($State -eq 'off') { Set-GiryaWebSearch -Enabled $false; Write-GiryaOk 'Веб-поиск выключен.'; return }
    Write-Host "Веб-поиск сейчас: $(if($cfg.whizi.webSearch){'включён'}else{'выключен'})" -ForegroundColor Cyan
}

function Invoke-MenuWebSearch {
    $cfg = Get-GiryaConfig
    $new = -not [bool]$cfg.whizi.webSearch
    Set-GiryaWebSearch -Enabled $new
    Write-GiryaOk "Веб-поиск $(if($new){'включён'}else{'выключен'})."
}

# Печатает готовый блок настройки OpenCode (с вшитым API-ключом — копипаст готов).
function Show-GiryaOpenCode {
    $cfg = Get-GiryaConfig
    $base = "http://$($cfg.server.host):$($cfg.server.port)/v1"
    $modelLines = @($cfg.whizi.models | ForEach-Object { "        `"$_`": { `"name`": `"$_`" }" }) -join ",`n"
    $cfgPath = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'
    Write-Host ''
    Write-Host "Вставьте в файл OpenCode: $cfgPath" -ForegroundColor Cyan
    $sample = @"
{
  "`$schema": "https://opencode.ai/config.json",
  "provider": {
    "girya": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Гиря (whizi)",
      "options": {
        "baseURL": "$base",
        "apiKey": "$($cfg.apiKey)"
      },
      "models": {
$modelLines
      }
    }
  }
}
"@
    Write-Host $sample -ForegroundColor White
    Write-Host ''
    Write-Host 'Дальше: запустите "girya serve", в OpenCode выберите модель провайдера "Гиря (whizi)".' -ForegroundColor Cyan
    Write-Host ''
}

# --- Интерактивные обёртки --------------------------------------------------

function Invoke-MenuAddAccount {
    $name = Read-Host 'Имя аккаунта'
    if ([string]::IsNullOrWhiteSpace($name)) { Write-GiryaWarn 'Отменено.'; return }
    Write-Host 'Cookie из запроса к clerk.whizi.io (DevTools -> Network -> запрос .../tokens -> заголовок Cookie):' -ForegroundColor Cyan
    $cookie = Read-Host 'Cookie'
    if ([string]::IsNullOrWhiteSpace($cookie)) { Write-GiryaWarn 'Пустой cookie — отменено.'; return }
    Write-Host 'User ID — UUID из тела запроса add-message (поле "user_id").' -ForegroundColor Cyan
    $uid = Read-Host 'User ID (UUID whizi)'
    if ([string]::IsNullOrWhiteSpace($uid)) { Write-GiryaWarn 'Без User ID запросы не пройдут, но аккаунт добавлю — заполните позже.' }
    $sid = Read-Host 'Session ID (sess_..., можно оставить пустым — определю автоматически)'
    Add-GiryaAccount -Name $name -Cookie $cookie -SessionId $sid -UserId $uid
}

function Invoke-MenuRemoveAccount {
    Show-GiryaAccounts
    $name = Read-Host 'Имя аккаунта для удаления'
    if ([string]::IsNullOrWhiteSpace($name)) { Write-GiryaWarn 'Отменено.'; return }
    Remove-GiryaAccount -Name $name
}

function Invoke-MenuUseAccount {
    Show-GiryaAccounts
    $name = Read-Host 'Имя аккаунта, сделать активным'
    if ([string]::IsNullOrWhiteSpace($name)) { Write-GiryaWarn 'Отменено.'; return }
    Set-GiryaActiveAccount -Name $name
}

function Show-GiryaMenu {
    Show-GiryaBanner
    while ($true) {
        Write-Host '--------------------------------------------' -ForegroundColor DarkGray
        Write-Host ' 1) Показать аккаунты'        -ForegroundColor White
        Write-Host ' 2) Добавить аккаунт (cookie)' -ForegroundColor White
        Write-Host ' 3) Удалить аккаунт'           -ForegroundColor White
        Write-Host ' 4) Сменить активный аккаунт'  -ForegroundColor White
        Write-Host ' 5) Сменить модель'            -ForegroundColor White
        Write-Host ' 6) Веб-поиск (вкл/выкл)'      -ForegroundColor White
        Write-Host ' 7) Показать API-ключ / Base URL' -ForegroundColor White
        Write-Host ' 8) Перегенерировать API-ключ' -ForegroundColor White
        Write-Host ' 9) Настройка OpenCode'        -ForegroundColor White
        Write-Host ' c) Показать конфигурацию'     -ForegroundColor White
        Write-Host ' s) Запустить локальный сервер' -ForegroundColor Green
        Write-Host ' 0) Выход'                     -ForegroundColor White
        Write-Host '--------------------------------------------' -ForegroundColor DarkGray
        $choice = Read-Host 'Выбор'

        try {
            switch ($choice) {
                '1' { Show-GiryaAccounts }
                '2' { Invoke-MenuAddAccount }
                '3' { Invoke-MenuRemoveAccount }
                '4' { Invoke-MenuUseAccount }
                '5' { Invoke-MenuModel }
                '6' { Invoke-MenuWebSearch }
                '7' { Show-GiryaKey }
                '8' { Show-GiryaKey -Regenerate }
                '9' { Show-GiryaOpenCode }
                'c' { Show-GiryaConfigInfo }
                's' { Start-GiryaServer }
                '0' { Write-GiryaInfo 'До встречи!'; return }
                default { Write-GiryaWarn 'Неизвестный пункт.' }
            }
        }
        catch {
            Write-GiryaError $_.Exception.Message
        }
        Write-Host ''
    }
}

# --- Точка входа: разбор команды -------------------------------------------

# Гарантируем, что конфиг и ключ существуют при первом запуске.
[void](Get-GiryaConfig)

switch ($Command) {
    'menu'   { Show-GiryaMenu }
    'add'    {
        if (-not $Name)   { $Name   = Read-Host 'Имя аккаунта' }
        if (-not $Cookie) { $Cookie = Read-Host 'Cookie' }
        if (-not $UserId) { $UserId = Read-Host 'User ID (UUID whizi из тела add-message)' }
        Add-GiryaAccount -Name $Name -Cookie $Cookie -SessionId $SessionId -UserId $UserId
    }
    'remove' {
        if (-not $Name) { $Name = Read-Host 'Имя аккаунта' }
        Remove-GiryaAccount -Name $Name
    }
    'use'    {
        if (-not $Name) { $Name = Read-Host 'Имя аккаунта' }
        Set-GiryaActiveAccount -Name $Name
    }
    'list'   { Show-GiryaAccounts }
    'serve'  { Start-GiryaServer -ListenHost $ListenHost -Port $Port }
    'key'    { Show-GiryaKey -Regenerate:$Regenerate }
    'config' { Show-GiryaConfigInfo }
    'opencode' { Show-GiryaOpenCode }
    'model'    { Show-GiryaModel -Model $Model }
    'websearch' { Show-GiryaWebSearch -State $State }
}
