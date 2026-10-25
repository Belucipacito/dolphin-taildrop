#!/usr/bin/env bash
#
# Taildrop for Dolphin (KDE 5 / KDE 6)
#
#   ./taildrop-dolphin.sh install
#   ./taildrop-dolphin.sh uninstall
#
# What `install` sets up (all inside your home directory, except /etc/taildrop):
#   1. A Qt GUI ("Send via Taildrop") in Dolphin's right-click menu.
#      It lists your tailnet devices and only lets you pick ones that are online.
#   2. A systemd *user* service (tailreceive) that runs `tailscale file get`
#      in a loop, so incoming Taildrop files are saved automatically.
#   3. /etc/taildrop/taildrop.conf, which controls where files are saved.
#      A systemd path unit watches it and restarts the service on every change.
#
# Everything the installer changes is recorded in a small manifest file, so
# `uninstall` can undo exactly those changes and leave nothing behind.
#
# Exit on errors (-e), unset variables (-u) and failures inside pipes (pipefail).
set -Eeuo pipefail

# --------------------------------------------------------------------------- #
# Constants
# --------------------------------------------------------------------------- #
# XDG base directories (fall back to the usual defaults if the variables are unset).
readonly APP_NAME="taildrop-dolphin"
readonly DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
readonly CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"

# Where the app itself lives: GUI, receiver script, icon, a copy of this
# installer and the manifest that records what was changed.
readonly APP_DIR="${DATA_HOME}/${APP_NAME}"
readonly MANIFEST="${APP_DIR}/manifest"

# systemd user units go here.
readonly SYSTEMD_DIR="${CONFIG_HOME}/systemd/user"

# System-wide receiver configuration (the only thing installed outside $HOME).
readonly ETC_DIR="/etc/taildrop"
readonly ETC_CONF="${ETC_DIR}/taildrop.conf"

# Name of the receiver service (tailreceive.service) and its helper units.
readonly SERVICE="tailreceive"

# Dolphin reads service menus from different places depending on the KDE version.
readonly SERVICE_MENU_DIRS=(
  "${DATA_HOME}/kio/servicemenus"          # KDE 6
  "${DATA_HOME}/kservices5/ServiceMenus"   # KDE 5
)
readonly SERVICE_MENU_FILE="taildrop.desktop"

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
# Colored status output: log = progress, warn = non-fatal problem, die = abort.
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx \033[0m %s\n' "$*" >&2; exit 1; }

# The manifest is a plain KEY=VALUE file. It remembers things the installer
# changed (previous Tailscale operator, whether /etc/taildrop was created by us,
# which directories we created) so that uninstall can revert only those.

# The manifest is a plain KEY=VALUE file that records what the installer changed
# (Tailscale operator, /etc config, created directories). Uninstall reads it to undo
# exactly those changes and nothing else.
# Read a value from the install manifest (empty if missing).
manifest_get() {
  [[ -f ${MANIFEST} ]] || return 0
  grep -m1 "^$1=" "${MANIFEST}" 2>/dev/null | cut -d= -f2- || true
}

# Set (or replace) a key in the install manifest.
manifest_set() {
  local key=$1 value=$2 tmp
  mkdir -p "${APP_DIR}"
  touch "${MANIFEST}"
  # Rewrite the file without the old value of this key, then append the new one.
  tmp=$(mktemp)
  grep -v "^${key}=" "${MANIFEST}" > "${tmp}" || true
  printf '%s=%s\n' "${key}" "${value}" >> "${tmp}"
  cat "${tmp}" > "${MANIFEST}"
  rm -f "${tmp}"
}

# Current Tailscale operator user (empty if none).
# `debug prefs` needs root, hence sudo; the JSON field is parsed with sed so
# that no extra tools like jq are required.
current_operator() {
  sudo tailscale debug prefs 2>/dev/null \
    | sed -n 's/.*"OperatorUser": *"\([^"]*\)".*/\1/p' | head -n1 || true
}

# Make KDE pick up added/removed service menus right away.
# kbuildsycoca6 is KDE 6, kbuildsycoca5 is KDE 5; whichever exists is used.
refresh_kde_cache() {
  local tool
  for tool in kbuildsycoca6 kbuildsycoca5; do
    command -v "${tool}" >/dev/null 2>&1 && "${tool}" >/dev/null 2>&1 || true
  done
}

# --------------------------------------------------------------------------- #
# Preflight checks
# --------------------------------------------------------------------------- #
# Verify everything the installer depends on *before* touching the system.
preflight() {
  # Running as root would put everything into root's home instead of yours.
  [[ ${EUID} -ne 0 ]] || die "Run as a regular user, not root (sudo is requested when needed)."
  command -v tailscale >/dev/null 2>&1 || die "tailscale not found in PATH."
  command -v systemctl >/dev/null 2>&1 || die "systemd not found."
  command -v python3   >/dev/null 2>&1 || die "python3 not found."
  command -v sudo      >/dev/null 2>&1 || die "sudo not found."
  # The receiver is a systemd *user* service, so a user session must be running.
  systemctl --user show-environment >/dev/null 2>&1 \
    || die "Cannot connect to systemd --user (no user session?)."

  # The GUI needs one of the Qt bindings below; the first one found is used.
  if ! python3 - <<'PY'
import importlib.util as u, sys
sys.exit(0 if any(u.find_spec(m) for m in ("PyQt6", "PySide6", "PyQt5")) else 1)
PY
  then
    cat >&2 <<'MSG'
xx No Qt binding for Python found (PyQt6 / PySide6 / PyQt5). Install one of them:
     Arch/Manjaro : sudo pacman -S python-pyqt6
     Debian/Ubuntu: sudo apt install python3-pyqt6      (or python3-pyqt5)
     Fedora       : sudo dnf install python3-pyqt6      (or python3-qt5)
     openSUSE     : sudo zypper install python3-qt6     (or python3-qt5)
MSG
    exit 1
  fi

  # Not fatal: Tailscale may simply be stopped right now.
  tailscale status >/dev/null 2>&1 \
    || warn "Tailscale is not running or not logged in. Installation will continue, but the GUI will show an error until it is."
}

# --------------------------------------------------------------------------- #
# Clean up artifacts of the old (pre-manifest) version of this script
# --------------------------------------------------------------------------- #
# The first version of this installer put its files in different places.
# Only those exact files are removed, and the directories only if empty.
cleanup_legacy() {
  local f
  for f in \
    "${CONFIG_HOME}/dolphin_service_menus_creator/taildrop_script.sh" \
    "${DATA_HOME}/kservices5/ServiceMenus/Taildrop.desktop" \
    "${HOME}/Themes/Icons/tailscale.png"; do
    [[ -e ${f} ]] && rm -f "${f}" && log "Removed legacy file: ${f}"
  done
  rmdir "${CONFIG_HOME}/dolphin_service_menus_creator" "${HOME}/Themes/Icons" "${HOME}/Themes" 2>/dev/null || true
}

# --------------------------------------------------------------------------- #
# Tailscale operator (so sending/receiving does not need sudo every time)
# --------------------------------------------------------------------------- #
# By default only root may control tailscaled. Making this user the "operator"
# lets `tailscale file cp/get` work without sudo. `tailscale set` is used
# instead of `tailscale up` because it does not require logging in again.
setup_operator() {
  local cur
  cur=$(current_operator)
  if [[ ${cur} == "${USER}" ]]; then
    log "Tailscale operator is already ${USER}"
    return
  fi
  # Remember the previous value so uninstall can restore it.
  manifest_set OPERATOR_PREV "${cur}"
  manifest_set OPERATOR_CHANGED 1
  log "Setting ${USER} as Tailscale operator (no re-authentication needed)..."
  sudo tailscale set --operator="${USER}"
}

# --------------------------------------------------------------------------- #
# /etc/taildrop/taildrop.conf
# --------------------------------------------------------------------------- #
# Create the config only if it does not exist yet, so a re-install never
# overwrites settings you have edited. The manifest remembers that *we*
# created it, so uninstall will not delete a file that was there before.
install_etc_config() {
  # Never overwrite an existing config: it may contain the user's own settings.
  if [[ -f ${ETC_CONF} ]]; then
    log "${ETC_CONF} already exists, leaving it untouched."
    return
  fi
  log "Creating ${ETC_CONF}..."
  sudo install -d -m 0755 "${ETC_DIR}"
  sudo tee "${ETC_CONF}" >/dev/null <<'EOF'
# Taildrop receiver configuration.
# Changes are applied automatically a few seconds after saving
# (a systemd path unit restarts the tailreceive service).

# Directory where received files are saved.
# "~" and $HOME are expanded. To receive straight into your home: "$HOME"
TAILDROP_DIR="$HOME/Taildrop"

# What to do if a file with the same name already exists:
#   rename | skip | overwrite
CONFLICT="rename"

# Desktop notification when a file is received:  yes | no
NOTIFY="yes"
EOF
  sudo chmod 0644 "${ETC_CONF}"
  manifest_set ETC_CREATED 1
}

# Create the default receive directory up front and remember it, so uninstall
# can remove it again (only if it is still empty).
ensure_default_receive_dir() {
  local dir="${HOME}/Taildrop"
  if [[ ! -d ${dir} ]]; then
    mkdir -p "${dir}"
    manifest_set RECEIVE_DIR_CREATED "${dir}"
  fi
}

# --------------------------------------------------------------------------- #
# Application files
# --------------------------------------------------------------------------- #
# The icon is a small SVG drawn from dots (a 3x3 grid), written locally.
# Nothing is downloaded from the internet.
write_icon() {
  cat > "${APP_DIR}/taildrop.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <rect width="64" height="64" rx="14" fill="#141414"/>
  <g fill="#ffffff">
    <circle cx="16" cy="16" r="5" opacity=".3"/><circle cx="32" cy="16" r="5" opacity=".3"/><circle cx="48" cy="16" r="5" opacity=".3"/>
    <circle cx="16" cy="32" r="5"/><circle cx="32" cy="32" r="5"/><circle cx="48" cy="32" r="5"/>
    <circle cx="16" cy="48" r="5"/><circle cx="32" cy="48" r="5" opacity=".3"/><circle cx="48" cy="48" r="5"/>
  </g>
</svg>
EOF
}

# The receiver wrapper that systemd starts. It re-reads the /etc config on every
# start, validates the values, creates the target directory and then runs
# `tailscale file get --loop`, which waits for and saves incoming files.
write_receiver_script() {
  cat > "${APP_DIR}/taildrop-receive.sh" <<'EOF'
#!/usr/bin/env bash
# Automatic Taildrop receiver. Settings: /etc/taildrop/taildrop.conf
set -uo pipefail

CONF="/etc/taildrop/taildrop.conf"
TAILDROP_DIR="${HOME}/Taildrop"
CONFLICT="rename"
NOTIFY="yes"

# shellcheck disable=SC1090
[[ -r ${CONF} ]] && source "${CONF}"

# Expand a leading "~" (variables like $HOME are already expanded by `source`).
dir="${TAILDROP_DIR/#\~/${HOME}}"
# Fall back to a safe default if the config contains an unknown value.
case "${CONFLICT}" in skip|overwrite|rename) ;; *) CONFLICT="rename" ;; esac

