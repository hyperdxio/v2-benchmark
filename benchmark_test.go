package main

import (
	"fmt"
	"io/ioutil"
	"net/http"
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

// benchmarkQueryLoki sends a query request to Loki and measures the response time.
func benchmarkQueryLoki(query LokiQuery, headers map[string]string, b *testing.B) {
	url := fmt.Sprintf("http://localhost:3100/loki/api/v1/query_range?query=%s&start=%d&end=%d&limit=%d",
		query.Query, query.StartTime.UnixNano(), query.EndTime.UnixNano(), query.Limit)

	// Create a client to send the request
	client := &http.Client{}

	// Reset the timer to exclude setup time
	b.ResetTimer()

	for i := 0; i < b.N; i++ {
		// Create a new request
		req, err := http.NewRequest("GET", url, nil)
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
		Query:     `{container="loki-flog-1"}`,
		StartTime: time.Now().Add(-1 * time.Hour),
		EndTime:   time.Now(),
		Limit:     5000, // max
	}

	// Define your headers here
	headers := map[string]string{
		"X-Scope-OrgID": "tenant1",
	}

	benchmarkQueryLoki(query, headers, b)
}

func main() {
	// Running benchmarks as standalone code
	testing.Benchmark(BenchmarkLokiQuery)
}
