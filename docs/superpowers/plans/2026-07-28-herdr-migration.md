# Herdr Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace glove-agentd's Claude-Code-hooks/tmux pipeline with herdr's socket API so Glove80 F-key LEDs mirror herdr's sidebar and F-key jumps focus agents in herdr.

**Architecture:** A new `internal/herdr` package speaks herdr's newline-delimited JSON socket protocol (one request per connection; a persistent `events.subscribe` connection streams change triggers). Every trigger causes a debounced `agent.list` refetch; the result lands in a new `internal/roster` package that renders LED frames positionally (slot N = Nth sidebar row). Jump sends `agent.focus` over the socket, then raises the single iTerm session hosting the herdr client. The hook binary, ingest listener, liveness prober, and sticky-slot registry are deleted.

**Tech Stack:** Go (module `github.com/calvin-barker/glove-agentd`), Unix domain sockets, herdr 0.7.5 socket API (protocol 17), osascript/iTerm2 AppleScript, launchd.

**Spec:** `docs/superpowers/specs/2026-07-28-herdr-migration-design.md` (glove80-zmk-config repo).

## Global Constraints

- All work happens in `~/development/glove-agentd` except Task 8's herdr/Claude config edits. Repo is private; commits go to a feature branch `feature/herdr-migration` (Task 0 lands prior work on `main` first).
- Red/green TDD for every code task: write the failing test, watch it fail for the right reason, make it pass, keep `make test` (race-checked) green.
- herdr wire facts (verified live 2026-07-28 against herdr 0.7.5): socket `~/.config/herdr/herdr.sock`; frames are single JSON lines terminated by `\n`; request `{"id":"<any>","method":"<name>","params":{...}}`; success `{"id":"<echo>","result":{...}}`; error `{"id":"","error":{"code":"...","message":"..."}}`. The server closes the connection after one request/response exchange, except `events.subscribe`, which acks with `{"result":{"type":"subscription_started"}}` and then streams `{"event":"<kind>","data":{...}}` lines and may replay a backlog burst immediately after subscribing. `ping` result carries `{"protocol":17,"version":"0.7.5"}`. `agent.list` result is `{"type":"agent_list","agents":[{"agent","agent_status","cwd","pane_id","workspace_id","tab_id","terminal_id","terminal_title","terminal_title_stripped","focused",...}]}` in workspace (sidebar) order. `agent.focus` params are `{"target":"<pane_id>"}`. Subscription entries are `{"type":"<kind>"}`; `pane.agent_status_changed` requires a `pane_id` field, so we do not use it; global `pane.updated` fires on every pane revision (~10/s under load) and covers status flips because status is derived from pane content.
- Agent statuses: `idle`, `working`, `blocked`, `done`, `unknown`. LED mapping: working/unknown → Working dim, blocked → Amber, idle/done → Green, empty slot or unreachable herdr → dark. Red is no longer rendered.
- The daemon keeps its own Unix socket (`~/.local/state/glove-agentd/agentd.sock`) solely for the `glove-agentd status` CLI. Hook-event ingestion on that socket is deleted.
- Never touch `internal/hidio` or `internal/protocol` behavior; the sleep/wake self-heal and HID report format are frozen.
- Comments follow the repo's style: explain why, single-line Go doc comments on exported identifiers.

---

### Task 0: Land the in-flight sleep/wake refinement on main

The repo sits on `fix/hid-sleep-wake-self-heal` with six modified, uncommitted files (configurable `stuck_threshold_sec`, fast reopen ticker, tests, README). `main` (69f0c02) is one commit behind the branch (938c232) and the deployed binary. This work is unrelated to herdr; land it first so the feature branch starts clean.

**Files:**
- Commit as-is: `README.md`, `cmd/glove-agentd/main.go`, `internal/config/config.go`, `internal/config/config_test.go`, `internal/hidio/hidio.go`, `internal/hidio/hidio_test.go`

- [ ] **Step 1: Verify the suite passes with the uncommitted changes**

Run: `cd ~/development/glove-agentd && make test`
Expected: PASS (race-checked). If it fails, stop and diagnose before committing anything.

- [ ] **Step 2: Commit on the fix branch**

```bash
git add README.md cmd/glove-agentd/main.go internal/config internal/hidio
git commit -m "Make the stuck-handle threshold configurable and reopen on a fast tick"
```

- [ ] **Step 3: Land on main and create the feature branch**

```bash
git checkout main
git merge --ff-only fix/hid-sleep-wake-self-heal
git checkout -b feature/herdr-migration
```

Expected: `main` fast-forwards (branch = main + linear commits). If `--ff-only` refuses, inspect with `git log --oneline --graph main fix/hid-sleep-wake-self-heal` before doing anything else.

---

### Task 1: herdr client core (request framing, Ping, ListAgents, FocusAgent)

**Files:**
- Create: `internal/herdr/client.go`
- Test: `internal/herdr/client_test.go`

**Interfaces:**
- Produces: `herdr.Client{SocketPath string, Timeout time.Duration}` with methods `Ping() (proto int, version string, err error)`, `ListAgents() ([]Agent, error)`, `FocusAgent(target string) error`; type `herdr.Agent{Agent, Status, CWD, PaneID, WorkspaceID, Title string}` (JSON tags `agent`, `agent_status`, `cwd`, `pane_id`, `workspace_id`, `terminal_title_stripped`); constant `herdr.SupportedProtocol = 17`.

- [ ] **Step 1: Write the failing test**

```go
package herdr

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// fakeOneShot serves the herdr one-request-per-connection contract: read one
// line, reply with handle's result JSON (or an error line), close.
func fakeOneShot(t *testing.T, handle func(method string, params json.RawMessage) (result string, errLine string)) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "hd")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	path := filepath.Join(dir, "h.sock")
	l, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		for {
			conn, err := l.Accept()
			if err != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				line, err := bufio.NewReader(conn).ReadBytes('\n')
				if err != nil {
					return
				}
				var req struct {
					ID     string          `json:"id"`
					Method string          `json:"method"`
					Params json.RawMessage `json:"params"`
				}
				if err := json.Unmarshal(line, &req); err != nil {
					return
				}
				result, errLine := handle(req.Method, req.Params)
				if errLine != "" {
					fmt.Fprintf(conn, "%s\n", errLine)
					return
				}
				fmt.Fprintf(conn, `{"id":%q,"result":%s}`+"\n", req.ID, result)
			}(conn)
		}
	}()
	return path
}

func TestPing(t *testing.T) {
	path := fakeOneShot(t, func(method string, _ json.RawMessage) (string, string) {
		if method != "ping" {
			t.Errorf("method = %q, want ping", method)
		}
		return `{"type":"pong","version":"0.7.5","protocol":17}`, ""
	})
	c := &Client{SocketPath: path, Timeout: time.Second}
	proto, version, err := c.Ping()
	if err != nil {
		t.Fatal(err)
	}
	if proto != 17 || version != "0.7.5" {
		t.Fatalf("got %d %q", proto, version)
	}
}

func TestListAgents(t *testing.T) {
	path := fakeOneShot(t, func(method string, _ json.RawMessage) (string, string) {
		if method != "agent.list" {
			t.Errorf("method = %q, want agent.list", method)
		}
		return `{"type":"agent_list","agents":[
			{"agent":"claude","agent_status":"working","cwd":"/a","pane_id":"w3:p1","workspace_id":"w3","terminal_title_stripped":"first"},
			{"agent":"claude","agent_status":"blocked","cwd":"/b","pane_id":"w5:p1","workspace_id":"w5","terminal_title_stripped":"second"}]}`, ""
	})
	c := &Client{SocketPath: path, Timeout: time.Second}
	agents, err := c.ListAgents()
	if err != nil {
		t.Fatal(err)
	}
	if len(agents) != 2 {
		t.Fatalf("len = %d", len(agents))
	}
	if agents[0].PaneID != "w3:p1" || agents[0].Status != "working" || agents[1].Title != "second" {
		t.Fatalf("bad decode: %+v", agents)
	}
}

func TestFocusAgentSendsTarget(t *testing.T) {
	var got string
	path := fakeOneShot(t, func(method string, params json.RawMessage) (string, string) {
		if method != "agent.focus" {
			t.Errorf("method = %q, want agent.focus", method)
		}
		var p struct {
			Target string `json:"target"`
		}
		json.Unmarshal(params, &p)
		got = p.Target
		return `{"type":"ok"}`, ""
	})
	c := &Client{SocketPath: path, Timeout: time.Second}
	if err := c.FocusAgent("w3:p1"); err != nil {
		t.Fatal(err)
	}
	if got != "w3:p1" {
		t.Fatalf("target = %q", got)
	}
}

func TestServerErrorSurfaces(t *testing.T) {
	path := fakeOneShot(t, func(string, json.RawMessage) (string, string) {
		return "", `{"id":"","error":{"code":"invalid_request","message":"nope"}}`
	})
	c := &Client{SocketPath: path, Timeout: time.Second}
	if _, err := c.ListAgents(); err == nil {
		t.Fatal("want error")
	}
}

func TestDialFailure(t *testing.T) {
	c := &Client{SocketPath: "/nonexistent/h.sock", Timeout: 200 * time.Millisecond}
	if _, _, err := c.Ping(); err == nil {
		t.Fatal("want error")
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/herdr/ -run 'TestPing|TestListAgents|TestFocusAgentSendsTarget|TestServerErrorSurfaces|TestDialFailure' -v`
Expected: compile FAIL, `undefined: Client`.