# Fail early (systemd will retry) if the directory cannot be created or written.
if ! mkdir -p -- "${dir}" 2>/dev/null || [[ ! -w ${dir} ]]; then
  echo "taildrop-receive: directory '${dir}' is not writable" >&2
  exit 1
fi

# Show a desktop notification if enabled; try notify-send first, then kdialog.
notify() {
  [[ ${NOTIFY} == "yes" ]] || return 0
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -a Taildrop -i network-transmit-receive -- "Taildrop" "$1" || true
  elif command -v kdialog >/dev/null 2>&1; then
    kdialog --title Taildrop --passivepopup "$1" 5 || true
  fi
}

echo "taildrop-receive: saving to '${dir}' (conflict=${CONFLICT})"

# --loop  : keep waiting for new files instead of exiting after the first batch
# --verbose: print a "wrote <file>" line for every received file (used for notifications)
# The while-loop passes the log through to journald and triggers notifications.
tailscale file get --loop --verbose --conflict="${CONFLICT}" -- "${dir}" 2>&1 \
  | while IFS= read -r line; do
      printf '%s\n' "${line}"
      if [[ ${line} == wrote\ * ]]; then
        notify "Received: ${line#wrote }"
      fi
    done
# Propagate tailscale's exit code (not the while-loop's) so systemd can restart us.
exit "${PIPESTATUS[0]}"
EOF
  chmod 0755 "${APP_DIR}/taildrop-receive.sh"
}

