#!/bin/bash

CURL_BIN=$(which curl)
RETRIES=5
LOGS_LIMIT=5000

cleanup() {
    # echo "Spinning down existing services..."
    # docker-compose down

    # echo "Cleaning up data..."
    # rm -rf .data

    exit 0
}

# Function to URL encode a parameter
url_encode() {
    local param="$1"
    # Use jq to encode the parameter
    local encoded_param=$(jq -Rn --arg param "$param" '$param | @uri')
    echo "$encoded_param"
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
  local NAME=$2
  local METHOD=$3
  local URL=$4
  local DATA=$5

  local MIN_TIME=999999
  local MAX_TIME=0
  local TOTAL_TIME=0

  # Perform the benchmark
  for i in $(seq 1 $RETRIES); do
    resp=$(curl -o /dev/null -s -w "%{time_total} %{http_code}" \
      -X $METHOD "$URL" \
      -H "Content-Type: application/json" \
      -H "kbn-xsrf: reporting" \
      -H "Elastic-Api-Version: 1" \
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
  echo "[$SERVICE] - ($NAME): Average response time: $AVG_TIME ms, Min response time: $MIN_TIME ms, Max response time: $MAX_TIME ms"
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
# sleep 5

# Prepare the benchmark
echo "Collecting Grafana dashboard data..."
LOKI_DATA_SOURCE_ID=$(curl -s -X GET http://localhost:3000/api/datasources | jq -r '.[] | select(.type == "loki") | .uid')
CLICKHOUSE_DATA_SOURCE_ID=$(curl -s -X GET http://localhost:3000/api/datasources | jq -r '.[] | select(.type == "grafana-clickhouse-datasource") | .uid')
echo "Loki data source ID: $LOKI_DATA_SOURCE_ID"
echo "Clickhouse data source ID: $CLICKHOUSE_DATA_SOURCE_ID"
FROM=$(date -v -24H +%s)000
TO=$(date +%s)000

benchmarkLoki() {
  # Extract current data size
  local _dataSize=$(du -sh ./.data/minio/loki-data | awk '{print $1}')
  echo "[Loki] Current data size: $_dataSize"

  local payloadA=$(jq -n \
    --arg uid "$LOKI_DATA_SOURCE_ID" \
    --arg from "$FROM" \
    --arg to "$TO" \
    --argjson limit $LOGS_LIMIT \
    '{
      queries: [
        {
          "refId": "A",
          "expr": "{service_name=\"unknown_service\"}",
          "queryType": "range",
          "datasource": {
            "type": "loki",
            "uid": $uid
          },
          "editorMode": "builder",
          "maxLines": $limit,
          "step": "",
          "legendFormat": "",
          "datasourceId": 1,
          "intervalMs": 30000,
          "maxDataPoints": 1180
        }
      ], 
      from: $from,
      to: $to
    }'
  )

  local payloadB=$(jq -n \
    --arg uid "$LOKI_DATA_SOURCE_ID" \
    --arg from "$FROM" \
    --arg to "$TO" \
    --argjson limit $LOGS_LIMIT \
    '{
      queries: [
        {
          "refId": "A",
          "expr": "{service_name=\"unknown_service\"} |= `6361`",
          "queryType": "range",
          "datasource": {
            "type": "loki",
            "uid": $uid
          },
          "editorMode": "builder",
          "maxLines": $limit,
          "step": "",
          "legendFormat": "",
          "datasourceId": 1,
          "intervalMs": 30000,
          "maxDataPoints": 1180
        }
      ], 
      from: $from,
      to: $to
    }'
  )
  benchmark "Loki" "BASIC SELECT ALL" "POST" "http://localhost:3000/api/ds/query?ds_type=loki" "$payloadA"
  benchmark "Loki" "BASIC SELECT TEXT CONTAINS" "POST" "http://localhost:3000/api/ds/query?ds_type=loki" "$payloadB"
}

benchmarkGrafanaClickHouse() {
  # Extract current data size
  local _dataSize=$(du -sh ./.data/minio/ch-data | awk '{print $1}')
  echo "[Grafana-CH] Current data size: $_dataSize"

  local payloadA=$(jq -n \
    --arg uid "$CLICKHOUSE_DATA_SOURCE_ID" \
    --arg from "$FROM" \
    --arg to "$TO" \
    --argjson limit $LOGS_LIMIT \
    '{
      "queries": [
        {
          "refId": "A",
          "datasource": {
            "type": "grafana-clickhouse-datasource",
            "uid": $uid
          },
          "pluginVersion": "4.5.0",
          "editorType": "builder",
          "rawSql": "SELECT TimestampTime as \"timestamp\", Body as \"body\", LogAttributes as \"labels\" FROM \"default\".\"otel_logs\" WHERE ( timestamp >= $__fromTime AND timestamp <= $__toTime ) ORDER BY timestamp DESC LIMIT 5000 SETTINGS use_query_cache=false,min_bytes_to_use_direct_io=1",
          "builderOptions": {
            "database": "default",
            "table": "otel_logs",
            "queryType": "logs",
            "mode": "list",
            "columns": [
              {
                "name": "Body",
                "type": "String",
                "custom": false,
                "alias": "Body"
              },
              {
                "name": "TimestampTime",
                "type": "DateTime",
                "custom": false,
                "alias": "TimestampTime"
              },
              {
                "name": "TimestampTime",
                "type": "DateTime",
                "hint": "time",
                "alias": "TimestampTime"
              },
              {
                "name": "SeverityText",
                "hint": "log_level"
              },
              {
                "name": "Body",
                "hint": "log_message"
              },
              {
                "name": "LogAttributes",
                "hint": "log_labels"
              }
            ],
            "meta": {
              "otelVersion": "latest",
              "otelEnabled": false,
              "logMessageLike": ""
            },
            "limit": $limit,
            "filters": [
              {
                "type": "datetime",
                "operator": "WITH IN DASHBOARD TIME RANGE",
                "filterType": "custom",
                "key": "",
                "hint": "time",
                "condition": "AND"
              },
              {
                "type": "string",
                "operator": "IS ANYTHING",
                "filterType": "custom",
                "key": "",
                "hint": "log_level",
                "condition": "AND"
              }
            ],
            "orderBy": [
              {
                "name": "",
                "hint": "time",
                "dir": "DESC",
                "default": true
              }
            ]
          },
          "format": 2,
          "meta": {
            "timezone": "America/Los_Angeles"
          },
          "datasourceId": 2,
          "intervalMs": 5000,
          "maxDataPoints": 753
        }
      ],
      "from": $from,
      "to": $to
    }'
  )

  local payloadB=$(jq -n \
    --arg uid "$CLICKHOUSE_DATA_SOURCE_ID" \
    --arg from "$FROM" \
    --arg to "$TO" \
    --argjson limit $LOGS_LIMIT \
    '{
      "queries": [
        {
          "refId": "A",
          "datasource": {
            "type": "grafana-clickhouse-datasource",
            "uid": $uid
          },
          "pluginVersion": "4.5.0",
          "editorType": "builder",
          "rawSql": "SELECT Timestamp as \"timestamp\", Body as \"body\", LogAttributes as \"labels\" FROM \"default\".\"otel_logs\" WHERE ( timestamp >= $__fromTime AND timestamp <= $__toTime ) AND (body LIKE toString(6361)) ORDER BY timestamp DESC LIMIT 5000 SETTINGS use_query_cache=false,min_bytes_to_use_direct_io=1",
          "builderOptions": {
            "database": "default",
            "table": "otel_logs",
            "queryType": "logs",
            "mode": "list",
            "columns": [
              {
                "name": "Body",
                "type": "String",
                "custom": false,
                "alias": "Body"
              },
              {
                "name": "TimestampTime",
                "type": "DateTime",
                "custom": false,
                "alias": "TimestampTime"
              },
              {
                "name": "TimestampTime",
                "type": "DateTime",
                "hint": "time",
                "alias": "TimestampTime"
              },
              {
                "name": "SeverityText",
                "hint": "log_level"
              },
              {
                "name": "Body",
                "hint": "log_message"
              },
              {
                "name": "LogAttributes",
                "hint": "log_labels"
              }
            ],
            "meta": {
              "otelVersion": "latest",
              "otelEnabled": false,
              "logMessageLike": ""
            },
            "limit": $limit,
            "filters": [
              {
                "type": "datetime",
                "operator": "WITH IN DASHBOARD TIME RANGE",
                "filterType": "custom",
                "key": "",
                "hint": "time",
                "condition": "AND"
              },
              {
                "type": "string",
                "operator": "IS ANYTHING",
                "filterType": "custom",
                "key": "",
                "hint": "log_level",
                "condition": "AND"
              }
            ],
            "orderBy": [
              {
                "name": "",
                "hint": "time",
                "dir": "DESC",
                "default": true
              }
            ]
          },
          "format": 2,
          "meta": {
            "timezone": "America/Los_Angeles"
          },
          "datasourceId": 2,
          "intervalMs": 5000,
          "maxDataPoints": 753
        }
      ],
      "from": $from,
      "to": $to
    }'
  )
  benchmark "Grafana-CH" "BASIC SELECT ALL" "POST" "http://localhost:3000/api/ds/query" "$payloadA"
  benchmark "Grafana-CH" "BASIC SELECT TEXT CONTAINS" "POST" "http://localhost:3000/api/ds/query" "$payloadB"
}
benchmarkHyperDX() {
  # Extract current data size
  local _dataSize=$(du -sh ./.data/minio/ch-data | awk '{print $1}')
  echo "[HyperDX] Current data size: $_dataSize"

  # Copy the request URL from HyperDX
  local _requestUrlA="http://localhost:8123/?use_query_cache=0&min_bytes_to_use_direct_io=1&add_http_cors_header=1&query=SELECT+TimestampTime%2CBody+FROM+%7BHYPERDX_PARAM_1544803905%3AIdentifier%7D.%7BHYPERDX_PARAM_129845054%3AIdentifier%7D+WHERE+%28TimestampTime+%3E%3D+fromUnixTimestamp64Milli%28%7BHYPERDX_PARAM_1710755125%3AInt64%7D%29+AND+TimestampTime+%3C%3D+fromUnixTimestamp64Milli%28%7BHYPERDX_PARAM_1483136077%3AInt64%7D%29%29++ORDER+BY+TimestampTime+DESC+LIMIT+%7BHYPERDX_PARAM_49586%3AInt32%7D+OFFSET+%7BHYPERDX_PARAM_48%3AInt32%7D&default_format=JSONCompactEachRowWithNamesAndTypes&date_time_output_format=iso&wait_end_of_query=0&cancel_http_readonly_queries_on_client_close=1&user=default&param_HYPERDX_PARAM_1544803905=default&param_HYPERDX_PARAM_129845054=otel_logs&param_HYPERDX_PARAM_1710755125=${FROM}&param_HYPERDX_PARAM_1483136077=${TO}&param_HYPERDX_PARAM_49586=${LOGS_LIMIT}&param_HYPERDX_PARAM_48=0"
  local _requestUrlB="http://localhost:8123/?use_query_cache=0&min_bytes_to_use_direct_io=1&add_http_cors_header=1&query=SELECT+Timestamp%2CBody%2CServiceName%2CTimestampTime+FROM+%7BHYPERDX_PARAM_1544803905%3AIdentifier%7D.%7BHYPERDX_PARAM_129845054%3AIdentifier%7D+WHERE+%28TimestampTime+%3E%3D+fromUnixTimestamp64Milli%28%7BHYPERDX_PARAM_1515071666%3AInt64%7D%29+AND+TimestampTime+%3C%3D+fromUnixTimestamp64Milli%28%7BHYPERDX_PARAM_1518044896%3AInt64%7D%29%29+AND+%28%28hasTokenCaseInsensitive%28%60Body%60%2C+%276361%27%29%29%29++ORDER+BY+TimestampTime+DESC+LIMIT+%7BHYPERDX_PARAM_49586%3AInt32%7D+OFFSET+%7BHYPERDX_PARAM_48%3AInt32%7D&default_format=JSONCompactEachRowWithNamesAndTypes&date_time_output_format=iso&wait_end_of_query=0&cancel_http_readonly_queries_on_client_close=1&user=default&param_HYPERDX_PARAM_1544803905=default&param_HYPERDX_PARAM_129845054=otel_logs&param_HYPERDX_PARAM_1515071666=${FROM}&param_HYPERDX_PARAM_1518044896=${TO}&param_HYPERDX_PARAM_49586=${LOGS_LIMIT}&param_HYPERDX_PARAM_48=0"


  benchmark "HyperDX" "BASIC SELECT ALL" "GET" "$_requestUrlA" ""
  benchmark "HyperDX" "BASIC SELECT TEXT CONTAINS" "GET" "$_requestUrlB" ""
}

