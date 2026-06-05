# procurement.pyx

# ── System Oveview acquisition ───────────────────────────────────────────── #
import platform
import socket

from protocol import SystemInfo

def read_os_release() -> str:
    pretty_name = ""
    name = ""
    version = ""

    try:
        with open("/etc/os-release", "r", encoding="utf-8", errors="replace") as fh:
            for raw_line in fh:
                line = raw_line.strip()
                if not line or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                value = value.strip().strip('"')
                if key == "PRETTY_NAME":
                    pretty_name = value
                elif key == "NAME":
                    name = value
                elif key == "VERSION":
                    version = value
    except OSError:
        return ""

    if pretty_name:
        return pretty_name
    return " ".join(part for part in (name, version) if part).strip()


def get_primary_ipv4() -> str:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.connect(("8.8.8.8", 80))
            return str(sock.getsockname()[0] or "")
    except OSError:
        return ""


def get_primary_interface() -> str:
    try:
        with open("/proc/net/route", "r", encoding="utf-8", errors="replace") as fh:
            next(fh, None)
            for line in fh:
                cols = line.split()
                if len(cols) >= 2 and cols[1] == "00000000":
                    return cols[0]
    except OSError:
        pass
    return ""

def __read_first_line(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.readline().strip()
    except OSError:
        return ""

def get_mac_address(iface: str) -> str:
    if not iface:
        return ""
    return __read_first_line(f"/sys/class/net/{iface}/address")


def read_cpu_info() -> tuple[str, str]:
    model = ""
    vendor = ""
    try:
        with open("/proc/cpuinfo", "r", encoding="utf-8", errors="replace") as fh:
            for raw_line in fh:
                line = raw_line.strip()
                if not line or ":" not in line:
                    continue
                key, value = [part.strip() for part in line.split(":", 1)]
                if key == "model name" and not model:
                    model = value
                elif key == "vendor_id" and not vendor:
                    vendor = value
                if model and vendor:
                    break
    except OSError:
        return "", ""
    return model, vendor

def read_ram_gbs() -> int:
    try:
        with open("/proc/meminfo", "r", encoding="utf-8", errors="replace") as fh:
            for raw_line in fh:
                if not raw_line.startswith("MemTotal:"):
                    continue
                parts = raw_line.split()
                if len(parts) < 2:
                    return 0
                kib = int(parts[1])
                return max(1, round(kib / (1024 * 1024)))
    except (OSError, ValueError):
        return 0
    return 0

def collect_system_info() -> SystemInfo:
    uname = platform.uname()

    ret = SystemInfo()
    
    ret.hostname  = socket.gethostname()
    ret.kernelver = "".join(part for part in (uname.release, uname.machine) if part).strip()
    ret.distro    = read_os_release()
    ret.ipaddr    = get_primary_ipv4()
    ret.macaddr   = get_mac_address(get_primary_interface())
    ret.processor, ret.processor_vend = read_cpu_info()
    ret.ram_gbs   = read_ram_gbs()

    return ret