# The GUI is a single Python file embedded below. Dolphin runs it with the
# selected files/folders as arguments. It talks to Tailscale only through the
# `tailscale` CLI, so there are no extra Python dependencies besides Qt.
write_gui() {
  cat > "${APP_DIR}/taildrop-send.py" <<'PYEOF'
#!/usr/bin/env python3
"""Taildrop sender: GUI for the Dolphin context menu.

Flow:
  1. List peers from `tailscale status --json` (refreshed every few seconds).
  2. Keep only devices Taildrop may send to (`tailscale file cp --targets`);
     show offline ones greyed out and not selectable.
  3. Send each file with `tailscale file cp` in a background thread and
     measure progress by reading the file offset of that process.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile
from collections import deque
from dataclasses import dataclass
from string import Template

# Use whichever Qt binding is installed. The code only uses features that exist
# in all three, differing only in how the Signal class is named.
try:
    # Try the Qt bindings in order of preference: PyQt6, PySide6, PyQt5.
    # `Signal` is aliased so the rest of the code is binding-agnostic.
    from PyQt6 import QtCore, QtGui, QtWidgets
    Signal = QtCore.pyqtSignal
except ImportError:
    try:
        from PySide6 import QtCore, QtGui, QtWidgets
        Signal = QtCore.Signal
    except ImportError:
        from PyQt5 import QtCore, QtGui, QtWidgets
        Signal = QtCore.pyqtSignal

Qt = QtCore.Qt
# Full path to the tailscale CLI (resolved once; Dolphin may start us with a short PATH).
TS = shutil.which("tailscale") or "tailscale"


# --------------------------------------------------------------------------- #
# Formatting
# --------------------------------------------------------------------------- #
def human_size(n):
    n = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.0f} B" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024


# Format seconds as 12s / 3m 05s / 1h 02m.
def human_time(s):
    s = int(s + 0.5)
    if s < 60:
        return f"{s}s"
    m, s = divmod(s, 60)
    if m < 60:
        return f"{m}m {s:02d}s"
    h, m = divmod(m, 60)
    return f"{h}h {m:02d}m"


# Shorten long text in the middle so it fits a label of the given pixel width.
def elide(label, text, width):
    return QtGui.QFontMetrics(label.font()).elidedText(
        text, Qt.TextElideMode.ElideMiddle, width)


# --------------------------------------------------------------------------- #
# Tailscale
# --------------------------------------------------------------------------- #
# One Tailscale peer. frozen=True makes it comparable and hashable, which lets
# the UI detect "nothing changed" and skip needless redraws.
@dataclass(frozen=True)
class Device:
    name: str
    os: str
    ip: str
    online: bool
    mine: bool
    owner: str


# Run the tailscale CLI and capture its output. The timeout keeps the GUI
# from hanging on a stuck daemon.
def run_ts(args, timeout=8):
    return subprocess.run([TS, *args], capture_output=True, text=True, timeout=timeout)


def fetch_targets():
    """Names/IPs of devices Taildrop may send to. None if it can't be determined."""
    try:
        r = run_ts(["file", "cp", "--targets"])
    except Exception:
        return None
    if r.returncode != 0:
        return None
    found = set()
    for line in r.stdout.splitlines():
        parts = line.split()
        found.update(parts[:2])
    return found


def fetch_devices():
    """Return the list of devices this machine can send files to."""
    r = run_ts(["status", "--json"])
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or "tailscale status failed")
    data = json.loads(r.stdout)
    state = data.get("BackendState")
    if state != "Running":
        hints = {
            "Stopped": "Tailscale is turned off.\nRun: tailscale up",
            "NeedsLogin": "Tailscale needs you to log in.\nRun: tailscale up",
            "NoState": "Tailscale is starting…",
        }
        raise RuntimeError(hints.get(state, f"Tailscale state: {state}"))

    # UserID tells us whether a peer is one of *our* devices or shared with us.
    self_uid = (data.get("Self") or {}).get("UserID")
    users = data.get("User") or {}
    # Taildrop only works for some peers (own devices and devices shared with us);
    # `tailscale file cp --targets` tells us which ones.
    targets = fetch_targets()
    devices = []
    for peer in (data.get("Peer") or {}).values():
        # MagicDNS short name is what `tailscale file cp --targets` prints.
        dns = (peer.get("DNSName") or "").split(".")[0]
        host = peer.get("HostName") or dns
        name = dns or host
        ips = peer.get("TailscaleIPs") or []
        # Prefer the IPv4 address; it is the most compatible destination for `file cp`.
        ip = next((i for i in ips if ":" not in i), ips[0] if ips else "")
        if not ip:
            continue
        uid = peer.get("UserID")
        mine = uid == self_uid
        # Prefer Tailscale's own list of valid targets; if it is unavailable,
        # fall back to showing only our own devices.
        if targets is not None:
            allowed = bool({name, host, ip} & targets)
        else:
            allowed = mine
        if not allowed:
            continue
        owner = (users.get(str(uid)) or {}).get("LoginName", "")
        devices.append(Device(name, peer.get("OS") or "", ip,
                              bool(peer.get("Online")), mine, owner))
    # Online devices first, then alphabetically.
    devices.sort(key=lambda d: (not d.online, d.name.lower()))
    return devices


# `tailscale file cp` streams the file to tailscaled but prints no progress. Instead we find the
# file descriptor it opened for the source file and read its current offset from /proc,
# which gives the exact number of bytes read so far.
def file_position(pid, real_path):
    """Bytes of the file already read by `tailscale file cp` (via /proc/<pid>/fdinfo).

    `tailscale file cp` has no progress output, but it reads the source file
    sequentially while uploading. The kernel exposes the current read offset
    of every open file descriptor in /proc/<pid>/fdinfo/<fd> ("pos:"), so we
    find the descriptor that points at our file and read that number.
    Returns None if the file is not open (yet or anymore).
    """
    fd_dir = f"/proc/{pid}/fd"
    try:
        fds = os.listdir(fd_dir)
    except OSError:
        return None
    for fd in fds:
        try:
            if os.path.realpath(os.readlink(f"{fd_dir}/{fd}")) != real_path:
                continue
            with open(f"/proc/{pid}/fdinfo/{fd}") as fh:
                for line in fh:
                    if line.startswith("pos:"):
                        return int(line.split()[1])
        except OSError:
            continue
    return None


# --------------------------------------------------------------------------- #
# Threads
# --------------------------------------------------------------------------- #
class Cancelled(Exception):
    """Raised inside the worker when the user presses Cancel."""


# Fetches the device list off the UI thread so the window never freezes
# while the tailscale CLI is running.
class Fetcher(QtCore.QThread):
    done = Signal(object, str)

    def run(self):
        try:
            self.done.emit(fetch_devices(), "")
        except Exception as exc:  # noqa: BLE001
            self.done.emit(None, str(exc) or exc.__class__.__name__)


