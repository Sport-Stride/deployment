import json

with open("/tmp/metric_names.json") as f:
    data = json.load(f)

names = data["data"]
mongo = [n for n in names if "mongo" in n.lower()]
frontend = [n for n in names if "frontend" in n.lower()]
gin = [n for n in names if "gin" in n.lower() or "http" in n.lower()]

print("=== MONGO METRICS ===")
for n in mongo:
    print(n)

print("\n=== FRONTEND METRICS ===")
for n in frontend:
    print(n)
