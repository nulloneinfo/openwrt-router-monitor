#!/bin/sh
rm -f /www/cgi-bin/router_stats.sh
rm -f /www/temp.html

# -------------------------------------------------------------
# 1. HARDENED CGI DATA ENGINE (Backend)
# -------------------------------------------------------------
cat << 'EOF' > /www/cgi-bin/router_stats.sh
#!/bin/sh
echo "Content-Type: application/json"
echo "Cache-Control: no-store, no-cache, must-revalidate"
echo ""

HOSTNAME=$(hostname 2>/dev/null || echo "Unknown")

if [ -f /tmp/sysinfo/model ]; then
    MODEL=$(cat /tmp/sysinfo/model)
elif [ -f /proc/device-tree/model ]; then
    MODEL=$(cat /proc/device-tree/model)
else
    MODEL="Generic Router"
fi
MODEL=$(echo "$MODEL" | tr -d '\n\r\0')

if [ -f /etc/openwrt_release ]; then
    . /etc/openwrt_release
    FIRMWARE="${DISTRIB_DESCRIPTION:-OpenWrt}"
else
    FIRMWARE="OpenWrt Compatible"
fi
KERNEL=$(uname -r)

# Non-Blocking CPU
STAT_CACHE="/tmp/router_monitor.stat"
read cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
CURR_TOTAL=$((user+nice+system+idle+iowait+irq+softirq+steal))
CURR_IDLE=$((idle+iowait))

if [ -f "$STAT_CACHE" ]; then
    read PREV_TOTAL PREV_IDLE < "$STAT_CACHE"
    TOTAL_DIFF=$((CURR_TOTAL - PREV_TOTAL))
    IDLE_DIFF=$((CURR_IDLE - PREV_IDLE))
    if [ "$TOTAL_DIFF" -gt 0 ]; then
        CPU_USAGE=$(awk "BEGIN { printf \"%.0f\", (100 * ($TOTAL_DIFF - $IDLE_DIFF) / $TOTAL_DIFF) }")
    else
        CPU_USAGE="0"
    fi
else
    CPU_USAGE="0"
fi
echo "$CURR_TOTAL $CURR_IDLE" > "$STAT_CACHE"

LOAD=$(cut -d' ' -f1 /proc/loadavg)

# RAM
RAM_TOTAL=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
RAM_AVAIL=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
if [ -z "$RAM_AVAIL" ]; then
    RAM_FREE=$(awk '/MemFree/ {print $2}' /proc/meminfo)
    RAM_BUFF=$(awk '/Cached/ {print $2}' /proc/meminfo)
    RAM_AVAIL=$((RAM_FREE + RAM_BUFF))
fi
RAM_TOTAL_MB=$((RAM_TOTAL / 1024))
RAM_FREE_MB=$((RAM_AVAIL / 1024))
RAM_USED_MB=$((RAM_TOTAL_MB - RAM_FREE_MB))
RAM_PCT=$(( (RAM_USED_MB * 100) / RAM_TOTAL_MB ))

# Portable Overlay & Extroot Resolution
OVERLAY_DATA=$(df | grep -E 'overlay' | head -n 1)
if [ -z "$OVERLAY_DATA" ]; then
    OVERLAY_DATA=$(df / 2>/dev/null | tail -n 1)
fi
if [ -n "$OVERLAY_DATA" ]; then
    STR_TOTAL=$(echo "$OVERLAY_DATA" | awk '{print $2}')
    STR_USED=$(echo "$OVERLAY_DATA" | awk '{print $3}')
    STR_PCT=$(echo "$OVERLAY_DATA" | awk '{print $5}' | tr -d '%')
    STR_TOTAL_GB=$(awk "BEGIN {printf \"%.1f\", $STR_TOTAL/1048576}")
    STR_USED_GB=$(awk "BEGIN {printf \"%.1f\", $STR_USED/1048576}")
else
    STR_TOTAL_GB="0.0" ; STR_USED_GB="0.0" ; STR_PCT="0"
fi

