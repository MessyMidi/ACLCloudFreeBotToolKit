// ACLCloudFreeBotToolKit
// Copyright (C) 2026 MessyMidi
//
// SPDX-License-Identifier: AGPL-3.0-only
// Additional terms under AGPLv3 Section 7:
// see /ADDITIONAL_TERMS.md

package renew

import (
	"bytes"
	"context"
	"crypto/sha256"
	_ "embed"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math/big"
	"net/http"
	"os"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
)

const (
	capAPIEndpoint       = "https://cap.aclclouds.com/235a82a3e3/"
	capSiteOrigin        = "https://aclclouds.com"
	capMaxChallenges     = 8
	capMaxDifficulty     = 100_000_000
	capMaxNoncesPerBlock = 1 << 20
	capUserAgent         = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
		"(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

	// capSolveBudget bounds a single hashwx challenge on the wasm layer's own
	// terms, independent of the caller's context. wazero's CloseOnContextDone
	// closes a module permanently the moment the context passed to Call is
	// done, so inheriting the caller's deadline turns "the overall check ran
	// long" into an unrecoverable "module closed" in every worker at once.
	//
	// At production difficulty four concurrent challenges finish in seconds;
	// this ceiling exists only to stop a runaway generated module from pinning
	// a worker forever.
	capSolveBudget = 45 * time.Second

	// capMaxShardsPerChallenge caps how far one challenge's nonce space is
	// split. Sharding stops paying off well before this, and every shard costs
	// a full wazero runtime with its own linear memory.
	capMaxShardsPerChallenge = 8

	// capProgressInterval is how often a still-unfinished solve reports that it
	// is still working. A healthy solve finishes in a couple of seconds, so
	// anything shorter would only ever cry wolf.
	capProgressInterval = 3 * time.Second

	// capSolveGrace is how long the wait may outlast the solver's own budget
	// before the whole attempt is abandoned. With CloseOnContextDone off there
	// is nothing that can interrupt a wedged wasm call, so the wait has to be
	// bounded from the outside.
	capSolveGrace = 5 * time.Second
)

// hashwx.wasm is the official @cap.js/wasm v0.0.8 browser kernel. Embedding
// it keeps the renewal helper self-contained and avoids executing downloaded
// code at runtime.
//
//go:embed hashwx.wasm
var embeddedHashwxWASM []byte

type captchaSolverFunc func(context.Context) (string, error)

type capChallenge struct {
	Token      string                 `json:"token"`
	Format     int                    `json:"format"`
	Expires    int64                  `json:"expires"`
	Challenges []capProtocolChallenge `json:"challenges"`
}

type capProtocolChallenge struct {
	Protocol string        `json:"protocol"`
	Payload  hashwxPayload `json:"payload"`
}

type hashwxPayload struct {
	Challenge  string `json:"c"`
	Difficulty int    `json:"d"`
	BlockSize  int    `json:"n"`
}

type capSolution struct {
	Nonce string `json:"nonce,omitempty"`
	Y     string `json:"y,omitempty"`
}

type capRedeemResponse struct {
	Success bool   `json:"success"`
	Token   string `json:"token"`
	Expires int64  `json:"expires"`
	Error   string `json:"error"`
}

// capChallengeSolver solves one shard of one challenge. A challenge's nonce
// space is split across `shards` workers, each searching the blocks congruent
// to its own index; the first shard to produce a valid nonce wins and its
// siblings are cancelled.
type capChallengeSolver func(ctx context.Context, payload hashwxPayload, shard, shards int) (capSolution, error)

type capClient struct {
	httpClient *http.Client
	endpoint   string
	solve      capChallengeSolver
}

func newCapClient(httpClient *http.Client, endpoint string, solve capChallengeSolver) *capClient {
	return &capClient{
		httpClient: httpClient,
		endpoint:   strings.TrimRight(endpoint, "/") + "/",
		solve:      solve,
	}
}

