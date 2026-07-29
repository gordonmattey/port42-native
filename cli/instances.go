package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Instance is one running Port42 answering on a local port.
type Instance struct {
	Port int
	Name string // the instance's display name, e.g. "gordon" or "gordontest3"
}

// candidatePorts is where a Port42 gateway plausibly listens. 4242 is the prod default
// (GatewayProcess.swift:11); the rest are what a dev machine running several instances at once
// lands on via PORT42_GATEWAY_PORT. 42 is reserved for the canonical port if it is ever taken.
//
// Probing beats requiring the user to know a port number, and it needs no app change. If this
// list ever feels like guesswork, the app can publish its port instead (docs/plan-teleport.md
// section 3.2) and discovery reads that.
var candidatePorts = []int{42, 4242, 4243, 4244, 4245, 4246, 4247, 4248}

// probe asks one port who it is. Short timeout: these are loopback calls to a process that is
// either there or not, and the whole sweep runs concurrently.
func probe(port int) (Instance, bool) {
	body, _ := json.Marshal(map[string]any{"method": "user.get", "args": map[string]any{}})
	client := &http.Client{Timeout: 1500 * time.Millisecond}

	resp, err := client.Post(fmt.Sprintf("http://127.0.0.1:%d/call", port), "application/json", bytes.NewReader(body))
	if err != nil {
		return Instance{}, false
	}
	defer resp.Body.Close()

	var out callResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil || out.Error != "" {
		return Instance{}, false
	}
	var user struct {
		DisplayName string `json:"displayName"`
	}
	if err := decodeContent(out.Content, &user); err != nil {
		return Instance{}, false
	}
	return Instance{Port: port, Name: user.DisplayName}, true
}

// DiscoverInstances sweeps the candidate ports concurrently and returns whoever answers,
// lowest port first.
func DiscoverInstances() []Instance {
	var (
		mu    sync.Mutex
		found []Instance
		wg    sync.WaitGroup
	)
	for _, port := range candidatePorts {
		wg.Add(1)
		go func(p int) {
			defer wg.Done()
			if inst, ok := probe(p); ok {
				mu.Lock()
				found = append(found, inst)
				mu.Unlock()
			}
		}(port)
	}
	wg.Wait()
	sort.Slice(found, func(i, j int) bool { return found[i].Port < found[j].Port })
	return found
}

// ChooseInstance picks which Port42 to teleport into. One running instance needs no question.
// Several is only ever a dev machine, and guessing which one gets a live agent dropped into it
// is not a guess worth making, so it asks, or refuses when nobody is there to answer.
func ChooseInstance(w io.Writer, r io.Reader, instances []Instance, interactive bool) (Instance, error) {
	switch len(instances) {
	case 0:
		return Instance{}, ErrNotRunning
	case 1:
		return instances[0], nil
	}

	if !interactive {
		return Instance{}, fmt.Errorf("more than one Port42 is running, so pass --port.\n%s", formatInstances(instances))
	}

	fmt.Fprintln(w, "More than one Port42 is running. Which one?")
	fmt.Fprintln(w)
	for i, inst := range instances {
		fmt.Fprintf(w, "   %d) %s (port %d)\n", i+1, inst.Name, inst.Port)
	}
	fmt.Fprintf(w, "\nPick a number: ")

	line, err := bufio.NewReader(r).ReadString('\n')
	answer := strings.TrimSpace(line)
	if err != nil && answer == "" {
		return Instance{}, fmt.Errorf("no choice given, so pass --port.\n%s", formatInstances(instances))
	}
	n, convErr := strconv.Atoi(answer)
	if convErr != nil || n < 1 || n > len(instances) {
		return Instance{}, fmt.Errorf("%q is not one of the listed choices", answer)
	}
	return instances[n-1], nil
}

func formatInstances(instances []Instance) string {
	var b strings.Builder
	b.WriteString("Running instances:\n")
	for _, inst := range instances {
		fmt.Fprintf(&b, "  %-20s --port %d\n", inst.Name, inst.Port)
	}
	return b.String()
}
