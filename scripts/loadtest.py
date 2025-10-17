#!/usr/bin/env python3
import asyncio, aiohttp, random, time, statistics, sys, json

HOSTS = ["http://foo.localhost", "http://bar.localhost"]
CONCURRENCY = int(sys.argv[1]) if len(sys.argv) > 1 else 50
DURATION = int(sys.argv[2]) if len(sys.argv) > 2 else 30  # seconds

async def worker(session, end_time, latencies, failures, per_host):
    while time.time() < end_time:
        url = random.choice(HOSTS)
        start = time.time()
        try:
            async with session.get(url) as resp:
                status = resp.status
                if status != 200:
                    failures.append((url, status))
                    per_host[url]['failed'] += 1
                else:
                    per_host[url]['success'] += 1
        except Exception as e:
            failures.append((url, str(e)))
            per_host[url]['failed'] += 1
        finally:
            latencies.append((time.time() - start) * 1000)  # ms
        await asyncio.sleep(random.random() * 0.05)

async def main():
    latencies = []
    failures = []
    per_host = {h: {'success':0, 'failed':0} for h in HOSTS}
    end_time = time.time() + DURATION
    timeout = aiohttp.ClientTimeout(total=10)
    conn = aiohttp.TCPConnector(limit=0)
    async with aiohttp.ClientSession(timeout=timeout, connector=conn) as session:
        tasks = [asyncio.create_task(worker(session, end_time, latencies, failures, per_host))
                 for _ in range(CONCURRENCY)]
        await asyncio.gather(*tasks)

    total = len(latencies)
    failed = sum(v['failed'] for v in per_host.values())
    avg = statistics.mean(latencies) if latencies else 0
    p90 = statistics.quantiles(latencies, n=100)[89] if len(latencies) > 10 else 0
    p95 = statistics.quantiles(latencies, n=100)[94] if len(latencies) > 10 else 0
    req_per_sec = total / DURATION if DURATION > 0 else 0
    fail_rate = (failed / total * 100) if total else 0

    # print a machine-friendly JSON summary to stdout to be consumed by runner
    summary = {
        'requests_total': total,
        'requests_per_sec': round(req_per_sec,2),
        'failures': failed,
        'failure_rate_percent': round(fail_rate,3),
        'latency_avg_ms': round(avg,3),
        'latency_p90_ms': round(p90,3),
        'latency_p95_ms': round(p95,3),
        'per_host': per_host
    }
    print(json.dumps(summary))
    # also print human readable
    print("\nHuman readable summary:\n")
    print(f"Requests total: {total}")
    print(f"Requests/sec: {req_per_sec:.2f}")
    print(f"Failures: {failed} ({fail_rate:.2f}%)")
    print(f"Latency avg: {avg:.2f} ms") 
    print(f"Latency p90: {p90:.2f} ms") 
    print(f"Latency p95: {p95:.2f} ms")

if __name__ == "__main__":
    asyncio.run(main())
