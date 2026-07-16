package poseidon

import (
	"math/big"

	"github.com/consensys/gnark/frontend"
	"github.com/iden3/go-iden3-crypto/ff"
)

// NROUNDSF / NROUNDSP — the iden3/circomlib Poseidon round counts (full / partial).
const nRoundsF = 8

var nRoundsP = []int{56, 57, 56, 60, 60, 63, 64, 63, 60, 66, 60, 65, 70, 60, 64, 68}

func toBig(e *ff.Element) *big.Int {
	b := new(big.Int)
	e.ToBigIntRegular(b)
	return b
}

// pow5 computes x^5 in-circuit.
func pow5(api frontend.API, x frontend.Variable) frontend.Variable {
	x2 := api.Mul(x, x)
	x4 := api.Mul(x2, x2)
	return api.Mul(x4, x)
}

// mix: newState[i] = Σ_j M[j][i] * state[j]  (matches iden3 `mix`).
func mix(api frontend.API, state []frontend.Variable, M [][]*ff.Element) []frontend.Variable {
	t := len(state)
	out := make([]frontend.Variable, t)
	for i := 0; i < t; i++ {
		acc := frontend.Variable(0)
		for j := 0; j < t; j++ {
			acc = api.Add(acc, api.Mul(state[j], toBig(M[j][i])))
		}
		out[i] = acc
	}
	return out
}

// PoseidonBn254 computes iden3/circomlib Poseidon over `inputs` in-circuit,
// bit-exact with sui::poseidon_bn254 (initState = 0). len(inputs) in [1,16].
func PoseidonBn254(api frontend.API, inputs []frontend.Variable) frontend.Variable {
	t := len(inputs) + 1
	rp := nRoundsP[t-2]
	C := c.c[t-2]
	S := c.s[t-2]
	M := c.m[t-2]
	P := c.p[t-2]

	state := make([]frontend.Variable, t)
	state[0] = frontend.Variable(0) // initState
	copy(state[1:], inputs)

	// ark(state, C, 0)
	for i := 0; i < t; i++ {
		state[i] = api.Add(state[i], toBig(C[i]))
	}
	// first half full rounds
	for i := 0; i < nRoundsF/2-1; i++ {
		for j := 0; j < t; j++ {
			state[j] = pow5(api, state[j])
		}
		for j := 0; j < t; j++ {
			state[j] = api.Add(state[j], toBig(C[(i+1)*t+j]))
		}
		state = mix(api, state, M)
	}
	for j := 0; j < t; j++ {
		state[j] = pow5(api, state[j])
	}
	for j := 0; j < t; j++ {
		state[j] = api.Add(state[j], toBig(C[(nRoundsF/2)*t+j]))
	}
	state = mix(api, state, P)

	// partial rounds (sparse)
	for i := 0; i < rp; i++ {
		state[0] = pow5(api, state[0])
		state[0] = api.Add(state[0], toBig(C[(nRoundsF/2+1)*t+i]))

		newState0 := frontend.Variable(0)
		for j := 0; j < t; j++ {
			newState0 = api.Add(newState0, api.Mul(state[j], toBig(S[(t*2-1)*i+j])))
		}
		for k := 1; k < t; k++ {
			state[k] = api.Add(state[k], api.Mul(state[0], toBig(S[(t*2-1)*i+t+k-1])))
		}
		state[0] = newState0
	}

	// second half full rounds
	for i := 0; i < nRoundsF/2-1; i++ {
		for j := 0; j < t; j++ {
			state[j] = pow5(api, state[j])
		}
		for j := 0; j < t; j++ {
			state[j] = api.Add(state[j], toBig(C[(nRoundsF/2+1)*t+rp+i*t+j]))
		}
		state = mix(api, state, M)
	}
	for j := 0; j < t; j++ {
		state[j] = pow5(api, state[j])
	}
	state = mix(api, state, M)

	return state[0]
}