# Generic Multi-Sensor / Thermal Zone Parsing Engine
SENSORS_JSON=""
# 1. Check all hwmon directories and look for ANY numerical temp inputs
for hdir in /sys/class/hwmon/hwmon*; do
    if [ -d "$hdir" ]; then
        SNAME=$(cat "$hdir/name" 2>/dev/null || echo "Zone")
        case "$SNAME" in
            *cpu*|*CPU*|*soc*|*SoC*) SNAME="CPU" ;;
            *mtk*|*thermal*) SNAME="SoC" ;;
        esac
        for tfile in "$hdir"/temp*_input; do
            if [ -f "$tfile" ]; then
                SRAW=$(cat "$tfile" 2>/dev/null)
                if [ -n "$SRAW" ] && [ "$SRAW" -gt 0 ] 2>/dev/null; then
                    SVAL=$(awk -v r="$SRAW" 'BEGIN { printf "%.1f", r/1000 }')
                    # Keep track of multiple temp inputs per hwmon device mapping
                    SUF=$(echo "$tfile" | grep -oE 'temp[0-9]+' | tr -d 'temp')
                    SENSORS_JSON="${SENSORS_JSON}{\"name\":\"$SNAME-$SUF\",\"temp\":$SVAL},"
                fi
            fi
        done
    fi
done
# 2. Fall back to thermal_zone entries if hwmon collection returns empty
if [ -z "$SENSORS_JSON" ]; then
    for tzone in /sys/class/thermal/thermal_zone*; do
        if [ -f "$tzone/temp" ]; then
            SRAW=$(cat "$tzone/temp" 2>/dev/null)
            ZNAME=$(cat "$tzone/type" 2>/dev/null || echo "Zone")
            if [ -n "$SRAW" ]; then
                SVAL=$(awk -v r="$SRAW" 'BEGIN { printf "%.1f", r/1000 }')
                SENSORS_JSON="${SENSORS_JSON}{\"name\":\"$ZNAME\",\"temp\":$SVAL},"
            fi
        fi
    done
fi
SENSORS_JSON="[${SENSORS_JSON%,}]"

# Outbound IP Routing
WAN_IP="Disconnected"
for dev in $(ip route show default | awk '/default/ {print $5}'); do
    IP_ADDR=$(ip -4 addr show dev "$dev" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n 1)
    if [ -n "$IP_ADDR" ]; then
        WAN_IP="$IP_ADDR"
        break
    fi
done

UP=$(cut -d. -f1 /proc/uptime)
DAYS=$((UP/86400)) ; HOURS=$(((UP%86400)/3600)) ; MINS=$(((UP%3600)/60))
if [ "$DAYS" -gt 0 ]; then UPTIME="${DAYS}d ${HOURS}h"
elif [ "$HOURS" -gt 0 ]; then UPTIME="${HOURS}h ${MINS}m"
else UPTIME="${MINS}m" ; fi

NOW=$(date '+%H:%M:%S')

printf '{"hostname":"%s","model":"%s","firmware":"%s","kernel":"%s","cpu_usage":%s,"load":"%s","ram_free":%s,"ram_total":%s,"ram_used_percent":%s,"overlay_total":"%s","overlay_used":"%s","overlay_percent":%s,"wan_ip":"%s","uptime":"%s","time":"%s","sensors":%s}\n' \
    "$HOSTNAME" "$MODEL" "$FIRMWARE" "$KERNEL" "$CPU_USAGE" "$LOAD" "$RAM_FREE_MB" "$RAM_TOTAL_MB" "$RAM_PCT" "$STR_TOTAL_GB" "$STR_USED_GB" "$STR_PCT" "$WAN_IP" "$UPTIME" "$NOW" "$SENSORS_JSON"
EOF

chmod 755 /www/cgi-bin/router_stats.sh

