# glove-agentd Daemon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `glove-agentd`, a macOS daemon that tracks Claude Code sessions via hooks and drives per-key status LEDs on a Glove80 keyboard over raw HID, plus the jump-to-session path triggered from the keyboard.

**Architecture:** One Go daemon owns everything on the host: a Unix socket ingests Claude Code hook events, a slot registry maps sessions to keyboard slots 1-10 and their states, an HID writer pushes full LED frames to the keyboard (and reads jump messages back), a liveness poller catches crashed sessions, and a jump executor focuses tmux/iTerm2 targets. A tiny `glove-agent-hook` client binary forwards hook events to the socket. All side effects (HID device, processes, tmux, osascript) sit behind interfaces so every package is unit-testable.

**Tech Stack:** Go 1.22+, stdlib `testing` only, one external dependency: `github.com/sstallion/go-hid` (hidapi bindings, vendors its own C sources, needs cgo which works out of the box with Xcode CLT). AppleScript via `osascript` for iTerm2 control.

## Global Constraints

- Repo: `~/development/glove-agentd`, module `github.com/calvin-barker/glove-agentd`, Go 1.22+.
- TDD every internal package: write the failing test first, watch it fail, implement, watch it pass, commit. `cmd/` binaries are thin wiring verified by `go build` and smoke tests.
- Protocol (must match the firmware plan byte for byte): 32-byte reports; byte0 = protocol version `0x01`; commands: `0x01` SET_LEDS (bytes 2..31 = 10 slots x RGB, always a full frame), `0x02` HELLO (reply from keyboard: `[0x01, 0x02, maxSlots]`), `0x10` JUMP (byte2 = slot 1-10). hidapi writes prepend a `0x00` report ID byte, so a write is 33 bytes on the wire.
- HID device discovery: usage page `0xFF60`, usage `0x61`. Never match by VID/PID.
- State machine: SessionStart and UserPromptSubmit -> working (LED off); Notification -> needs_input (amber); Stop -> idle (green); SessionEnd -> slot freed; liveness failure -> dead (red); jump on a dead slot -> acknowledge and free.
- Slots: lowest free slot first; dead slots are reused last (oldest dead evicted only when no free slot exists); overflow sessions queue in registration order and are promoted when a slot frees. Default slot cap 5 (config can raise to 10).
- Default colors: amber `FFB000`, green `00C853`, red `FF1744`. Working and empty slots are off (black).
- Paths: socket `~/.local/state/glove-agentd/agentd.sock`, persisted registry `~/.local/state/glove-agentd/state.json`, config `~/.config/glove-agentd/config.json`.
- Daemon re-sends the LED frame every 30 seconds (heartbeat) and immediately on any state change or device reconnect.
- Hook client must never slow Claude Code: 100ms dial+write deadline, always exit 0.
- Commit after every task. Never add Claude/Anthropic attribution to commits.

---

### Task 1: Repo scaffold and protocol package

**Files:**
- Create: `~/development/glove-agentd/go.mod` (via `go mod init`)
- Create: `internal/protocol/protocol.go`
- Test: `internal/protocol/protocol_test.go`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `protocol.RGB{R,G,B byte}`, `protocol.EncodeSetLEDs([10]RGB) []byte`, `protocol.EncodeHello() []byte`, `protocol.ParseInbound([]byte) (Inbound, error)` returning `protocol.Jump{Slot int}` or `protocol.HelloReply{MaxSlots int}`, constants `ReportSize=32`, `NumSlots=10`, `Version=0x01`, `CmdSetLEDs=0x01`, `CmdHello=0x02`, `CmdJump=0x10`.

- [ ] **Step 1: Scaffold the repo**

```bash
mkdir -p ~/development/glove-agentd && cd ~/development/glove-agentd
git init
go mod init github.com/calvin-barker/glove-agentd
mkdir -p cmd/glove-agentd cmd/glove-agent-hook internal/protocol internal/state internal/ingest internal/hidio internal/liveness internal/jump internal/config test
printf 'glove-agentd\nglove-agent-hook\n' > .gitignore
```

- [ ] **Step 2: Write the failing test**

`internal/protocol/protocol_test.go`:

```go
package protocol

import (
	"errors"
	"testing"
)

func TestEncodeSetLEDs(t *testing.T) {
	var colors [NumSlots]RGB
	colors[0] = RGB{R: 0xFF, G: 0xB0, B: 0x00}
	colors[9] = RGB{R: 0x00, G: 0xC8, B: 0x53}
	got := EncodeSetLEDs(colors)
	if len(got) != ReportSize {
		t.Fatalf("len = %d, want %d", len(got), ReportSize)
	}
	if got[0] != Version || got[1] != CmdSetLEDs {
		t.Fatalf("header = [%#x %#x], want [0x01 0x01]", got[0], got[1])
	}
	if got[2] != 0xFF || got[3] != 0xB0 || got[4] != 0x00 {
		t.Fatalf("slot 1 rgb = [%#x %#x %#x]", got[2], got[3], got[4])
	}
	if got[29] != 0x00 || got[30] != 0xC8 || got[31] != 0x53 {
		t.Fatalf("slot 10 rgb = [%#x %#x %#x]", got[29], got[30], got[31])
	}
}

func TestEncodeHello(t *testing.T) {
	got := EncodeHello()
	if len(got) != ReportSize || got[0] != Version || got[1] != CmdHello {
		t.Fatalf("hello = %v", got[:2])
	}
}

func TestParseInboundJump(t *testing.T) {
	report := make([]byte, ReportSize)
	report[0], report[1], report[2] = Version, CmdJump, 3
	msg, err := ParseInbound(report)
	if err != nil {
		t.Fatal(err)
	}
	j, ok := msg.(Jump)
	if !ok || j.Slot != 3 {
		t.Fatalf("got %#v, want Jump{Slot:3}", msg)
	}
}

func TestParseInboundHelloReply(t *testing.T) {
	report := make([]byte, ReportSize)
	report[0], report[1], report[2] = Version, CmdHello, 5
	msg, err := ParseInbound(report)
	if err != nil {
		t.Fatal(err)
	}
	h, ok := msg.(HelloReply)
	if !ok || h.MaxSlots != 5 {
		t.Fatalf("got %#v, want HelloReply{MaxSlots:5}", msg)
	}
}

func TestParseInboundErrors(t *testing.T) {
	cases := []struct {
		name   string
		report []byte
		want   error
	}{
		{"short", []byte{Version, CmdJump}, ErrShortReport},
		{"bad version", pad([]byte{0x02, CmdJump, 1}), ErrBadVersion},
		{"unknown command", pad([]byte{Version, 0x7F, 1}), ErrUnknownCommand},
		{"slot zero", pad([]byte{Version, CmdJump, 0}), ErrBadSlot},
		{"slot eleven", pad([]byte{Version, CmdJump, 11}), ErrBadSlot},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := ParseInbound(c.report)
			if !errors.Is(err, c.want) {
				t.Fatalf("err = %v, want %v", err, c.want)
			}
		})
	}
}

func pad(b []byte) []byte {
	out := make([]byte, ReportSize)
	copy(out, b)
	return out
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `go test ./internal/protocol/ -v`
Expected: FAIL to build with `undefined: NumSlots` (and friends).

- [ ] **Step 4: Write minimal implementation**

`internal/protocol/protocol.go`:

```go
// Package protocol encodes and decodes the 32-byte raw HID reports shared
// with the Glove80 agent-status firmware. Keep in sync with the firmware plan.
package protocol

import "errors"

const (
	ReportSize = 32
	NumSlots   = 10

	Version    byte = 0x01
	CmdSetLEDs byte = 0x01
	CmdHello   byte = 0x02
	CmdJump    byte = 0x10
)

var (
	ErrShortReport    = errors.New("protocol: report shorter than 32 bytes")
	ErrBadVersion     = errors.New("protocol: unknown protocol version")
	ErrUnknownCommand = errors.New("protocol: unknown command")
	ErrBadSlot        = errors.New("protocol: slot out of range 1-10")
)

type RGB struct{ R, G, B byte }

// Inbound is a message sent by the keyboard to the host.
type Inbound interface{ isInbound() }

type Jump struct{ Slot int }

func (Jump) isInbound() {}

type HelloReply struct{ MaxSlots int }

func (HelloReply) isInbound() {}

func EncodeSetLEDs(colors [NumSlots]RGB) []byte {
	out := make([]byte, ReportSize)
	out[0], out[1] = Version, CmdSetLEDs
	for i, c := range colors {
		out[2+i*3], out[3+i*3], out[4+i*3] = c.R, c.G, c.B
	}
	return out
}

func EncodeHello() []byte {
	out := make([]byte, ReportSize)
	out[0], out[1] = Version, CmdHello
	return out
}

