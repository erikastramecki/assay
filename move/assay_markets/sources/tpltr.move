/// Test collateral coin for the Assay PLTR market (devnet demo; mintable via TreasuryCap).
module assay_markets::tpltr {
    use sui::coin::{Self, TreasuryCap};
    public struct TPLTR has drop {}
    fun init(w: TPLTR, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tPLTR", b"Palantir xStock", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TPLTR>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