# Does the actual sending in the background and reports back via signals.
class SendWorker(QtCore.QThread):
    phase = Signal(str)
    progress = Signal(float, float, float, int, int, str)  # done, total, speed, idx, count, name
    sent = Signal()
    failed = Signal(str)  # empty string == cancelled by the user

    def __init__(self, paths, device):
        super().__init__()
        self.paths = paths
        self.device = device
        self._cancel = False
        self._proc = None

    def cancel(self):
        self._cancel = True
        proc = self._proc
        if proc is not None and proc.poll() is None:
            try:
                proc.terminate()
            except OSError:
                pass

    def run(self):
        tmp = None
        try:
            # Scratch space for zip archives; always removed in `finally`.
            tmp = tempfile.mkdtemp(prefix="taildrop-")
            items = self._prepare(tmp)
            self._send(items)
            self.sent.emit()
        except Cancelled:
            self.failed.emit("")
        except Exception as exc:  # noqa: BLE001
            self.failed.emit(str(exc) or exc.__class__.__name__)
        finally:
            if tmp:
                shutil.rmtree(tmp, ignore_errors=True)

    # Turn the selection into a list of regular files (folders become .zip archives).
    def _prepare(self, tmp):
        """Turn the selection into a flat list of regular files (folders become .zip)."""
        items = []
        for i, path in enumerate(self.paths):
            if self._cancel:
                raise Cancelled
            if os.path.isdir(path):
                name = os.path.basename(path.rstrip("/")) or "folder"
                self.phase.emit(f"Packing “{name}”…")
                folder = os.path.join(tmp, str(i))
                os.makedirs(folder)
                archive = os.path.join(folder, name + ".zip")
                self._zip(path, archive)
                items.append(archive)
            elif os.path.isfile(path):
                items.append(path)
            else:
                raise RuntimeError(f"Not a file or folder: {path}")
        return items

    # Zip a folder, keeping its top-level name inside the archive and including empty directories.
    def _zip(self, src, dst):
        # Archive paths are relative to the folder's parent, so the archive
        # contains the folder itself and extracts into a single directory.
        base = os.path.dirname(src.rstrip("/"))
        with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED, allowZip64=True) as z:
            for root, dirs, files in os.walk(src):
                if self._cancel:
                    raise Cancelled
                rel = os.path.relpath(root, base)
                if not dirs and not files:
                    z.write(root, rel)
                for fname in files:
                    if self._cancel:
                        raise Cancelled
                    fp = os.path.join(root, fname)
                    if os.path.isfile(fp):
                        z.write(fp, os.path.join(rel, fname))

    # Send files one at a time so progress and errors are reported per file.
    def _send(self, items):
        """Send files one by one, emitting overall progress, speed and counts."""
        sizes = [os.path.getsize(f) for f in items]
        total = float(sum(sizes)) or 1.0
        done_before = 0.0
        # Recent (time, bytes) samples; speed is averaged over the last ~3 seconds
        # to keep the readout stable.
        window = deque()
        count = len(items)

        for idx, (path, size) in enumerate(zip(items, sizes), 1):
            name = os.path.basename(path)
            self.phase.emit(f"Sending “{name}”")
            # The destination is the device's Tailscale IP followed by ':' (Taildrop syntax).
            proc = subprocess.Popen(
                [TS, "file", "cp", path, f"{self.device.ip}:"],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            self._proc = proc
            real = os.path.realpath(path)
            started = time.monotonic()
            seen = False
            cur = 0
            window.clear()

            # Poll the running process ~10 times per second.
            while proc.poll() is None:
                now = time.monotonic()
                pos = file_position(proc.pid, real)
                if pos is not None:
                    seen = True
                    cur = min(pos, size)
                if seen:
                    done = done_before + cur
                    # Speed = bytes moved over the last 3 seconds (smooths out spikes).
                    window.append((now, done))
                    while window and now - window[0][0] > 3:
                        window.popleft()
                    speed = 0.0
                    if len(window) > 1 and window[-1][0] > window[0][0]:
                        speed = (window[-1][1] - window[0][1]) / (window[-1][0] - window[0][0])
                    self.progress.emit(done, total, speed, idx, count, name)
                elif now - started > 1.5:
                    # Progress is unavailable: negative speed switches the bar to "busy".
                    self.progress.emit(done_before, total, -1.0, idx, count, name)
                time.sleep(0.1)

            # The process has exited: collect its output and check the result.
            # Exit code 0 means the receiving device accepted the file.
            out, err = proc.communicate()
            self._proc = None
            if self._cancel:
                raise Cancelled
            if proc.returncode != 0:
                raise RuntimeError((err or out).strip()
                                   or f"tailscale exited with code {proc.returncode}")
            done_before += size
            self.progress.emit(done_before, total, 0.0, idx, count, name)


# --------------------------------------------------------------------------- #
# Styling
# --------------------------------------------------------------------------- #
# One stylesheet for the whole window, generated from a light or dark palette
# so it matches the current system theme.
def make_style(dark):
    c = (dict(bg="#1c1b1a", card="#262524", border="#383635", text="#f5f5f4",
              muted="#a8a29e", accent="#4a6cf7", accent_h="#6481ff", soft="#2a3050",
              ok="#3ecf8e", off="#6b6560", err="#f87171")
         if dark else
         dict(bg="#faf9f8", card="#ffffff", border="#e7e5e4", text="#1c1917",
              muted="#78716c", accent="#3b5bdb", accent_h="#4c6ef5", soft="#e8edff",
              ok="#16a34a", off="#a8a29e", err="#dc2626"))
    return Template("""
QWidget { background: $bg; color: $text; font-size: 13px; }
QLabel { background: transparent; }
QWidget#row { background: transparent; }
#title { font-size: 18px; font-weight: 600; }
#muted { color: $muted; }
#small { color: $muted; font-size: 12px; }
#section { color: $muted; font-size: 11px; font-weight: 600; letter-spacing: 1px; }
#chip { background: $card; border: 1px solid $border; border-radius: 10px; }
QLineEdit { background: $card; border: 1px solid $border; border-radius: 8px; padding: 8px 10px; }
QLineEdit:focus { border-color: $accent; }
QListWidget { background: transparent; border: none; outline: 0; }
QListWidget::item { border-radius: 10px; margin: 2px 0; border: 1px solid transparent; }
QListWidget::item:selected { background: $soft; border: 1px solid $accent; }
QListWidget::item:hover:!selected { background: $card; }
QScrollBar:vertical { background: transparent; width: 8px; }
QScrollBar::handle:vertical { background: $border; border-radius: 4px; min-height: 24px; }
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height: 0; }
QPushButton { background: $card; border: 1px solid $border; border-radius: 8px; padding: 9px 20px; }
QPushButton:hover { border-color: $accent; }
QPushButton#primary { background: $accent; color: white; border: none; font-weight: 600; }
QPushButton#primary:hover { background: $accent_h; }
QPushButton#primary:disabled { background: $border; color: $muted; }
QProgressBar { background: $border; border: none; border-radius: 4px; max-height: 8px; min-height: 8px; }
QProgressBar::chunk { background: $accent; border-radius: 4px; }
#dotOn { background: $ok; border-radius: 5px; }
#dotOff { background: $off; border-radius: 5px; }
#statusOn { color: $ok; font-weight: 600; font-size: 12px; }
#statusOff { color: $off; font-size: 12px; }
#devOff { color: $off; font-weight: 600; font-size: 14px; }
#devOn { font-weight: 600; font-size: 14px; }
#okBadge { background: $ok; color: white; border-radius: 28px; font-size: 28px; font-weight: 700; }
#errBadge { background: $err; color: white; border-radius: 28px; font-size: 28px; font-weight: 700; }
#errText { color: $muted; }
""").substitute(c)


# The dotted logo is painted in code (no image files). 1 = bright dot, 0 = dim dot.
class Logo(QtWidgets.QWidget):
    PATTERN = ((0, 0, 0), (1, 1, 1), (1, 0, 1))

    def __init__(self, size=30):
        super().__init__()
        self.setFixedSize(size, size)

    def paintEvent(self, _event):
        p = QtGui.QPainter(self)
        p.setRenderHint(QtGui.QPainter.RenderHint.Antialiasing)
        draw_logo(p, self.width(), self.palette().text().color())
        p.end()


# Paint a 3x3 grid of dots; "on" dots are opaque, the others are dimmed.
def draw_logo(p, size, color):
    step = size / 3.0
    r = step * 0.30
    p.setPen(Qt.PenStyle.NoPen)
    for y, row in enumerate(Logo.PATTERN):
        for x, on in enumerate(row):
            col = QtGui.QColor(color)
            col.setAlphaF(1.0 if on else 0.3)
            p.setBrush(col)
            p.drawEllipse(QtCore.QPointF(step * (x + .5), step * (y + .5)), r, r)


# Window icon rendered at runtime, so no image file has to be shipped.
def app_icon():
    pm = QtGui.QPixmap(64, 64)
    pm.fill(Qt.GlobalColor.transparent)
    p = QtGui.QPainter(pm)
    p.setRenderHint(QtGui.QPainter.RenderHint.Antialiasing)
    p.setPen(Qt.PenStyle.NoPen)
    p.setBrush(QtGui.QColor("#141414"))
    p.drawRoundedRect(0, 0, 64, 64, 14, 14)
    p.translate(8, 8)
    draw_logo(p, 48, QtGui.QColor("white"))
    p.end()
    return QtGui.QIcon(pm)


# One row in the device list: status dot, name, details and Online/Offline label.
class DeviceRow(QtWidgets.QWidget):
    def __init__(self, dev):
        super().__init__()
        self.setObjectName("row")
        lay = QtWidgets.QHBoxLayout(self)
        lay.setContentsMargins(12, 6, 14, 6)
        lay.setSpacing(12)

        dot = QtWidgets.QLabel()
        dot.setFixedSize(10, 10)
        dot.setObjectName("dotOn" if dev.online else "dotOff")
        lay.addWidget(dot)

        col = QtWidgets.QVBoxLayout()
        col.setSpacing(1)
        name = QtWidgets.QLabel(dev.name)
        name.setObjectName("devOn" if dev.online else "devOff")
        bits = [b for b in (dev.os, dev.ip) if b]
        if not dev.mine and dev.owner:
            bits.append(dev.owner)
        sub = QtWidgets.QLabel(" · ".join(bits))
        sub.setObjectName("small")
        col.addWidget(name)
        col.addWidget(sub)
        lay.addLayout(col, 1)

        status = QtWidgets.QLabel("Online" if dev.online else "Offline")
        status.setObjectName("statusOn" if dev.online else "statusOff")
        lay.addWidget(status)


# --------------------------------------------------------------------------- #
# Main window
# --------------------------------------------------------------------------- #
# The window has three pages in a QStackedWidget:
#   0 = pick a device, 1 = sending with progress, 2 = result (success / error)
class Window(QtWidgets.QWidget):
    def __init__(self, paths):
        super().__init__()
        self.paths = paths
        self.devices = []
        self.err = ""
        self.loaded = False
        self.target = None
        self.worker = None
        self.fetcher = None
        self._last_key = None
        self._success = False

        self.setWindowTitle("Taildrop")
        self.setWindowIcon(app_icon())
        self.resize(440, 620)
        self.setMinimumSize(380, 500)

        self.stack = QtWidgets.QStackedWidget()
        outer = QtWidgets.QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.addWidget(self.stack)
        self.stack.addWidget(self._build_pick())
        self.stack.addWidget(self._build_send())
        self.stack.addWidget(self._build_result())

        # Re-check device status periodically so Online/Offline stays current.
        self.timer = QtCore.QTimer(self)
        self.timer.timeout.connect(self.refresh)
        self.timer.start(4000)
        self.refresh()

    # ----- pages ----------------------------------------------------------- #
    def _build_pick(self):
        page = QtWidgets.QWidget()
        lay = QtWidgets.QVBoxLayout(page)
        lay.setContentsMargins(20, 20, 20, 16)
        lay.setSpacing(12)

        head = QtWidgets.QHBoxLayout()
        head.setSpacing(12)
        head.addWidget(Logo(30))
        tb = QtWidgets.QVBoxLayout()
        tb.setSpacing(0)
        t = QtWidgets.QLabel("Taildrop")
        t.setObjectName("title")
        s = QtWidgets.QLabel("Send to a device on your tailnet")
        s.setObjectName("muted")
        tb.addWidget(t)
        tb.addWidget(s)
        head.addLayout(tb, 1)
        lay.addLayout(head)

        chip = QtWidgets.QFrame()
        chip.setObjectName("chip")
        cl = QtWidgets.QVBoxLayout(chip)
        cl.setContentsMargins(14, 10, 14, 10)
        cl.setSpacing(1)
        title, sub = self._summary()
        c1 = QtWidgets.QLabel(elide(QtWidgets.QLabel(), title, 340))
        c1.setStyleSheet("font-weight: 600;")
        c2 = QtWidgets.QLabel(sub)
        c2.setObjectName("small")
        cl.addWidget(c1)
        cl.addWidget(c2)
        lay.addWidget(chip)

        self.search = QtWidgets.QLineEdit()
        self.search.setPlaceholderText("Search devices")
        self.search.setClearButtonEnabled(True)
        self.search.textChanged.connect(self.rebuild)
        self.search.returnPressed.connect(self.start_send)
        lay.addWidget(self.search)

        self.list = QtWidgets.QListWidget()
        self.list.setSelectionMode(QtWidgets.QAbstractItemView.SelectionMode.SingleSelection)
        self.list.setVerticalScrollMode(QtWidgets.QAbstractItemView.ScrollMode.ScrollPerPixel)
        self.list.itemSelectionChanged.connect(self.update_buttons)
        self.list.itemDoubleClicked.connect(lambda _i: self.start_send())
        lay.addWidget(self.list, 1)

        self.empty = QtWidgets.QLabel("Looking for devices…")
        self.empty.setObjectName("muted")
        self.empty.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.empty.setWordWrap(True)
        self.empty.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        lay.addWidget(self.empty, 1)

        hint = QtWidgets.QLabel("Only devices that are online can receive files.")
        hint.setObjectName("small")
        lay.addWidget(hint)

        row = QtWidgets.QHBoxLayout()
        row.addStretch(1)
        cancel = QtWidgets.QPushButton("Cancel")
        cancel.clicked.connect(self.close)
        self.send_btn = QtWidgets.QPushButton("Send")
        self.send_btn.setObjectName("primary")
        self.send_btn.setEnabled(False)
        self.send_btn.setDefault(True)
        self.send_btn.clicked.connect(self.start_send)
        row.addWidget(cancel)
        row.addWidget(self.send_btn)
        lay.addLayout(row)
        return page

    # Page 1: progress bar, speed/ETA labels and a Cancel button.
    def _build_send(self):
        page = QtWidgets.QWidget()
        lay = QtWidgets.QVBoxLayout(page)
        lay.setContentsMargins(28, 28, 28, 20)
        lay.setSpacing(10)
        lay.addStretch(1)

        logo = Logo(56)
        lay.addWidget(logo, 0, Qt.AlignmentFlag.AlignHCenter)
        lay.addSpacing(10)

        self.s_title = QtWidgets.QLabel("Sending…")
        self.s_title.setObjectName("title")
        self.s_title.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.s_file = QtWidgets.QLabel("")
        self.s_file.setObjectName("muted")
        self.s_file.setAlignment(Qt.AlignmentFlag.AlignCenter)
        lay.addWidget(self.s_title)
        lay.addWidget(self.s_file)
        lay.addSpacing(14)

        self.bar = QtWidgets.QProgressBar()
        self.bar.setRange(0, 1000)
        self.bar.setTextVisible(False)
        lay.addWidget(self.bar)

        row = QtWidgets.QHBoxLayout()
        self.s_left = QtWidgets.QLabel("")
        self.s_left.setObjectName("small")
        self.s_right = QtWidgets.QLabel("")
        self.s_right.setObjectName("small")
        self.s_right.setAlignment(Qt.AlignmentFlag.AlignRight)
        row.addWidget(self.s_left, 1)
        row.addWidget(self.s_right, 1)
        lay.addLayout(row)

        self.s_count = QtWidgets.QLabel("")
        self.s_count.setObjectName("small")
        self.s_count.setAlignment(Qt.AlignmentFlag.AlignCenter)
        lay.addWidget(self.s_count)

        lay.addStretch(2)
        self.s_cancel = QtWidgets.QPushButton("Cancel")
        self.s_cancel.clicked.connect(self.cancel_send)
        lay.addWidget(self.s_cancel, 0, Qt.AlignmentFlag.AlignHCenter)
        return page

    # Page 2: success or error message (only one of the two badges is visible).
    def _build_result(self):
        page = QtWidgets.QWidget()
        lay = QtWidgets.QVBoxLayout(page)
        lay.setContentsMargins(28, 28, 28, 20)
        lay.setSpacing(10)
        lay.addStretch(1)

        self.r_ok = QtWidgets.QLabel("✓")
        self.r_ok.setObjectName("okBadge")
        self.r_err = QtWidgets.QLabel("✕")
        self.r_err.setObjectName("errBadge")
        for b in (self.r_ok, self.r_err):
            b.setFixedSize(56, 56)
            b.setAlignment(Qt.AlignmentFlag.AlignCenter)
            lay.addWidget(b, 0, Qt.AlignmentFlag.AlignHCenter)
        lay.addSpacing(8)

        self.r_title = QtWidgets.QLabel("")
        self.r_title.setObjectName("title")
        self.r_title.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.r_title.setWordWrap(True)
        self.r_text = QtWidgets.QLabel("")
        self.r_text.setObjectName("errText")
        self.r_text.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.r_text.setWordWrap(True)
        self.r_text.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        lay.addWidget(self.r_title)
        lay.addWidget(self.r_text)
        lay.addStretch(2)

        row = QtWidgets.QHBoxLayout()
        row.addStretch(1)
        close = QtWidgets.QPushButton("Close")
        close.clicked.connect(self.close)
        self.r_retry = QtWidgets.QPushButton("Try again")
        self.r_retry.setObjectName("primary")
        self.r_retry.clicked.connect(lambda: self.start_send(self.target))
        row.addWidget(close)
        row.addWidget(self.r_retry)
        row.addStretch(1)
        lay.addLayout(row)
        return page

    # ----- data ------------------------------------------------------------ #
    def _summary(self):
        files = [p for p in self.paths if os.path.isfile(p)]
        dirs = [p for p in self.paths if os.path.isdir(p)]
        if len(self.paths) == 1:
            p = self.paths[0]
            name = os.path.basename(p.rstrip("/")) or p
            if files:
                return name, human_size(os.path.getsize(p))
            return name, "Folder — will be sent as .zip"
        parts = []
        if files:
            size = sum(os.path.getsize(f) for f in files)
            parts.append(f"{len(files)} file{'s' if len(files) != 1 else ''} ({human_size(size)})")
        if dirs:
            parts.append(f"{len(dirs)} folder{'s' if len(dirs) != 1 else ''} (zipped)")
        return f"{len(self.paths)} items", " · ".join(parts)

    # Start a background device fetch, unless one is already running
    # or we are not on the picker page.
    def refresh(self):
        if self.stack.currentIndex() != 0:
            return
        if self.fetcher is not None and self.fetcher.isRunning():
            return
        self.fetcher = Fetcher()
        self.fetcher.done.connect(self.on_devices)
        self.fetcher.start()

    # Called when a background fetch finishes; redraws only if the result differs
    # from the previous one.
    def on_devices(self, devs, err):
        self.loaded = True
        key = (err, tuple(devs or ()))
        if key == self._last_key:
            return  # nothing changed, avoid flicker
        self._last_key = key
        self.err = err
        self.devices = list(devs or [])
        self.rebuild()

    # The selected device, or None. Offline devices can't be selected,
    # but the online flag is re-checked anyway.
    def selected_device(self):
        items = self.list.selectedItems()
        if not items:
            return None
        ip = items[0].data(Qt.ItemDataRole.UserRole)
        for d in self.devices:
            if d.ip == ip and d.online:
                return d
        return None

    # Rebuild the list from self.devices, applying the search filter
    # and keeping the current selection.
    def rebuild(self, *_):
        """Redraw the device list (applies the search filter, keeps the selection)."""
        q = self.search.text().strip().lower()
        keep = None
        sel = self.list.selectedItems()
        if sel:
            keep = sel[0].data(Qt.ItemDataRole.UserRole)

        devs = [d for d in self.devices
                if not q or q in d.name.lower() or q in d.ip
                or q in d.os.lower() or q in d.owner.lower()]
        # Block signals while rebuilding so selection handlers don't fire for every item.
        self.list.blockSignals(True)
        self.list.clear()
        shown = False
        for title, group in (("YOUR DEVICES", [d for d in devs if d.mine]),
                             ("SHARED WITH YOU", [d for d in devs if not d.mine])):
            if not group:
                continue
            self._add_header(title)
            for d in group:
                self._add_device(d, d.ip == keep)
                shown = True
        self.list.blockSignals(False)

        if shown:
            self.list.setVisible(True)
            self.empty.setVisible(False)
        else:
            if self.err:
                text = f"Can’t get the device list\n\n{self.err}"
            elif not self.loaded:
                text = "Looking for devices…"
            elif q:
                text = "No matching devices"
            else:
                text = ("No devices can receive files.\n\n"
                        "Taildrop works between your own devices and devices "
                        "shared with you.")
            self.empty.setText(text)
            self.list.setVisible(False)
            self.empty.setVisible(True)
        self.update_buttons()

    # Non-selectable section title such as YOUR DEVICES.
    def _add_header(self, text):
        item = QtWidgets.QListWidgetItem()
        item.setFlags(Qt.ItemFlag.NoItemFlags)
        item.setSizeHint(QtCore.QSize(100, 30))
        label = QtWidgets.QLabel(text)
        label.setObjectName("section")
        label.setContentsMargins(4, 8, 0, 0)
        self.list.addItem(item)
        self.list.setItemWidget(item, label)

    # Add one device row. Only online devices are selectable, so the Send button
    # can never target an offline device.
    def _add_device(self, dev, select):
        item = QtWidgets.QListWidgetItem()
        item.setData(Qt.ItemDataRole.UserRole, dev.ip)
        item.setSizeHint(QtCore.QSize(100, 58))
        if dev.online:
            item.setFlags(Qt.ItemFlag.ItemIsSelectable | Qt.ItemFlag.ItemIsEnabled)
        else:
            # Enabled but not selectable: keeps the tooltip working.
            item.setFlags(Qt.ItemFlag.ItemIsEnabled)
            item.setToolTip("Offline — this device can’t receive files right now")
        self.list.addItem(item)
        self.list.setItemWidget(item, DeviceRow(dev))
        if select and dev.online:
            item.setSelected(True)

    # The Send button is enabled only while an online device is selected.
    def update_buttons(self):
        self.send_btn.setEnabled(self.selected_device() is not None)

    # ----- sending --------------------------------------------------------- #
    # Called by the Send button, double click, Enter and "Try again".
    def start_send(self, dev=None):
        dev = dev if isinstance(dev, Device) else self.selected_device()
        if dev is None or not dev.online:
            return
        self.target = dev
        self._success = False
        self.s_title.setText(f"Sending to {dev.name}")
        self.s_file.setText("Preparing…")
        self.s_left.setText("")
        self.s_right.setText("")
        self.s_count.setText("")
        self.bar.setRange(0, 1000)
        self.bar.setValue(0)
        self.s_cancel.setEnabled(True)
        self.stack.setCurrentIndex(1)

        w = SendWorker(self.paths, dev)
        w.phase.connect(lambda t: self.s_file.setText(elide(self.s_file, t, 360)))
        w.progress.connect(self.on_progress)
        w.sent.connect(self.on_sent)
        w.failed.connect(self.on_failed)
        self.worker = w
        w.start()

    # Update the progress bar and the bytes/speed/ETA labels.
    # A negative speed means progress could not be measured.
    def on_progress(self, done, total, speed, idx, count, name):
        self.s_file.setText(elide(self.s_file, f"Sending “{name}”", 360))
        if count > 1:
            self.s_count.setText(f"File {idx} of {count}")
        # A negative speed is the worker's signal that no progress data is
        # available, so show an indeterminate (moving) bar instead.
        if speed < 0:  # progress information unavailable
            self.bar.setRange(0, 0)
            self.s_left.setText(f"{human_size(total)} total")
            self.s_right.setText("Transferring…")
            return
        if self.bar.maximum() == 0:
            self.bar.setRange(0, 1000)
        # The bar uses 0..1000 so very large transfers can't overflow Qt's 32-bit integers.
        self.bar.setValue(int(1000 * min(done / total, 1.0)))
        self.s_left.setText(f"{human_size(done)} of {human_size(total)}  ·  {100 * done / total:.0f}%")
        if speed > 1:
            eta = (total - done) / speed
            self.s_right.setText(f"{human_size(speed)}/s  ·  {human_time(eta)} left")
        else:
            self.s_right.setText("")

    # Show the success page and close the window automatically after 4 seconds.
    def on_sent(self):
        self._success = True
        self.r_ok.setVisible(True)
        self.r_err.setVisible(False)
        self.r_retry.setVisible(False)
        self.r_title.setText(f"Sent to {self.target.name}")
        self.r_text.setText("The file is now on the other device.")
        self.stack.setCurrentIndex(2)
        QtCore.QTimer.singleShot(4000, self._auto_close)

    def _auto_close(self):
        if self._success and self.stack.currentIndex() == 2:
            self.close()

    # An empty message means the user cancelled; anything else is a real error to display.
    def on_failed(self, msg):
        if not msg:  # cancelled by the user
            self.stack.setCurrentIndex(0)
            self._last_key = None
            self.refresh()
            return
        self.r_ok.setVisible(False)
        self.r_err.setVisible(True)
        self.r_retry.setVisible(True)
        self.r_title.setText("Couldn’t send")
        self.r_text.setText(msg)
        self.stack.setCurrentIndex(2)

    # Ask the worker to stop; it terminates the tailscale process and removes temp files.
    def cancel_send(self):
        self.s_cancel.setEnabled(False)
        if self.worker:
            self.worker.cancel()

    # ----- events ---------------------------------------------------------- #
    def keyPressEvent(self, e):
        if e.key() == Qt.Key.Key_Escape and self.stack.currentIndex() != 1:
            self.close()
            return
        super().keyPressEvent(e)

    # Make sure no background thread is still running when the window closes;
    # an active send is cancelled so no half-finished transfer is left behind.
    def closeEvent(self, e):
        self.timer.stop()
        if self.worker is not None and self.worker.isRunning():
            self.worker.cancel()
            self.worker.wait(5000)
        if self.fetcher is not None and self.fetcher.isRunning():
            self.fetcher.wait(9000)
        e.accept()


# Entry point: set up Qt, pick a style that matches the system theme,
# and open the window for the paths Dolphin passes in.
def main():
    app = QtWidgets.QApplication(sys.argv[:1])
    app.setApplicationName("Taildrop")
    app.setStyle("Fusion")
    # Pick the dark or light theme from the system palette.
    dark = app.palette().window().color().lightness() < 128
    app.setStyleSheet(make_style(dark))

    paths = [os.path.abspath(a) for a in sys.argv[1:]]
    if not paths:
        QtWidgets.QMessageBox.information(
            None, "Taildrop",
            "Nothing to send.\nUse Dolphin: right click → Send via Taildrop.")
        return 0

    win = Window(paths)
    win.show()
    return app.exec() if hasattr(app, "exec") else app.exec_()


if __name__ == "__main__":
    sys.exit(main())
PYEOF
  chmod 0755 "${APP_DIR}/taildrop-send.py"
}