func ParseInbound(report []byte) (Inbound, error) {
	if len(report) < ReportSize {
		return nil, ErrShortReport
	}
	if report[0] != Version {
		return nil, ErrBadVersion
	}
	switch report[1] {
	case CmdJump:
		slot := int(report[2])
		if slot < 1 || slot > NumSlots {
			return nil, ErrBadSlot
		}
		return Jump{Slot: slot}, nil
	case CmdHello:
		return HelloReply{MaxSlots: int(report[2])}, nil
	default:
		return nil, ErrUnknownCommand
	}
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `go test ./internal/protocol/ -v`
Expected: PASS (6 tests).

- [ ] **Step 6: Commit**

```bash
git add .
git commit -m "feat: scaffold repo and add raw HID protocol codec"
```

---

### Task 2: Session state transitions

**Files:**
- Create: `internal/state/state.go`
- Test: `internal/state/state_test.go`

**Interfaces:**
- Consumes: nothing new.
- Produces: `state.Event` (JSON-tagged hook event), `state.Session`, `state.SessionState` enum (`StateWorking`, `StateNeedsInput`, `StateIdle`, `StateDead`) with `String()`, `state.NewRegistry(cap int, clock func() time.Time) *Registry`, `(*Registry).Apply(Event)`, `(*Registry).Get(id string) (Session, bool)`.

- [ ] **Step 1: Write the failing test**

`internal/state/state_test.go`:

```go
package state

import (
	"testing"
	"time"
)

func fixedClock() time.Time { return time.Date(2026, 7, 16, 12, 0, 0, 0, time.UTC) }

func ev(id, hook string) Event {
	return Event{SessionID: id, HookEvent: hook, PID: 100, CWD: "/tmp/proj", TmuxSession: "work"}
}

func TestApplyTransitions(t *testing.T) {
	cases := []struct {
		hook string
		want SessionState
	}{
		{"SessionStart", StateWorking},
		{"UserPromptSubmit", StateWorking},
		{"Notification", StateNeedsInput},
		{"Stop", StateIdle},
	}
	for _, c := range cases {
		t.Run(c.hook, func(t *testing.T) {
			r := NewRegistry(5, fixedClock)
			r.Apply(ev("s1", "SessionStart"))
			r.Apply(ev("s1", c.hook))
			s, ok := r.Get("s1")
			if !ok || s.State != c.want {
				t.Fatalf("state = %v ok=%v, want %v", s.State, ok, c.want)
			}
		})
	}
}

func TestUnknownSessionAutoRegisters(t *testing.T) {
	r := NewRegistry(5, fixedClock)
	r.Apply(ev("ghost", "Notification"))
	s, ok := r.Get("ghost")
	if !ok || s.State != StateNeedsInput || s.Slot != 1 {
		t.Fatalf("got %#v ok=%v", s, ok)
	}
}

func TestSessionEndRemoves(t *testing.T) {
	r := NewRegistry(5, fixedClock)
	r.Apply(ev("s1", "SessionStart"))
	r.Apply(ev("s1", "SessionEnd"))
	if _, ok := r.Get("s1"); ok {
		t.Fatal("session still present after SessionEnd")
	}
	r.Apply(ev("s2", "SessionEnd")) // unknown: must not panic
}

func TestOnChangeFires(t *testing.T) {
	r := NewRegistry(5, fixedClock)
	n := 0
	r.SetOnChange(func() { n++ })
	r.Apply(ev("s1", "SessionStart"))
	r.Apply(ev("s1", "Stop"))
	if n != 2 {
		t.Fatalf("onChange fired %d times, want 2", n)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/state/ -v`
Expected: FAIL to build with `undefined: Event`.

- [ ] **Step 3: Write minimal implementation**

`internal/state/state.go`:

```go
// Package state tracks Claude Code sessions and their keyboard slots.
package state

import (
	"sync"
	"time"
)

// Event is one hook notification forwarded by glove-agent-hook.
type Event struct {
	SessionID   string `json:"session_id"`
	HookEvent   string `json:"hook_event_name"`
	CWD         string `json:"cwd"`
	PID         int    `json:"pid"`
	TmuxSession string `json:"tmux_session"`
	TmuxPane    string `json:"tmux_pane"`
	ITermID     string `json:"iterm_session_id"`
}

type SessionState int

const (
	StateWorking SessionState = iota
	StateNeedsInput
	StateIdle
	StateDead
)

func (s SessionState) String() string {
	switch s {
	case StateWorking:
		return "working"
	case StateNeedsInput:
		return "needs input"
	case StateIdle:
		return "idle"
	case StateDead:
		return "dead"
	}
	return "unknown"
}

type Session struct {
	ID          string       `json:"id"`
	PID         int          `json:"pid"`
	CWD         string       `json:"cwd"`
	TmuxSession string       `json:"tmux_session"`
	TmuxPane    string       `json:"tmux_pane"`
	ITermID     string       `json:"iterm_session_id"`
	Slot        int          `json:"slot"` // 0 means queued, no slot yet
	State       SessionState `json:"state"`
	LastEvent   time.Time    `json:"last_event"`
}

type Registry struct {
	mu       sync.Mutex
	cap      int
	clock    func() time.Time
	sessions map[string]*Session
	slots    []string // index 1..NumSlots -> session ID, index 0 unused
	queue    []string
	onChange func()
}

func NewRegistry(slotCap int, clock func() time.Time) *Registry {
	if clock == nil {
		clock = time.Now
	}
	return &Registry{
		cap:      slotCap,
		clock:    clock,
		sessions: map[string]*Session{},
		slots:    make([]string, 11),
	}
}

func (r *Registry) SetOnChange(f func()) { r.onChange = f }

func (r *Registry) notify() {
	if r.onChange != nil {
		r.onChange()
	}
}

func (r *Registry) Apply(e Event) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if e.HookEvent == "SessionEnd" {
		r.remove(e.SessionID)
		r.notify()
		return
	}
	s, ok := r.sessions[e.SessionID]
	if !ok {
		s = &Session{ID: e.SessionID}
		r.sessions[e.SessionID] = s
		r.assignSlot(e.SessionID)
	}
	s.PID, s.CWD = e.PID, e.CWD
	s.TmuxSession, s.TmuxPane, s.ITermID = e.TmuxSession, e.TmuxPane, e.ITermID
	s.LastEvent = r.clock()
	switch e.HookEvent {
	case "SessionStart", "UserPromptSubmit":
		s.State = StateWorking
	case "Notification":
		s.State = StateNeedsInput
	case "Stop":
		s.State = StateIdle
	}
	r.notify()
}

func (r *Registry) Get(id string) (Session, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	s, ok := r.sessions[id]
	if !ok {
		return Session{}, false
	}
	return *s, true
}

// assignSlot and remove are completed in Task 3; minimal versions here keep
// Task 2 green.
func (r *Registry) assignSlot(id string) {
	for i := 1; i <= r.cap; i++ {
		if r.slots[i] == "" {
			r.slots[i] = id
			r.sessions[id].Slot = i
			return
		}
	}
	r.queue = append(r.queue, id)
}

func (r *Registry) remove(id string) {
	s, ok := r.sessions[id]
	if !ok {
		return
	}
	if s.Slot != 0 {
		r.slots[s.Slot] = ""
	}
	delete(r.sessions, id)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/state/ -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/state/
git commit -m "feat: add session registry with hook event state transitions"
```

---

### Task 3: Slot assignment rules

**Files:**
- Modify: `internal/state/state.go` (replace `assignSlot` and `remove`)
- Test: `internal/state/slots_test.go`

**Interfaces:**
- Consumes: `Registry` from Task 2.
- Produces: `(*Registry).MarkDead(id string)`, `(*Registry).Resolve(slot int) (Session, bool)`, `(*Registry).ClearDead(slot int) bool`, `(*Registry).LivePIDs() map[string]int`, plus final slot semantics: lowest free, dead reused last, queue with promotion.

- [ ] **Step 1: Write the failing test**

`internal/state/slots_test.go`:

```go
package state

import "testing"

func start(r *Registry, id string) {
	r.Apply(Event{SessionID: id, HookEvent: "SessionStart", PID: 100, TmuxSession: id})
}

func TestLowestFreeSlot(t *testing.T) {
	r := NewRegistry(5, fixedClock)
	start(r, "a")
	start(r, "b")
	r.Apply(Event{SessionID: "a", HookEvent: "SessionEnd"})
	start(r, "c")
	s, _ := r.Get("c")
	if s.Slot != 1 {
		t.Fatalf("slot = %d, want 1", s.Slot)
	}
}

func TestOverflowQueuesAndPromotes(t *testing.T) {
	r := NewRegistry(2, fixedClock)
	start(r, "a")
	start(r, "b")
	start(r, "c")
	if s, _ := r.Get("c"); s.Slot != 0 {
		t.Fatalf("c should queue, got slot %d", s.Slot)
	}
	r.Apply(Event{SessionID: "a", HookEvent: "SessionEnd"})
	if s, _ := r.Get("c"); s.Slot != 1 {
		t.Fatalf("c should be promoted to slot 1, got %d", s.Slot)
	}
}

func TestDeadSlotsReusedLast(t *testing.T) {
	r := NewRegistry(2, fixedClock)
	start(r, "a")
	start(r, "b")
	r.MarkDead("a")
	r.Apply(Event{SessionID: "b", HookEvent: "SessionEnd"}) // slot 2 now free
	start(r, "c")
	if s, _ := r.Get("c"); s.Slot != 2 {
		t.Fatalf("c should take free slot 2, not dead slot 1; got %d", s.Slot)
	}
	start(r, "d") // no free slot: evict the dead session in slot 1
	if s, _ := r.Get("d"); s.Slot != 1 {
		t.Fatalf("d should reclaim dead slot 1, got %d", s.Slot)
	}
	if _, ok := r.Get("a"); ok {
		t.Fatal("dead session a should be evicted")
	}
}

func TestMarkDeadAndClearDead(t *testing.T) {
	r := NewRegistry(5, fixedClock)
	start(r, "a")
	r.MarkDead("a")
	s, _ := r.Get("a")
	if s.State != StateDead {
		t.Fatalf("state = %v, want dead", s.State)
	}
	if !r.ClearDead(1) {
		t.Fatal("ClearDead(1) = false, want true")
	}
	if _, ok := r.Get("a"); ok {
		t.Fatal("a still present after ClearDead")
	}
	if r.ClearDead(1) {
		t.Fatal("ClearDead on empty slot must be false")
	}
}

func TestResolveReturnsCopy(t *testing.T) {
	r := NewRegistry(5, fixedClock)
	start(r, "a")
	s, ok := r.Resolve(1)
	if !ok || s.ID != "a" {
		t.Fatalf("Resolve(1) = %#v ok=%v", s, ok)
	}
	if _, ok := r.Resolve(3); ok {
		t.Fatal("Resolve(3) should be false")
	}
}

func TestLivePIDs(t *testing.T) {
	r := NewRegistry(5, fixedClock)
	start(r, "a")
	start(r, "b")
	r.MarkDead("b")
	pids := r.LivePIDs()
	if len(pids) != 1 || pids["a"] != 100 {
		t.Fatalf("LivePIDs = %v", pids)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/state/ -v`
Expected: FAIL to build with `undefined: (*Registry).MarkDead` (and `TestDeadSlotsReusedLast` would fail once built).

- [ ] **Step 3: Write the implementation**

In `internal/state/state.go`, replace the Task 2 `assignSlot` and `remove` and add the new methods:

```go
func (r *Registry) assignSlot(id string) {
	for i := 1; i <= r.cap; i++ {
		if r.slots[i] == "" {
			r.slots[i] = id
			r.sessions[id].Slot = i
			return
		}
	}
	// No free slot: reuse the oldest dead slot, if any.
	oldest := 0
	for i := 1; i <= r.cap; i++ {
		s := r.sessions[r.slots[i]]
		if s == nil || s.State != StateDead {
			continue
		}
		if oldest == 0 || s.LastEvent.Before(r.sessions[r.slots[oldest]].LastEvent) {
			oldest = i
		}
	}
	if oldest != 0 {
		delete(r.sessions, r.slots[oldest])
		r.slots[oldest] = id
		r.sessions[id].Slot = oldest
		return
	}
	r.queue = append(r.queue, id)
}

func (r *Registry) remove(id string) {
	s, ok := r.sessions[id]
	if !ok {
		return
	}
	delete(r.sessions, id)
	for i, qid := range r.queue {
		if qid == id {
			r.queue = append(r.queue[:i], r.queue[i+1:]...)
			break
		}
	}
	if s.Slot != 0 {
		r.freeSlot(s.Slot)
	}
}

// freeSlot empties a slot and promotes the queue head into it.
func (r *Registry) freeSlot(slot int) {
	r.slots[slot] = ""
	if len(r.queue) == 0 {
		return
	}
	next := r.queue[0]
	r.queue = r.queue[1:]
	r.slots[slot] = next
	r.sessions[next].Slot = slot
}

func (r *Registry) MarkDead(id string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	s, ok := r.sessions[id]
	if !ok {
		return
	}
	if s.Slot == 0 {
		r.remove(id) // a queued session that died just disappears
	} else {
		s.State = StateDead
	}
	r.notify()
}

func (r *Registry) Resolve(slot int) (Session, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if slot < 1 || slot >= len(r.slots) || r.slots[slot] == "" {
		return Session{}, false
	}
	return *r.sessions[r.slots[slot]], true
}

func (r *Registry) ClearDead(slot int) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if slot < 1 || slot >= len(r.slots) || r.slots[slot] == "" {
		return false
	}
	s := r.sessions[r.slots[slot]]
	if s.State != StateDead {
		return false
	}
	r.remove(s.ID)
	r.notify()
	return true
}

func (r *Registry) LivePIDs() map[string]int {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := map[string]int{}
	for id, s := range r.sessions {
		if s.State != StateDead && s.PID > 0 {
			out[id] = s.PID
		}
	}
	return out
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/state/ -v`
Expected: PASS (all Task 2 and Task 3 tests).

- [ ] **Step 5: Commit**

```bash
git add internal/state/
git commit -m "feat: slot assignment with dead-last reuse and overflow queue"
```

---

### Task 4: LED frame rendering

**Files:**
- Create: `internal/state/frame.go`
- Test: `internal/state/frame_test.go`

**Interfaces:**
- Consumes: `Registry`, `protocol.RGB`.
- Produces: `state.Palette{Amber, Green, Red protocol.RGB}`, `(*Registry).Frame(Palette) [protocol.NumSlots]protocol.RGB`.

- [ ] **Step 1: Write the failing test**

`internal/state/frame_test.go`:

```go
package state

import (
	"testing"

	"github.com/calvin-barker/glove-agentd/internal/protocol"
)

func TestFrame(t *testing.T) {
	p := Palette{
		Amber: protocol.RGB{R: 0xFF, G: 0xB0},
		Green: protocol.RGB{G: 0xC8, B: 0x53},
		Red:   protocol.RGB{R: 0xFF, G: 0x17, B: 0x44},
	}
	r := NewRegistry(5, fixedClock)
	start(r, "a") // slot 1, working
	start(r, "b") // slot 2
	start(r, "c") // slot 3
	start(r, "d") // slot 4
	r.Apply(Event{SessionID: "b", HookEvent: "Notification"})
	r.Apply(Event{SessionID: "c", HookEvent: "Stop"})
	r.MarkDead("d")

	f := r.Frame(p)
	if f[0] != (protocol.RGB{}) {
		t.Fatalf("working slot must be off, got %#v", f[0])
	}
	if f[1] != p.Amber {
		t.Fatalf("needs input must be amber, got %#v", f[1])
	}
	if f[2] != p.Green {
		t.Fatalf("idle must be green, got %#v", f[2])
	}
	if f[3] != p.Red {
		t.Fatalf("dead must be red, got %#v", f[3])
	}
	if f[4] != (protocol.RGB{}) {
		t.Fatalf("empty slot must be off, got %#v", f[4])
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/state/ -run TestFrame -v`
Expected: FAIL to build with `undefined: Palette`.

- [ ] **Step 3: Write minimal implementation**

`internal/state/frame.go`:

```go
package state

import "github.com/calvin-barker/glove-agentd/internal/protocol"

type Palette struct {
	Amber, Green, Red protocol.RGB
}

func (r *Registry) Frame(p Palette) [protocol.NumSlots]protocol.RGB {
	r.mu.Lock()
	defer r.mu.Unlock()
	var f [protocol.NumSlots]protocol.RGB
	for i := 1; i <= protocol.NumSlots && i < len(r.slots); i++ {
		id := r.slots[i]
		if id == "" {
			continue
		}
		switch r.sessions[id].State {
		case StateNeedsInput:
			f[i-1] = p.Amber
		case StateIdle:
			f[i-1] = p.Green
		case StateDead:
			f[i-1] = p.Red
		}
	}
	return f
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/state/ -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/state/frame.go internal/state/frame_test.go
git commit -m "feat: render registry snapshot to a 10-slot LED frame"
```

---

### Task 5: Registry persistence

**Files:**
- Create: `internal/state/persist.go`
- Test: `internal/state/persist_test.go`

**Interfaces:**
- Consumes: `Registry`.
- Produces: `(*Registry).Save(path string) error`, `state.Load(path string, cap int, clock func() time.Time) (*Registry, error)` (missing file returns an empty registry, not an error).

- [ ] **Step 1: Write the failing test**

`internal/state/persist_test.go`:

```go
package state

import (
	"path/filepath"
	"testing"
)

func TestSaveLoadRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	r := NewRegistry(2, fixedClock)
	start(r, "a")
	start(r, "b")
	start(r, "c") // queued
	r.Apply(Event{SessionID: "a", HookEvent: "Notification"})

	if err := r.Save(path); err != nil {
		t.Fatal(err)
	}
	r2, err := Load(path, 2, fixedClock)
	if err != nil {
		t.Fatal(err)
	}
	a, _ := r2.Get("a")
	if a.Slot != 1 || a.State != StateNeedsInput {
		t.Fatalf("a = %#v", a)
	}
	c, _ := r2.Get("c")
	if c.Slot != 0 {
		t.Fatalf("c should still be queued, got slot %d", c.Slot)
	}
	// Queue order survives: freeing slot 1 promotes c.
	r2.Apply(Event{SessionID: "a", HookEvent: "SessionEnd"})
	c, _ = r2.Get("c")
	if c.Slot != 1 {
		t.Fatalf("c should be promoted after reload, got slot %d", c.Slot)
	}
}

func TestLoadMissingFile(t *testing.T) {
	r, err := Load(filepath.Join(t.TempDir(), "nope.json"), 5, fixedClock)
	if err != nil || r == nil {
		t.Fatalf("missing file should give empty registry, got %v %v", r, err)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/state/ -run 'TestSaveLoad|TestLoadMissing' -v`
Expected: FAIL to build with `undefined: Load`.

- [ ] **Step 3: Write minimal implementation**

`internal/state/persist.go`:

```go
package state

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"time"
)

type persisted struct {
	Sessions map[string]*Session `json:"sessions"`
	Slots    []string            `json:"slots"`
	Queue    []string            `json:"queue"`
}

func (r *Registry) Save(path string) error {
	r.mu.Lock()
	blob, err := json.MarshalIndent(persisted{Sessions: r.sessions, Slots: r.slots, Queue: r.queue}, "", "  ")
	r.mu.Unlock()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, blob, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func Load(path string, slotCap int, clock func() time.Time) (*Registry, error) {
	r := NewRegistry(slotCap, clock)
	blob, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return r, nil
	}
	if err != nil {
		return nil, err
	}
	var p persisted
	if err := json.Unmarshal(blob, &p); err != nil {
		return nil, err
	}
	if p.Sessions != nil {
		r.sessions = p.Sessions
	}
	if len(p.Slots) == len(r.slots) {
		r.slots = p.Slots
	}
	r.queue = p.Queue
	return r, nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/state/ -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/state/persist.go internal/state/persist_test.go
git commit -m "feat: persist registry to disk and restore on load"
```

---

### Task 6: Config package

**Files:**
- Create: `internal/config/config.go`
- Test: `internal/config/config_test.go`

**Interfaces:**
- Consumes: `protocol.RGB`, `state.Palette`.
- Produces: `config.Config{SlotCap int, PollIntervalSec int, HeartbeatSec int, Amber, Green, Red string, SocketPath, StatePath string}`, `config.Load(path string) (Config, error)` (missing file returns defaults), `(Config).Palette() (state.Palette, error)`, `config.DefaultDir() string` helpers.

- [ ] **Step 1: Write the failing test**

`internal/config/config_test.go`:

```go
package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadDefaults(t *testing.T) {
	c, err := Load(filepath.Join(t.TempDir(), "missing.json"))
	if err != nil {
		t.Fatal(err)
	}
	if c.SlotCap != 5 || c.PollIntervalSec != 5 || c.HeartbeatSec != 30 {
		t.Fatalf("defaults wrong: %#v", c)
	}
	if c.Amber != "FFB000" || c.Green != "00C853" || c.Red != "FF1744" {
		t.Fatalf("default colors wrong: %#v", c)
	}
	if !strings.HasSuffix(c.SocketPath, ".local/state/glove-agentd/agentd.sock") {
		t.Fatalf("socket path = %s", c.SocketPath)
	}
	if !strings.HasSuffix(c.StatePath, ".local/state/glove-agentd/state.json") {
		t.Fatalf("state path = %s", c.StatePath)
	}
}

func TestLoadOverrides(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	os.WriteFile(path, []byte(`{"slot_cap": 10, "amber": "AABBCC"}`), 0o644)
	c, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if c.SlotCap != 10 || c.Amber != "AABBCC" || c.Green != "00C853" {
		t.Fatalf("override merge wrong: %#v", c)
	}
}

func TestPalette(t *testing.T) {
	c, _ := Load(filepath.Join(t.TempDir(), "missing.json"))
	p, err := c.Palette()
	if err != nil {
		t.Fatal(err)
	}
	if p.Amber.R != 0xFF || p.Amber.G != 0xB0 || p.Amber.B != 0x00 {
		t.Fatalf("amber = %#v", p.Amber)
	}
	c.Red = "xyz"
	if _, err := c.Palette(); err == nil {
		t.Fatal("bad hex must error")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/config/ -v`
Expected: FAIL to build with `undefined: Load`.

- [ ] **Step 3: Write minimal implementation**

`internal/config/config.go`:

```go
// Package config loads daemon settings with sane defaults.
package config

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"

	"github.com/calvin-barker/glove-agentd/internal/protocol"
	"github.com/calvin-barker/glove-agentd/internal/state"
)

type Config struct {
	SlotCap         int    `json:"slot_cap"`
	PollIntervalSec int    `json:"poll_interval_sec"`
	HeartbeatSec    int    `json:"heartbeat_sec"`
	Amber           string `json:"amber"`
	Green           string `json:"green"`
	Red             string `json:"red"`
	SocketPath      string `json:"socket_path"`
	StatePath       string `json:"state_path"`
}

func stateDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "state", "glove-agentd")
}

// DefaultPath is where Load looks when the caller passes "".
func DefaultPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "glove-agentd", "config.json")
}

func defaults() Config {
	return Config{
		SlotCap:         5,
		PollIntervalSec: 5,
		HeartbeatSec:    30,
		Amber:           "FFB000",
		Green:           "00C853",
		Red:             "FF1744",
		SocketPath:      filepath.Join(stateDir(), "agentd.sock"),
		StatePath:       filepath.Join(stateDir(), "state.json"),
	}
}

func Load(path string) (Config, error) {
	if path == "" {
		path = DefaultPath()
	}
	c := defaults()
	blob, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return c, nil
	}
	if err != nil {
		return c, err
	}
	if err := json.Unmarshal(blob, &c); err != nil {
		return c, fmt.Errorf("config: %w", err)
	}
	return c, nil
}

func parseHex(s string) (protocol.RGB, error) {
	b, err := hex.DecodeString(s)
	if err != nil || len(b) != 3 {
		return protocol.RGB{}, fmt.Errorf("config: bad color %q", s)
	}
	return protocol.RGB{R: b[0], G: b[1], B: b[2]}, nil
}

func (c Config) Palette() (state.Palette, error) {
	var p state.Palette
	var err error
	if p.Amber, err = parseHex(c.Amber); err != nil {
		return p, err
	}
	if p.Green, err = parseHex(c.Green); err != nil {
		return p, err
	}
	if p.Red, err = parseHex(c.Red); err != nil {
		return p, err
	}
	return p, nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/config/ -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/config/
git commit -m "feat: config loading with defaults and palette parsing"
```

---

### Task 7: Ingest socket server

**Files:**
- Create: `internal/ingest/server.go`
- Test: `internal/ingest/server_test.go`

**Interfaces:**
- Consumes: `state.Event`.
- Produces: `ingest.Handler` interface `{ HandleEvent(state.Event); StatusJSON() []byte }`, `ingest.Serve(ctx context.Context, l net.Listener, h Handler)`, `ingest.Listen(socketPath string) (net.Listener, error)` (removes a stale socket file first). Wire format: one JSON object per line; a line `{"type":"status"}` gets the handler's StatusJSON written back followed by newline; anything with a `session_id` is decoded as `state.Event`.

- [ ] **Step 1: Write the failing test**

`internal/ingest/server_test.go`:

```go
package ingest

import (
	"bufio"
	"context"
	"net"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/calvin-barker/glove-agentd/internal/state"
)

type fakeHandler struct {
	mu     sync.Mutex
	events []state.Event
}

func (f *fakeHandler) HandleEvent(e state.Event) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.events = append(f.events, e)
}

func (f *fakeHandler) StatusJSON() []byte { return []byte(`{"slots":[]}`) }

func (f *fakeHandler) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.events)
}

func startServer(t *testing.T) (string, *fakeHandler) {
	t.Helper()
	sock := filepath.Join(t.TempDir(), "agentd.sock")
	l, err := Listen(sock)
	if err != nil {
		t.Fatal(err)
	}
	h := &fakeHandler{}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go Serve(ctx, l, h)
	return sock, h
}

func TestServeHookEvent(t *testing.T) {
	sock, h := startServer(t)
	conn, err := net.Dial("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	conn.Write([]byte(`{"session_id":"s1","hook_event_name":"Stop","pid":42}` + "\n"))
	conn.Close()
	deadline := time.Now().Add(2 * time.Second)
	for h.count() == 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.events) != 1 || h.events[0].SessionID != "s1" || h.events[0].PID != 42 {
		t.Fatalf("events = %#v", h.events)
	}
}

func TestServeStatusQuery(t *testing.T) {
	sock, _ := startServer(t)
	conn, err := net.Dial("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.Write([]byte(`{"type":"status"}` + "\n"))
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	line, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	if line != `{"slots":[]}`+"\n" {
		t.Fatalf("status reply = %q", line)
	}
}

func TestServeIgnoresGarbage(t *testing.T) {
	sock, h := startServer(t)
	conn, _ := net.Dial("unix", sock)
	conn.Write([]byte("not json at all\n"))
	conn.Write([]byte(`{"session_id":"s2","hook_event_name":"Stop"}` + "\n"))
	conn.Close()
	deadline := time.Now().Add(2 * time.Second)
	for h.count() == 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if h.count() != 1 {
		t.Fatalf("garbage line must be skipped, events = %d", h.count())
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/ingest/ -v`
Expected: FAIL to build with `undefined: Listen`.

- [ ] **Step 3: Write minimal implementation**

`internal/ingest/server.go`:

```go
// Package ingest receives hook events and status queries on a Unix socket.
package ingest

import (
	"bufio"
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"

	"github.com/calvin-barker/glove-agentd/internal/state"
)

type Handler interface {
	HandleEvent(state.Event)
	StatusJSON() []byte
}

func Listen(socketPath string) (net.Listener, error) {
	if err := os.MkdirAll(filepath.Dir(socketPath), 0o755); err != nil {
		return nil, err
	}
	os.Remove(socketPath) // stale socket from a previous run
	return net.Listen("unix", socketPath)
}

func Serve(ctx context.Context, l net.Listener, h Handler) {
	go func() {
		<-ctx.Done()
		l.Close()
	}()
	for {
		conn, err := l.Accept()
		if err != nil {
			return // listener closed
		}
		go handleConn(conn, h)
	}
}

type probe struct {
	Type      string `json:"type"`
	SessionID string `json:"session_id"`
}

func handleConn(conn net.Conn, h Handler) {
	defer conn.Close()
	scanner := bufio.NewScanner(conn)
	for scanner.Scan() {
		line := scanner.Bytes()
		var p probe
		if err := json.Unmarshal(line, &p); err != nil {
			continue
		}
		if p.Type == "status" {
			conn.Write(append(h.StatusJSON(), '\n'))
			continue
		}
		if p.SessionID == "" {
			continue
		}
		var e state.Event
		if err := json.Unmarshal(line, &e); err != nil {
			continue
		}
		h.HandleEvent(e)
	}
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/ingest/ -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/ingest/
git commit -m "feat: unix socket server for hook events and status queries"
```

---

### Task 8: Hook payload builder

**Files:**
- Create: `internal/ingest/hookpayload.go`
- Test: `internal/ingest/hookpayload_test.go`

**Interfaces:**
- Consumes: `state.Event`.
- Produces: `ingest.CommandOutput` func type `func(name string, args ...string) (string, error)`, `ingest.BuildEvent(stdin []byte, getenv func(string) string, run CommandOutput, startPID int) (state.Event, error)`, `ingest.FindClaudePID(startPID int, run CommandOutput) int`. Used by `cmd/glove-agent-hook` in Task 12.

- [ ] **Step 1: Write the failing test**

`internal/ingest/hookpayload_test.go`:

```go
package ingest

import (
	"fmt"
	"testing"
)

func envMap(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func TestBuildEventInsideTmux(t *testing.T) {
	stdin := []byte(`{"session_id":"abc","hook_event_name":"Notification","cwd":"/w"}`)
	env := envMap(map[string]string{
		"TMUX":             "/tmp/tmux-501/default,123,0",
		"TMUX_PANE":        "%5",
		"ITERM_SESSION_ID": "w0t2p0:AAAA-BBBB",
	})
	run := func(name string, args ...string) (string, error) {
		if name == "tmux" {
			return "work\n", nil
		}
		return "", fmt.Errorf("unexpected command %s", name)
	}
	e, err := BuildEvent(stdin, env, run, 0)
	if err != nil {
		t.Fatal(err)
	}
	if e.SessionID != "abc" || e.HookEvent != "Notification" || e.CWD != "/w" {
		t.Fatalf("stdin fields lost: %#v", e)
	}
	if e.TmuxSession != "work" || e.TmuxPane != "%5" {
		t.Fatalf("tmux identity wrong: %#v", e)
	}
	if e.ITermID != "AAAA-BBBB" {
		t.Fatalf("iterm id = %q, want prefix stripped", e.ITermID)
	}
}

func TestBuildEventOutsideTmux(t *testing.T) {
	stdin := []byte(`{"session_id":"abc","hook_event_name":"Stop"}`)
	env := envMap(map[string]string{"ITERM_SESSION_ID": "w0t0p1:CCCC"})
	run := func(name string, args ...string) (string, error) {
		t.Fatalf("must not exec anything outside tmux, got %s", name)
		return "", nil
	}
	e, err := BuildEvent(stdin, env, run, 0)
	if err != nil {
		t.Fatal(err)
	}
	if e.TmuxSession != "" || e.ITermID != "CCCC" {
		t.Fatalf("event = %#v", e)
	}
}

func TestBuildEventRejectsBadJSON(t *testing.T) {
	if _, err := BuildEvent([]byte("nope"), envMap(nil), nil, 0); err == nil {
		t.Fatal("bad stdin must error")
	}
}

func TestFindClaudePID(t *testing.T) {
	// Chain: 300 (sh) -> 200 (claude) -> 100 (zsh)
	run := func(name string, args ...string) (string, error) {
		pid := args[len(args)-1]
		switch pid {
		case "300":
			return " 200 sh\n", nil
		case "200":
			return " 100 claude\n", nil
		case "100":
			return "   1 zsh\n", nil
		}
		return "", fmt.Errorf("no such pid %s", pid)
	}
	// ps -o ppid=,comm= -p 300 tells us 300's parent is 200 running "sh";
	// checking 300 itself first: its comm comes from the parent lookup chain,
	// so the walk asks about each pid and matches on the comm column.
	if got := FindClaudePID(300, run); got != 200 {
		t.Fatalf("FindClaudePID = %d, want 200", got)
	}
}

func TestFindClaudePIDFallsBack(t *testing.T) {
	run := func(name string, args ...string) (string, error) {
		return " 1 launchd\n", nil
	}
	if got := FindClaudePID(300, run); got != 300 {
		t.Fatalf("fallback = %d, want 300", got)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/ingest/ -run 'TestBuildEvent|TestFindClaude' -v`
Expected: FAIL to build with `undefined: BuildEvent`.

- [ ] **Step 3: Write minimal implementation**

`internal/ingest/hookpayload.go`:

```go
package ingest

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"github.com/calvin-barker/glove-agentd/internal/state"
)

type CommandOutput func(name string, args ...string) (string, error)

// BuildEvent merges the hook's stdin JSON with terminal identity from the
// environment. startPID is the hook process's parent PID (os.Getppid()).
func BuildEvent(stdin []byte, getenv func(string) string, run CommandOutput, startPID int) (state.Event, error) {
	var e state.Event
	if err := json.Unmarshal(stdin, &e); err != nil {
		return e, fmt.Errorf("hook stdin: %w", err)
	}
	if e.SessionID == "" {
		return e, fmt.Errorf("hook stdin: missing session_id")
	}
	if id := getenv("ITERM_SESSION_ID"); id != "" {
		parts := strings.SplitN(id, ":", 2)
		e.ITermID = parts[len(parts)-1]
	}
	if getenv("TMUX") != "" {
		e.TmuxPane = getenv("TMUX_PANE")
		if out, err := run("tmux", "display-message", "-p", "-t", e.TmuxPane, "#S"); err == nil {
			e.TmuxSession = strings.TrimSpace(out)
		}
	}
	if startPID > 0 {
		e.PID = FindClaudePID(startPID, run)
	}
	return e, nil
}

// FindClaudePID walks up the process tree from startPID looking for the
// nearest ancestor whose command contains "claude". Hook commands run as
// `sh -c` children of the claude process, but an extra shell layer can sit
// in between; the walk tolerates up to 10 hops and falls back to startPID.
func FindClaudePID(startPID int, run CommandOutput) int {
	pid := startPID
	for hop := 0; hop < 10; hop++ {
		out, err := run("ps", "-o", "ppid=,comm=", "-p", strconv.Itoa(pid))
		if err != nil {
			break
		}
		fields := strings.Fields(strings.TrimSpace(out))
		if len(fields) < 2 {
			break
		}
		ppid, err := strconv.Atoi(fields[0])
		if err != nil {
			break
		}
		comm := strings.Join(fields[1:], " ")
		if strings.Contains(strings.ToLower(comm), "claude") {
			// The comm column describes pid's own process image as reported
			// with its parent; treat the parent as the claude process.
			return ppid
		}
		if ppid <= 1 {
			break
		}
		pid = ppid
	}
	return startPID
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/ingest/ -v`
Expected: the `TestBuildEvent*` tests PASS; `TestFindClaudePID` FAILS with `FindClaudePID = 100, want 200`. The failure is intentional and teaches the ps semantics: `ps -o ppid=,comm= -p N` prints N's parent PID and N's OWN command name, so when the row for pid 200 says `100 claude`, the claude process is 200 itself, not its parent 100. The implementation above wrongly returns `ppid` at match time. Step 5 fixes the implementation to return the inspected `pid` and tightens the test comment to match.

- [ ] **Step 5: Fix the match to return the inspected pid**

The `ps -o ppid=,comm= -p N` output row is N's parent PID and N's own command. The claude process is therefore the inspected `pid`, not `ppid`. Final implementation of the loop body:

```go
	for hop := 0; hop < 10; hop++ {
		out, err := run("ps", "-o", "ppid=,comm=", "-p", strconv.Itoa(pid))
		if err != nil {
			break
		}
		fields := strings.Fields(strings.TrimSpace(out))
		if len(fields) < 2 {
			break
		}
		ppid, err := strconv.Atoi(fields[0])
		if err != nil {
			break
		}
		comm := strings.Join(fields[1:], " ")
		if strings.Contains(strings.ToLower(comm), "claude") {
			return pid
		}
		if ppid <= 1 {
			break
		}
		pid = ppid
	}
```

And the matching test chain (replace `TestFindClaudePID` body):

```go
	// ps -p 300 says: parent 200, comm sh. ps -p 200 says: parent 100, comm claude.
	run := func(name string, args ...string) (string, error) {
		pid := args[len(args)-1]
		switch pid {
		case "300":
			return " 200 sh\n", nil
		case "200":
			return " 100 claude\n", nil
		}
		return "", fmt.Errorf("no such pid %s", pid)
	}
	if got := FindClaudePID(300, run); got != 200 {
		t.Fatalf("FindClaudePID = %d, want 200", got)
	}
```

Run: `go test ./internal/ingest/ -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add internal/ingest/hookpayload.go internal/ingest/hookpayload_test.go
git commit -m "feat: build hook event payloads with terminal identity"
```

---

### Task 9: HID writer and reader

**Files:**
- Create: `internal/hidio/hidio.go`
- Create: `internal/hidio/open_darwin.go`
- Test: `internal/hidio/hidio_test.go`

**Interfaces:**
- Consumes: `protocol` package.
- Produces: `hidio.Device` interface `{ Write([]byte) (int, error); ReadWithTimeout([]byte, time.Duration) (int, error); Close() error }`, `hidio.OpenFunc func() (Device, error)`, `hidio.New(open OpenFunc, heartbeat <-chan time.Time) *Writer`, `(*Writer).Run(ctx)`, `(*Writer).SetFrame([]byte)`, `(*Writer).Inbound() <-chan protocol.Inbound`, `hidio.OpenGlove80() (Device, error)` (real device, usage page 0xFF60 usage 0x61).

- [ ] **Step 1: Add the go-hid dependency**

```bash
go get github.com/sstallion/go-hid@latest
```

- [ ] **Step 2: Write the failing test**

`internal/hidio/hidio_test.go`:

```go
package hidio

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/calvin-barker/glove-agentd/internal/protocol"
)

type fakeDevice struct {
	mu      sync.Mutex
	writes  [][]byte
	reports [][]byte // queued inbound reports
	failOne bool
}

func (d *fakeDevice) Write(p []byte) (int, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.failOne {
		d.failOne = false
		return 0, errors.New("io error")
	}
	cp := append([]byte(nil), p...)
	d.writes = append(d.writes, cp)
	return len(p), nil
}

func (d *fakeDevice) ReadWithTimeout(p []byte, _ time.Duration) (int, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if len(d.reports) == 0 {
		return 0, nil // timeout
	}
	r := d.reports[0]
	d.reports = d.reports[1:]
	copy(p, r)
	return len(r), nil
}

func (d *fakeDevice) Close() error { return nil }

func (d *fakeDevice) writeCount() int {
	d.mu.Lock()
	defer d.mu.Unlock()
	return len(d.writes)
}

func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for !cond() && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if !cond() {
		t.Fatal("condition never met")
	}
}

func TestWriteFramePrependsReportID(t *testing.T) {
	dev := &fakeDevice{}
	hb := make(chan time.Time)
	w := New(func() (Device, error) { return dev, nil }, hb)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go w.Run(ctx)

	frame := protocol.EncodeSetLEDs([protocol.NumSlots]protocol.RGB{})
	w.SetFrame(frame)
	waitFor(t, func() bool { return dev.writeCount() >= 1 })

	dev.mu.Lock()
	defer dev.mu.Unlock()
	got := dev.writes[0]
	if len(got) != 33 || got[0] != 0x00 || got[1] != protocol.Version {
		t.Fatalf("write = len %d first bytes %v", len(got), got[:2])
	}
}

func TestHeartbeatRewritesFrame(t *testing.T) {
	dev := &fakeDevice{}
	hb := make(chan time.Time)
	w := New(func() (Device, error) { return dev, nil }, hb)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go w.Run(ctx)

	w.SetFrame(protocol.EncodeSetLEDs([protocol.NumSlots]protocol.RGB{}))
	waitFor(t, func() bool { return dev.writeCount() == 1 })
	hb <- time.Now()
	waitFor(t, func() bool { return dev.writeCount() == 2 })
}

func TestReopenAfterWriteError(t *testing.T) {
	dev := &fakeDevice{failOne: true}
	opens := 0
	hb := make(chan time.Time)
	w := New(func() (Device, error) { opens++; return dev, nil }, hb)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go w.Run(ctx)

	w.SetFrame(protocol.EncodeSetLEDs([protocol.NumSlots]protocol.RGB{}))
	time.Sleep(50 * time.Millisecond) // first write fails, device dropped
	hb <- time.Now()                  // heartbeat retries: reopen + write
	waitFor(t, func() bool { return dev.writeCount() >= 1 })
	if opens < 2 {
		t.Fatalf("opens = %d, want >= 2", opens)
	}
}

func TestInboundJumpDelivered(t *testing.T) {
	report := make([]byte, protocol.ReportSize)
	report[0], report[1], report[2] = protocol.Version, protocol.CmdJump, 4
	dev := &fakeDevice{reports: [][]byte{report}}
	hb := make(chan time.Time)
	w := New(func() (Device, error) { return dev, nil }, hb)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go w.Run(ctx)
	w.SetFrame(protocol.EncodeSetLEDs([protocol.NumSlots]protocol.RGB{})) // triggers open

	select {
	case msg := <-w.Inbound():
		j, ok := msg.(protocol.Jump)
		if !ok || j.Slot != 4 {
			t.Fatalf("inbound = %#v", msg)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("no inbound message")
	}
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `go test ./internal/hidio/ -v`
Expected: FAIL to build with `undefined: New`.

- [ ] **Step 4: Write minimal implementation**

`internal/hidio/hidio.go`:

```go
// Package hidio owns the raw HID connection to the keyboard.
package hidio

import (
	"context"
	"log"
	"sync"
	"time"

	"github.com/calvin-barker/glove-agentd/internal/protocol"
)

type Device interface {
	Write(p []byte) (int, error)
	ReadWithTimeout(p []byte, timeout time.Duration) (int, error)
	Close() error
}

type OpenFunc func() (Device, error)

type Writer struct {
	open      OpenFunc
	heartbeat <-chan time.Time
	frameCh   chan []byte
	inbound   chan protocol.Inbound

	mu    sync.Mutex
	dev   Device
	frame []byte
}

func New(open OpenFunc, heartbeat <-chan time.Time) *Writer {
	return &Writer{
		open:      open,
		heartbeat: heartbeat,
		frameCh:   make(chan []byte, 8),
		inbound:   make(chan protocol.Inbound, 8),
	}
}

func (w *Writer) Inbound() <-chan protocol.Inbound { return w.inbound }

func (w *Writer) SetFrame(frame []byte) {
	select {
	case w.frameCh <- frame:
	default: // a newer frame is already queued; the latest write wins anyway
	}
}

func (w *Writer) Run(ctx context.Context) {
	go w.readLoop(ctx)
	for {
		select {
		case <-ctx.Done():
			w.dropDevice()
			return
		case f := <-w.frameCh:
			w.mu.Lock()
			w.frame = f
			w.mu.Unlock()
			w.writeFrame()
		case <-w.heartbeat:
			w.writeFrame()
		}
	}
}

func (w *Writer) currentDevice() Device {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.dev
}

func (w *Writer) ensureOpen() Device {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.dev != nil {
		return w.dev
	}
	dev, err := w.open()
	if err != nil {
		log.Printf("hid: open failed: %v (will retry)", err)
		return nil
	}
	w.dev = dev
	return dev
}

func (w *Writer) dropDevice() {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.dev != nil {
		w.dev.Close()
		w.dev = nil
	}
}

func (w *Writer) writeFrame() {
	w.mu.Lock()
	frame := w.frame
	w.mu.Unlock()
	if frame == nil {
		return
	}
	dev := w.ensureOpen()
	if dev == nil {
		return
	}
	buf := append([]byte{0x00}, frame...) // hidapi report ID prefix
	if _, err := dev.Write(buf); err != nil {
		log.Printf("hid: write failed: %v", err)
		w.dropDevice()
	}
}

func (w *Writer) readLoop(ctx context.Context) {
	buf := make([]byte, protocol.ReportSize)
	for ctx.Err() == nil {
		dev := w.currentDevice()
		if dev == nil {
			time.Sleep(100 * time.Millisecond)
			continue
		}
		n, err := dev.ReadWithTimeout(buf, 500*time.Millisecond)
		if err != nil {
			w.dropDevice()
			continue
		}
		if n == 0 {
			continue
		}
		msg, err := protocol.ParseInbound(buf[:n])
		if err != nil {
			continue
		}
		select {
		case w.inbound <- msg:
		case <-ctx.Done():
			return
		}
	}
}
```

`internal/hidio/open_darwin.go`:

```go
package hidio

import (
	"fmt"

	"github.com/sstallion/go-hid"
)

const (
	usagePage = 0xFF60
	usage     = 0x61
)

// OpenGlove80 finds the Glove80 raw HID interface by usage page/usage.
func OpenGlove80() (Device, error) {
	var path string
	hid.Enumerate(hid.VendorIDAny, hid.ProductIDAny, func(info *hid.DeviceInfo) error {
		if info.UsagePage == usagePage && info.Usage == usage && path == "" {
			path = info.Path
		}
		return nil
	})
	if path == "" {
		return nil, fmt.Errorf("hid: no device with usage page %#x usage %#x", usagePage, usage)
	}
	return hid.OpenPath(path)
}
```

Note: `*hid.Device` from go-hid already satisfies `Device` (it has `Write`, `ReadWithTimeout`, and `Close`). If the installed go-hid version's signatures differ, adapt with a small wrapper struct in `open_darwin.go`; do not change the `Device` interface.

- [ ] **Step 5: Run test to verify it passes**

Run: `go test ./internal/hidio/ -v`
Expected: PASS (4 tests). `open_darwin.go` compiles but is not exercised by tests.

- [ ] **Step 6: Commit**

```bash
git add internal/hidio/ go.mod go.sum
git commit -m "feat: HID writer with reconnect, heartbeat, and inbound reader"
```

---

### Task 10: Liveness poller

**Files:**
- Create: `internal/liveness/liveness.go`
- Test: `internal/liveness/liveness_test.go`

**Interfaces:**
- Consumes: `(*state.Registry).LivePIDs()`, `(*state.Registry).MarkDead(id)`.
- Produces: `liveness.ProcessProber` interface `{ Alive(pid int) bool }`, `liveness.KillProber{}` (real, `syscall.Kill(pid, 0)`), `liveness.CheckOnce(reg *state.Registry, p ProcessProber)`, `liveness.Poll(ctx, interval, reg, p)`.

- [ ] **Step 1: Write the failing test**

`internal/liveness/liveness_test.go`:

```go
package liveness

import (
	"testing"
	"time"

	"github.com/calvin-barker/glove-agentd/internal/state"
)

type fakeProber struct{ alive map[int]bool }

func (f fakeProber) Alive(pid int) bool { return f.alive[pid] }

func clock() time.Time { return time.Date(2026, 7, 16, 12, 0, 0, 0, time.UTC) }

func TestCheckOnceMarksDead(t *testing.T) {
	r := state.NewRegistry(5, clock)
	r.Apply(state.Event{SessionID: "a", HookEvent: "SessionStart", PID: 100})
	r.Apply(state.Event{SessionID: "b", HookEvent: "SessionStart", PID: 200})
	CheckOnce(r, fakeProber{alive: map[int]bool{100: true}})
	a, _ := r.Get("a")
	b, _ := r.Get("b")
	if a.State == state.StateDead {
		t.Fatal("a is alive, must not be dead")
	}
	if b.State != state.StateDead {
		t.Fatalf("b state = %v, want dead", b.State)
	}
}

func TestCheckOnceSkipsZeroPID(t *testing.T) {
	r := state.NewRegistry(5, clock)
	r.Apply(state.Event{SessionID: "a", HookEvent: "SessionStart", PID: 0})
	CheckOnce(r, fakeProber{alive: map[int]bool{}})
	a, _ := r.Get("a")
	if a.State == state.StateDead {
		t.Fatal("sessions without a PID must never be marked dead")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/liveness/ -v`
Expected: FAIL to build with `undefined: CheckOnce`.

- [ ] **Step 3: Write minimal implementation**

`internal/liveness/liveness.go`:

```go
// Package liveness detects crashed Claude sessions by probing their PIDs.
package liveness

import (
	"context"
	"errors"
	"syscall"
	"time"

	"github.com/calvin-barker/glove-agentd/internal/state"
)

type ProcessProber interface {
	Alive(pid int) bool
}

// KillProber uses signal 0: delivery is never attempted, but permission and
// existence are checked. EPERM still means the process exists.
type KillProber struct{}

func (KillProber) Alive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

func CheckOnce(reg *state.Registry, p ProcessProber) {
	for id, pid := range reg.LivePIDs() {
		if !p.Alive(pid) {
			reg.MarkDead(id)
		}
	}
}

func Poll(ctx context.Context, interval time.Duration, reg *state.Registry, p ProcessProber) {
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			CheckOnce(reg, p)
		}
	}
}
```

Note: `LivePIDs` already excludes PID 0 sessions (it requires `PID > 0`), which is what `TestCheckOnceSkipsZeroPID` locks in.

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/liveness/ -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/liveness/
git commit -m "feat: liveness poller marking crashed sessions dead"
```

---

### Task 11: Jump executor

**Files:**
- Create: `internal/jump/jump.go`
- Test: `internal/jump/jump_test.go`

**Interfaces:**
- Consumes: `(*state.Registry).Resolve(slot)`, `(*state.Registry).ClearDead(slot)`, `state.StateDead`.
- Produces: `jump.Runner` interface `{ Output(name string, args ...string) (string, error) }`, `jump.ExecRunner{}` (real, `os/exec`), `jump.New(reg *state.Registry, run Runner) *Executor`, `(*Executor).Jump(slot int) error`.

Resolution order (each branch must be covered by a test):
1. Empty slot: no-op.
2. Dead session: `ClearDead(slot)`, no process interaction.
3. Session with a tmux session name: run `tmux list-clients -t <name> -F '#{client_tty}'`.
   - Non-empty output: focus the iTerm session whose tty matches the first line, then activate iTerm2. If the focus script errors, fall back to focusing by the recorded iTerm session ID.
   - Empty output (detached): open a new iTerm tab and `tmux attach -t <name>`.
   - Command error (tmux session vanished): fall back to focusing by iTerm session ID.
4. No tmux session (bare pane): focus by recorded iTerm session ID.

- [ ] **Step 1: Write the failing test**

`internal/jump/jump_test.go`:

```go
package jump

import (
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/calvin-barker/glove-agentd/internal/state"
)

type call struct {
	name string
	args []string
}

type fakeRunner struct {
	calls   []call
	outputs map[string]string // key: command name
	errs    map[string]error
}

func (f *fakeRunner) Output(name string, args ...string) (string, error) {
	f.calls = append(f.calls, call{name, args})
	if err := f.errs[name]; err != nil {
		return "", err
	}
	return f.outputs[name], nil
}

func clock() time.Time { return time.Date(2026, 7, 16, 12, 0, 0, 0, time.UTC) }

func regWith(t *testing.T, e state.Event) *state.Registry {
	t.Helper()
	r := state.NewRegistry(5, clock)
	e.HookEvent = "SessionStart"
	r.Apply(e)
	return r
}

func TestJumpEmptySlotNoop(t *testing.T) {
	r := state.NewRegistry(5, clock)
	f := &fakeRunner{}
	if err := New(r, f).Jump(3); err != nil {
		t.Fatal(err)
	}
	if len(f.calls) != 0 {
		t.Fatalf("calls = %v", f.calls)
	}
}

func TestJumpDeadSlotClears(t *testing.T) {
	r := regWith(t, state.Event{SessionID: "a", PID: 9})
	r.MarkDead("a")
	f := &fakeRunner{}
	if err := New(r, f).Jump(1); err != nil {
		t.Fatal(err)
	}
	if _, ok := r.Get("a"); ok {
		t.Fatal("dead session must be cleared by jump")
	}
	if len(f.calls) != 0 {
		t.Fatalf("dead ack must not exec anything, calls = %v", f.calls)
	}
}

func TestJumpAttachedTmuxFocusesByTTY(t *testing.T) {
	r := regWith(t, state.Event{SessionID: "a", TmuxSession: "work", ITermID: "UUID-1"})
	f := &fakeRunner{outputs: map[string]string{"tmux": "/dev/ttys004\n"}}
	if err := New(r, f).Jump(1); err != nil {
		t.Fatal(err)
	}
	if f.calls[0].name != "tmux" {
		t.Fatalf("first call = %v", f.calls[0])
	}
	if f.calls[1].name != "osascript" || !strings.Contains(f.calls[1].args[1], "/dev/ttys004") {
		t.Fatalf("second call = %v", f.calls[1])
	}
}

func TestJumpDetachedTmuxOpensTab(t *testing.T) {
	r := regWith(t, state.Event{SessionID: "a", TmuxSession: "work"})
	f := &fakeRunner{outputs: map[string]string{"tmux": ""}}
	if err := New(r, f).Jump(1); err != nil {
		t.Fatal(err)
	}
	script := f.calls[1].args[1]
	if !strings.Contains(script, "create tab") || !strings.Contains(script, "tmux attach -t 'work'") {
		t.Fatalf("script = %s", script)
	}
}

func TestJumpTmuxGoneFallsBackToITermID(t *testing.T) {
	r := regWith(t, state.Event{SessionID: "a", TmuxSession: "work", ITermID: "UUID-1"})
	f := &fakeRunner{errs: map[string]error{"tmux": errors.New("no server")}}
	if err := New(r, f).Jump(1); err != nil {
		t.Fatal(err)
	}
	if f.calls[1].name != "osascript" || !strings.Contains(f.calls[1].args[1], "UUID-1") {
		t.Fatalf("fallback call = %v", f.calls[1])
	}
}

func TestJumpBarePaneFocusesByITermID(t *testing.T) {
	r := regWith(t, state.Event{SessionID: "a", ITermID: "UUID-2"})
	f := &fakeRunner{}
	if err := New(r, f).Jump(1); err != nil {
		t.Fatal(err)
	}
	if len(f.calls) != 1 || f.calls[0].name != "osascript" || !strings.Contains(f.calls[0].args[1], "UUID-2") {
		t.Fatalf("calls = %v", f.calls)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/jump/ -v`
Expected: FAIL to build with `undefined: New`.

- [ ] **Step 3: Write minimal implementation**

`internal/jump/jump.go`:

```go
// Package jump focuses the terminal pane for a keyboard slot.
package jump

import (
	"fmt"
	"log"
	"os/exec"
	"strings"

	"github.com/calvin-barker/glove-agentd/internal/state"
)

type Runner interface {
	Output(name string, args ...string) (string, error)
}

type ExecRunner struct{}

func (ExecRunner) Output(name string, args ...string) (string, error) {
	out, err := exec.Command(name, args...).Output()
	return string(out), err
}

type Executor struct {
	reg *state.Registry
	run Runner
}

func New(reg *state.Registry, run Runner) *Executor {
	return &Executor{reg: reg, run: run}
}

func (e *Executor) Jump(slot int) error {
	s, ok := e.reg.Resolve(slot)
	if !ok {
		return nil
	}
	if s.State == state.StateDead {
		e.reg.ClearDead(slot)
		return nil
	}
	if s.TmuxSession != "" {
		out, err := e.run.Output("tmux", "list-clients", "-t", s.TmuxSession, "-F", "#{client_tty}")
		if err != nil {
			log.Printf("jump: tmux session %q gone: %v", s.TmuxSession, err)
			return e.focusByID(s.ITermID)
		}
		tty := firstLine(out)
		if tty == "" {
			return e.openTabAndAttach(s.TmuxSession)
		}
		if err := e.focusByTTY(tty); err != nil {
			return e.focusByID(s.ITermID)
		}
		return nil
	}
	return e.focusByID(s.ITermID)
}

func firstLine(s string) string {
	for _, line := range strings.Split(s, "\n") {
		if t := strings.TrimSpace(line); t != "" {
			return t
		}
	}
	return ""
}

const focusByTTYScript = `tell application "iTerm2"
	repeat with w in windows
		repeat with t in tabs of w
			repeat with s in sessions of t
				if tty of s is "%s" then
					select w
					select t
					select s
					activate
					return
				end if
			end repeat
		end repeat
	end repeat
end tell`

const focusByIDScript = `tell application "iTerm2"
	repeat with w in windows
		repeat with t in tabs of w
			repeat with s in sessions of t
				if id of s is "%s" then
					select w
					select t
					select s
					activate
					return
				end if
			end repeat
		end repeat
	end repeat
end tell`

const openTabScript = `tell application "iTerm2"
	activate
	if (count of windows) is 0 then
		create window with default profile
	else
		tell current window
			create tab with default profile
		end tell
	end if
	tell current session of current window
		write text "exec tmux attach -t '%s'"
	end tell
end tell`

func (e *Executor) osascript(script string) error {
	_, err := e.run.Output("osascript", "-e", script)
	return err
}

func (e *Executor) focusByTTY(tty string) error {
	return e.osascript(fmt.Sprintf(focusByTTYScript, tty))
}

func (e *Executor) focusByID(id string) error {
	if id == "" {
		return nil
	}
	return e.osascript(fmt.Sprintf(focusByIDScript, id))
}

func (e *Executor) openTabAndAttach(name string) error {
	safe := strings.ReplaceAll(name, "'", "")
	safe = strings.ReplaceAll(safe, `"`, "")
	safe = strings.ReplaceAll(safe, `\`, "")
	return e.osascript(fmt.Sprintf(openTabScript, safe))
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/jump/ -v`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add internal/jump/
git commit -m "feat: jump executor with tmux and iTerm2 resolution"
```

---

### Task 12: Hook client binary

**Files:**
- Create: `cmd/glove-agent-hook/main.go`

**Interfaces:**
- Consumes: `ingest.BuildEvent`, `config.Load`.
- Produces: the `glove-agent-hook` binary. Reads hook JSON on stdin, writes one JSON line to the daemon socket, 100ms deadline, always exits 0.

- [ ] **Step 1: Write the binary**

`cmd/glove-agent-hook/main.go`:

```go
// glove-agent-hook forwards one Claude Code hook event to glove-agentd.
// It must never block or fail loudly: worst case it drops the event.
package main

import (
	"encoding/json"
	"io"
	"net"
	"os"
	"os/exec"
	"time"

	"github.com/calvin-barker/glove-agentd/internal/config"
	"github.com/calvin-barker/glove-agentd/internal/ingest"
)

func runCommand(name string, args ...string) (string, error) {
	out, err := exec.Command(name, args...).Output()
	return string(out), err
}

func main() {
	defer func() { recover() }() // never crash a hook
	stdin, err := io.ReadAll(io.LimitReader(os.Stdin, 1<<20))
	if err != nil {
		return
	}
	e, err := ingest.BuildEvent(stdin, os.Getenv, runCommand, os.Getppid())
	if err != nil {
		return
	}
	blob, err := json.Marshal(e)
	if err != nil {
		return
	}
	cfg, err := config.Load("")
	if err != nil {
		return
	}
	conn, err := net.DialTimeout("unix", cfg.SocketPath, 100*time.Millisecond)
	if err != nil {
		return
	}
	defer conn.Close()
	conn.SetWriteDeadline(time.Now().Add(100 * time.Millisecond))
	conn.Write(append(blob, '\n'))
}
```

- [ ] **Step 2: Verify it builds and smoke-test it**

```bash
go build ./...
go vet ./...
echo '{"session_id":"smoke","hook_event_name":"Stop","cwd":"/tmp"}' | go run ./cmd/glove-agent-hook
echo "exit: $?"
```

Expected: builds clean; the run prints nothing and `exit: 0` even though no daemon is listening.

- [ ] **Step 3: Commit**

```bash
git add cmd/glove-agent-hook/
git commit -m "feat: hook client binary forwarding events to the daemon"
```

---

### Task 13: Daemon binary (run and status)

**Files:**
- Create: `cmd/glove-agentd/main.go`

**Interfaces:**
- Consumes: everything built so far.
- Produces: `glove-agentd run` (the daemon) and `glove-agentd status` (prints the slot table). Also produces the `statusHandler` wiring: registry changes save state, render a frame, and push it to the HID writer; inbound `protocol.Jump` messages call the executor.

- [ ] **Step 1: Write the binary**

`cmd/glove-agentd/main.go`:

```go
// glove-agentd tracks Claude Code sessions and drives Glove80 status LEDs.
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
	"syscall"
	"time"

	"github.com/calvin-barker/glove-agentd/internal/config"
	"github.com/calvin-barker/glove-agentd/internal/hidio"
	"github.com/calvin-barker/glove-agentd/internal/ingest"
	"github.com/calvin-barker/glove-agentd/internal/jump"
	"github.com/calvin-barker/glove-agentd/internal/liveness"
	"github.com/calvin-barker/glove-agentd/internal/protocol"
	"github.com/calvin-barker/glove-agentd/internal/state"

	"github.com/sstallion/go-hid"
)

type app struct {
	cfg     config.Config
	reg     *state.Registry
	palette state.Palette
	writer  *hidio.Writer
}

func (a *app) HandleEvent(e state.Event) { a.reg.Apply(e) }

type statusReply struct {
	Slots []slotRow `json:"slots"`
}

type slotRow struct {
	Slot     int    `json:"slot"`
	Session  string `json:"session"`
	State    string `json:"state"`
	Location string `json:"location"`
	CWD      string `json:"cwd"`
}

func (a *app) StatusJSON() []byte {
	var rows []slotRow
	for i := 1; i <= protocol.NumSlots; i++ {
		s, ok := a.reg.Resolve(i)
		if !ok {
			continue
		}
		loc := s.TmuxSession
		if loc == "" {
			loc = "iterm:" + s.ITermID
		}
		rows = append(rows, slotRow{Slot: i, Session: s.ID, State: s.State.String(), Location: loc, CWD: s.CWD})
	}
	blob, _ := json.Marshal(statusReply{Slots: rows})
	return blob
}

func (a *app) pushFrame() {
	f := a.reg.Frame(a.palette)
	a.writer.SetFrame(protocol.EncodeSetLEDs(f))
	if err := a.reg.Save(a.cfg.StatePath); err != nil {
		log.Printf("state: save failed: %v", err)
	}
}

func runDaemon() error {
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

	reg, err := state.Load(cfg.StatePath, cfg.SlotCap, time.Now)
	if err != nil {
		return err
	}
	heartbeat := time.NewTicker(time.Duration(cfg.HeartbeatSec) * time.Second)
	defer heartbeat.Stop()
	writer := hidio.New(hidio.OpenGlove80, heartbeat.C)

	a := &app{cfg: cfg, reg: reg, palette: palette, writer: writer}
	reg.SetOnChange(a.pushFrame)

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	l, err := ingest.Listen(cfg.SocketPath)
	if err != nil {
		return err
	}
	go ingest.Serve(ctx, l, a)
	go writer.Run(ctx)
	go liveness.Poll(ctx, time.Duration(cfg.PollIntervalSec)*time.Second, reg, liveness.KillProber{})

	exec := jump.New(reg, jump.ExecRunner{})
	go func() {
		for msg := range writer.Inbound() {
			if j, ok := msg.(protocol.Jump); ok {
				if err := exec.Jump(j.Slot); err != nil {
					log.Printf("jump: slot %d: %v", j.Slot, err)
				}
			}
		}
	}()

	liveness.CheckOnce(reg, liveness.KillProber{}) // re-verify restored sessions
	a.pushFrame()
	log.Printf("glove-agentd running: socket=%s slots=%d", cfg.SocketPath, cfg.SlotCap)
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
	conn.Write([]byte(`{"type":"status"}` + "\n"))
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
		fmt.Println("no active sessions")
		return nil
	}
	fmt.Printf("%-4s %-12s %-12s %-24s %s\n", "SLOT", "STATE", "SESSION", "LOCATION", "CWD")
	for _, r := range reply.Slots {
		id := r.Session
		if len(id) > 10 {
			id = id[:10]
		}
		fmt.Printf("%-4d %-12s %-12s %-24s %s\n", r.Slot, r.State, id, r.Location, r.CWD)
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

- [ ] **Step 2: Build and smoke-test without a keyboard**

```bash
go build -o glove-agentd ./cmd/glove-agentd
./glove-agentd run &
sleep 1
echo '{"session_id":"smoke1","hook_event_name":"Notification","cwd":"/tmp","pid":'$$'}' | go run ./cmd/glove-agent-hook
sleep 1
./glove-agentd status
kill %1
```

Expected: daemon logs `glove-agentd running`, HID open failures are logged and retried quietly, and `status` prints a table with slot 1 in state `needs input`.

- [ ] **Step 3: Commit**

```bash
git add cmd/glove-agentd/
git commit -m "feat: daemon binary wiring run and status subcommands"
```

---

### Task 14: End-to-end integration test

**Files:**
- Test: `test/integration_test.go`

**Interfaces:**
- Consumes: every package; constructs the same wiring as `main.go` but with a fake HID device and fake command runner.

- [ ] **Step 1: Write the failing test**

`test/integration_test.go`:

```go
package test

import (
	"context"
	"net"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/calvin-barker/glove-agentd/internal/hidio"
	"github.com/calvin-barker/glove-agentd/internal/ingest"
	"github.com/calvin-barker/glove-agentd/internal/jump"
	"github.com/calvin-barker/glove-agentd/internal/protocol"
	"github.com/calvin-barker/glove-agentd/internal/state"
)

type fakeDevice struct {
	mu      sync.Mutex
	frames  [][]byte
	reports [][]byte
}

func (d *fakeDevice) Write(p []byte) (int, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.frames = append(d.frames, append([]byte(nil), p...))
	return len(p), nil
}

func (d *fakeDevice) ReadWithTimeout(p []byte, _ time.Duration) (int, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if len(d.reports) == 0 {
		return 0, nil
	}
	r := d.reports[0]
	d.reports = d.reports[1:]
	copy(p, r)
	return len(r), nil
}

func (d *fakeDevice) Close() error { return nil }

func (d *fakeDevice) lastFrame() []byte {
	d.mu.Lock()
	defer d.mu.Unlock()
	if len(d.frames) == 0 {
		return nil
	}
	return d.frames[len(d.frames)-1]
}

type recordingRunner struct {
	mu    sync.Mutex
	calls []string
}

func (r *recordingRunner) Output(name string, args ...string) (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.calls = append(r.calls, name+" "+strings.Join(args, " "))
	if name == "tmux" {
		return "/dev/ttys009\n", nil
	}
	return "", nil
}

type handler struct {
	reg *state.Registry
}

func (h *handler) HandleEvent(e state.Event) { h.reg.Apply(e) }
func (h *handler) StatusJSON() []byte        { return []byte(`{}`) }

func TestHookEventToLEDFrameToJump(t *testing.T) {
	dev := &fakeDevice{}
	hb := make(chan time.Time)
	writer := hidio.New(func() (hidio.Device, error) { return dev, nil }, hb)
	reg := state.NewRegistry(5, time.Now)
	palette := state.Palette{Amber: protocol.RGB{R: 0xFF, G: 0xB0}}
	reg.SetOnChange(func() {
		writer.SetFrame(protocol.EncodeSetLEDs(reg.Frame(palette)))
	})

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go writer.Run(ctx)

	sock := filepath.Join(t.TempDir(), "agentd.sock")
	l, err := ingest.Listen(sock)
	if err != nil {
		t.Fatal(err)
	}
	go ingest.Serve(ctx, l, &handler{reg: reg})

	runner := &recordingRunner{}
	exec := jump.New(reg, runner)
	go func() {
		for msg := range writer.Inbound() {
			if j, ok := msg.(protocol.Jump); ok {
				exec.Jump(j.Slot)
			}
		}
	}()

	// 1. A hook event arrives over the socket.
	conn, err := net.Dial("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	conn.Write([]byte(`{"session_id":"s1","hook_event_name":"SessionStart","pid":1,"tmux_session":"work"}` + "\n"))
	conn.Write([]byte(`{"session_id":"s1","hook_event_name":"Notification"}` + "\n"))
	conn.Close()

	// 2. The LED frame goes amber on slot 1.
	waitFor(t, func() bool {
		f := dev.lastFrame()
		return f != nil && f[3] == 0xFF && f[4] == 0xB0 // 0x00 report id, ver, cmd, then R G
	})

	// 3. The keyboard sends JUMP slot 1 and the executor runs tmux + osascript.
	report := make([]byte, protocol.ReportSize)
	report[0], report[1], report[2] = protocol.Version, protocol.CmdJump, 1
	dev.mu.Lock()
	dev.reports = append(dev.reports, report)
	dev.mu.Unlock()

	waitFor(t, func() bool {
		runner.mu.Lock()
		defer runner.mu.Unlock()
		return len(runner.calls) >= 2 &&
			strings.HasPrefix(runner.calls[0], "tmux list-clients -t work") &&
			strings.HasPrefix(runner.calls[1], "osascript")
	})
}

func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !cond() && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if !cond() {
		t.Fatal("condition never met")
	}
}
```

- [ ] **Step 2: Run test to verify it fails or passes for the right reason**

Run: `go test ./test/ -v`
Expected: PASS if Tasks 1-13 are correct. If it fails, the failure names the first broken seam (frame bytes, socket wiring, or the jump chain); fix the seam, not the test. This test exists to lock the whole pipeline.

- [ ] **Step 3: Run the full suite**

Run: `go test ./...`
Expected: PASS across all packages.

- [ ] **Step 4: Commit**

```bash
git add test/
git commit -m "test: end-to-end pipeline from hook event to LED frame to jump"
```

---

### Task 15: launchd, hooks config, and README

**Files:**
- Create: `dist/com.calvin-barker.glove-agentd.plist`
- Create: `dist/claude-hooks-snippet.json`
- Create: `README.md`

**Interfaces:**
- Consumes: the two binaries.
- Produces: install artifacts and documentation. No code.

- [ ] **Step 1: Write the launchd plist**

`dist/com.calvin-barker.glove-agentd.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.calvin-barker.glove-agentd</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/local/bin/glove-agentd</string>
		<string>run</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>/tmp/glove-agentd.log</string>
	<key>StandardErrorPath</key>
	<string>/tmp/glove-agentd.log</string>
</dict>
</plist>
```

- [ ] **Step 2: Write the Claude Code hooks snippet**

`dist/claude-hooks-snippet.json` (merge into the `"hooks"` key of `~/.claude/settings.json`):

```json
{
  "hooks": {
    "SessionStart": [
      {"hooks": [{"type": "command", "command": "/usr/local/bin/glove-agent-hook"}]}
    ],
    "UserPromptSubmit": [
      {"hooks": [{"type": "command", "command": "/usr/local/bin/glove-agent-hook"}]}
    ],
    "Notification": [
      {"hooks": [{"type": "command", "command": "/usr/local/bin/glove-agent-hook"}]}
    ],
    "Stop": [
      {"hooks": [{"type": "command", "command": "/usr/local/bin/glove-agent-hook"}]}
    ],
    "SessionEnd": [
      {"hooks": [{"type": "command", "command": "/usr/local/bin/glove-agent-hook"}]}
    ]
  }
}
```

- [ ] **Step 3: Write the README**

`README.md`:

```markdown
# glove-agentd

Drives agent status LEDs on a Glove80 keyboard from Claude Code session
state, and jumps to the right tmux/iTerm2 session when a lit key is
pressed. Requires the agent-status firmware on the keyboard, wired USB.

LED semantics are dark by default: a light means a human is needed.
Amber = needs input, green = idle after finishing a turn, red = session
died. Working sessions and empty slots stay dark.

## Install

    go build -o glove-agentd ./cmd/glove-agentd
    go build -o glove-agent-hook ./cmd/glove-agent-hook
    sudo cp glove-agentd glove-agent-hook /usr/local/bin/
    cp dist/com.calvin-barker.glove-agentd.plist ~/Library/LaunchAgents/
    launchctl load ~/Library/LaunchAgents/com.calvin-barker.glove-agentd.plist

Merge `dist/claude-hooks-snippet.json` into `~/.claude/settings.json`.

The first jump will trigger a macOS Automation permission prompt
("glove-agentd wants to control iTerm2"). Approve it once.

## Verify

    glove-agentd status

Start a Claude Code session; its slot appears in the table and the
matching F-row LED lights when it needs you.

## Config

Optional `~/.config/glove-agentd/config.json`:

    {
      "slot_cap": 5,
      "poll_interval_sec": 5,
      "heartbeat_sec": 30,
      "amber": "FFB000",
      "green": "00C853",
      "red": "FF1744"
    }

Raise `slot_cap` to 10 once the phase 2 firmware (right half relay)
is flashed.
```

- [ ] **Step 4: Verify and commit**

```bash
plutil -lint dist/com.calvin-barker.glove-agentd.plist
python3 -m json.tool dist/claude-hooks-snippet.json > /dev/null && echo "hooks json ok"
git add dist/ README.md
git commit -m "docs: launchd unit, Claude hooks snippet, and install guide"
```

Expected: `plutil` prints `OK`, hooks json validates.

---

## Hardware acceptance walkthrough (manual, after the firmware plan ships)

Not a task, a checklist for the first live run:

1. `launchctl load` the daemon, plug in the keyboard, confirm `/tmp/glove-agentd.log` shows a successful HID open.
2. Start a Claude session inside tmux, give it a long prompt, walk away: LED stays dark while working, goes green at Stop.
3. Trigger a permission prompt: LED goes amber. Hold H, tap the lit F-key: iTerm focuses the right pane.
4. Detach the tmux session, jump again: a new iTerm tab attaches.
5. `kill -9` the claude process: LED goes red within 5 seconds. Jump clears it.
6. Unplug and replug the keyboard: the frame reappears within 30 seconds.
7. `launchctl unload` the daemon: LEDs clear within 120 seconds (firmware timeout).
```