# -------------------------------------------------------------
# 2. OPTIMIZED RESPONSIVE UI DASHBOARD (Frontend)
# -------------------------------------------------------------
cat << 'EOF' > /www/temp.html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>OpenWrt Router Monitor v2.0</title>
<style>
:root {
    --bg: #07111f; --card: #0b1a2d; --text: #ffffff; --muted: #9aa8ba;
    --blue: #4db8ff; --green: #34d058; --yellow: #ffb347; --orange: #ff7733; --red: #ff5c5c;
}
body {
    margin: 0; padding: 20px; font-family: system-ui, -apple-system, sans-serif;
    background: var(--bg); color: var(--text);
}
.container { max-width: 1000px; margin: auto; }
.header-panel {
    background: var(--card); border-radius: 16px; padding: 24px; margin-bottom: 24px;
    display: flex; flex-wrap: wrap; justify-content: space-between; align-items: center; gap: 16px;
}
.brand-title h1 { margin: 0; font-size: 26px; font-weight: 800; }
.brand-title p { margin: 4px 0 0; color: var(--muted); font-size: 14px; }
.sys-meta-info { font-size: 13px; color: var(--muted); line-height: 1.6; text-align: right; }
.sys-meta-info span { color: var(--text); font-weight: 600; }
/* Adaptive Mobile Width Layout Upgraded to 280px */
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 20px; margin-bottom: 24px; }
.card { background: var(--card); border-radius: 16px; padding: 20px; display: flex; flex-direction: column; justify-content: space-between; }
.label { color: var(--muted); text-transform: uppercase; letter-spacing: 0.8px; font-size: 11px; margin-bottom: 10px; font-weight: 700; }
.value-container { display: flex; align-items: baseline; justify-content: space-between; }
.value { font-size: 38px; font-weight: 800; line-height: 1; }
.sub-value { font-size: 13px; color: var(--muted); font-weight: 500; }
.meter-bar { width: 100%; height: 6px; background: rgba(255,255,255,0.08); border-radius: 4px; margin-top: 14px; overflow: hidden; }
.meter-fill { height: 100%; width: 0%; border-radius: 4px; transition: width 0.4s ease; }
.status-dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 6px; }
.bg-blue { background-color: var(--blue); } .bg-green { background-color: var(--green); }
.bg-yellow { background-color: var(--yellow); } .bg-orange { background-color: var(--orange); } .bg-red { background-color: var(--red); }
.text-blue { color: var(--blue); } .text-green { color: var(--green); }
.text-yellow { color: var(--yellow); } .text-orange { color: var(--orange); } .text-red { color: var(--red); }
.interactive-ctr { text-align: center; margin: 30px 0; }
button { padding: 10px 24px; border: none; border-radius: 8px; background: #3ea6ff; color: white; cursor: pointer; font-weight: 600; }
.footer { border-top: 1px solid rgba(255,255,255,0.06); padding-top: 20px; text-align: center; color: var(--muted); font-size: 13px; }
.footer a { color: #3ea6ff; text-decoration: none; font-weight: 600; }
@media (max-width: 640px) {
    .header-panel { flex-direction: column; align-items: flex-start; }
    .sys-meta-info { text-align: left; }
    .grid { grid-template-columns: 1fr; gap: 14px; }
}
</style>
</head>
<body>
<div class="container">
    <header class="header-panel">
        <div class="brand-title">
            <h1 id="nodeHostname">OpenWrt Router Monitor</h1>
            <p>System Monitoring Dashboard</p>
        </div>
        <div class="sys-meta-info">
            Model: <span id="metaModel">--</span><br>
            Firmware: <span id="metaFirmware">--</span><br>
            Kernel: <span id="metaKernel">--</span>
        </div>
    </header>

    <div class="grid">
        <div class="card">
            <div class="label">CPU Usage</div>
            <div class="value-container"><div id="cpuVal" class="value text-blue">--</div></div>
            <div class="meter-bar"><div id="cpuFill" class="meter-fill bg-blue"></div></div>
        </div>
        <div class="card">
            <div class="label">System Load</div>
            <div class="value-container" style="margin-top: 4px;"><div id="loadVal" class="value" style="font-size:42px;">--</div></div>
        </div>
        <div class="card">
            <div class="label">RAM Allocation</div>
            <div class="value-container"><div id="ramVal" class="value text-green">--</div><div id="ramSub" class="sub-value">--</div></div>
            <div class="meter-bar"><div id="ramFill" class="meter-fill bg-green"></div></div>
        </div>
        <div class="card">
            <div class="label">Overlay Space</div>
            <div class="value-container"><div id="storageVal" class="value text-yellow">--</div><div id="storageSub" class="sub-value">--</div></div>
            <div class="meter-bar"><div id="storageFill" class="meter-fill bg-yellow"></div></div>
        </div>
        <div class="card">
            <div class="label">WAN IP Endpoint</div>
            <div class="value-container" style="margin-top:8px;"><div id="wanVal" style="font-size:18px; font-weight:700;">--</div></div>
            <div style="font-size:12px; margin-top:14px; color:var(--muted);"><span id="wanDot" class="status-dot"></span><span id="wanStatusText">Checking</span></div>
        </div>
        <div class="card">
            <div class="label">System Uptime</div>
            <div class="value-container" style="margin-top:8px;"><div id="uptimeVal" class="value text-orange" style="font-size:30px;">--</div></div>
            <div id="lastUpdateText" style="font-size:12px; margin-top:18px; color:var(--muted);">Syncing...</div>
        </div>
    </div>

    <h3 style="margin: 24px 0 12px; font-size:12px; text-transform:uppercase; letter-spacing:1px; color:var(--muted);">Hardware Temperature Zones</h3>
    <div class="grid" id="sensorGrid"></div>

    <div class="interactive-ctr"><button id="refreshBtn" onclick="syncData()">Refresh Now</button></div>
    <footer class="footer">
        <div><strong>OpenWrt Router Monitor</strong> Engine v2.0 | Created by <a href="https://github.com/nulloneinfo" target="_blank">nulloneinfo ↗</a></div>
    </footer>
</div>

<script>
function getTempColorClass(t) {
    if (t < 45) return ['text-blue', 'bg-blue'];
    if (t < 60) return ['text-green', 'bg-green'];
    if (t < 70) return ['text-yellow', 'bg-yellow'];
    if (t < 80) return ['text-orange', 'bg-orange'];
    return ['text-red', 'bg-red'];
}

function syncData() {
    const btn = document.getElementById("refreshBtn");
    btn.disabled = true; btn.textContent = "Refreshing...";

    fetch(window.location.origin + "/cgi-bin/router_stats.sh?" + Date.now(), { cache: "no-store" })
    .then(r => r.json())
    .then(data => {
        document.getElementById("nodeHostname").textContent = "OpenWrt Router Monitor";
        document.getElementById("metaModel").textContent = data.model;
        document.getElementById("metaFirmware").textContent = data.firmware;
        document.getElementById("metaKernel").textContent = data.kernel;

        document.getElementById("cpuVal").textContent = data.cpu_usage + "%";
        document.getElementById("cpuFill").style.width = data.cpu_usage + "%";
        
        document.getElementById("loadVal").textContent = data.load;

        document.getElementById("ramVal").textContent = data.ram_used_percent + "%";
        document.getElementById("ramSub").textContent = `${data.ram_total - data.ram_free}/${data.ram_total} MB`;
        document.getElementById("ramFill").style.width = data.ram_used_percent + "%";

        document.getElementById("storageVal").textContent = data.overlay_percent + "%";
        document.getElementById("storageSub").textContent = `${data.overlay_used}/${data.overlay_total} GB`;
        document.getElementById("storageFill").style.width = data.overlay_percent + "%";

        document.getElementById("wanVal").textContent = data.wan_ip;
        const wDot = document.getElementById("wanDot");
        const wTxt = document.getElementById("wanStatusText");
        if(data.wan_ip !== "Disconnected") {
            wDot.className = "status-dot bg-green"; wTxt.textContent = "Online Connected";
        } else {
            wDot.className = "status-dot bg-red"; wTxt.textContent = "Disconnected";
        }

        document.getElementById("uptimeVal").textContent = data.uptime;
        document.getElementById("lastUpdateText").textContent = "Last Polled: " + data.time;

        const sGrid = document.getElementById("sensorGrid");
        sGrid.innerHTML = "";
        if (data.sensors && data.sensors.length > 0) {
            data.sensors.forEach((s) => {
                const cPair = getTempColorClass(s.temp);
                const sCard = document.createElement("div");
                sCard.className = "card";
                sCard.innerHTML = `
                    <div class="label">${s.name || 'Sensor'}</div>
                    <div class="value-container"><div class="value ${cPair[0]}">${s.temp}°C</div></div>
                    <div class="meter-bar"><div class="meter-fill ${cPair[1]}" style="width: ${Math.min((s.temp/100)*100, 100)}%"></div></div>
                `;
                sGrid.appendChild(sCard);
            });
        } else {
            sGrid.innerHTML = `<div class="card" style="grid-column: 1/-1; text-align:center; color:var(--red)">No thermal sensors found.</div>`;
        }
    })
    .catch(err => {
        console.error("Pipeline failure: ", err);
        document.getElementById("lastUpdateText").textContent = "Connection Failure";
    })
    .finally(() => {
        btn.disabled = false; btn.textContent = "Refresh Now";
    });
}
syncData();
setInterval(syncData, 5000);
</script>
</body>
</html>
EOF

chmod 644 /www/temp.html

/etc/init.d/uhttpd reload >/dev/null 2>&1 || /etc/init.d/uhttpd restart
echo "[+] Hardened Deployment completed successfully."