- [ ] **Step 3: Write the implementation**

```go
// Package herdr speaks the herdr server's socket API: newline-delimited JSON
// with one request per connection, plus a streaming events.subscribe channel.
package herdr

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"time"
)

// SupportedProtocol is the herdr socket protocol this client was built against
// (herdr 0.7.5). Other versions get a loud log line but requests still run;
// real incompatibilities surface as decode failures.
const SupportedProtocol = 17

// Client issues requests against a herdr server socket.
type Client struct {
	SocketPath string
	Timeout    time.Duration // per-request bound; 0 means 3s
}

// Agent is one row of agent.list, in herdr's sidebar order.
type Agent struct {
	Agent       string `json:"agent"`
	Status      string `json:"agent_status"`
	CWD         string `json:"cwd"`
	PaneID      string `json:"pane_id"`
	WorkspaceID string `json:"workspace_id"`
	Title       string `json:"terminal_title_stripped"`
}

type request struct {
	ID     string `json:"id"`
	Method string `json:"method"`
	Params any    `json:"params"`
}

type response struct {
	ID     string          `json:"id"`
	Result json.RawMessage `json:"result"`
	Error  *respError      `json:"error"`
}

type respError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (c *Client) timeout() time.Duration {
	if c.Timeout > 0 {
		return c.Timeout
	}
	return 3 * time.Second
}

// call runs one request on a fresh connection; the herdr server hangs up
// after a single exchange, so there is nothing to reuse.
func (c *Client) call(method string, params, result any) error {
	conn, err := net.DialTimeout("unix", c.SocketPath, c.timeout())
	if err != nil {
		return fmt.Errorf("herdr: dial: %w", err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(c.timeout()))
	if params == nil {
		params = struct{}{}
	}
	blob, err := json.Marshal(request{ID: "glove-agentd", Method: method, Params: params})
	if err != nil {
		return err
	}
	if _, err := conn.Write(append(blob, '\n')); err != nil {
		return fmt.Errorf("herdr: write: %w", err)
	}
	line, err := bufio.NewReader(conn).ReadBytes('\n')
	if err != nil {
		return fmt.Errorf("herdr: read: %w", err)
	}
	var resp response
	if err := json.Unmarshal(line, &resp); err != nil {
		return fmt.Errorf("herdr: decode: %w", err)
	}
	if resp.Error != nil {
		return fmt.Errorf("herdr: %s: %s", resp.Error.Code, resp.Error.Message)
	}
	if result != nil {
		if err := json.Unmarshal(resp.Result, result); err != nil {
			return fmt.Errorf("herdr: decode result: %w", err)
		}
	}
	return nil
}

// Ping returns the server's protocol number and version.
func (c *Client) Ping() (int, string, error) {
	var r struct {
		Protocol int    `json:"protocol"`
		Version  string `json:"version"`
	}
	if err := c.call("ping", nil, &r); err != nil {
		return 0, "", err
	}
	return r.Protocol, r.Version, nil
}

// ListAgents returns herdr's agents in sidebar (workspace) order.
func (c *Client) ListAgents() ([]Agent, error) {
	var r struct {
		Agents []Agent `json:"agents"`
	}
	if err := c.call("agent.list", nil, &r); err != nil {
		return nil, err
	}
	return r.Agents, nil
}

// FocusAgent focuses an agent pane inside herdr; target is a pane id like
// "w3:p1".
func (c *Client) FocusAgent(target string) error {
	return c.call("agent.focus", map[string]string{"target": target}, nil)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/herdr/ -v`
Expected: PASS (all five).

- [ ] **Step 5: Commit**

```bash
git add internal/herdr
git commit -m "Add herdr socket client: ping, agent list, focus"
```

---

### Task 2: herdr watch loop (subscribe, debounce, reconcile, backoff)

**Files:**
- Create: `internal/herdr/watch.go`
- Test: `internal/herdr/watch_test.go`

**Interfaces:**
- Consumes: `Client.ListAgents`, `Client.Ping`, `request` (Task 1).
- Produces: `herdr.Run(ctx context.Context, c *Client, reconcile time.Duration, publish func([]Agent))`. Contract: `publish(agents)` on every successful refetch; `publish(nil)` whenever herdr becomes unreachable; never returns before ctx cancellation; reconnects forever with capped backoff.

- [ ] **Step 1: Write the failing test**