func fetchCapToken(ctx context.Context) (string, error) {
	cache := wazero.NewCompilationCache()
	defer cache.Close(context.Background())

	client := newCapClient(
		&http.Client{Timeout: 60 * time.Second},
		capAPIEndpoint,
		func(challengeCtx context.Context, payload hashwxPayload, shard, shards int) (capSolution, error) {
			return solveHashwxChallengeWithCache(challengeCtx, payload, shard, shards, cache)
		},
	)
	return client.fetchToken(ctx)
}

// capWorkerBudget returns how many hashwx workers may run at once.
//
// It reads GOMAXPROCS rather than NumCPU on purpose: a container's CPU quota is
// what GOMAXPROCS reflects, while NumCPU reports the host's cores even when the
// process is pinned to half of one. Getting this backwards would size the
// worker pool for a machine the process cannot actually use.
//
// ACL_CAPTCHA_WORKERS overrides the whole calculation, for hosts where even the
// container-aware value is wrong.
func capWorkerBudget() int {
	if override := strings.TrimSpace(os.Getenv("ACL_CAPTCHA_WORKERS")); override != "" {
		if n, err := strconv.Atoi(override); err == nil && n > 0 {
			return n
		}
	}
	budget := runtime.GOMAXPROCS(0)
	if host := runtime.NumCPU(); host < budget {
		budget = host
	}
	if budget < 1 {
		budget = 1
	}
	return budget
}

// capChallengeShards decides how many workers split each challenge's nonce
// space. Hashwx throughput scales with cores but not linearly: measured on a
// 16-thread host, four workers reached 773k hash/s, eight 1.28M and sixteen
// 1.38M, while thirty-two regressed. Aiming one worker per usable CPU is
// therefore near optimal.
//
// Overshooting is not catastrophic -- pinned to GOMAXPROCS=1, one through four
// workers all landed within 6% of each other -- but every extra shard costs a
// full wazero runtime with its own linear memory, which on a fraction of a CPU
// is the resource actually worth protecting.
func capChallengeShards(challenges int) int {
	if challenges < 1 {
		return 1
	}
	shards := capWorkerBudget() / challenges
	if shards < 1 {
		return 1
	}
	if shards > capMaxShardsPerChallenge {
		return capMaxShardsPerChallenge
	}
	return shards
}

// solveCaptcha produces a Cap token for the current ACLClouds CAPTCHA.
func solveCaptcha(ctx context.Context, s *session) (string, error) {
	if s == nil || s.captchaSolver == nil {
		return "", errors.New("CAPTCHA solver is not configured")
	}
	token, err := s.captchaSolver(ctx)
	if err != nil {
		return "", err
	}
	if strings.TrimSpace(token) == "" {
		return "", errors.New("CAPTCHA solver returned an empty token")
	}
	return token, nil
}

