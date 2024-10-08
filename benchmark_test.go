package main

import (
	"fmt"
	"io/ioutil"
	"net/http"
	"net/url"
	"strconv" // For integer conversion
	"testing"
	"time"
)

// LokiQuery represents the query to be tested
type LokiQuery struct {
	Query     string
	StartTime time.Time
	EndTime   time.Time
	Limit     int
}

func fetchLokiLogStats(query LokiQuery, headers map[string]string) {
	// fetch log stats
	baseURL := "http://localhost:3100/loki/api/v1/index/stats"
	params := url.Values{}
	params.Add("query", query.Query)
	params.Add("start", strconv.FormatInt(query.StartTime.UnixNano(), 10))
	params.Add("end", strconv.FormatInt(query.EndTime.UnixNano(), 10))
	fullURL := fmt.Sprintf("%s?%s", baseURL, params.Encode())
	req, err := http.NewRequest("GET", fullURL, nil)
	if err != nil {
		fmt.Printf("Failed to create request: %v", err)
	}

	// Add custom headers
	for key, value := range headers {
		req.Header.Add(key, value)
	}

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		fmt.Printf("Failed to query Loki: %v", err)
	}
	defer resp.Body.Close()
	_, err = ioutil.ReadAll(resp.Body)
	if err != nil {
		fmt.Printf("Failed to read response: %v", err)
	}
	// fmt.Println(string(body))
}

// benchmarkQueryLoki sends a query request to Loki and measures the response time.
func benchmarkQueryLoki(query LokiQuery, headers map[string]string, b *testing.B) {
	baseURL := "http://localhost:3100/loki/api/v1/query_range"
	params := url.Values{}
	params.Add("query", query.Query)
	params.Add("start", strconv.FormatInt(query.StartTime.UnixNano(), 10))
	params.Add("end", strconv.FormatInt(query.EndTime.UnixNano(), 10))
	params.Add("limit", strconv.Itoa(query.Limit))

	fullURL := fmt.Sprintf("%s?%s", baseURL, params.Encode())

	// Create a client to send the request
	client := &http.Client{}

	// Reset the timer to exclude setup time
	b.ResetTimer()

	for i := 0; i < b.N; i++ {
		// Create a new request
		req, err := http.NewRequest("GET", fullURL, nil)
		if err != nil {
			b.Fatalf("Failed to create request: %v", err)
		}

		// Add custom headers
		for key, value := range headers {
			req.Header.Add(key, value)
		}

		// Send the request
		resp, err := client.Do(req)
		if err != nil {
			b.Fatalf("Failed to query Loki: %v", err)
		}
		defer resp.Body.Close()

		// Read the response body
		_, err = ioutil.ReadAll(resp.Body)
		if err != nil {
			b.Fatalf("Failed to read response: %v", err)
		}

		if resp.StatusCode != http.StatusOK {
			b.Fatalf("Received non-OK HTTP status: %d", resp.StatusCode)
		}
	}
}

// BenchmarkLokiQuery benchmarks a specific Loki query.
func BenchmarkLokiQuery(b *testing.B) {
	query := LokiQuery{
		Query:     `{service_name="unknown_service"}`,
		StartTime: time.Now().Add(-1 * time.Hour),
		EndTime:   time.Now(),
		Limit:     5000, // max
	}

	// Define your headers here
	headers := map[string]string{
		"X-Scope-OrgID": "tenant1",
	}

	fetchLokiLogStats(query, headers)

	benchmarkQueryLoki(query, headers, b)
}

type ClickhouseQuery struct {
	Query     string
	StartTime time.Time
	EndTime   time.Time
	Limit     int
}

func benchmarkQueryClickhouse(query ClickhouseQuery, headers map[string]string, b *testing.B) {
	baseURL := "http://localhost:8123"
	params := url.Values{}

	params.Add("query", query.Query)
	params.Add("date_time_output_format", "iso")
	params.Add("wait_end_of_query", "0")
	params.Add("cancel_http_readonly_queries_on_client_close", "1")
	params.Add("min_bytes_to_use_direct_io", "1")

	fullURL := fmt.Sprintf("%s?%s", baseURL, params.Encode())

	// Create a client to send the request
	client := &http.Client{}

	// Reset the timer to exclude setup time
	b.ResetTimer()

	for i := 0; i < b.N; i++ {
		// Create a new request
		req, err := http.NewRequest("GET", fullURL, nil)
		if err != nil {
			b.Fatalf("Failed to create request: %v", err)
		}

		// Add custom headers
		for key, value := range headers {
			req.Header.Add(key, value)
		}

		// Send the request
		resp, err := client.Do(req)
		if err != nil {
			b.Fatalf("Failed to query Clickhouse: %v", err)
		}
		defer resp.Body.Close()

		// Read the response body
		_, err = ioutil.ReadAll(resp.Body)
		if err != nil {
			b.Fatalf("Failed to read response: %v", err)
		}

		if resp.StatusCode != http.StatusOK {
			b.Fatalf("Received non-OK HTTP status: %d", resp.StatusCode)
		}
	}
}

func BenchmarkClickhouseQuery(b *testing.B) {
	query := ClickhouseQuery{
		Query:     `SELECT * FROM default.otel_logs WHERE ServiceName = 'unknown_service' LIMIT 5000`,
		StartTime: time.Now().Add(-1 * time.Hour),
		EndTime:   time.Now(),
	}

	// Define your headers here
	headers := map[string]string{
		"X-Scope-OrgID": "tenant1",
	}

	benchmarkQueryClickhouse(query, headers, b)
}

func main() {
	// TODO: benchmark ingestion?

	// Make sure all data sources have logs ingested

	// Running benchmarks as standalone code
	testing.Benchmark(BenchmarkLokiQuery)
	testing.Benchmark(BenchmarkClickhouseQuery)
}