```go
package herdr

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// fakeHerdr serves ping and agent.list as one-shots and events.subscribe as a
// stream, mimicking the real server's connection contract.
type fakeHerdr struct {
	t    *testing.T
	path string
	l    net.Listener

	mu     sync.Mutex
	agents string // JSON array body served by agent.list
	subs   []net.Conn
}

func newFakeHerdr(t *testing.T) *fakeHerdr {
	t.Helper()
	dir, err := os.MkdirTemp("", "hd")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	f := &fakeHerdr{t: t, path: filepath.Join(dir, "h.sock"), agents: "[]"}
	l, err := net.Listen("unix", f.path)
	if err != nil {
		t.Fatal(err)
	}
	f.l = l
	t.Cleanup(f.close)
	go f.serve()
	return f
}

func (f *fakeHerdr) close() {
	f.l.Close()
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, c := range f.subs {
		c.Close()
	}
	f.subs = nil
}

func (f *fakeHerdr) setAgents(body string) {
	f.mu.Lock()
	f.agents = body
	f.mu.Unlock()
}

// pushEvent emits one event line to every subscriber.
func (f *fakeHerdr) pushEvent(kind string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, c := range f.subs {
		fmt.Fprintf(c, `{"event":%q,"data":{}}`+"\n", kind)
	}
}

func (f *fakeHerdr) serve() {
	for {
		conn, err := f.l.Accept()
		if err != nil {
			return
		}
		go func(conn net.Conn) {
			line, err := bufio.NewReader(conn).ReadBytes('\n')
			if err != nil {
				conn.Close()
				return
			}
			var req struct {
				ID     string `json:"id"`
				Method string `json:"method"`
			}
			json.Unmarshal(line, &req)
			switch req.Method {
			case "ping":
				fmt.Fprintf(conn, `{"id":%q,"result":{"type":"pong","version":"0.7.5","protocol":17}}`+"\n", req.ID)
				conn.Close()
			case "agent.list":
				f.mu.Lock()
				body := f.agents
				f.mu.Unlock()
				fmt.Fprintf(conn, `{"id":%q,"result":{"type":"agent_list","agents":%s}}`+"\n", req.ID, body)
				conn.Close()
			case "events.subscribe":
				fmt.Fprintf(conn, `{"id":%q,"result":{"type":"subscription_started"}}`+"\n", req.ID)
				f.mu.Lock()
				f.subs = append(f.subs, conn)
				f.mu.Unlock()
			default:
				fmt.Fprintf(conn, `{"id":"","error":{"code":"invalid_request","message":"unknown"}}`+"\n")
				conn.Close()
			}
		}(conn)
	}
}

// collect drains publishes into a slice guarded for -race.
type collect struct {
	mu   sync.Mutex
	got  [][]Agent
	cond chan struct{}
}

func newCollect() *collect { return &collect{cond: make(chan struct{}, 64)} }

func (c *collect) publish(a []Agent) {
	c.mu.Lock()
	c.got = append(c.got, a)
	c.mu.Unlock()
	select {
	case c.cond <- struct{}{}:
	default:
	}
}

// waitFor polls until pred(latest publish) is true or the deadline hits.
func (c *collect) waitFor(t *testing.T, timeout time.Duration, pred func([]Agent) bool) {
	t.Helper()
	deadline := time.After(timeout)
	for {
		c.mu.Lock()
		n := len(c.got)
		var last []Agent
		if n > 0 {
			last = c.got[n-1]
		}
		c.mu.Unlock()
		if n > 0 && pred(last) {
			return
		}
		select {
		case <-c.cond:
		case <-deadline:
			t.Fatalf("condition not reached; %d publishes", n)
		}
	}
}

func TestRunPublishesInitialListThenEventTriggeredUpdate(t *testing.T) {
	f := newFakeHerdr(t)
	f.setAgents(`[{"agent":"claude","agent_status":"working","pane_id":"w3:p1"}]`)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	col := newCollect()
	go Run(ctx, &Client{SocketPath: f.path, Timeout: time.Second}, time.Hour, col.publish)

	col.waitFor(t, 3*time.Second, func(a []Agent) bool {
		return len(a) == 1 && a[0].Status == "working"
	})

	f.setAgents(`[{"agent":"claude","agent_status":"blocked","pane_id":"w3:p1"}]`)
	f.pushEvent("pane_updated")
	col.waitFor(t, 3*time.Second, func(a []Agent) bool {
		return len(a) == 1 && a[0].Status == "blocked"
	})
}

func TestRunPublishesNilOnDisconnect(t *testing.T) {
	f := newFakeHerdr(t)
	f.setAgents(`[{"agent":"claude","agent_status":"idle","pane_id":"w3:p1"}]`)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	col := newCollect()
	go Run(ctx, &Client{SocketPath: f.path, Timeout: 500 * time.Millisecond}, time.Hour, col.publish)

	col.waitFor(t, 3*time.Second, func(a []Agent) bool { return len(a) == 1 })

	f.close() // server goes away entirely
	col.waitFor(t, 3*time.Second, func(a []Agent) bool { return a == nil })
}

func TestRunReconcileTickRefetches(t *testing.T) {
	f := newFakeHerdr(t)
	f.setAgents(`[]`)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	col := newCollect()
	// Tiny reconcile interval: updates must arrive without any event push.
	go Run(ctx, &Client{SocketPath: f.path, Timeout: time.Second}, 50*time.Millisecond, col.publish)

	col.waitFor(t, 3*time.Second, func(a []Agent) bool { return a != nil && len(a) == 0 })
	f.setAgents(`[{"agent":"claude","agent_status":"done","pane_id":"w9:p1"}]`)
	col.waitFor(t, 3*time.Second, func(a []Agent) bool {
		return len(a) == 1 && a[0].Status == "done"
	})
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/herdr/ -run TestRun -v`
Expected: compile FAIL, `undefined: Run`.

- [ ] **Step 3: Write the implementation**

```go
package herdr

import (
	"context"
	"bufio"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"time"
)

// subscriptions are change triggers only; truth always comes from a fresh
// agent.list. Lifecycle kinds catch membership changes; pane.updated fires on
// any pane revision, which includes the content changes herdr derives agent
// status from, so status flips are covered without per-pane subscriptions
// (pane.agent_status_changed requires a fixed pane_id we would have to chase).
var subscriptions = []map[string]string{
	{"type": "pane.created"},
	{"type": "pane.closed"},
	{"type": "pane.exited"},
	{"type": "pane.updated"},
	{"type": "pane.agent_detected"},
	{"type": "workspace.closed"},
}

// debounce coalesces event bursts (pane.updated fires ~10/s under load) into
// at most one agent.list refetch per interval.
const debounce = 200 * time.Millisecond

// Run keeps publish fed with herdr's agent list until ctx ends. publish(nil)
// means herdr is unreachable. Reconnects forever with capped backoff; a
// reconcile tick refetches even without events as a missed-event backstop.
func Run(ctx context.Context, c *Client, reconcile time.Duration, publish func([]Agent)) {
	backoff := time.Second
	for {
		start := time.Now()
		if err := c.watch(ctx, reconcile, publish); err != nil {
			log.Printf("herdr: %v (reconnect in %s)", err, backoff)
		}
		publish(nil)
		if ctx.Err() != nil {
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		// A connection that stayed healthy for a while resets the backoff so a
		// herdr restart after days of uptime reconnects in a second.
		if time.Since(start) > time.Minute {
			backoff = time.Second
		} else if backoff *= 2; backoff > 30*time.Second {
			backoff = 30 * time.Second
		}
	}
}

// watch holds one subscription connection and refetches on triggers until the
// stream breaks or ctx is cancelled. Returns nil only on cancellation.
func (c *Client) watch(ctx context.Context, reconcile time.Duration, publish func([]Agent)) error {
	proto, version, err := c.Ping()
	if err != nil {
		return err
	}
	if proto != SupportedProtocol {
		log.Printf("herdr: server %s speaks protocol %d, client built against %d; continuing, expect breakage if shapes changed", version, proto, SupportedProtocol)
	}
	conn, err := net.DialTimeout("unix", c.SocketPath, c.timeout())
	if err != nil {
		return fmt.Errorf("subscribe dial: %w", err)
	}
	defer conn.Close()
	// Unblock the blocking reader when ctx ends; stop keeps the goroutine from
	// outliving this watch.
	stop := make(chan struct{})
	defer close(stop)
	go func() {
		select {
		case <-ctx.Done():
			conn.Close()
		case <-stop:
		}
	}()
	blob, err := json.Marshal(request{ID: "glove-agentd-sub", Method: "events.subscribe", Params: map[string]any{"subscriptions": subscriptions}})
	if err != nil {
		return err
	}
	if _, err := conn.Write(append(blob, '\n')); err != nil {
		return fmt.Errorf("subscribe write: %w", err)
	}
	// Every line (the ack, backlog replay, live events) is just a trigger; an
	// extra refetch is harmless and decoding event payloads would be a lie
	// waiting to happen across herdr versions.
	events := make(chan struct{}, 1)
	readErr := make(chan error, 1)
	go func() {
		r := bufio.NewReader(conn)
		for {
			if _, err := r.ReadBytes('\n'); err != nil {
				readErr <- err
				return
			}
			select {
			case events <- struct{}{}:
			default:
			}
		}
	}()
	refetch := func() error {
		agents, err := c.ListAgents()
		if err != nil {
			return fmt.Errorf("agent.list: %w", err)
		}
		publish(agents)
		return nil
	}
	if err := refetch(); err != nil {
		return err
	}
	tick := time.NewTicker(reconcile)
	defer tick.Stop()
	var pending <-chan time.Time
	for {
		select {
		case <-ctx.Done():
			return nil
		case err := <-readErr:
			if ctx.Err() != nil {
				return nil
			}
			return fmt.Errorf("event stream: %w", err)
		case <-events:
			if pending == nil {
				pending = time.After(debounce)
			}
		case <-pending:
			pending = nil
			if err := refetch(); err != nil {
				return err
			}
		case <-tick.C:
			if err := refetch(); err != nil {
				return err
			}
		}
	}
}
```

