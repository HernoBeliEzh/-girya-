# ============================================================================
#  Гиря — bootstrap.ps1  (быстрая установка одной строкой)
#
#  Использование:
#     irm https://raw.githubusercontent.com/HernoBeliEzh/-girya-/main/bootstrap.ps1 | iex
#
#  Скрипт: клонирует репозиторий в %LOCALAPPDATA%\Programs\Girya и запускает Install.ps1.
#  Требуется установленный git (https://git-scm.com/download/win).
# ============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Repo = 'https://github.com/HernoBeliEzh/-girya-.git'

$target = Join-Path $env:LOCALAPPDATA 'Programs\Girya'

Write-Host '=== Быстрая установка Гири ===' -ForegroundColor Yellow

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host 'Не найден git. Установите: https://git-scm.com/download/win' -ForegroundColor Red
    return
}

if (Test-Path $target) {
    Write-Host "Обновляю существующую копию: $target" -ForegroundColor Cyan
    git -C $target pull --ff-only
} else {
    Write-Host "Клонирую в: $target" -ForegroundColor Cyan
    New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
    git clone --depth 1 $Repo $target
}

Write-Host 'Запускаю установку...' -ForegroundColor Cyan
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $target 'Install.ps1')
