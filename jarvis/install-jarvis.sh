#!/usr/bin/env bash
# =============================================================================
#  install-jarvis.sh – Lokales "Jarvis"-Sprachassistenz-System
# -----------------------------------------------------------------------------
#  Ziel:     Ubuntu Server 24.04 LTS (x86_64, z. B. i5 7th Gen, 8 GB RAM)
#  Aufruf:   sudo bash install-jarvis.sh
#
#  Installiert / konfiguriert:
#    1. Docker Engine + Docker Compose Plugin (offizielles get.docker.com)
#    2. Home Assistant (Supervised, Fallback: Container – siehe HA_MODE)
#    3. Ollama (Docker, Port 11434) + LLM-Modell (Standard: qwen2.5:3b)
#    4. Whisper / faster-whisper (Wyoming, Docker, Port 10300)  – Speech-to-Text
#    5. Piper (Wyoming, Docker, Port 10200)                     – Text-to-Speech
#       (+ openWakeWord mit "hey_jarvis", Port 10400           – Wake-Word)
#    6. HACS (Home Assistant Community Store)
#    7. wake_on_lan: in configuration.yaml
#    8. systemd-Units für alle Jarvis-Container (Autostart beim Booten)
#    9. Ausgabe der IP + generierte README.md mit den nächsten Schritten
#
#  Das Skript ist idempotent: Jeder Schritt prüft zuerst, ob er schon erledigt
#  ist, und wird dann übersprungen. Mehrfaches Ausführen ist unbedenklich.
#
#  Anpassbar per Umgebungsvariable, z. B.:
#    sudo OLLAMA_MODEL=llama3.2:3b HA_MODE=container bash install-jarvis.sh
# =============================================================================

set -Eeuo pipefail

# -----------------------------------------------------------------------------
# Konfiguration (per Umgebungsvariable überschreibbar)
# -----------------------------------------------------------------------------
JARVIS_DIR="${JARVIS_DIR:-/opt/jarvis}"            # Basisverzeichnis
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5:3b}"         # alternativ: llama3.2:3b
TIMEZONE="${TIMEZONE:-Europe/Berlin}"
WHISPER_MODEL="${WHISPER_MODEL:-small-int8}"       # tiny-int8 = schneller, small-int8 = genauer
WHISPER_LANG="${WHISPER_LANG:-de}"
PIPER_VOICE="${PIPER_VOICE:-de_DE-thorsten-medium}"
WAKEWORD="${WAKEWORD:-hey_jarvis}"
# HA_MODE:
#   supervised – Home Assistant Supervised (wie gewünscht; auf Ubuntu offiziell
#                "unsupported", Supervised ist seit 2025.12 deprecated)
#   container  – Home Assistant Core als Docker-Container (robust, empfohlen,
#                aber ohne Add-on-Store)
HA_MODE="${HA_MODE:-supervised}"
HA_LEGACY_INSTALLER_URL="https://raw.githubusercontent.com/home-assistant/supervised-installer/master/installer.sh"
HA_MACHINE="${HA_MACHINE:-generic-x86-64}"
HA_WAIT_SECONDS="${HA_WAIT_SECONDS:-1200}"         # max. Wartezeit auf HA-Start

COMPOSE_FILE="${JARVIS_DIR}/docker-compose.yml"
LOG_FILE="/var/log/install-jarvis.log"

# Der "echte" Benutzer (nicht root), auch wenn per sudo aufgerufen
TARGET_USER="${SUDO_USER:-${USER:-root}}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6 || echo /root)"

# -----------------------------------------------------------------------------
# Hilfsfunktionen für Statusmeldungen
# -----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_BLUE=$'\e[1;34m'; C_GREEN=$'\e[1;32m'; C_YELLOW=$'\e[1;33m'
  C_RED=$'\e[1;31m'; C_RESET=$'\e[0m'
else
  C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_RESET=""
fi

STEP_NO=0
step() { STEP_NO=$((STEP_NO + 1)); echo; echo "${C_BLUE}==> [Schritt ${STEP_NO}] $*${C_RESET}"; }
ok()   { echo "${C_GREEN}  [OK]${C_RESET}        $*"; }
skip() { echo "${C_YELLOW}  [ÜBERSPRUNGEN]${C_RESET} $*"; }
info() { echo "  [INFO]      $*"; }
warn() { echo "${C_YELLOW}  [WARNUNG]${C_RESET}   $*" >&2; }
die()  { echo "${C_RED}  [FEHLER]${C_RESET}    $*" >&2; exit 1; }