func (c *capClient) fetchToken(ctx context.Context) (string, error) {
	if c == nil || c.httpClient == nil || c.solve == nil {
		return "", errors.New("invalid Cap client configuration")
	}

	started := time.Now()
	var challenge capChallenge
	if err := c.postJSON(ctx, "challenge", map[string]any{}, &challenge); err != nil {
		return "", fmt.Errorf("Cap challenge: %w", err)
	}
	if challenge.Token == "" {
		return "", errors.New("Cap challenge did not include a token")
	}
	if challenge.Format != 2 {
		return "", fmt.Errorf("unsupported Cap format %d", challenge.Format)
	}
	if len(challenge.Challenges) == 0 || len(challenge.Challenges) > capMaxChallenges {
		return "", fmt.Errorf("invalid Cap challenge count %d", len(challenge.Challenges))
	}

	shards := capChallengeShards(len(challenge.Challenges))
	budget := capWorkerBudget()
	log.Printf("[renew] CAPTCHA: challenge fetched in %v (format=%d challenges=%d difficulty=%d block=%d)",
		time.Since(started).Round(time.Millisecond), challenge.Format, len(challenge.Challenges),
		challenge.Challenges[0].Payload.Difficulty, challenge.Challenges[0].Payload.BlockSize)
	log.Printf("[renew] CAPTCHA: %d shard(s) per challenge = %d workers, %d at a time (GOMAXPROCS=%d NumCPU=%d)",
		shards, len(challenge.Challenges)*shards, budget, runtime.GOMAXPROCS(0), runtime.NumCPU())

	// Bounds how many wazero runtimes exist simultaneously. On a fraction of a
	// CPU the extra workers buy no throughput, so the budget is what keeps
	// several copies of the module's linear memory from being held at once.
	semaphore := make(chan struct{}, budget)

	count := len(challenge.Challenges)
	solutions := make([]capSolution, count)
	errs := make([]error, count)
	settled := make([]bool, count)
	shardCtxs := make([]context.Context, count)
	stops := make([]context.CancelFunc, count)

	for index, item := range challenge.Challenges {
		if item.Protocol != "hashwx" {
			errs[index] = fmt.Errorf("unsupported protocol %q", item.Protocol)
			continue
		}
		shardCtxs[index], stops[index] = context.WithCancel(ctx)
	}
	// Losing shards are cancelled through this context, which the solver polls
	// between blocks instead of handing to wasm.
	defer func() {
		for _, stop := range stops {
			if stop != nil {
				stop()
			}
		}
	}()

	var mutex sync.Mutex
	var workers sync.WaitGroup
	solveStart := time.Now()
	progressDone := make(chan struct{})

	// Reporting separately keeps the log honest about where the time goes: a
	// challenge that is still hashing looks nothing like a slow HTTP round trip.
	go func() {
		ticker := time.NewTicker(capProgressInterval)
		defer ticker.Stop()
		for {
			select {
			case <-progressDone:
				return
			case <-ticker.C:
				mutex.Lock()
				var pending []int
				for index := range settled {
					if !settled[index] && errs[index] == nil && stops[index] != nil {
						pending = append(pending, index)
					}
				}
				mutex.Unlock()
				if len(pending) > 0 {
					log.Printf("[renew] CAPTCHA: still hashing challenge(s) %v after %v",
						pending, time.Since(solveStart).Round(100*time.Millisecond))
				}
			}
		}
	}()

	for index, item := range challenge.Challenges {
		if stops[index] == nil {
			continue
		}
		for shard := 0; shard < shards; shard++ {
			workers.Add(1)
			go func(index, shard int, payload hashwxPayload, shardCtx context.Context, stop context.CancelFunc) {
				defer workers.Done()

				// Hold a slot for the whole solve, not just for the schedule: the
				// cost being bounded is a live runtime, not a runnable goroutine.
				select {
				case semaphore <- struct{}{}:
					defer func() { <-semaphore }()
				case <-shardCtx.Done():
					return
				}

				solution, err := c.solve(shardCtx, payload, shard, shards)

				mutex.Lock()
				defer mutex.Unlock()
				if err != nil {
					// Hold on to the first failure, for a challenge nobody solves.
					if !settled[index] && errs[index] == nil {
						errs[index] = err
					}
					return
				}
				if settled[index] {
					return
				}
				settled[index] = true
				solutions[index] = solution
				errs[index] = nil
				stop() // the siblings have nothing left to find
			}(index, shard, item.Payload, shardCtxs[index], stops[index])
		}
	}
	// Nothing can interrupt a wedged wasm call, so the wait is bounded from the
	// outside too: one hung shard must not hang the whole renewal check.
	finished := make(chan struct{})
	go func() {
		workers.Wait()
		close(finished)
	}()

	select {
	case <-finished:
	case <-time.After(capSolveBudget + capSolveGrace):
		return "", fmt.Errorf("Cap solving did not finish within %v", capSolveBudget+capSolveGrace)
	}
	close(progressDone)

	solved := 0
	for _, ok := range settled {
		if ok {
			solved++
		}
	}
	log.Printf("[renew] CAPTCHA: %d/%d challenges solved in %v",
		solved, count, time.Since(solveStart).Round(time.Millisecond))

	for index, err := range errs {
		if err != nil {
			return "", fmt.Errorf("Cap challenge %d: %w", index, err)
		}
	}

	redeemStart := time.Now()
	var redeem capRedeemResponse
	if err := c.postJSON(ctx, "redeem", map[string]any{
		"token":     challenge.Token,
		"solutions": solutions,
	}, &redeem); err != nil {
		return "", fmt.Errorf("Cap redeem: %w", err)
	}
	if !redeem.Success {
		return "", errors.New("Cap redeem was rejected")
	}
	if strings.TrimSpace(redeem.Token) == "" {
		return "", errors.New("Cap redeem returned an empty token")
	}
	log.Printf("[renew] CAPTCHA: token redeemed in %v (total %v)",
		time.Since(redeemStart).Round(time.Millisecond), time.Since(started).Round(time.Millisecond))
	return redeem.Token, nil
}

