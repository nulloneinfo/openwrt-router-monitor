#!/bin/sh
set -e

TS="$(date +%Y%m%d_%H%M%S)"
CGI_DIR="/www/cgi-bin"
CGI_FILE="$CGI_DIR/router_stats.sh"
HTML_FILE="/www/temp.html"

echo "Installing Router Monitor..."

mkdir -p "$CGI_DIR"

# Detect first temperature sensor
SENSOR=""
for p in /sys/class/hwmon/hwmon*/temp1_input; do
    [ -f "$p" ] && SENSOR="$p" && break
done

if [ -z "$SENSOR" ]; then
    echo "ERROR: No temperature sensor found under /sys/class/hwmon/"
    exit 1
fi

echo "Using sensor: $SENSOR"

# Backup old files
if [ -f "$CGI_FILE" ]; then
    cp -a "$CGI_FILE" "${CGI_FILE}.bak_$TS"
    echo "Backed up: $CGI_FILE -> ${CGI_FILE}.bak_$TS"
fi

if [ -f "$HTML_FILE" ]; then
    cp -a "$HTML_FILE" "${HTML_FILE}.bak_$TS"
    echo "Backed up: $HTML_FILE -> ${HTML_FILE}.bak_$TS"
fi

# Install CGI backend
cat <<EOF > "$CGI_FILE"
#!/bin/sh
echo "Content-Type: application/json"
echo ""

SENSOR="$SENSOR"

# Temperature
if [ -f "\$SENSOR" ]; then
    RAW=\$(cat "\$SENSOR" 2>/dev/null)
    if printf '%s' "\$RAW" | grep -qE '^[0-9]+$'; then
        TEMP=\$(awk -v r="\$RAW" 'BEGIN { printf "%.1f", r/1000 }')
    else
        TEMP=null
    fi
else
    TEMP=null
fi

# CPU Usage (%), calculated from /proc/stat with 1-second sample
read cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
TOTAL1=\$((user+nice+system+idle+iowait+irq+softirq+steal))
IDLE1=\$((idle+iowait))

sleep 1

read cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
TOTAL2=\$((user+nice+system+idle+iowait+irq+softirq+steal))
IDLE2=\$((idle+iowait))

TOTAL_DIFF=\$((TOTAL2-TOTAL1))
IDLE_DIFF=\$((IDLE2-IDLE1))

if [ "\$TOTAL_DIFF" -gt 0 ]; then
    CPU=\$(awk "BEGIN { printf \"%.0f\", (100 * (\$TOTAL_DIFF - \$IDLE_DIFF) / \$TOTAL_DIFF) }")
else
    CPU="0"
fi

# RAM free in MB
RAM=\$(awk '/MemAvailable/ {printf "%.0f", \$2/1024}' /proc/meminfo)

# Uptime
UP=\$(cut -d. -f1 /proc/uptime)
DAYS=\$((UP/86400))
HOURS=\$(((UP%86400)/3600))
MINS=\$(((UP%3600)/60))

if [ "\$DAYS" -gt 0 ]; then
    UPTIME="\${DAYS}d \${HOURS}h"
elif [ "\$HOURS" -gt 0 ]; then
    UPTIME="\${HOURS}h \${MINS}m"
else
    UPTIME="\${MINS}m"
fi

NOW=\$(date '+%H:%M:%S')

printf '{"temp":%s,"cpu":"%s","ram":"%s","uptime":"%s","time":"%s"}\n' \
    "\$TEMP" "\$CPU" "\$RAM" "\$UPTIME" "\$NOW"
EOF

chmod 755 "$CGI_FILE"
echo "Installed CGI -> $CGI_FILE"

# Install dashboard
cat <<'EOF' > "$HTML_FILE"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>OpenWrt ROUTER MONITOR Monitor | nulloneinfo</title>