# Bei unerwartetem Fehler: Zeile + Befehl ausgeben
trap 'echo "${C_RED}  [FEHLER]${C_RESET} Abbruch in Zeile ${LINENO}: ${BASH_COMMAND}" >&2' ERR

# Alle Ausgaben zusätzlich ins Logfile schreiben
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

# Wartet, bis eine URL antwortet (max. $2 Sekunden)
wait_for_url() {
  local url="$1" timeout="${2:-120}" waited=0
  until curl -fsS -o /dev/null "$url" 2>/dev/null; do
    sleep 3; waited=$((waited + 3))
    (( waited >= timeout )) && return 1
  done
  return 0
}

# Wartet, bis eine Datei existiert (max. $2 Sekunden)
wait_for_file() {
  local file="$1" timeout="${2:-120}" waited=0
  until [[ -f "$file" ]]; do
    sleep 5; waited=$((waited + 5))
    (( waited >= timeout )) && return 1
    (( waited % 60 == 0 )) && info "warte weiterhin auf ${file} (${waited}s) …"
  done
  return 0
}

# Primäre IPv4-Adresse ermitteln (Interface der Default-Route)
get_ip() {
  local addr
  addr="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  [[ -n "$addr" ]] || addr="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo "$addr"
}

# =============================================================================
# Schritt 0: Vorabprüfungen
# =============================================================================
step "Vorabprüfungen"
[[ $EUID -eq 0 ]] || die "Bitte mit sudo/als root ausführen: sudo bash $0"
[[ "$(uname -m)" == "x86_64" ]] || die "Dieses Skript ist für x86_64 ausgelegt (gefunden: $(uname -m))."
# shellcheck disable=SC1091
. /etc/os-release
if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
  warn "Getestet für Ubuntu 24.04 – gefunden: ${PRETTY_NAME:-unbekannt}. Fahre trotzdem fort."
fi
[[ "$HA_MODE" == "supervised" || "$HA_MODE" == "container" ]] || die "HA_MODE muss 'supervised' oder 'container' sein."
ok "root, $(uname -m), ${PRETTY_NAME:-?}, Zielbenutzer: ${TARGET_USER}, HA_MODE=${HA_MODE}"

# =============================================================================
# Schritt 1: Zeitzone & Basispakete
# =============================================================================
step "Zeitzone auf ${TIMEZONE} setzen"
if [[ "$(timedatectl show -p Timezone --value 2>/dev/null)" == "$TIMEZONE" ]]; then
  skip "Zeitzone ist bereits ${TIMEZONE}"
else
  timedatectl set-timezone "$TIMEZONE"
  ok "Zeitzone gesetzt: $(timedatectl show -p Timezone --value)"
fi

step "Basispakete installieren"
BASE_PKGS=(curl wget jq unzip ca-certificates gnupg lsb-release etherwake iproute2)
MISSING_PKGS=()
for p in "${BASE_PKGS[@]}"; do
  dpkg -s "$p" &>/dev/null || MISSING_PKGS+=("$p")
