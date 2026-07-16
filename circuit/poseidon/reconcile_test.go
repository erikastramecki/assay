package poseidon

import (
	"math/big"
	"strings"
	"testing"

	iden3 "github.com/iden3/go-iden3-crypto/poseidon"
)

func TestBatchReconcile(t *testing.T) {
	laneStr := "421210617,1637814550,431291584,1953496675,369364366,1006647231,1866996710,48274474,475853519,766719301,209460128,156803433,548349625,139347276,174962960,1721084437,2,1452650278,1371598315,900534217,247034909,1097876273,883942418,247917708,237544049"
	want, _ := new(big.Int).SetString("013f16a8b02c1459bccec065cf53fa55318a909c4a5fc9ac452ebda268687415", 16)
	acc := big.NewInt(0)
	for _, s := range strings.Split(laneStr, ",") {
		v, _ := new(big.Int).SetString(strings.TrimSpace(s), 10)
		out, err := iden3.Hash([]*big.Int{acc, v})
		if err != nil { t.Fatal(err) }
		acc = out
	}
	if acc.Cmp(want) != 0 {
		t.Fatalf("poseidon-fold(25 lanes) = %x\n want proof public input %x", acc, want)
	}
	t.Logf("poseidon-fold(25 lanes) == proof public input ✓ (on-chain sui::poseidon will match)")
}