<style>
:root{
    --bg:#07111f;
    --card:#0b1a2d;
    --text:#ffffff;
    --muted:#9aa8ba;
}
body{
    margin:0;
    padding:20px;
    font-family:system-ui,sans-serif;
    background:var(--bg);
    color:var(--text);
}
.container{
    max-width:1100px;
    margin:auto;
}
.header{
    background:rgba(11,26,45,.96);
    border-radius:18px;
    padding:24px;
    margin-bottom:20px;
    box-shadow:0 10px 30px rgba(0,0,0,.18);
}
.title{
    font-size:36px;
    font-weight:800;
    letter-spacing:.5px;
}
.subtitle{
    margin-top:6px;
    color:var(--muted);
}
.grid{
    display:grid;
    grid-template-columns:repeat(auto-fit,minmax(240px,1fr));
    gap:20px;
}
.card{
    background:var(--card);
    border-radius:18px;
    padding:24px;
    box-shadow:0 10px 30px rgba(0,0,0,.22);
}
.label{
    color:#9fb0c7;
    text-transform:uppercase;
    letter-spacing:1px;
    font-size:13px;
    margin-bottom:12px;
}
.value{
    font-size:52px;
    font-weight:800;
    line-height:1;
}
.green{color:#34d058;}
.blue{color:#4db8ff;}
.purple{color:#bb86fc;}
.orange{color:#ffb347;}
.red{color:#ff5c5c;}
.footer{
    margin-top:26px;
    text-align:center;
    color:#7f93ab;
    font-size:14px;
}
.credit{
    margin-top:8px;
    color:#9fb0c7;
}
.version{
    margin-top:4px;
    color:#6f8197;
    font-size:12px;
}
.time{
    margin-top:8px;
    color:#91a4bb;
    font-size:13px;
}
button{
    margin-top:18px;
    padding:10px 18px;
    border:none;
    border-radius:10px;
    background:#3ea6ff;
    color:white;
    cursor:pointer;
    font-weight:600;
}
button:hover{
    opacity:.92;
}
button:disabled{
    opacity:.6;
    cursor:not-allowed;
}
</style>
</head>
<body>

<div class="container">

<div class="header">
    <div class="title">OPENWRT ROUTER MONITOR</div>
    <div class="subtitle">Lightweight OpenWrt Advance Monitoring Dashboard</div>
</div>

<div class="grid">
    <div class="card">
        <div class="label">CPU Temperature</div>
        <div id="temp" class="value green">--</div>
    </div>

    <div class="card">
        <div class="label">CPU Usage</div>
        <div id="cpu" class="value blue">--</div>
    </div>

    <div class="card">
        <div class="label">RAM Free</div>
        <div id="ram" class="value purple">--</div>
    </div>

    <div class="card">
        <div class="label">Uptime</div>
        <div id="uptime" class="value orange">--</div>
    </div>
</div>

<div style="text-align:center">
    <button id="refreshBtn" onclick="update()">Refresh Now</button>
</div>

<div class="footer">
    <div id="updated" class="time">Last Update: --</div>
    <div class="credit">Created by <strong>nulloneinfo</strong></div>
    <div class="version">OpenWrt Router Monitor v1.2</div>
    <div class="version">OpenWrt / ImmortalWrt /XWrt Compatible</div>
</div>

</div>

<script>
function update() {
    const btn = document.getElementById("refreshBtn");
    btn.disabled = true;
    btn.textContent = "Refreshing...";

    fetch(window.location.origin + "/cgi-bin/router_stats.sh?" + Date.now(), {
        cache: "no-store"
    })
    .then(r => r.json())
    .then(j => {
        const t = document.getElementById("temp");
        if (j.temp !== null) {
            t.innerHTML = j.temp + "°C";
            t.className = "value";
            if (j.temp >= 80) t.classList.add("red");
            else if (j.temp >= 65) t.classList.add("orange");
            else t.classList.add("green");
        } else {
            t.innerHTML = "N/A";
            t.className = "value red";
        }

        document.getElementById("cpu").innerHTML = j.cpu + "%";
        document.getElementById("ram").innerHTML = j.ram + " MB";
        document.getElementById("uptime").innerHTML = j.uptime;
        document.getElementById("updated").innerHTML = "Last Update: " + j.time;
    })
    .catch(() => {
        document.getElementById("temp").innerHTML = "N/A";
        document.getElementById("cpu").innerHTML = "N/A";
        document.getElementById("ram").innerHTML = "N/A";
        document.getElementById("uptime").innerHTML = "N/A";
        document.getElementById("updated").innerHTML = "Last Update: --";
    })
    .finally(() => {
        btn.disabled = false;
        btn.textContent = "Refresh Now";
    });
}

update();
setInterval(update, 5000);
</script>

</body>
</html>
EOF

chmod 644 "$HTML_FILE"

# Reload uhttpd
/etc/init.d/uhttpd reload >/dev/null 2>&1 || /etc/init.d/uhttpd restart

echo
echo "Done."
echo "Open: http://<router-ip>/temp.html"
echo "Created by nulloneinfo"
