package poseidon

import (
	"math/big"
	"testing"

	"github.com/consensys/gnark-crypto/ecc"
	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/test"
	iden3 "github.com/iden3/go-iden3-crypto/poseidon"
)

type twoInCircuit struct {
	In0, In1 frontend.Variable
	Out      frontend.Variable `gnark:",public"`
}

func (c *twoInCircuit) Define(api frontend.API) error {
	api.AssertIsEqual(PoseidonBn254(api, []frontend.Variable{c.In0, c.In1}), c.Out)
	return nil
}

func TestGadgetMatchesIden3(t *testing.T) {
	for _, p := range [][2]int64{{1, 2}, {7, 99}, {123456789, 987654321}, {0, 0}} {
		a, b := big.NewInt(p[0]), big.NewInt(p[1])
		want, err := iden3.Hash([]*big.Int{a, b})
		if err != nil { t.Fatal(err) }
		if err := test.IsSolved(&twoInCircuit{}, &twoInCircuit{In0: a, In1: b, Out: want}, ecc.BN254.ScalarField()); err != nil {
			t.Fatalf("gadget != iden3 for %v: %v", p, err)
		}
		t.Logf("in-circuit poseidon(%d,%d) == iden3 native ✓", p[0], p[1])
	}
}
