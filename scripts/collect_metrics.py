#!/usr/bin/env python3
import requests, csv, sys, time, base64, statistics, json, os
import pandas as pd
import matplotlib.pyplot as plt

PROM = 'http://127.0.0.1:9090'
START = int(sys.argv[1])
END = int(sys.argv[2])
STEP = sys.argv[3] if len(sys.argv)>3 else '15s'

queries = {
    'cpu_foo': 'avg(rate(container_cpu_usage_seconds_total{namespace="default",pod=~"foo.*"}[30s]))',
    'cpu_bar': 'avg(rate(container_cpu_usage_seconds_total{namespace="default",pod=~"bar.*"}[30s]))',
    'mem_foo': 'avg(container_memory_usage_bytes{namespace="default",pod=~"foo.*"})',
    'mem_bar': 'avg(container_memory_usage_bytes{namespace="default",pod=~"bar.*"})',
    'cpu_node': 'sum(rate(node_cpu_seconds_total{mode!="idle"}[30s]))',
    'mem_node': 'sum(node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes)'
}

def query_range(q, start, end, step):
    url = f"{PROM}/api/v1/query_range"
    params = {'query': q, 'start': start, 'end': end, 'step': step}
    r = requests.get(url, params=params, timeout=30)
    r.raise_for_status()
    data = r.json()
    if data.get('status') != 'success':
        return []
    results = data['data'].get('result', [])
    if not results:
        return []
    ts_map = {}
    for serie in results:
        for ts, val in serie.get('values', []):
            ts_map.setdefault(float(ts), []).append(float(val))
    rows = []
    for ts in sorted(ts_map.keys()):
        vals = ts_map[ts]
        rows.append((ts, sum(vals)/len(vals)))
    return rows

outputs = {}
for name, q in queries.items():
    rows = query_range(q, START, END, STEP)
    outputs[name] = rows
    csv_path = f"metrics_{name}.csv"
    with open(csv_path, 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(['timestamp', 'value'])
        for ts, val in rows:
            writer.writerow([ts, val])

png_files = []
for name, rows in outputs.items():
    if not rows:
        continue
    import pandas as pd
    df = pd.DataFrame(rows, columns=['ts','value'])
    df['time'] = pd.to_datetime(df['ts'], unit='s')
    fig, ax = plt.subplots(figsize=(8,3))
    ax.plot(df['time'], df['value'])
    ax.set_title(name)
    ax.set_xlabel('time')
    ax.set_ylabel('value')
    fig.tight_layout()
    png = f"{name}.png"
    fig.savefig(png)
    plt.close(fig)
    png_files.append(png)

summary = []
for name, rows in outputs.items():
    vals = [v for _, v in rows]
    if not vals:
        continue
    avg = statistics.mean(vals)
    p90 = statistics.quantiles(vals, n=100)[89] if len(vals)>10 else vals[-1]
    p95 = statistics.quantiles(vals, n=100)[94] if len(vals)>10 else vals[-1]
    summary.append((name, avg, p90, p95))

print('\nPrometheus metrics summary:')
for name, avg, p90, p95 in summary:
    print(f"{name}: avg={avg:.6f}, p90={p90:.6f}, p95={p95:.6f}")

imgs = {}
for png in png_files:
    with open(png, 'rb') as f:
        b64 = base64.b64encode(f.read()).decode('ascii')
    imgs[png] = f"data:image/png;base64,{b64}"

out_path = os.path.join(os.getcwd(), "metrics_summary.json")
out = {'summary':[{'metric':n,'avg':a,'p90':p,'p95':pp} for (n,a,p,pp) in summary], 'images': imgs}
with open(out_path, 'w') as f:
    json.dump(out, f)
print(f'\nWrote {out_path} and PNGs.')
