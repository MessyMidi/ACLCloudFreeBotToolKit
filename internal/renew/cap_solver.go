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
	"math/big"
	"net/http"
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

type capChallengeSolver func(context.Context, hashwxPayload) (capSolution, error)

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
		func(challengeCtx context.Context, payload hashwxPayload) (capSolution, error) {
			return solveHashwxChallengeWithCache(challengeCtx, payload, cache)
		},
	)
	return client.fetchToken(ctx)
}

// solveCaptcha preserves the renewer's existing integration point while the
// current ACLClouds CAPTCHA no longer uses the old image challenge context.
func solveCaptcha(ctx context.Context, s *session, _ string) (string, error) {
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

	solutions := make([]capSolution, len(challenge.Challenges))
	errs := make([]error, len(challenge.Challenges))
	var workers sync.WaitGroup
	for index, item := range challenge.Challenges {
		if item.Protocol != "hashwx" {
			errs[index] = fmt.Errorf("unsupported protocol %q", item.Protocol)
			continue
		}
		workers.Add(1)
		go func(index int, payload hashwxPayload) {
			defer workers.Done()
			solutions[index], errs[index] = c.solve(ctx, payload)
		}(index, item.Payload)
	}
	workers.Wait()

	for index, err := range errs {
		if err != nil {
			return "", fmt.Errorf("Cap challenge %d: %w", index, err)
		}
	}

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
	return solveHashwxChallengeWithCache(ctx, payload, cache)
}

func solveHashwxChallengeWithCache(
	ctx context.Context,
	payload hashwxPayload,
	cache wazero.CompilationCache,
) (capSolution, error) {
	runtimeConfig := wazero.NewRuntimeConfig().
		WithCloseOnContextDone(true).
		WithCompilationCache(cache)
	runtime := wazero.NewRuntimeWithConfig(ctx, runtimeConfig)
	defer runtime.Close(context.Background())

	solver, err := newHashwxSolverOn(ctx, runtime, embeddedHashwxWASM)
	if err != nil {
		return capSolution{}, err
	}
	defer solver.close()
	nonce, _, err := solver.solve(payload)
	if err != nil {
		return capSolution{}, err
	}
	return capSolution{Nonce: fmt.Sprintf("%d", nonce)}, nil
}

type hashwxSolver struct {
	ctx         context.Context
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
	runtimeConfig := wazero.NewRuntimeConfig().WithCloseOnContextDone(true)
	runtime := wazero.NewRuntimeWithConfig(ctx, runtimeConfig)
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

// solve walks hashwx blocks until a nonce hashes at or below
// (2^64-1)/difficulty. Difficulty, block size and challenge bytes always come
// from the server response; none are fixed to current production values.
func (s *hashwxSolver) solve(payload hashwxPayload) (uint64, uint64, error) {
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

	var hashes uint64
	for block := uint64(0); block <= 1<<20; block++ {
		if err := s.ctx.Err(); err != nil {
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