# Install the Dolphin right-click entry. The same file works for KDE 5 and 6;
# it is written to both locations. MimeType=all/allfiles + inode/directory
# makes it appear for any file and for folders.
write_service_menus() {
  local dir
  for dir in "${SERVICE_MENU_DIRS[@]}"; do
    mkdir -p "${dir}"
    cat > "${dir}/${SERVICE_MENU_FILE}" <<EOF
[Desktop Entry]
Type=Service
X-KDE-ServiceTypes=KonqPopupMenu/Plugin
MimeType=all/allfiles;inode/directory;
Actions=taildropSend;
X-KDE-Priority=TopLevel
X-KDE-StartupNotify=false
Icon=${APP_DIR}/taildrop.svg

[Desktop Action taildropSend]
Name=Send via Taildrop
Icon=${APP_DIR}/taildrop.svg
Exec="${APP_DIR}/taildrop-send.py" %F
EOF
    # KDE 6 only trusts service menus that are executable.
    chmod +x "${dir}/${SERVICE_MENU_FILE}"
  done
}

# --------------------------------------------------------------------------- #
# systemd (user)
# --------------------------------------------------------------------------- #
# Three small units:
#   tailreceive.service         runs the receiver and restarts it if it dies
#   tailreceive-reload.path     watches /etc/taildrop/taildrop.conf for changes
#   tailreceive-reload.service  restarts the receiver when the path unit fires
write_systemd_units() {
  mkdir -p "${SYSTEMD_DIR}"

  cat > "${SYSTEMD_DIR}/${SERVICE}.service" <<EOF
[Unit]
Description=Taildrop file receiver (config: ${ETC_CONF})

[Service]
Type=simple
UMask=0077
ExecStart="${APP_DIR}/taildrop-receive.sh"
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF

  cat > "${SYSTEMD_DIR}/${SERVICE}-reload.path" <<EOF
[Unit]
Description=Restart Taildrop receiver when ${ETC_CONF} changes

[Path]
PathChanged=${ETC_CONF}
Unit=${SERVICE}-reload.service

[Install]
WantedBy=default.target
EOF

  cat > "${SYSTEMD_DIR}/${SERVICE}-reload.service" <<EOF
[Unit]
Description=Apply Taildrop receiver configuration

[Service]
Type=oneshot
ExecStart=/usr/bin/env systemctl --user try-restart ${SERVICE}.service
EOF
}

