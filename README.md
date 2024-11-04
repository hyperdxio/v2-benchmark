# Benchmark against Grafana Loki + Grafana Clickhouse + ELK + HyperDX


## Step 1: Spin Up Services

```bash
docker-compose up -d
```

## Step 2: Wait for Services to Warm Up 

Once the services are up, we will need to wait for the services to warm up and data to be ingested (1G logs ~= 3M lines).
This will take a minute. 

## Step 3: Run Benchmarks

```bash
./benchmark.sh
```