- [ ] **Step 4: Run tests to verify they pass, race-checked**

Run: `go test ./internal/herdr/ -race -v`
Expected: PASS (Task 1 + Task 2 tests).

- [ ] **Step 5: Commit**

```bash
git add internal/herdr
git commit -m "Add herdr watch loop: subscribe triggers, debounced refetch, backoff"
```

---

### Task 3: roster package (positional slots, LED frame, palette)

**Files:**
- Create: `internal/roster/roster.go`
- Test: `internal/roster/roster_test.go`

**Interfaces:**
- Consumes: `herdr.Agent` (Task 1), `protocol.RGB`, `protocol.NumSlots`.
- Produces: `roster.Palette{Amber, Green, Red, Working protocol.RGB}`; `roster.Roster` with `Set(agents []herdr.Agent)`, `Resolve(slot int) (herdr.Agent, bool)`, `Agents() []herdr.Agent`, `Frame(p Palette, cap int) [protocol.NumSlots]protocol.RGB`. Task 4 changes `config.Palette()` to return `roster.Palette`; Tasks 5 and 6 consume `Resolve`/`Frame`.

- [ ] **Step 1: Write the failing test**

```go
package roster

import (
	"testing"

	"github.com/calvin-barker/glove-agentd/internal/herdr"
	"github.com/calvin-barker/glove-agentd/internal/protocol"
)

var pal = Palette{
	Amber:   protocol.RGB{R: 0xFF, G: 0xB0},
	Green:   protocol.RGB{G: 0xE0},
	Red:     protocol.RGB{R: 0xFF},
	Working: protocol.RGB{R: 0x30, G: 0x30, B: 0x30},
}

func agentsFixture(statuses ...string) []herdr.Agent {
	var out []herdr.Agent
	for i, s := range statuses {
		out = append(out, herdr.Agent{Agent: "claude", Status: s, PaneID: "w1:p1", CWD: "/tmp", Title: "t"})
		out[i].PaneID = out[i].PaneID[:1] + string(rune('0'+i)) + ":p1" // w0:p1, w1:p1, ...
	}
	return out
}

func TestFrameMapsStatuses(t *testing.T) {
	r := &Roster{}
	r.Set(agentsFixture("working", "blocked", "idle", "done", "unknown"))
	f := r.Frame(pal, 10)
	want := [protocol.NumSlots]protocol.RGB{pal.Working, pal.Amber, pal.Green, pal.Green, pal.Working}
	if f != want {
		t.Fatalf("frame = %v, want %v", f, want)
	}
}

func TestFrameEmptyAndUnreachableAreDark(t *testing.T) {
	r := &Roster{}
	var dark [protocol.NumSlots]protocol.RGB
	if f := r.Frame(pal, 10); f != dark {
		t.Fatalf("zero-value roster not dark: %v", f)
	}
	r.Set(agentsFixture("idle"))
	r.Set(nil) // herdr became unreachable
	if f := r.Frame(pal, 10); f != dark {
		t.Fatalf("unreachable roster not dark: %v", f)
	}
}

func TestFrameHonorsSlotCapAndOverflow(t *testing.T) {
	r := &Roster{}
	r.Set(agentsFixture("idle", "idle", "idle", "idle", "idle", "idle"))
	f := r.Frame(pal, 5)
	if f[4] != pal.Green {
		t.Fatalf("slot 5 dark: %v", f)
	}
	if (f[5] != protocol.RGB{}) {
		t.Fatalf("slot 6 lit beyond cap: %v", f)
	}
	// cap beyond NumSlots must not panic or index out of range
	_ = r.Frame(pal, 99)
}

func TestResolve(t *testing.T) {
	r := &Roster{}
	r.Set(agentsFixture("idle", "working"))
	a, ok := r.Resolve(2)
	if !ok || a.Status != "working" {
		t.Fatalf("Resolve(2) = %+v %v", a, ok)
	}
	if _, ok := r.Resolve(3); ok {
		t.Fatal("Resolve(3) should miss")
	}
	if _, ok := r.Resolve(0); ok {
		t.Fatal("Resolve(0) should miss")
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/roster/ -v`
Expected: compile FAIL, `undefined: Roster`.

- [ ] **Step 3: Write the implementation**

```go
// Package roster mirrors herdr's agent list onto keyboard slots.
package roster

import (
	"sync"

	"github.com/calvin-barker/glove-agentd/internal/herdr"
	"github.com/calvin-barker/glove-agentd/internal/protocol"
)

// Palette holds the LED colors for each rendered state.
type Palette struct {
	Amber, Green, Red, Working protocol.RGB
}

// Roster holds the latest herdr agent list. Slot N is agents[N-1], the Nth
// row of herdr's sidebar; nil means herdr is unreachable (all dark).
type Roster struct {
	mu     sync.Mutex
	agents []herdr.Agent
}

// Set replaces the list; pass nil when herdr is unreachable.
func (r *Roster) Set(agents []herdr.Agent) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.agents = agents
}

// Resolve returns the agent behind a 1-based slot.
func (r *Roster) Resolve(slot int) (herdr.Agent, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if slot < 1 || slot > len(r.agents) {
		return herdr.Agent{}, false
	}
	return r.agents[slot-1], true
}

// Agents returns a copy of the current list for status reporting.
func (r *Roster) Agents() []herdr.Agent {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]herdr.Agent(nil), r.agents...)
}

// Frame renders slots 1..cap. unknown renders as working because it is almost
// always a transient detection gap on a live pane, and dark would read as "no
// agent"; done renders as idle because both mean "waiting on you".
func (r *Roster) Frame(p Palette, cap int) [protocol.NumSlots]protocol.RGB {
	r.mu.Lock()
	defer r.mu.Unlock()
	var f [protocol.NumSlots]protocol.RGB
	if cap > protocol.NumSlots {
		cap = protocol.NumSlots
	}
	for i := 0; i < cap && i < len(r.agents); i++ {
		switch r.agents[i].Status {
		case "working", "unknown":
			f[i] = p.Working
		case "blocked":
			f[i] = p.Amber
		case "idle", "done":
			f[i] = p.Green
		}
	}
	return f
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/roster/ -race -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/roster
git commit -m "Add roster: positional slots over herdr's agent list"
```

