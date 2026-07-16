/// Test collateral coin for the Assay AAPL market (devnet demo; mintable via TreasuryCap).
module assay_markets::taapl {
    use sui::coin::{Self, TreasuryCap};
    public struct TAAPL has drop {}
    fun init(w: TAAPL, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tAAPL", b"Apple xStock", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TAAPL>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
