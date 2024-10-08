#!/bin/bash

CURL_BIN=$(which curl)
RETRIES=5

cleanup() {
    # echo "Spinning down existing services..."
    # docker-compose down

    # echo "Cleaning up data..."
    # rm -rf .data

    exit 0
}

# Health check
check_health() {
    local HOST=$1
    local PORT=$2
    local PATH=$3
    local URL="http://$HOST:$PORT$PATH"
    # Perform the health check
    # HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" $URL)
    local HTTP_STATUS=$($CURL_BIN -s -o /dev/null -w "%{http_code}" http://localhost:8123)
    
    # Check if the health check was successful (HTTP 200)
    if [ "$HTTP_STATUS" -eq 200 ]; then
        return 0
    else
        echo "Health check failed for $URL. HTTP Status: $HTTP_STATUS"
        return 1
    fi
}

benchmark() {
  local SERVICE=$1
  local METHOD=$2
  local URL=$3
  local DATA=$4

  local MIN_TIME=999999
  local MAX_TIME=0
  local TOTAL_TIME=0

  # Perform the benchmark
  for i in $(seq 1 $RETRIES); do
    # Send the POST request and capture the response time
    resp=$(curl -o /dev/null -s -w "%{time_total} %{http_code}" \
      -X $METHOD "$URL" \
      -H "Content-Type: application/json" \
      -d "$DATA")

    # Extract the response time and HTTP status code
    response_time=$(echo $resp | awk '{print $1}')
    http_status=$(echo $resp | awk '{print $2}')
    
    # check if the request was successful
    if [ "$http_status" -ne 200 ]; then
      echo "Request failed with HTTP status code $http_status"
      exit 1
    fi

    # tranform the response time to ms
    response_time=$(echo $response_time | awk '{printf "%.3f", $1 * 1000}')

    # add the response time to the total time
    TOTAL_TIME=$(echo "$TOTAL_TIME + $response_time" | bc)
    if (( $(echo "$response_time < $MIN_TIME" | bc -l) )); then
      MIN_TIME=$response_time
    fi
    if (( $(echo "$response_time > $MAX_TIME" | bc -l) )); then
      MAX_TIME=$response_time
    fi
  done

  # Calculate the average response time
  local AVG_TIME=$(echo "scale=3; $TOTAL_TIME / $RETRIES" | bc)
  echo "[$SERVICE] Average response time: $AVG_TIME ms, Min response time: $MIN_TIME ms, Max response time: $MAX_TIME ms"
  # echo "Min response time: $MIN_TIME ms"
  # echo "Max response time: $MAX_TIME ms"
}

# Set traps to call the cleanup function on EXIT and when receiving SIGINT (Ctrl+C)
trap cleanup EXIT
trap cleanup SIGINT

# Spin up services
echo "Spinning up services..."
docker-compose up -d

# Wait for services to be up
echo "Waiting for services to be up..."
while ! check_health "localhost" "8123" "/ping" \
  || ! check_health "localhost" "3101" "/ready" \
  ; do
    echo "Retrying in 5 seconds..."
    sleep 5
done

# Make sure all data is loaded

# Prepare the benchmark
echo "Collecting Grafana dashboard data..."
LOKI_DATA_SOURCE_ID=$(curl -s -X GET http://localhost:3000/api/datasources | jq -r '.[0].uid')
echo "Loki data source ID: $LOKI_DATA_SOURCE_ID"

benchmarkLoki() {
  local payload=$(jq -n \
    --arg uid "$LOKI_DATA_SOURCE_ID" \
    --arg from "$(date -v -12H +%s)000" \
    --arg to "$(date +%s)000" \
    '{
      queries: [
        {
          expr: "{service_name=\"unknown_service\"}",
          queryType: "range",
          refId: "loki-data-samples",
          maxLines: 10,
          supportingQueryType: "dataSample",
          step: "",
          legendFormat: "",
          datasource: {
            type: "loki",
            uid: $uid
          },
          datasourceId: 1,
          intervalMs: 3600000
        }
      ], 
      from: $from,
      to: $to
    }'
  )
  benchmark "Loki" "POST" "http://localhost:3000/api/ds/query?ds_type=loki&requestId=loki-data-samples_1" "$payload"
}

# Run the benchmark
benchmarkLoki 

echo "Script completed successfully."