---

### Task 4: config changes (herdr keys in, dead keys out, Palette rewire)

**Files:**
- Modify: `internal/config/config.go`
- Test: `internal/config/config_test.go`

**Interfaces:**
- Consumes: `roster.Palette` (Task 3).
- Produces: `Config.HerdrSocket string` (json `herdr_socket`, default `~/.config/herdr/herdr.sock`), `Config.HerdrClientTTY string` (json `herdr_client_tty`, default ""), `Config.Palette() (roster.Palette, error)`. Removed: `IgnoreCWD`, `IdleNotifications`, `StatePath` fields, `IgnoresCWD` method. Unknown JSON keys in existing config files are ignored by encoding/json, so the live config keeps loading.

- [ ] **Step 1: Update the tests (failing first)**

In `internal/config/config_test.go`: delete every reference to `StatePath`, `IgnoreCWD`, `IgnoresCWD`, and `idle_notification_substrings` (including any dedicated test functions for them), and add:

```go
func TestHerdrDefaults(t *testing.T) {
	c, err := Load(filepath.Join(t.TempDir(), "missing.json"))
	if err != nil {
		t.Fatal(err)
	}
	home, _ := os.UserHomeDir()
	if c.HerdrSocket != filepath.Join(home, ".config", "herdr", "herdr.sock") {
		t.Fatalf("HerdrSocket = %q", c.HerdrSocket)
	}
	if c.HerdrClientTTY != "" {
		t.Fatalf("HerdrClientTTY = %q", c.HerdrClientTTY)
	}
}

func TestHerdrOverrides(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	os.WriteFile(path, []byte(`{"herdr_socket":"/x/h.sock","herdr_client_tty":"/dev/ttys009"}`), 0o644)
	c, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if c.HerdrSocket != "/x/h.sock" || c.HerdrClientTTY != "/dev/ttys009" {
		t.Fatalf("got %q %q", c.HerdrSocket, c.HerdrClientTTY)
	}
}

func TestOldConfigKeysStillLoad(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	// The deployed config still carries retired keys; they must be ignored.
	os.WriteFile(path, []byte(`{"green":"00E000","ignore_cwd_substrings":[".claude-mem"],"state_path":"/x"}`), 0o644)
	c, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if c.Green != "00E000" {
		t.Fatalf("Green = %q", c.Green)
	}
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `go test ./internal/config/ -v`
Expected: compile FAIL (`c.HerdrSocket undefined`, plus removed-field references in the old tests you deleted must be gone; if the package still references `state.Palette`, that flips in Step 3).

- [ ] **Step 3: Update the implementation**

In `internal/config/config.go`:
- Replace import of `internal/state` with `internal/roster`.
- In `Config`: add `HerdrSocket string \`json:"herdr_socket"\`` and `HerdrClientTTY string \`json:"herdr_client_tty"\``; delete `IgnoreCWD`, `IdleNotifications`, `StatePath`.
- In `defaults()`: delete `StatePath` and `IdleNotifications` lines; add:

```go
HerdrSocket: filepath.Join(configDir(), "herdr", "herdr.sock"),
```

with the helper (place next to `stateDir`):

```go
func configDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config")
}
```

- Delete the `IgnoresCWD` method.
- Change `Palette()` to return `(roster.Palette, error)` with the same body (`var p roster.Palette`).
- Drop the now-unused `strings` import.

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/config/ -v`
Expected: PASS. `go build ./...` will fail (main.go, state, ingest still reference removed pieces); that is expected until Task 6 and fine because Task 6 lands before this branch merges. Run only the package tests here.

- [ ] **Step 5: Commit**

```bash
git add internal/config
git commit -m "Point config at herdr: socket path, client tty, roster palette"
```

---

### Task 5: jump rewrite (herdr focus + single-window raise, tmux deleted)

**Files:**
- Modify: `internal/jump/jump.go` (rewrite; keep `Runner`, `ExecRunner`, `focusByTTYScript`, `focusByTTY`, `firstLine` deleted)
- Keep unchanged: `internal/jump/dispatch.go`
- Test: `internal/jump/jump_test.go` (rewrite)

**Interfaces:**
- Consumes: `herdr.Agent` (Task 1); `roster.Roster.Resolve` shape (Task 3).
- Produces: `jump.New(roster Resolver, focuser Focuser, run Runner, tty string) *Executor` with `Jump(slot int) error`; interfaces `Resolver{ Resolve(int) (herdr.Agent, bool) }` and `Focuser{ FocusAgent(string) error }` defined in package jump so tests fake them without real sockets.

- [ ] **Step 1: Write the failing test (replace jump_test.go entirely)**

```go
package jump

import (
	"errors"
	"strings"
	"testing"

	"github.com/calvin-barker/glove-agentd/internal/herdr"
)

type fakeRoster map[int]herdr.Agent

func (f fakeRoster) Resolve(slot int) (herdr.Agent, bool) {
	a, ok := f[slot]
	return a, ok
}

type fakeFocuser struct {
	target string
	err    error
}

func (f *fakeFocuser) FocusAgent(target string) error {
	f.target = target
	return f.err
}

type fakeRunner struct {
	calls [][]string
	out   map[string]string // keyed by command name
	err   map[string]error
}

func (f *fakeRunner) Output(name string, args ...string) (string, error) {
	f.calls = append(f.calls, append([]string{name}, args...))
	return f.out[name], f.err[name]
}

func TestJumpFocusesPaneAndRaisesConfiguredTTY(t *testing.T) {
	foc := &fakeFocuser{}
	run := &fakeRunner{out: map[string]string{"osascript": "hit"}}
	e := New(fakeRoster{3: {PaneID: "w6:p1"}}, foc, run, "/dev/ttys009")
	if err := e.Jump(3); err != nil {
		t.Fatal(err)
	}
	if foc.target != "w6:p1" {
		t.Fatalf("focus target = %q", foc.target)
	}
	if len(run.calls) != 1 || run.calls[0][0] != "osascript" {
		t.Fatalf("calls = %v", run.calls)
	}
	if !strings.Contains(run.calls[0][2], "/dev/ttys009") {
		t.Fatal("script does not target the configured tty")
	}
}

func TestJumpDiscoversClientTTY(t *testing.T) {
	foc := &fakeFocuser{}
	run := &fakeRunner{out: map[string]string{
		"ps":        "??       /opt/homebrew/bin/herdr\nttys003  -zsh\nttys009  herdr\n",
		"osascript": "hit",
	}}
	e := New(fakeRoster{1: {PaneID: "w3:p1"}}, foc, run, "")
	if err := e.Jump(1); err != nil {
		t.Fatal(err)
	}
	// call 0 = ps discovery, call 1 = osascript raise
	if len(run.calls) != 2 || run.calls[0][0] != "ps" {
		t.Fatalf("calls = %v", run.calls)
	}
	if !strings.Contains(run.calls[1][2], "/dev/ttys009") {
		t.Fatal("script does not target the discovered tty")
	}
}

func TestJumpEmptySlotIsNoop(t *testing.T) {
	foc := &fakeFocuser{}
	run := &fakeRunner{}
	e := New(fakeRoster{}, foc, run, "/dev/ttys009")
	if err := e.Jump(4); err != nil {
		t.Fatal(err)
	}
	if foc.target != "" || len(run.calls) != 0 {
		t.Fatal("no-op expected")
	}
}

