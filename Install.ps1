# ============================================================================
#  Гиря — Install.ps1
#  Полная настройка в PowerShell: проверка окружения, создание конфига и ключа,
#  опциональное добавление первого аккаунта, регистрация ярлыков-команд.
#
#  Запуск:
#     powershell -ExecutionPolicy Bypass -File Install.ps1
# ============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'src\Common.ps1')
. (Join-Path $PSScriptRoot 'src\Accounts.ps1')

Write-Host ''
Write-Host '=== Установка и настройка Гири ===' -ForegroundColor Yellow
Write-Host ''

# 1. Проверка версии PowerShell.
$psv = $PSVersionTable.PSVersion
Write-GiryaInfo "PowerShell версии $psv"
if ($psv.Major -lt 5) {
    Write-GiryaError 'Требуется PowerShell 5.1 или новее (входит в Windows 10/11).'
    return
}

# 2. Инициализация данных и ключа.
$cfg = Get-GiryaConfig   # создаст config.json + apiKey при первом запуске
Write-GiryaOk "Каталог данных: $script:GiryaDataDir"
Write-GiryaOk "Файл конфигурации: $script:GiryaConfigPath"
Write-GiryaOk "API-ключ: $($cfg.apiKey)"

# 3. Предложить добавить первый аккаунт.
Write-Host ''
$ans = Read-Host 'Добавить аккаунт whizi сейчас? (cookie из браузера) [y/N]'
if ($ans -match '^(y|yes|д|да)$') {
    $name = Read-Host 'Имя аккаунта'
    Write-Host 'Cookie: whizi.io -> F12 -> Network -> запрос к clerk.whizi.io (.../tokens) ->' -ForegroundColor Cyan
    Write-Host 'заголовок Cookie -> скопируйте целиком.' -ForegroundColor Cyan
    $cookie = Read-Host 'Cookie'
    Write-Host 'User ID: тот же раздел Network -> запрос add-message -> Полезная нагрузка -> поле "user_id".' -ForegroundColor Cyan
    $uid = Read-Host 'User ID (UUID whizi)'
    if (-not [string]::IsNullOrWhiteSpace($name) -and -not [string]::IsNullOrWhiteSpace($cookie)) {
        Add-GiryaAccount -Name $name -Cookie $cookie -UserId $uid
    } else {
        Write-GiryaWarn 'Аккаунт не добавлен (пустые данные).'
    }
}

# 4. Зарегистрировать команду 'girya' в текущем пользователе (PATH через ярлык-обёртку).
$binDir = Join-Path $script:GiryaDataDir 'bin'
if (-not (Test-Path $binDir)) { New-Item -ItemType Directory -Path $binDir -Force | Out-Null }
$launcher = Join-Path $binDir 'girya.cmd'
$giryaPs1 = Join-Path $PSScriptRoot 'src\Girya.ps1'
@"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$giryaPs1" %*
"@ | Set-Content -LiteralPath $launcher -Encoding ASCII

# Добавить bin в пользовательский PATH, если ещё нет.
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -notlike "*$binDir*") {
    [Environment]::SetEnvironmentVariable('Path', "$userPath;$binDir", 'User')
    Write-GiryaOk "Команда 'girya' добавлена в PATH (перезапустите терминал)."
} else {
    Write-GiryaOk "Команда 'girya' уже доступна."
}

Write-Host ''
Write-Host '=== Установка завершена ===' -ForegroundColor Green
Write-Host 'Запуск меню:        ' -NoNewline; Write-Host 'girya' -ForegroundColor White
Write-Host 'Запуск сервера:     ' -NoNewline; Write-Host 'girya serve' -ForegroundColor White
Write-Host 'Или двойной клик по ' -NoNewline; Write-Host 'Гиря.cmd' -ForegroundColor White
Write-Host ''