func (c *capClient) postJSON(ctx context.Context, path string, body, destination any) error {
	payload, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("encode request: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.endpoint+path, bytes.NewReader(payload))
	if err != nil {
		return fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json, text/plain, */*")
	req.Header.Set("User-Agent", capUserAgent)
	req.Header.Set("Origin", capSiteOrigin)
	req.Header.Set("Referer", capSiteOrigin+"/")

	response, err := c.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("request failed: %w", err)
	}
	defer response.Body.Close()
	contents, err := io.ReadAll(io.LimitReader(response.Body, maxResponseBytes))
	if err != nil {
		return fmt.Errorf("read response: %w", err)
	}
	if response.StatusCode != http.StatusOK {
		// The response may contain one-time challenge or redemption material;
		// never include its body in logs or returned errors.
		return fmt.Errorf("HTTP %d", response.StatusCode)
	}
	if err := json.Unmarshal(contents, destination); err != nil {
		return fmt.Errorf("decode response: %w", err)
	}
	return nil
}

func solveHashwxChallenge(ctx context.Context, payload hashwxPayload) (capSolution, error) {
	cache := wazero.NewCompilationCache()
	defer cache.Close(context.Background())
	return solveHashwxChallengeWithCache(ctx, payload, 0, 1, cache)
}

func solveHashwxChallengeWithCache(
	ctx context.Context,
	payload hashwxPayload,
	shard, shards int,
	cache wazero.CompilationCache,
) (capSolution, error) {
	// The wasm layer runs on a budget it owns. ctx is only polled between
	// blocks, so a caller that gives up stops the search without tearing the
	// module down mid-instruction.
	solveCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), capSolveBudget)
	defer cancel()

	// CloseOnContextDone is deliberately NOT enabled. wazero inserts a periodic
	// context check into every compiled function when it is, and that check
	// lands inside the per-hash loop: measured on this machine, 57.5k hash/s
	// with the guard against 280k without, a 4.87x tax on the whole solve.
	//
	// What the guard buys is a way to interrupt a wedged module, which hashwx
	// does not need. The kernel is the pinned official build (hash-checked by
	// TestEmbeddedHashwxArtifactAndInputValidation) and every call performs a
	// fixed amount of work, so a runaway search is caught between blocks by
	// budgetErr and callerErr, and a genuinely hung shard is abandoned by the
	// bounded wait in fetchToken.
	runtimeConfig := wazero.NewRuntimeConfig().WithCompilationCache(cache)
	runtime := wazero.NewRuntimeWithConfig(solveCtx, runtimeConfig)
	defer runtime.Close(context.Background())

	solver, err := newHashwxSolverOn(solveCtx, runtime, embeddedHashwxWASM)
	if err != nil {
		return capSolution{}, err
	}
	solver.caller = ctx
	defer solver.close()
	nonce, _, err := solver.solveShard(payload, uint64(shard), uint64(shards))
	if err != nil {
		return capSolution{}, err
	}
	return capSolution{Nonce: fmt.Sprintf("%d", nonce)}, nil
}

type hashwxSolver struct {
	// ctx bounds the module and every Call made on it. Because
	// CloseOnContextDone is enabled, wazero closes the module for good the
	// moment this context is done, so it must be a budget this layer owns --
	// never the caller's.
	ctx context.Context
	// caller is the optional cancellation source, polled between blocks so an
	// abandoned search stops early without destroying the module. Nil means no
	// caller signal.
	caller      context.Context
	runtime     wazero.Runtime
	main        api.Module
	contextID   uint32
	compiled    bool
	seedPtr     uint32
	registers   uint32
	memoryPtr   uint32
	execBegin   api.Function
	execFinal   api.Function
	exec        api.Function
	make        api.Function
	module      api.Function
	moduleSize  api.Function
	ownsRuntime bool
}

func newHashwxSolver(ctx context.Context, wasm []byte) (*hashwxSolver, error) {
	if len(wasm) == 0 {
		return nil, errors.New("hashwx WASM is empty")
	}
	// Same configuration as the production path: no CloseOnContextDone.
	runtime := wazero.NewRuntime(ctx)
	solver, err := newHashwxSolverOn(ctx, runtime, wasm)
	if err != nil {
		_ = runtime.Close(context.Background())
		return nil, err
	}
	solver.ownsRuntime = true
	return solver, nil
}

// newHashwxSolverOn creates a solver on a caller-owned runtime. Every
// concurrently solved challenge must use a distinct runtime because the
// generated hashwx module imports memory from a module hard-coded as "env".
// CompilationCache may be shared across those runtimes; module instances may
// not be shared.
func newHashwxSolverOn(ctx context.Context, runtime wazero.Runtime, wasm []byte) (*hashwxSolver, error) {
	if len(wasm) == 0 {
		return nil, errors.New("hashwx WASM is empty")
	}
	mainModule, err := runtime.InstantiateWithConfig(ctx, wasm, wazero.NewModuleConfig().WithName("env"))
	if err != nil {
		return nil, fmt.Errorf("instantiate hashwx WASM: %w", err)
	}

	solver := &hashwxSolver{ctx: ctx, runtime: runtime, main: mainModule}
	if initialize := mainModule.ExportedFunction("_initialize"); initialize != nil {
		if _, err := initialize.Call(ctx); err != nil {
			solver.close()
			return nil, fmt.Errorf("initialize hashwx WASM: %w", err)
		}
	}

	contextID, err := solver.call("hashwx_alloc", 1)
	if err != nil {
		solver.close()
		return nil, err
	}
	solver.contextID = uint32(contextID)
	solver.compiled = true
	if solver.contextID == 0 || solver.contextID == ^uint32(0) {
		solver.compiled = false
		contextID, err = solver.call("hashwx_alloc", 0)
		if err != nil {
			solver.close()
			return nil, err
		}
		solver.contextID = uint32(contextID)
	}
	if solver.contextID == 0 || solver.contextID == ^uint32(0) {
		solver.close()
		return nil, errors.New("hashwx_alloc failed")
	}

	if err := solver.loadExports(); err != nil {
		solver.close()
		return nil, err
	}
	return solver, nil
}

func (s *hashwxSolver) loadExports() error {
	var err error
	if s.seedPtr, err = s.pointer("hashwx_seed"); err != nil {
		return err
	}
	if s.registers, err = s.pointer("hashwx_registers"); err != nil {
		return err
	}
	if s.memoryPtr, err = s.pointer("hashwx_memory"); err != nil {
		return err
	}
	s.make = s.main.ExportedFunction("hashwx_make")
	if s.make == nil {
		return errors.New("hashwx export \"hashwx_make\" is missing")
	}
	if s.compiled {
		s.execBegin = s.main.ExportedFunction("hashwx_exec_begin")
		s.execFinal = s.main.ExportedFunction("hashwx_exec_final")
		s.module = s.main.ExportedFunction("hashwx_module")
		s.moduleSize = s.main.ExportedFunction("hashwx_module_size")
		if s.execBegin == nil || s.execFinal == nil || s.module == nil || s.moduleSize == nil {
			return errors.New("compiled hashwx exports are incomplete")
		}
	} else {
		s.exec = s.main.ExportedFunction("hashwx_exec")
		if s.exec == nil {
			return errors.New("hashwx export \"hashwx_exec\" is missing")
		}
	}
	if s.main.Memory() == nil {
		return errors.New("hashwx WASM does not export memory")
	}
	return nil
}

func (s *hashwxSolver) call(name string, args ...uint64) (uint64, error) {
	function := s.main.ExportedFunction(name)
	if function == nil {
		return 0, fmt.Errorf("hashwx export %q is missing", name)
	}
	results, err := function.Call(s.ctx, args...)
	if err != nil {
		return 0, err
	}
	if len(results) == 0 {
		return 0, nil
	}
	return results[0], nil
}

func (s *hashwxSolver) pointer(name string) (uint32, error) {
	value, err := s.call(name, uint64(s.contextID))
	return uint32(value), err
}

func (s *hashwxSolver) close() {
	if s == nil {
		return
	}
	if s.ownsRuntime && s.runtime != nil {
		_ = s.runtime.Close(context.Background())
	} else if s.main != nil {
		_ = s.main.Close(context.Background())
	}
}

// budgetErr reports whether this solver's own budget is spent. Spending it is
// the one case where wazero is allowed to close the module.
func (s *hashwxSolver) budgetErr() error {
	if err := s.ctx.Err(); err != nil {
		return fmt.Errorf("hashwx budget exhausted: %w", err)
	}
	return nil
}

// callerErr reports the caller's cancellation. It is deliberately polled
// between blocks rather than inherited through the solver: handing this
// context to wasm would let the caller's deadline close the module for good.
func (s *hashwxSolver) callerErr() error {
	if s.caller == nil {
		return nil
	}
	if err := s.caller.Err(); err != nil {
		return fmt.Errorf("hashwx solve abandoned: %w", err)
	}
	return nil
}

// solveShard searches only the blocks this worker owns: block ≡ shard (mod
// shards). Difficulty, block size and challenge bytes always come from the
// server response; none are fixed to current production values. Any nonce below
// the target wins, so separate shards legitimately return different nonces.
func (s *hashwxSolver) solveShard(payload hashwxPayload, shard, shards uint64) (uint64, uint64, error) {
	challenge, err := hex.DecodeString(payload.Challenge)
	if err != nil || len(challenge) != sha256.Size {
		return 0, 0, errors.New("invalid hashwx challenge")
	}
	if payload.Difficulty < 1 || payload.Difficulty > capMaxDifficulty {
		return 0, 0, fmt.Errorf("invalid hashwx difficulty %d", payload.Difficulty)
	}
	if payload.BlockSize < 1 || payload.BlockSize > capMaxNoncesPerBlock {
		return 0, 0, fmt.Errorf("invalid hashwx block size %d", payload.BlockSize)
	}

	maximum := new(big.Int).SetUint64(^uint64(0))
	target := new(big.Int).Div(maximum, big.NewInt(int64(payload.Difficulty))).Uint64()
	seedInput := make([]byte, sha256.Size+8)
	copy(seedInput, challenge)
	seed := make([]byte, sha256.Size)
	memory := s.main.Memory()
	blockSize := uint64(payload.BlockSize)

	if shards < 1 {
		shards = 1
	}

	var hashes uint64
	for block := shard; block <= 1<<20; block += shards {
		if err := s.budgetErr(); err != nil {
			return 0, hashes, err
		}
		if err := s.callerErr(); err != nil {
			return 0, hashes, err
		}
		binary.LittleEndian.PutUint64(seedInput[sha256.Size:], block)
		sum := sha256.Sum256(seedInput)
		copy(seed, sum[:])
		if !memory.Write(s.seedPtr, seed) {
			return 0, hashes, errors.New("write hashwx seed failed")
		}
		if _, err := s.make.Call(s.ctx, uint64(s.contextID), uint64(s.seedPtr)); err != nil {
			return 0, hashes, err
		}

		var nonce uint64
		var found bool
		var blockHashes uint64
		if s.compiled {
			nonce, blockHashes, found, err = s.solveCompiledBlock(block, blockSize, target)
		} else {
			nonce, blockHashes, found, err = s.solveInterpretedBlock(block, blockSize, target)
		}
		hashes += blockHashes
		if err != nil {
			return 0, hashes, err
		}
		if found {
			return nonce, hashes, nil
		}
	}
	return 0, hashes, errors.New("hashwx nonce search exhausted")
}

func (s *hashwxSolver) solveCompiledBlock(block, blockSize, target uint64) (uint64, uint64, bool, error) {
	modulePointer, err := s.module.Call(s.ctx, uint64(s.contextID))
	if err != nil || len(modulePointer) == 0 {
		return 0, 0, false, errors.New("read generated hashwx module pointer")
	}
	moduleSize, err := s.moduleSize.Call(s.ctx, uint64(s.contextID))
	if err != nil || len(moduleSize) == 0 {
		return 0, 0, false, errors.New("read generated hashwx module size")
	}
	moduleBytes, ok := s.main.Memory().Read(uint32(modulePointer[0]), uint32(moduleSize[0]))
	if !ok {
		return 0, 0, false, errors.New("read generated hashwx module")
	}
	moduleCopy := append([]byte(nil), moduleBytes...)
	compiledModule, err := s.runtime.CompileModule(s.ctx, moduleCopy)
	if err != nil {
		return 0, 0, false, fmt.Errorf("compile generated hashwx module: %w", err)
	}
	defer compiledModule.Close(s.ctx)
	sideModule, err := s.runtime.InstantiateModule(s.ctx, compiledModule, wazero.NewModuleConfig())
	if err != nil {
		return 0, 0, false, fmt.Errorf("instantiate generated hashwx module: %w", err)
	}
	defer sideModule.Close(s.ctx)
	sideExec := sideModule.ExportedFunction("exec")
	if sideExec == nil {
		return 0, 0, false, errors.New("generated hashwx module lacks exec")
	}

	base := block * blockSize
	for offset := uint64(0); offset < blockSize; offset++ {
		candidate := base + offset
		if _, err := s.execBegin.Call(s.ctx, uint64(s.contextID), candidate); err != nil {
			return 0, offset, false, err
		}
		if _, err := sideExec.Call(s.ctx, uint64(s.registers), uint64(s.memoryPtr)); err != nil {
			return 0, offset, false, err
		}
		result, err := s.execFinal.Call(s.ctx, uint64(s.contextID))
		if err != nil {
			return 0, offset, false, fmt.Errorf("finish hashwx execution: %w", err)
		}
		if len(result) == 0 {
			return 0, offset, false, errors.New("finish hashwx execution")
		}
		if result[0] <= target {
			return candidate, offset + 1, true, nil
		}
	}
	return 0, blockSize, false, nil
}

func (s *hashwxSolver) solveInterpretedBlock(block, blockSize, target uint64) (uint64, uint64, bool, error) {
	base := block * blockSize
	for offset := uint64(0); offset < blockSize; offset++ {
		candidate := base + offset
		result, err := s.exec.Call(s.ctx, uint64(s.contextID), candidate)
		if err != nil {
			return 0, offset, false, fmt.Errorf("execute hashwx: %w", err)
		}
		if len(result) == 0 {
			return 0, offset, false, errors.New("execute hashwx")
		}
		if result[0] <= target {
			return candidate, offset + 1, true, nil
		}
	}
	return 0, blockSize, false, nil
}