func TestJumpFocusErrorSurfaces(t *testing.T) {
	foc := &fakeFocuser{err: errors.New("gone")}
	run := &fakeRunner{}
	e := New(fakeRoster{1: {PaneID: "w3:p1"}}, foc, run, "/dev/ttys009")
	if err := e.Jump(1); err == nil {
		t.Fatal("want error")
	}
	if len(run.calls) != 0 {
		t.Fatal("raise must not run when in-herdr focus failed")
	}
}

func TestJumpRaiseFailureIsBestEffort(t *testing.T) {
	foc := &fakeFocuser{}
	run := &fakeRunner{err: map[string]error{"ps": errors.New("boom")}}
	e := New(fakeRoster{1: {PaneID: "w3:p1"}}, foc, run, "")
	if err := e.Jump(1); err != nil {
		t.Fatalf("raise failure must not fail the jump: %v", err)
	}
	if foc.target != "w3:p1" {
		t.Fatal("in-herdr focus must still happen")
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/jump/ -v`
Expected: compile FAIL (`New` signature mismatch, `fakeRoster` type mismatch against the old registry-based Executor).

- [ ] **Step 3: Rewrite jump.go**

Replace the whole file. Keep `defaultExecTimeout`, `Runner`, `ExecRunner` verbatim; keep `focusByTTYScript` verbatim (the hardware-verified AppleScript block with the AXRaise notes comment); delete `errNoTTYMatch` handling semantics (a "miss" is now just an error string), `focusByIDScript`, `openTabScript`, `openTabAndAttach`, `firstLine`, and all tmux calls.

```go
// Package jump focuses the herdr pane for a keyboard slot.
package jump

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os/exec"
	"strings"
	"time"

	"github.com/calvin-barker/glove-agentd/internal/herdr"
)

// defaultExecTimeout bounds each external call so a hung osascript cannot
// wedge the jump worker forever.
const defaultExecTimeout = 5 * time.Second

type Runner interface {
	Output(name string, args ...string) (string, error)
}

type ExecRunner struct {
	// Timeout bounds each command; 0 uses defaultExecTimeout.
	Timeout time.Duration
}

func (r ExecRunner) Output(name string, args ...string) (string, error) {
	timeout := r.Timeout
	if timeout == 0 {
		timeout = defaultExecTimeout
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, name, args...).Output()
	return string(out), err
}

// Resolver maps a keyboard slot to a herdr agent (implemented by roster).
type Resolver interface {
	Resolve(slot int) (herdr.Agent, bool)
}

// Focuser focuses a pane inside herdr (implemented by herdr.Client).
type Focuser interface {
	FocusAgent(target string) error
}

type Executor struct {
	roster Resolver
	herdr  Focuser
	run    Runner
	tty    string // config override; "" discovers the herdr client tty per jump
}

func New(roster Resolver, focuser Focuser, run Runner, tty string) *Executor {
	return &Executor{roster: roster, herdr: focuser, run: run, tty: tty}
}

// Jump focuses the slot's agent in herdr, then raises the iTerm window
// hosting the herdr client. The raise is best-effort: the in-herdr focus has
// already landed, so a raise failure only means the window did not come
// forward.
func (e *Executor) Jump(slot int) error {
	a, ok := e.roster.Resolve(slot)
	if !ok {
		log.Printf("jump: slot %d is empty", slot)
		return nil
	}
	if err := e.herdr.FocusAgent(a.PaneID); err != nil {
		return fmt.Errorf("jump: focus %s: %w", a.PaneID, err)
	}
	tty := e.tty
	if tty == "" {
		var err error
		if tty, err = e.clientTTY(); err != nil {
			log.Printf("jump: raise skipped: %v", err)
			return nil
		}
	}
	if err := e.focusByTTY(tty); err != nil {
		log.Printf("jump: raise failed: %v", err)
	}
	return nil
}

// clientTTY finds the interactive herdr client: the only herdr process with a
// real controlling terminal (the server runs detached on "??").
func (e *Executor) clientTTY() (string, error) {
	out, err := e.run.Output("ps", "-axo", "tty=,comm=")
	if err != nil {
		return "", err
	}
	for _, line := range strings.Split(out, "\n") {
		f := strings.Fields(line)
		if len(f) < 2 || !strings.HasPrefix(f[0], "ttys") {
			continue
		}
		if f[1] == "herdr" || strings.HasSuffix(f[1], "/herdr") {
			return "/dev/" + f[0], nil
		}
	}
	return "", errors.New("no herdr client with a tty")
}
```

Then keep the existing `focusByTTYScript` constant and these two helpers verbatim from the old file:

```go
func (e *Executor) osascript(script string) (string, error) {
	return e.run.Output("osascript", "-e", script)
}

func (e *Executor) focusByTTY(tty string) error {
	out, err := e.osascript(fmt.Sprintf(focusByTTYScript, tty))
	if err != nil {
		return err
	}
	if strings.TrimSpace(out) != "hit" {
		return fmt.Errorf("no iTerm2 session on %s", tty)
	}
	return nil
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/jump/ -race -v`
Expected: PASS (all five plus the existing dispatcher tests).

- [ ] **Step 5: Commit**

```bash
git add internal/jump
git commit -m "Jump via herdr focus plus a single-window iTerm raise"
```

---

### Task 6: main.go rewrite, delete the hook pipeline, Makefile/README

**Files:**
- Modify: `cmd/glove-agentd/main.go` (rewrite `app`, `runDaemon`, `runStatus` rows)
- Delete: `cmd/glove-agent-hook/`, `internal/ingest/`, `internal/liveness/`, `internal/state/`
- Modify: `Makefile` (drop hook binary from build/install/uninstall, drop `hooks` target), `README.md` (architecture/config/install sections), `scripts/` if any reference the hook binary (check `grep -rn glove-agent-hook scripts/ Makefile README.md`)

**Interfaces:**
- Consumes: everything produced by Tasks 1-5.
- Produces: a daemon whose only inputs are the herdr socket and the keyboard, and whose status socket replies to any request line with the roster JSON.

- [ ] **Step 1: Rewrite main.go**

```go
// glove-agentd mirrors herdr's agent list onto Glove80 status LEDs.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/calvin-barker/glove-agentd/internal/config"
	"github.com/calvin-barker/glove-agentd/internal/herdr"
	"github.com/calvin-barker/glove-agentd/internal/hidio"
	"github.com/calvin-barker/glove-agentd/internal/jump"
	"github.com/calvin-barker/glove-agentd/internal/protocol"
	"github.com/calvin-barker/glove-agentd/internal/roster"

	"github.com/sstallion/go-hid"
)

type app struct {
	cfg     config.Config
	ros     *roster.Roster
	palette roster.Palette
	writer  *hidio.Writer
}

func (a *app) push() {
	a.writer.SetFrame(protocol.EncodeSetLEDs(a.ros.Frame(a.palette, a.cfg.SlotCap)))
}

type statusReply struct {
	Slots []slotRow `json:"slots"`
}

type slotRow struct {
	Slot   int    `json:"slot"`
	Agent  string `json:"agent"`
	Status string `json:"status"`
	Pane   string `json:"pane"`
	CWD    string `json:"cwd"`
	Title  string `json:"title"`
}

func (a *app) statusJSON() []byte {
	var rows []slotRow
	for i, ag := range a.ros.Agents() {
		rows = append(rows, slotRow{Slot: i + 1, Agent: ag.Agent, Status: ag.Status, Pane: ag.PaneID, CWD: ag.CWD, Title: ag.Title})
	}
	blob, _ := json.Marshal(statusReply{Slots: rows})
	return blob
}

// serveStatus answers any request line on the daemon socket with the roster,
// for the `glove-agentd status` CLI.
func serveStatus(ctx context.Context, l net.Listener, a *app) {
	go func() {
		<-ctx.Done()
		l.Close()
	}()
	for {
		conn, err := l.Accept()
		if err != nil {
			return
		}
		go func(conn net.Conn) {
			defer conn.Close()
			conn.SetDeadline(time.Now().Add(2 * time.Second))
			bufio.NewReader(conn).ReadString('\n')
			conn.Write(append(a.statusJSON(), '\n'))
		}(conn)
	}
}

func listenStatus(path string) (net.Listener, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	// A previous daemon's socket file blocks bind; it is dead, remove it.
	os.Remove(path)
	return net.Listen("unix", path)
}

func runDaemon() error {
	if _, err := os.UserHomeDir(); err != nil {
		return fmt.Errorf("cannot resolve home directory: %w", err)
	}
	cfg, err := config.Load("")
	if err != nil {
		return err
	}
	palette, err := cfg.Palette()
	if err != nil {
		return err
	}
	if err := hid.Init(); err != nil {
		return fmt.Errorf("hidapi init: %w", err)
	}
	defer hid.Exit()

	heartbeat := time.NewTicker(time.Duration(cfg.HeartbeatSec) * time.Second)
	defer heartbeat.Stop()
	writer := hidio.New(hidio.OpenGlove80, heartbeat.C)
	// Retry a closed handle every few seconds rather than waiting for the 30s
	// heartbeat, so after a wake the lights come back within the stuck threshold
	// instead of a heartbeat-quantized minute-plus.
	reopen := time.NewTicker(3 * time.Second)
	defer reopen.Stop()
	writer.SetReopenTicker(reopen.C)
	// After a sleep/wake the OS can pin the keyboard's exclusive HID claim to
	// this process until it exits, so every reopen fails "already open" and the
	// lights stay dark. Close does not release it; only process death does. When
	// that persists past the threshold, exit so launchd (KeepAlive) relaunches a
	// fresh process that reclaims the device.
	stuckAfter := time.Duration(cfg.StuckThresholdSec) * time.Second
	writer.SetStuckHandler(stuckAfter, func() {
		log.Printf("hid: device stuck 'already open' for %s (sleep/wake orphaned handle); exiting for a clean launchd relaunch", stuckAfter)
		os.Exit(1)
	}, time.Now)

	a := &app{cfg: cfg, ros: &roster.Roster{}, palette: palette, writer: writer}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	l, err := listenStatus(cfg.SocketPath)
	if err != nil {
		return err
	}
	go serveStatus(ctx, l, a)
	go writer.Run(ctx)

	hc := &herdr.Client{SocketPath: cfg.HerdrSocket}
	go herdr.Run(ctx, hc, time.Duration(cfg.PollIntervalSec)*time.Second, func(agents []herdr.Agent) {
		a.ros.Set(agents)
		a.push()
	})

	exec := jump.New(a.ros, hc, jump.ExecRunner{}, cfg.HerdrClientTTY)
	// Run jumps on a worker so a slow focus call never blocks the HID reader
	// (which drains writer.Inbound()); a blocked reader stops receiving keys.
	dispatcher := jump.NewDispatcher(ctx, exec.Jump, 8)
	go func() {
		for msg := range writer.Inbound() {
			if j, ok := msg.(protocol.Jump); ok {
				dispatcher.Submit(j.Slot)
			}
		}
	}()

	a.push()
	log.Printf("glove-agentd running: herdr=%s slots=%d", cfg.HerdrSocket, cfg.SlotCap)
	<-ctx.Done()
	return nil
}

func runStatus() error {
	cfg, err := config.Load("")
	if err != nil {
		return err
	}
	conn, err := net.DialTimeout("unix", cfg.SocketPath, time.Second)
	if err != nil {
		return fmt.Errorf("daemon not reachable at %s: %w", cfg.SocketPath, err)
	}
	defer conn.Close()
	conn.Write([]byte("status\n"))
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	line, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil {
		return err
	}
	var reply statusReply
	if err := json.Unmarshal([]byte(line), &reply); err != nil {
		return err
	}
	if len(reply.Slots) == 0 {
		fmt.Println("no agents (or herdr unreachable)")
		return nil
	}
	fmt.Printf("%-4s %-8s %-9s %-8s %s\n", "SLOT", "AGENT", "STATUS", "PANE", "TITLE")
	for _, r := range reply.Slots {
		fmt.Printf("%-4d %-8s %-9s %-8s %s\n", r.Slot, r.Agent, r.Status, r.Pane, r.Title)
	}
	return nil
}

func main() {
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	cmd := "run"
	if len(os.Args) > 1 {
		cmd = os.Args[1]
	}
	var err error
	switch cmd {
	case "run":
		err = runDaemon()
	case "status":
		err = runStatus()
	default:
		err = fmt.Errorf("usage: glove-agentd [run|status]")
	}
	if err != nil {
		log.Fatal(err)
	}
}
```

- [ ] **Step 2: Delete the retired packages and binary**

```bash
git rm -r cmd/glove-agent-hook internal/ingest internal/liveness internal/state
```

- [ ] **Step 3: Update Makefile and README**

`grep -rn "glove-agent-hook\|ingest\|hooks" Makefile README.md scripts/` and fix every hit: `build` compiles only `./cmd/glove-agentd`; `install`/`uninstall`/`sign` drop the hook binary; delete the `hooks` target; README's architecture section describes the herdr socket source of truth, the config keys (`herdr_socket`, `herdr_client_tty`, `slot_cap`, `poll_interval_sec`, `heartbeat_sec`, `stuck_threshold_sec`, colors), documents the retired keys (`ignore_cwd_substrings`, `idle_notification_substrings`, `state_path`) as ignored, and replaces the hook-install instructions with "run herdr; the daemon finds it".

- [ ] **Step 4: Build and run the full suite**

Run: `go build ./... && make test`
Expected: everything compiles; all package tests PASS. `go vet ./...` clean.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Source agent state from herdr; retire the hook pipeline"
```

---

### Task 7: integration test rewrite

**Files:**
- Modify: `test/integration_test.go` (rewrite)

**Interfaces:**
- Consumes: `herdr.Run`, `herdr.Client`, `roster.Roster`, `roster.Palette`, `protocol.EncodeSetLEDs`.

- [ ] **Step 1: Write the failing test (replace the file)**

The old file exercises hook ingestion + tmux jumps; both are gone. The new test wires the real watch loop to a real roster and asserts LED frames end to end against a fake herdr server (reuse the `fakeHerdr` helper by exporting it via `internal/herdr/testserver_test.go`? No: `test/` is a separate package, so give it its own copy of the fake server; duplication between test helpers is acceptable and keeps packages independent).

```go
package test

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/calvin-barker/glove-agentd/internal/herdr"
	"github.com/calvin-barker/glove-agentd/internal/protocol"
	"github.com/calvin-barker/glove-agentd/internal/roster"
)

// fakeHerdr mimics the herdr server contract: one-shot requests, streaming
// subscribe. Copied from internal/herdr's test helper on purpose; this
// package tests the public seams only.
type fakeHerdr struct {
	path string
	l    net.Listener
	mu   sync.Mutex
	body string
	subs []net.Conn
}

func newFakeHerdr(t *testing.T) *fakeHerdr {
	t.Helper()
	dir, err := os.MkdirTemp("", "hd")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	f := &fakeHerdr{path: filepath.Join(dir, "h.sock"), body: "[]"}
	l, err := net.Listen("unix", f.path)
	if err != nil {
		t.Fatal(err)
	}
	f.l = l
	t.Cleanup(func() { l.Close() })
	go func() {
		for {
			conn, err := l.Accept()
			if err != nil {
				return
			}
			go f.handle(conn)
		}
	}()
	return f
}

func (f *fakeHerdr) handle(conn net.Conn) {
	line, err := bufio.NewReader(conn).ReadBytes('\n')
	if err != nil {
		conn.Close()
		return
	}
	var req struct {
		ID     string `json:"id"`
		Method string `json:"method"`
	}
	json.Unmarshal(line, &req)
	switch req.Method {
	case "ping":
		fmt.Fprintf(conn, `{"id":%q,"result":{"type":"pong","version":"0.7.5","protocol":17}}`+"\n", req.ID)
		conn.Close()
	case "agent.list":
		f.mu.Lock()
		body := f.body
		f.mu.Unlock()
		fmt.Fprintf(conn, `{"id":%q,"result":{"type":"agent_list","agents":%s}}`+"\n", req.ID, body)
		conn.Close()
	case "events.subscribe":
		fmt.Fprintf(conn, `{"id":%q,"result":{"type":"subscription_started"}}`+"\n", req.ID)
		f.mu.Lock()
		f.subs = append(f.subs, conn)
		f.mu.Unlock()
	default:
		conn.Close()
	}
}

func (f *fakeHerdr) setAgents(body string) {
	f.mu.Lock()
	f.body = body
	for _, c := range f.subs {
		fmt.Fprintf(c, `{"event":"pane_updated","data":{}}`+"\n")
	}
	f.mu.Unlock()
}

type frameSink struct {
	mu     sync.Mutex
	frames [][]byte
	cond   chan struct{}
}

func (s *frameSink) push(b []byte) {
	s.mu.Lock()
	s.frames = append(s.frames, b)
	s.mu.Unlock()
	select {
	case s.cond <- struct{}{}:
	default:
	}
}

func (s *frameSink) waitFor(t *testing.T, timeout time.Duration, want []byte) {
	t.Helper()
	deadline := time.After(timeout)
	for {
		s.mu.Lock()
		var last []byte
		if len(s.frames) > 0 {
			last = s.frames[len(s.frames)-1]
		}
		s.mu.Unlock()
		if string(last) == string(want) {
			return
		}
		select {
		case <-s.cond:
		case <-deadline:
			t.Fatalf("frame never matched; last=%v want=%v", last, want)
		}
	}
}

func TestHerdrToLEDFrameEndToEnd(t *testing.T) {
	f := newFakeHerdr(t)
	f.setAgents(`[{"agent":"claude","agent_status":"working","pane_id":"w3:p1"},{"agent":"claude","agent_status":"idle","pane_id":"w5:p1"}]`)

	pal := roster.Palette{
		Amber:   protocol.RGB{R: 0xFF, G: 0xB0},
		Green:   protocol.RGB{G: 0xE0},
		Working: protocol.RGB{R: 0x30, G: 0x30, B: 0x30},
	}
	ros := &roster.Roster{}
	sink := &frameSink{cond: make(chan struct{}, 64)}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go herdr.Run(ctx, &herdr.Client{SocketPath: f.path, Timeout: time.Second}, time.Hour, func(agents []herdr.Agent) {
		ros.Set(agents)
		sink.push(protocol.EncodeSetLEDs(ros.Frame(pal, 10)))
	})

	frame := func(colors ...protocol.RGB) []byte {
		var arr [protocol.NumSlots]protocol.RGB
		copy(arr[:], colors)
		return protocol.EncodeSetLEDs(arr)
	}
	sink.waitFor(t, 3*time.Second, frame(pal.Working, pal.Green))

	// A status flip pushed through the event stream repaints amber.
	f.setAgents(`[{"agent":"claude","agent_status":"blocked","pane_id":"w3:p1"},{"agent":"claude","agent_status":"idle","pane_id":"w5:p1"}]`)
	sink.waitFor(t, 3*time.Second, frame(pal.Amber, pal.Green))

	// The second agent exits: slot 1 keeps the survivor, slot 2 goes dark.
	f.setAgents(`[{"agent":"claude","agent_status":"idle","pane_id":"w5:p1"}]`)
	sink.waitFor(t, 3*time.Second, frame(pal.Green))
}
```

- [ ] **Step 2: Run to verify current failure, then pass**

Run: `go test ./test/ -race -v`
Expected: the old file fails to compile against the new packages before the rewrite; after replacing it, PASS.

- [ ] **Step 3: Full suite and commit**

```bash
make test
git add test/integration_test.go
git commit -m "Rewrite integration test against a fake herdr server"
```

---

### Task 8: land, configure, deploy

**Files:**
- Create: `~/.config/herdr/config.toml`
- Modify: `~/.claude/settings.json` (remove glove-agent-hook entries)
- Repo: merge `feature/herdr-migration` into `main`, push

- [ ] **Step 1: herdr theme adoption**

`~/.config/herdr/config.toml` does not exist yet (herdr runs stock catppuccin). Create it:

```toml
[theme.custom]
green = "#00E000"
yellow = "#FFB000"
red = "#FF0000"
```

Then validate and apply:

```bash
herdr config check
herdr server reload-config
```

Expected: `config: ok` (or no issues) and a reloaded server. Visual follow-up for Calvin: if the working-state spinner color should also match the dim LED, add `accent = "#RRGGBB"` later; leaving stock accent is fine.

- [ ] **Step 2: Merge and push**

```bash
git checkout main && git merge --no-ff feature/herdr-migration -m "Source agent state from herdr instead of Claude Code hooks"
git push origin main
```

- [ ] **Step 3: Sign and stage the binary**

```bash
make sign
```

Then Calvin, in a real terminal (sudo cannot prompt through the agent):

```bash
sudo cp ~/development/glove-agentd/glove-agentd /usr/local/bin/
sudo rm -f /usr/local/bin/glove-agent-hook
launchctl kickstart -k gui/$(id -u)/com.calvin-barker.glove-agentd
```

The Input Monitoring and Accessibility grants persist because `make sign` keeps the same designated requirement.

- [ ] **Step 4: Remove the Claude Code hooks**

Back up `~/.claude/settings.json`, then delete the five hook entries whose command is `/usr/local/bin/glove-agent-hook` (SessionStart, UserPromptSubmit, PostToolUse, Notification, Stop/SessionEnd blocks). Leave all other hooks intact. New Claude sessions stop reporting; the old daemon binary keeps working off its last state until the new binary is installed, which is fine.

- [ ] **Step 5: Acceptance (Calvin at the keyboard)**

- F1..F4 mirror herdr's sidebar top to bottom (states: dim=working, amber=blocked, green=idle/done).
- Block an agent (permission prompt): its LED goes amber within about a second; approve: back to dim.
- Hold H, tap the F-key of a background agent: herdr switches to that agent and the iTerm window comes forward.
- `herdr server stop`: all LEDs go dark; `herdr` (relaunch): LEDs return without touching the daemon.
- `glove-agentd status` prints the slot table matching the sidebar.
- Sidebar colors: idle/done rows read as the LED green, blocked as the LED amber.