# Reload systemd, enable the units for future logins and start them now.
enable_services() {
  systemctl --user daemon-reload
  systemctl --user enable --now "${SERVICE}.service" "${SERVICE}-reload.path"
  systemctl --user restart "${SERVICE}.service"
}

# --------------------------------------------------------------------------- #
# Commands
# --------------------------------------------------------------------------- #
# Install: check requirements, write files, configure Tailscale/systemd/KDE.
cmd_install() {
  preflight
  # Ask for the sudo password once up front instead of in the middle of the install.
  log "sudo is needed to set the Tailscale operator and create ${ETC_DIR}"
  sudo -v

  mkdir -p "${APP_DIR}"
  cleanup_legacy

  log "Installing files into ${APP_DIR}..."
  write_icon
  write_gui
  write_receiver_script
  # Keep a copy of this script so `uninstall` works even if the download is deleted.
  if [[ $(readlink -f "${BASH_SOURCE[0]}") != "$(readlink -f "${APP_DIR}/taildrop.sh")" ]]; then
    install -m 0755 "${BASH_SOURCE[0]}" "${APP_DIR}/taildrop.sh"
  fi

  setup_operator
  install_etc_config
  ensure_default_receive_dir

  log "Configuring systemd and the Dolphin menu..."
  write_systemd_units
  write_service_menus
  enable_services
  refresh_kde_cache
  manifest_set INSTALLED 1

  cat <<EOF

Done.
  * Dolphin: right click a file or folder -> "Send via Taildrop"
    (restart Dolphin if the entry does not show up).
  * Receiving: the ${SERVICE} service starts automatically at login.
  * Receiver config: ${ETC_CONF}
      sudoedit ${ETC_CONF}   # changes are applied automatically
  * Receiver logs:   journalctl --user -u ${SERVICE} -f
  * Uninstall:       ${APP_DIR}/taildrop.sh uninstall
EOF
}

