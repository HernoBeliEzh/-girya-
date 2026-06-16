# ============================================================================
#  Гиря — Accounts.ps1
#  Управление аккаунтами whizi.io: добавить / удалить / сменить активный / показать.
#  Cookie хранится в зашифрованном виде (DPAPI), привязан к пользователю Windows.
# ============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

# Получить список аккаунтов (как массив объектов).
function Get-GiryaAccounts {
    $cfg = Get-GiryaConfig
    return @($cfg.accounts)
}

# Получить активный аккаунт (или $null).
function Get-GiryaActiveAccount {
    $accounts = Get-GiryaAccounts
    return $accounts | Where-Object { $_.active } | Select-Object -First 1
}

# Получить расшифрованный cookie активного аккаунта.
function Get-GiryaActiveCookie {
    $acc = Get-GiryaActiveAccount
    if ($null -eq $acc) { return $null }
    return Unprotect-GiryaSecret $acc.cookie
}

# Добавить аккаунт. Cookie передаётся в открытом виде, шифруется внутри.
function Add-GiryaAccount {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $Cookie,
        [string] $SessionId = '',
        [string] $UserId = ''
    )
    $cfg = Get-GiryaConfig
    $accounts = @($cfg.accounts)

    if ($accounts | Where-Object { $_.name -eq $Name }) {
        throw "Аккаунт с именем '$Name' уже существует."
    }

    $isFirst = ($accounts.Count -eq 0)
    $new = [pscustomobject]@{
        name      = $Name
        cookie    = Protect-GiryaSecret $Cookie.Trim()
        sessionId = $SessionId   # sess_... (можно оставить пустым — определится автоматически)
        userId    = $UserId      # UUID пользователя whizi (из тела запроса add-message)
        active    = $isFirst     # первый добавленный становится активным
    }
    $cfg.accounts = @($accounts + $new)
    Save-GiryaConfig $cfg
    Write-GiryaOk "Аккаунт '$Name' добавлен$(if($isFirst){' и сделан активным'})."
}

# Сохранить (или обновить) sessionId аккаунта — используется адаптером при автоопределении.
function Set-GiryaAccountSessionId {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $SessionId
    )
    $cfg = Get-GiryaConfig
    $accounts = @($cfg.accounts)
    $acc = $accounts | Where-Object { $_.name -eq $Name }
    if (-not $acc) { return }
    if ($acc.PSObject.Properties.Name -contains 'sessionId') {
        $acc.sessionId = $SessionId
    } else {
        $acc | Add-Member -NotePropertyName sessionId -NotePropertyValue $SessionId -Force
    }
    $cfg.accounts = $accounts
    Save-GiryaConfig $cfg
}

# Обновить cookie аккаунта (шифрует и сохраняет). Используется при ротации токена
# и для ручного обновления cookie без пересоздания аккаунта.
function Set-GiryaAccountCookie {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $Cookie
    )
    $cfg = Get-GiryaConfig
    $accounts = @($cfg.accounts)
    $acc = $accounts | Where-Object { $_.name -eq $Name }
    if (-not $acc) { throw "Аккаунт '$Name' не найден." }
    $acc.cookie = Protect-GiryaSecret $Cookie.Trim()
    $cfg.accounts = $accounts
    Save-GiryaConfig $cfg
}

# Удалить аккаунт по имени.
function Remove-GiryaAccount {
    param([Parameter(Mandatory)][string] $Name)
    $cfg = Get-GiryaConfig
    $accounts = @($cfg.accounts)

    $target = $accounts | Where-Object { $_.name -eq $Name }
    if (-not $target) { throw "Аккаунт '$Name' не найден." }

    $wasActive = [bool]$target.active
    $remaining = @($accounts | Where-Object { $_.name -ne $Name })

    # Если удалили активный — активируем первый оставшийся.
    if ($wasActive -and $remaining.Count -gt 0) {
        $remaining[0].active = $true
    }
    $cfg.accounts = $remaining
    Save-GiryaConfig $cfg
    Write-GiryaOk "Аккаунт '$Name' удалён."
}

# Сделать аккаунт активным (остальные — неактивны).
function Set-GiryaActiveAccount {
    param([Parameter(Mandatory)][string] $Name)
    $cfg = Get-GiryaConfig
    $accounts = @($cfg.accounts)

    if (-not ($accounts | Where-Object { $_.name -eq $Name })) {
        throw "Аккаунт '$Name' не найден."
    }
    foreach ($a in $accounts) {
        $a.active = ($a.name -eq $Name)
    }
    $cfg.accounts = $accounts
    Save-GiryaConfig $cfg
    Write-GiryaOk "Активный аккаунт: '$Name'."
}

# Показать аккаунты в виде таблицы (cookie не раскрывается).
function Show-GiryaAccounts {
    $accounts = @(Get-GiryaAccounts)
    if ($accounts.Count -eq 0) {
        Write-GiryaWarn 'Аккаунты не добавлены. Используйте "Добавить аккаунт".'
        return
    }
    $accounts | ForEach-Object {
        [pscustomobject]@{
            'Активный' = if ($_.active) { '  ✓' } else { '' }
            'Имя'      = $_.name
            'Cookie'   = '*** (зашифрован)'
        }
    } | Format-Table -AutoSize | Out-Host
}