benchmarkElasticsearch() {
  # Extract current data size
  local _dataSize=$(du -sh ./.data/elasticsearch-data | awk '{print $1}')
  echo "[Elastic] Current data size: $_dataSize"
  local queryA="FROM logs* | KEEP @timestamp,Body | SORT @timestamp DESC | LIMIT $LOGS_LIMIT"
  local queryB="FROM logs* | WHERE Body LIKE \"*6361*\" | KEEP @timestamp,Body | SORT @timestamp DESC | LIMIT $LOGS_LIMIT"

  local payloadA=$(jq -n \
    --argjson from "$FROM" \
    --argjson to "$TO" \
    --arg query "$queryA" \
    '{
       "batch": [
        {
          "request": {
            "params": {
              "query": $query,
              "locale": "en",
              "filter": {
                "bool": {
                  "must": [],
                  "filter": [
                    {
                      "range": {
                        "@timestamp": {
                          "format": "epoch_millis",
                          "gte": $from,
                          "lte": $to
                        }
                      }
                    }
                  ],
                  "should": [],
                  "must_not": []
                }
              },
              "dropNullColumns": true
            }
          },
          "options": {
            "strategy": "esql",
            "isSearchStored": false,
            "executionContext": {
              "type": "application",
              "name": "discover",
              "url": "/app/discover",
              "page": "app",
              "id": "new"
            }
          }
        }
      ]
    }'
  )

  local payloadB=$(jq -n \
    --argjson from "$FROM" \
    --argjson to "$TO" \
    --arg query "$queryB" \
    '{
       "batch": [
        {
          "request": {
            "params": {
              "query": $query,
              "locale": "en",
              "filter": {
                "bool": {
                  "must": [],
                  "filter": [
                    {
                      "range": {
                        "@timestamp": {
                          "format": "epoch_millis",
                          "gte": $from,
                          "lte": $to
                        }
                      }
                    }
                  ],
                  "should": [],
                  "must_not": []
                }
              },
              "dropNullColumns": true
            }
          },
          "options": {
            "strategy": "esql",
            "isSearchStored": false,
            "executionContext": {
              "type": "application",
              "name": "discover",
              "url": "/app/discover",
              "page": "app",
              "id": "new"
            }
          }
        }
      ]
    }'
  )

  benchmark "Elastic" "BASIC SELECT" "POST" "http://localhost:5601/internal/bsearch?compress=false" "$payloadA"
  benchmark "Elastic" "BASIC SELECT TEXT CONTAINS" "POST" "http://localhost:5601/internal/bsearch?compress=false" "$payloadB"
}

# Run the benchmark
echo "Running the benchmark with $RETRIES iterations each..."
benchmarkLoki 
benchmarkGrafanaClickHouse
benchmarkHyperDX
benchmarkElasticsearch

echo "Script completed successfully."