# Uninstall: undo everything install did, using the manifest to know what to revert.
# Files you received are never deleted.
cmd_uninstall() {
  read -r -p "Remove Taildrop for Dolphin and the receiver service? Received files are kept. [y/N] " ans
  [[ ${ans} =~ ^[Yy] ]] || { echo "Aborted."; return 0; }
  [[ ${EUID} -ne 0 ]] || die "Run as a regular user, not root."
  sudo -v

  # 1. Stop the services and remove the unit files.
  log "Stopping and removing systemd units..."
  systemctl --user disable --now "${SERVICE}-reload.path" "${SERVICE}.service" 2>/dev/null || true
  systemctl --user stop "${SERVICE}-reload.service" 2>/dev/null || true
  rm -f "${SYSTEMD_DIR}/${SERVICE}.service" \
        "${SYSTEMD_DIR}/${SERVICE}-reload.path" \
        "${SYSTEMD_DIR}/${SERVICE}-reload.service"
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user reset-failed 2>/dev/null || true

  # 2. Remove the Dolphin menu entries (and the directories if they are now empty).
  log "Removing the Dolphin menu entry..."
  local dir
  for dir in "${SERVICE_MENU_DIRS[@]}"; do
    rm -f "${dir}/${SERVICE_MENU_FILE}"
    rmdir "${dir}" 2>/dev/null || true
  done
  rmdir "${DATA_HOME}/kio" 2>/dev/null || true
  cleanup_legacy
  refresh_kde_cache

  # 3. Restore the previous Tailscale operator, but only if we changed it.
  if [[ $(manifest_get OPERATOR_CHANGED) == 1 ]]; then
    local prev
    prev=$(manifest_get OPERATOR_PREV)
    log "Restoring Tailscale operator: '${prev:-<none>}'..."
    sudo tailscale set --operator="${prev}" || warn "Could not restore the Tailscale operator"
  fi

  # 4. Remove /etc/taildrop, but only if this installer created it.
  if [[ $(manifest_get ETC_CREATED) == 1 ]]; then
    log "Removing ${ETC_DIR}..."
    sudo rm -f "${ETC_CONF}"
    sudo rmdir "${ETC_DIR}" 2>/dev/null || true
  elif [[ -f ${ETC_CONF} ]]; then
    warn "${ETC_CONF} was not created by this script, leaving it in place."
  fi

  # 5. Remove the default receive directory only if we created it and it is
  #    empty (rmdir refuses to delete a directory that still contains files).
  local rdir
  rdir=$(manifest_get RECEIVE_DIR_CREATED)
  if [[ -n ${rdir} && -d ${rdir} ]]; then
    rmdir "${rdir}" 2>/dev/null && log "Removed empty directory ${rdir}" \
      || warn "${rdir} contains received files, leaving it in place."
  fi

  # 6. Finally remove the app directory (this also deletes the manifest).
  log "Removing ${APP_DIR}..."
  rm -rf "${APP_DIR}"

  echo "Done: Taildrop for Dolphin has been completely removed."
}

# Entry point: dispatch on the first argument.
main() {
  case "${1:-}" in
    install)   cmd_install ;;
    uninstall) cmd_uninstall ;;
    *) echo "Usage: ${0##*/} {install|uninstall}" >&2; exit 2 ;;
  esac
}

main "$@"