done
if (( ${#MISSING_PKGS[@]} == 0 )); then
  skip "Alle Basispakete bereits vorhanden"
else
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq "${MISSING_PKGS[@]}"
  ok "Installiert: ${MISSING_PKGS[*]}"
fi

# =============================================================================
# Schritt 2: Docker & Docker Compose
# =============================================================================
step "Docker & Docker Compose installieren"
if command -v docker &>/dev/null && docker compose version &>/dev/null; then
  skip "Docker ($(docker --version | awk '{print $3}' | tr -d ,)) und Compose ($(docker compose version --short)) bereits installiert"
else
  info "Lade offizielles Installationsskript von get.docker.com …"
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh
  ok "Docker installiert: $(docker --version)"
fi
systemctl enable --now docker &>/dev/null
ok "docker.service ist aktiviert und läuft"

step "Benutzer '${TARGET_USER}' zur Gruppe 'docker' hinzufügen"
if [[ "$TARGET_USER" == "root" ]]; then
  skip "Zielbenutzer ist root – nicht nötig"
elif id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx docker; then
  skip "${TARGET_USER} ist bereits in der Gruppe docker"
else
  usermod -aG docker "$TARGET_USER"
  ok "${TARGET_USER} hinzugefügt – wirksam nach 'newgrp docker', erneutem Login oder Reboot"
fi

# =============================================================================
# Schritt 3: Home Assistant
# =============================================================================
# Pfad zur HA-Konfiguration hängt vom Modus ab
if [[ "$HA_MODE" == "supervised" ]]; then
  HA_CONFIG_DIR="/usr/share/hassio/homeassistant"
else
  HA_CONFIG_DIR="${JARVIS_DIR}/homeassistant"
fi

install_ha_supervised() {
  # Abhängigkeiten laut offizieller Supervised-Anleitung
  local deps=(apparmor cifs-utils curl dbus jq libglib2.0-bin lsb-release network-manager
              nfs-common systemd-journal-remote systemd-resolved udisks2 wget)
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq "${deps[@]}"
  ok "Supervised-Abhängigkeiten installiert"

  # 3a) Zuerst den gewünschten (Legacy-)Installer versuchen.
  #     Hinweis: Dieser wurde vom HA-Team durch ein .deb-Paket ersetzt und
  #     liefert inzwischen meist 404 – dann greift automatisch 3b.
  local tmp; tmp="$(mktemp -d)"
  if curl -fsSL "$HA_LEGACY_INSTALLER_URL" -o "${tmp}/installer.sh" 2>/dev/null; then
    info "Legacy installer.sh gefunden – führe ihn aus …"
    if BYPASS_OS_CHECK=true bash "${tmp}/installer.sh" -m "$HA_MACHINE"; then
      rm -rf "$tmp"; return 0
    fi
    warn "Legacy-Installer fehlgeschlagen – versuche offizielles .deb-Paket."
  else
    info "Legacy installer.sh nicht mehr verfügbar – nutze offizielles .deb-Verfahren."
  fi

  # 3b) Aktuelles offizielles Verfahren: OS-Agent + homeassistant-supervised.deb
  if ! command -v os-agent &>/dev/null && ! dpkg -s os-agent &>/dev/null; then
    local agent_url
    agent_url="$(curl -fsSL https://api.github.com/repos/home-assistant/os-agent/releases/latest \
      | jq -r '.assets[] | select(.name | test("linux_x86_64\\.deb$")) | .browser_download_url' | head -n1)"
    [[ -n "$agent_url" ]] || { rm -rf "$tmp"; return 1; }
    curl -fsSL "$agent_url" -o "${tmp}/os-agent.deb"
    apt-get install -y -qq "${tmp}/os-agent.deb"
    ok "OS-Agent installiert"
  else
    skip "OS-Agent bereits installiert"
  fi

  curl -fsSL https://github.com/home-assistant/supervised-installer/releases/latest/download/homeassistant-supervised.deb \
    -o "${tmp}/homeassistant-supervised.deb" || { rm -rf "$tmp"; return 1; }
  # Machine-Typ vorbelegen, damit dpkg nicht interaktiv fragt
  echo "homeassistant-supervised ha/machine-type select ${HA_MACHINE}" | debconf-set-selections
  if MACHINE="$HA_MACHINE" BYPASS_OS_CHECK=true DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${tmp}/homeassistant-supervised.deb"; then
    rm -rf "$tmp"; return 0
  fi
  rm -rf "$tmp"; return 1
}

step "Home Assistant installieren (Modus: ${HA_MODE})"
if [[ "$HA_MODE" == "supervised" ]]; then
  if systemctl list-unit-files --no-legend 2>/dev/null | grep -q '^hassio-supervisor\.service'; then
    skip "Home Assistant Supervised ist bereits installiert (hassio-supervisor.service)"
  else
    warn "Supervised auf Ubuntu ist offiziell 'unsupported' und seit HA 2025.12 deprecated."
    warn "Der Installer stellt das Netzwerk auf NetworkManager um – SSH kann kurz abbrechen."
    warn "Tipp: Skript in 'tmux' oder 'screen' ausführen."
    if install_ha_supervised; then
      ok "Home Assistant Supervised installiert – Supervisor lädt Home Assistant nun im Hintergrund"
    else
      die "Supervised-Installation fehlgeschlagen. Alternative: sudo HA_MODE=container bash $0"
    fi
  fi
else
  # Container-Modus: Home Assistant wird weiter unten Teil des Compose-Stacks
  info "Home Assistant wird als Container 'homeassistant' im Jarvis-Stack betrieben"
  ok "Modus 'container' gewählt"
fi

# =============================================================================
# Schritt 4: Docker-Compose-Stack (Ollama, Whisper, Piper, openWakeWord[, HA])
# =============================================================================
step "Verzeichnisse & docker-compose.yml anlegen (${JARVIS_DIR})"
mkdir -p "${JARVIS_DIR}"/{ollama,whisper,piper,openwakeword}
[[ "$HA_MODE" == "container" ]] && mkdir -p "${JARVIS_DIR}/homeassistant"

# Compose-Datei in temporäre Datei schreiben und nur bei Änderung ersetzen
TMP_COMPOSE="$(mktemp)"
cat > "$TMP_COMPOSE" <<EOF
# Automatisch erzeugt von install-jarvis.sh – Änderungen werden beim nächsten
# Lauf überschrieben. Eigene Anpassungen bitte im Skript vornehmen.
name: jarvis

services:
  # --- LLM: Ollama ---------------------------------------------------------
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    ports:
      - "11434:11434"
    environment:
      - TZ=${TIMEZONE}
      - OLLAMA_HOST=0.0.0.0:11434
      - OLLAMA_KEEP_ALIVE=30m        # Modell 30 min im RAM halten (schnellere Antworten)
    volumes:
      - ${JARVIS_DIR}/ollama:/root/.ollama

  # --- Speech-to-Text: faster-whisper (Wyoming-Protokoll) --------------------
  whisper:
    image: rhasspy/wyoming-whisper:latest
    container_name: whisper
    restart: unless-stopped
    command: --model ${WHISPER_MODEL} --language ${WHISPER_LANG}
    ports:
      - "10300:10300"
    environment:
      - TZ=${TIMEZONE}
    volumes:
      - ${JARVIS_DIR}/whisper:/data

  # --- Text-to-Speech: Piper (Wyoming-Protokoll) ----------------------------
  piper:
    image: rhasspy/wyoming-piper:latest
    container_name: piper
    restart: unless-stopped
    command: --voice ${PIPER_VOICE}
    ports:
      - "10200:10200"
    environment:
      - TZ=${TIMEZONE}
    volumes:
      - ${JARVIS_DIR}/piper:/data

  # --- Wake-Word: openWakeWord ("Hey Jarvis") ---------------------------------
  openwakeword:
    image: rhasspy/wyoming-openwakeword:latest
    container_name: openwakeword
    restart: unless-stopped
    command: --preload-model ${WAKEWORD}
    ports:
      - "10400:10400"
    environment:
      - TZ=${TIMEZONE}
    volumes:
      - ${JARVIS_DIR}/openwakeword:/custom
EOF

if [[ "$HA_MODE" == "container" ]]; then
  cat >> "$TMP_COMPOSE" <<EOF

  # --- Home Assistant Core (nur HA_MODE=container) ------------------------------
  homeassistant:
    image: ghcr.io/home-assistant/home-assistant:stable
    container_name: homeassistant
    restart: unless-stopped
    network_mode: host               # nötig für Discovery & Wake-on-LAN-Broadcasts
    privileged: true
    environment:
      - TZ=${TIMEZONE}
    volumes:
      - ${JARVIS_DIR}/homeassistant:/config
      - /etc/localtime:/etc/localtime:ro
      - /run/dbus:/run/dbus:ro
EOF
fi

if [[ -f "$COMPOSE_FILE" ]] && cmp -s "$TMP_COMPOSE" "$COMPOSE_FILE"; then
  rm -f "$TMP_COMPOSE"
  skip "docker-compose.yml ist bereits aktuell"
else
  mv "$TMP_COMPOSE" "$COMPOSE_FILE"
  chmod 644 "$COMPOSE_FILE"
  ok "docker-compose.yml geschrieben"
fi
docker compose -f "$COMPOSE_FILE" config -q || die "docker-compose.yml ist ungültig"
ok "docker-compose.yml ist syntaktisch gültig"

# Liste der Compose-Services (für systemd-Units)
mapfile -t JARVIS_SERVICES < <(docker compose -f "$COMPOSE_FILE" config --services)

# =============================================================================
# Schritt 5: systemd-Units für alle Container
# =============================================================================
# Template-Unit "jarvis@<service>.service": eine Instanz pro Container.
# Startet den jeweiligen Compose-Service beim Booten nach docker.service.
step "systemd-Units für die Jarvis-Container anlegen"
UNIT_FILE="/etc/systemd/system/jarvis@.service"
TMP_UNIT="$(mktemp)"
cat > "$TMP_UNIT" <<EOF
[Unit]
Description=Jarvis Docker-Container: %i
Documentation=file://${JARVIS_DIR}/README.md
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${JARVIS_DIR}
ExecStart=/usr/bin/docker compose -f ${COMPOSE_FILE} up -d --remove-orphans %i
ExecStop=/usr/bin/docker compose -f ${COMPOSE_FILE} stop %i
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
if [[ -f "$UNIT_FILE" ]] && cmp -s "$TMP_UNIT" "$UNIT_FILE"; then
  rm -f "$TMP_UNIT"
  skip "${UNIT_FILE} ist bereits aktuell"
else
  mv "$TMP_UNIT" "$UNIT_FILE"
  chmod 644 "$UNIT_FILE"
  systemctl daemon-reload
  ok "${UNIT_FILE} geschrieben"
fi

for svc in "${JARVIS_SERVICES[@]}"; do
  if systemctl is-enabled --quiet "jarvis@${svc}.service" 2>/dev/null; then
    skip "jarvis@${svc}.service bereits aktiviert"
  else
    systemctl enable "jarvis@${svc}.service" &>/dev/null
    ok "jarvis@${svc}.service aktiviert (Autostart beim Booten)"
  fi
done

step "Container-Images laden & starten (kann beim ersten Mal einige Minuten dauern)"
docker compose -f "$COMPOSE_FILE" pull --quiet
for svc in "${JARVIS_SERVICES[@]}"; do
  # restart statt start, damit eine geänderte compose-Datei übernommen wird
  systemctl restart "jarvis@${svc}.service"
  ok "Container '${svc}' läuft ($(docker inspect -f '{{.State.Status}}' "$svc" 2>/dev/null || echo '?'))"
done
if [[ "$HA_MODE" == "supervised" ]]; then
  info "Hinweis: Home Assistant selbst wird vom Supervisor (hassio-supervisor.service) gestartet."
fi

# =============================================================================
# Schritt 6: Ollama-Modell laden
# =============================================================================
step "Ollama-Modell '${OLLAMA_MODEL}' bereitstellen"
if ! wait_for_url "http://127.0.0.1:11434/api/tags" 120; then
  die "Ollama antwortet nicht auf Port 11434 – siehe: docker logs ollama"
fi
ok "Ollama lauscht auf Port 11434"
if docker exec ollama ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$OLLAMA_MODEL"; then
  skip "Modell ${OLLAMA_MODEL} ist bereits vorhanden"
else
  info "Lade ${OLLAMA_MODEL} (~2 GB) …"
  docker exec ollama ollama pull "$OLLAMA_MODEL"
  ok "Modell ${OLLAMA_MODEL} geladen"
fi

step "Wyoming-Dienste prüfen (Whisper 10300, Piper 10200, openWakeWord 10400)"
for port in 10300 10200 10400; do
  waited=0
  until (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; do
    sleep 3; waited=$((waited + 3))
    (( waited >= 300 )) && break
  done
  if (( waited < 300 )); then
    ok "Port ${port} ist erreichbar"
  else
    warn "Port ${port} antwortet (noch) nicht – Modelle werden evtl. noch geladen (docker compose -f ${COMPOSE_FILE} logs)"
  fi
done

# =============================================================================
# Schritt 7: Auf Home Assistant warten
# =============================================================================
step "Auf Home Assistant warten (configuration.yaml in ${HA_CONFIG_DIR})"
HA_CONFIG_FILE="${HA_CONFIG_DIR}/configuration.yaml"
if [[ -f "$HA_CONFIG_FILE" ]]; then
  skip "configuration.yaml existiert bereits"
elif [[ "$HA_MODE" == "container" ]]; then
  # Im Container-Modus legt HA die Datei beim ersten Start an
  wait_for_file "$HA_CONFIG_FILE" 300 || die "Home Assistant hat keine configuration.yaml erzeugt – siehe: docker logs homeassistant"
  ok "configuration.yaml wurde von Home Assistant erzeugt"
else
  info "Der Supervisor lädt beim ersten Start das HA-Image (~1–2 GB). Max. Wartezeit: ${HA_WAIT_SECONDS}s"
  if wait_for_file "$HA_CONFIG_FILE" "$HA_WAIT_SECONDS"; then
    ok "configuration.yaml wurde von Home Assistant erzeugt"
  else
    die "Home Assistant noch nicht bereit. Bitte später erneut ausführen (das Skript macht dort weiter)."
  fi
fi

# =============================================================================
# Schritt 8: HACS installieren
# =============================================================================
step "HACS (Home Assistant Community Store) installieren"
HACS_DIR="${HA_CONFIG_DIR}/custom_components/hacs"
HA_NEEDS_RESTART=false
if [[ -f "${HACS_DIR}/manifest.json" ]]; then
  skip "HACS ist bereits installiert (Version $(jq -r .version "${HACS_DIR}/manifest.json" 2>/dev/null || echo '?'))"
else
  # Entspricht inhaltlich dem offiziellen get.hacs.xyz-Skript: das aktuelle
  # Release-Zip nach config/custom_components/hacs entpacken.
  TMP_HACS="$(mktemp -d)"
  curl -fsSL https://github.com/hacs/integration/releases/latest/download/hacs.zip -o "${TMP_HACS}/hacs.zip"
  mkdir -p "$HACS_DIR"
  unzip -oq "${TMP_HACS}/hacs.zip" -d "$HACS_DIR"
  rm -rf "$TMP_HACS"
  HA_NEEDS_RESTART=true
  ok "HACS nach ${HACS_DIR} entpackt"
fi

# =============================================================================
# Schritt 9: Wake-on-LAN in configuration.yaml
# =============================================================================
step "Wake-on-LAN in configuration.yaml aktivieren"
if grep -qE '^wake_on_lan:' "$HA_CONFIG_FILE"; then
  skip "'wake_on_lan:' ist bereits eingetragen"
else
  cp -a "$HA_CONFIG_FILE" "${HA_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  cat >> "$HA_CONFIG_FILE" <<'EOF'

# --- Jarvis: Wake-on-LAN (hinzugefügt von install-jarvis.sh) ---
# Stellt den Dienst wake_on_lan.send_magic_packet bereit.
# Den PC-Schalter (MAC-Adresse!) siehe README.md, Abschnitt "Windows-PC".
wake_on_lan:
EOF
  HA_NEEDS_RESTART=true
  ok "'wake_on_lan:' eingetragen (Backup der alten Datei angelegt)"
fi

step "Home Assistant neu starten (falls nötig)"
if [[ "$HA_NEEDS_RESTART" == true ]]; then
  if docker ps --format '{{.Names}}' | grep -qx homeassistant; then
    docker restart homeassistant >/dev/null
    ok "Container 'homeassistant' neu gestartet"
  else
    warn "Container 'homeassistant' läuft nicht – Änderungen greifen beim nächsten Start"
  fi
else
  skip "Keine Konfigurationsänderung – kein Neustart nötig"
fi

# =============================================================================
# Schritt 10: README.md mit nächsten manuellen Schritten
# =============================================================================
IP_ADDR="$(get_ip)"
IP_ADDR="${IP_ADDR:-<SERVER-IP>}"

step "README.md mit den nächsten Schritten erzeugen"
README="${JARVIS_DIR}/README.md"
cat > "$README" <<EOF
# Jarvis – nächste manuelle Schritte

Erzeugt von \`install-jarvis.sh\` am $(date '+%d.%m.%Y %H:%M') auf \`$(hostname)\`.

| Dienst | Adresse | Zweck |
|---|---|---|
| Home Assistant | http://${IP_ADDR}:8123 | Smart-Home-Zentrale (Modus: ${HA_MODE}) |
| Ollama | http://${IP_ADDR}:11434 | LLM \`${OLLAMA_MODEL}\` |
| Whisper | tcp ${IP_ADDR}:10300 | Speech-to-Text (Wyoming, Modell ${WHISPER_MODEL}, Sprache ${WHISPER_LANG}) |
| Piper | tcp ${IP_ADDR}:10200 | Text-to-Speech (Wyoming, Stimme ${PIPER_VOICE}) |
| openWakeWord | tcp ${IP_ADDR}:10400 | Wake-Word \`${WAKEWORD}\` (Wyoming) |

Dateien: \`${COMPOSE_FILE}\`, HA-Konfiguration: \`${HA_CONFIG_DIR}\`,
Log der Installation: \`${LOG_FILE}\`.

---

## 1. Home Assistant einrichten

1. \`http://${IP_ADDR}:8123\` öffnen und den Onboarding-Assistenten durchlaufen
   (Benutzer anlegen, Standort, Einheiten, Sprache **Deutsch**).
2. Falls du nicht neu gestartet hast: \`newgrp docker\` ausführen oder neu einloggen,
   damit \`${TARGET_USER}\` Docker ohne sudo nutzen kann.

## 2. Sprach-Pipeline ("Hey Jarvis") verbinden

*Einstellungen → Geräte & Dienste → Integration hinzufügen*:

1. **Wyoming Protocol** → Host \`${IP_ADDR}\`, Port \`10300\` (Whisper)
2. **Wyoming Protocol** → Host \`${IP_ADDR}\`, Port \`10200\` (Piper)
3. **Wyoming Protocol** → Host \`${IP_ADDR}\`, Port \`10400\` (openWakeWord)
4. **Ollama** → URL \`http://${IP_ADDR}:11434\`, Modell \`${OLLAMA_MODEL}\`.
   In den Optionen der Ollama-Integration **"Home Assistant steuern" (Assist)**
   aktivieren, damit das LLM Geräte schalten darf.
5. *Einstellungen → Sprachassistenten → Assistent hinzufügen*:
   Name "Jarvis", Sprache Deutsch, Konversationsagent **Ollama**
   (Option "Bevorzugt lokale Befehle verarbeiten" aktivieren – schneller),
   Speech-to-Text **faster-whisper**, Text-to-Speech **piper**,
   Wake-Word **openwakeword → ${WAKEWORD}**.

> Der Server hat kein Mikrofon. Du brauchst einen **Voice-Satelliten**, z. B.
> Home Assistant Voice Preview Edition, ESP32-S3-Box (ESPHome), einen
> Raspberry Pi mit \`wyoming-satellite\` oder die Home-Assistant-App am Handy.

## 3. Philips 55" TV (Ambilight) koppeln

1. TV einschalten, im selben Netzwerk wie der Server. Feste IP im Router vergeben.
2. *Integration hinzufügen → **Philips TV*** → IP des TVs eingeben.
3. Bei Android-TVs erscheint ein **PIN auf dem Fernseher** → in HA eintippen.
4. Für Netflix zusätzlich empfohlen: Integration **Android TV Remote**
   (ebenfalls Pairing per PIN). Beispiel-Skript für "Hey Jarvis, starte Netflix":

\`\`\`yaml
# scripts.yaml
netflix_starten:
  alias: "Netflix starten"
  sequence:
    - action: remote.turn_on
      target:
        entity_id: remote.philips_tv          # an deine Entität anpassen
      data:
        activity: "com.netflix.ninja"
\`\`\`

   Ambilight erscheint nach dem Pairing als \`light.*\`-Entität ("Ambilight an").

## 4. Govee LED-Strips

**Variante A – lokal, ohne Cloud (empfohlen):**
1. In der Govee-Home-App pro Gerät *Einstellungen → LAN Control* aktivieren.
2. *Integration hinzufügen → **Govee lights local*** (in HA enthalten).

**Variante B – Cloud-API mit API-Key (für Strips ohne LAN-Control):**
1. Govee-Home-App → *Profil → Einstellungen → "Apply for API Key"* → Key kommt per E-Mail.
2. HACS öffnen (Seitenleiste) → beim ersten Öffnen mit GitHub-Konto autorisieren.
   Falls HACS noch nicht sichtbar ist: *Integration hinzufügen → **HACS***.
3. In HACS nach **"Govee"** suchen (z. B. *Govee integration* von LaggAt),
   installieren, Home Assistant neu starten.
4. *Integration hinzufügen → Govee* → API-Key eintragen.

## 5. Windows-PC per Wake-on-LAN ("Hey Jarvis, PC an")

**Am Windows-PC:**
1. BIOS/UEFI: *Wake on LAN / Power On by PCI-E* aktivieren, *ErP/Deep Sleep* deaktivieren.
2. Geräte-Manager → Netzwerkadapter → Eigenschaften:
   *Energieverwaltung*: "Gerät kann den Computer aus dem Ruhezustand aktivieren" +
   "Nur Magic Packet …" anhaken; *Erweitert*: "Wake on Magic Packet" = Aktiviert.
3. Systemsteuerung → Energieoptionen → **Schnellstart deaktivieren**.
4. MAC-Adresse ermitteln: \`ipconfig /all\` → "Physische Adresse" (z. B. \`AA-BB-CC-DD-EE-FF\`).
   Im Router dem PC eine feste IP geben.

**In Home Assistant** (\`wake_on_lan:\` ist bereits aktiviert):
Einfachster Weg: *Integration hinzufügen → **Wake on LAN*** → MAC eintragen
(erzeugt einen Button). Alternativ als Schalter in \`configuration.yaml\`:

\`\`\`yaml
switch:
  - platform: wake_on_lan
    name: "PC"
    mac: "AA:BB:CC:DD:EE:FF"        # <- deine MAC-Adresse
    host: 192.168.1.50              # <- IP des PCs (für den Ein/Aus-Status)
\`\`\`

Danach HA neu starten und die Entität unter *Einstellungen → Sprachassistenten →
Entitäten freigeben* für Assist freigeben, ebenso TV, Ambilight und Govee-Lichter.

Test vom Server aus: \`sudo etherwake -i \$(ip route | awk '/default/{print \$5; exit}') AA:BB:CC:DD:EE:FF\`

## 6. Nützliche Befehle

\`\`\`bash
systemctl status 'jarvis@*'                       # Status aller Jarvis-Container
docker compose -f ${COMPOSE_FILE} logs -f        # Logs
docker exec ollama ollama list                   # geladene LLM-Modelle
docker exec ollama ollama pull llama3.2:3b       # weiteres Modell laden
sudo bash install-jarvis.sh                      # erneut ausführen (idempotent)
\`\`\`
EOF
chmod 644 "$README"
ok "README geschrieben: ${README}"
if [[ "$TARGET_USER" != "root" && -d "$TARGET_HOME" ]]; then
  cp "$README" "${TARGET_HOME}/JARVIS-README.md"
  chown "$TARGET_USER": "${TARGET_HOME}/JARVIS-README.md"
  ok "Kopie abgelegt: ${TARGET_HOME}/JARVIS-README.md"
fi

# =============================================================================
# Schritt 11: Zusammenfassung
# =============================================================================
step "Fertig – Zusammenfassung"
cat <<EOF

  ${C_GREEN}Jarvis-Installation abgeschlossen.${C_RESET}

  Lokale IP-Adresse:  ${IP_ADDR}

  ➜ Home Assistant:   http://${IP_ADDR}:8123
  ➜ Ollama (LLM):     http://${IP_ADDR}:11434   (Modell: ${OLLAMA_MODEL})
  ➜ Whisper (STT):    ${IP_ADDR}:10300
  ➜ Piper (TTS):      ${IP_ADDR}:10200
  ➜ openWakeWord:     ${IP_ADDR}:10400          (Wake-Word: ${WAKEWORD})

  Nächste Schritte:   ${README}
  Installations-Log:  ${LOG_FILE}

  Hinweis: Damit '${TARGET_USER}' Docker ohne sudo nutzen kann:
           'newgrp docker' ausführen, neu einloggen oder 'sudo reboot'.

EOF
