package poseidon

import (
	"math/big"
	"testing"

	iden3 "github.com/iden3/go-iden3-crypto/poseidon"
)

// Ground truth: iden3/circomlib Poseidon == what sui::poseidon_bn254 computes.
func TestIden3IsSuiPoseidon(t *testing.T) {
	want, _ := new(big.Int).SetString("7853200120776062878684798364095072458815029376092732009249414926327459813530", 10)
	got, err := iden3.Hash([]*big.Int{big.NewInt(1), big.NewInt(2)})
	if err != nil { t.Fatal(err) }
	if got.Cmp(want) != 0 { t.Fatalf("poseidon([1,2]) = %s, want %s", got, want) }
	t.Logf("iden3 poseidon([1,2]) == sui::poseidon_bn254 vector ✓")
}
