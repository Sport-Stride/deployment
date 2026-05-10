import sys, json
d = json.load(sys.stdin)
results = d["data"]["result"]
sorted_r = sorted(results, key=lambda x: float(x["value"][1]), reverse=True)
for r in sorted_r[:30]:
    svc = r["metric"].get("service", r["metric"].get("job", "?"))
    url = r["metric"].get("url", "?")
    ms = float(r["value"][1]) * 1000
    print(svc + " | " + url + " | " + str(round(ms, 1)) + "ms")
